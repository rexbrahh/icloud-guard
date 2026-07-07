import Foundation

/// Layer 3: Active defense against rematerialization.
///
/// Uses `NSMetadataQuery` to watch iCloud Drive items for download status changes.
/// When an evicted item transitions from `.notDownloaded` to `.current` or `.downloaded`,
/// the watcher immediately re-evicts it with exponential backoff to avoid
/// fighting `fileproviderd` in a tight loop.
///
/// Re-evictions and callbacks are coalesced: pending URLs are deduplicated into a `Set`,
/// and a single timer-driven flush processes the entire batch with one evictor instance.
/// This prevents actor mailbox explosion and dispatch pileup under heavy CloudKit sync.
public final class RematerializationWatcher {
    private let logger: GuardLogging
    private let evictorFactory: (GuardLogging) -> ICloudEvicting
    private var query: NSMetadataQuery?
    private var backoffSeconds: TimeInterval = 1.0
    private let maxBackoffSeconds: TimeInterval = 60.0
    private var lastRematerializationAt: Date?
    private var rematerializationCount: Int = 0
    private let protectedPaths: [String]

    // Coalescing state
    private var pendingReEvictions: Set<String> = []
    private var pendingEvents: [RematerializationEvent] = []
    private var coalesceTimer: DispatchSourceTimer?
    private var coalesceScheduled = false

    public var onRematerialization: ((RematerializationEvent) -> Void)?

    public init(logger: GuardLogging, evictorFactory: @escaping (GuardLogging) -> ICloudEvicting) {
        self.logger = logger
        self.evictorFactory = evictorFactory
        self.protectedPaths = ConfigStore().load().scope.protectedPaths
    }

    /// Start watching for rematerialization of iCloud Drive items.
    public func start() {
        guard query == nil else { return }

        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery.predicate = NSPredicate(format: "%K == %@", NSMetadataUbiquitousItemDownloadingStatusKey, URLUbiquitousItemDownloadingStatus.current.rawValue)
        // No valueListAttributes — we read per-item attributes in queryDidUpdate.
        // valueListAttributes causes the query to accumulate all matched item
        // attributes in memory permanently, which leaks with large iCloud drives.
        metadataQuery.notificationBatchingInterval = 1.0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: metadataQuery
        )

        metadataQuery.start()
        query = metadataQuery

        // Coalescing timer: flush pending re-evictions and events every 2 seconds
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.flushPending()
        }
        timer.resume()
        coalesceTimer = timer

        logger.log("watcher started scope=ubiquitous-documents coalesce=2s")
    }

    /// Stop watching.
    public func stop() {
        guard let query else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        self.query = nil
        coalesceTimer?.cancel()
        coalesceTimer = nil
        coalesceScheduled = false
        pendingReEvictions.removeAll()
        pendingEvents.removeAll()
        logger.log("watcher stopped rematerializationCount=\(rematerializationCount)")
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        guard notification.object is NSMetadataQuery else { return }

        let changedItems = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []

        for item in changedItems {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String else {
                continue
            }

            if status == URLUbiquitousItemDownloadingStatus.current.rawValue
                || status == URLUbiquitousItemDownloadingStatus.downloaded.rawValue {
                enqueueRematerialization(url: url, newStatus: status)
            }
        }
    }

    /// Enqueue a rematerialization event for coalesced processing.
    /// Does NOT dispatch immediately — the coalesce timer handles the flush.
    private func enqueueRematerialization(url: URL, newStatus: String) {
        let now = Date()
        let path = url.path

        rematerializationCount += 1

        if protectedPaths.contains(where: { path.hasPrefix($0) }) {
            logger.log("watcher skip-rematerialize path=\(path) reason=protected")
            return
        }

        // Deduplicate: only add if not already pending
        let (inserted, _) = pendingReEvictions.insert(path)
        guard inserted else { return }

        let event = RematerializationEvent(
            itemPath: path,
            detectedAt: now,
            previousStatus: URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue,
            newStatus: newStatus
        )
        pendingEvents.append(event)

        // Exponential backoff: double up to max
        if let lastAt = lastRematerializationAt, now.timeIntervalSince(lastAt) < 60 {
            backoffSeconds = min(backoffSeconds * 2, maxBackoffSeconds)
        } else {
            backoffSeconds = 1.0
        }
        lastRematerializationAt = now

        logger.log("watcher rematerialization-enqueued path=\(url.lastPathComponent) status=\(newStatus) count=\(rematerializationCount) pending=\(pendingReEvictions.count)")
    }

    /// Flush all pending events and re-evictions in one batch.
    /// Called every 2 seconds by the coalescing timer.
    private func flushPending() {
        // Snapshot and clear pending state
        let events = pendingEvents
        let urls = pendingReEvictions
        pendingEvents.removeAll()
        pendingReEvictions.removeAll()

        guard !events.isEmpty else { return }

        // Notify the callback for each event (GuardService spawns a single Task
        // cluster inside a tight loop — caller should batch internally if needed)
        for event in events {
            onRematerialization?(event)
        }

        // Schedule a single re-eviction for all pending URLs with backoff delay
        let backoff = backoffSeconds
        let log = logger
        let factory = evictorFactory
        let count = rematerializationCount

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + backoff) {
            let evictor = factory(log)
            let now = Date()

            var evicted = 0
            var failed = 0

            for path in urls {
                let url = URL(fileURLWithPath: path)
                let snapshot = ICloudItemSnapshot(
                    relativePath: url.lastPathComponent,
                    absolutePath: path,
                    localBytes: 0,
                    isRegularFile: true,
                    isPackage: false,
                    isUbiquitous: true,
                    isUploaded: true,
                    isUploading: false,
                    isDownloading: false,
                    downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
                    hasDownloadError: false,
                    hasUploadError: false,
                    contentModificationDate: now
                )
                autoreleasepool {
                    do {
                        let result = try evictor.evict(items: [snapshot], dryRun: false)
                        evicted += result.evictedCount
                        failed += result.failedCount
                    } catch {
                        failed += 1
                        log.log("watcher re-evict failed path=\(url.lastPathComponent) error=\(error)")
                    }
                }
            }

            log.log("watcher re-evict-batch urls=\(urls.count) evicted=\(evicted) failed=\(failed) totalCount=\(count)")
        }
    }
}

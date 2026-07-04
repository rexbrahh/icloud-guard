import Foundation

/// Layer 3: Active defense against rematerialization.
///
/// Uses `NSMetadataQuery` to watch iCloud Drive items for download status changes.
/// When an evicted item transitions from `.notDownloaded` to `.current` or `.downloaded`,
/// the watcher immediately re-evicts it with exponential backoff to avoid
/// fighting `fileproviderd` in a tight loop.
///
/// Verified working: `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope`
/// starts and returns download status changes from a non-extension process.
public final class RematerializationWatcher {
    private let logger: GuardLogging
    private let evictorFactory: (GuardLogging) -> ICloudEvicting
    private var query: NSMetadataQuery?
    private var backoffSeconds: TimeInterval = 1.0
    private let maxBackoffSeconds: TimeInterval = 60.0
    private var lastRematerializationAt: Date?
    private var rematerializationCount: Int = 0

    public var onRematerialization: ((RematerializationEvent) -> Void)?

    public init(logger: GuardLogging, evictorFactory: @escaping (GuardLogging) -> ICloudEvicting) {
        self.logger = logger
        self.evictorFactory = evictorFactory
    }

    /// Start watching for rematerialization of iCloud Drive items.
    public func start() {
        guard query == nil else { return }

        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery.predicate = NSPredicate(value: true)
        metadataQuery.valueListAttributes = [
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataItemURLKey,
        ]
        metadataQuery.notificationBatchingInterval = 1.0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: metadataQuery
        )

        metadataQuery.start()
        query = metadataQuery
        logger.log("watcher started scope=ubiquitous-documents")
    }

    /// Stop watching.
    public func stop() {
        guard let query else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        self.query = nil
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

            // .current or .downloaded means the item was materialized
            if status == URLUbiquitousItemDownloadingStatus.current.rawValue
                || status == URLUbiquitousItemDownloadingStatus.downloaded.rawValue {
                handleRematerialization(url: url, newStatus: status)
            }
        }
    }

    private func handleRematerialization(url: URL, newStatus: String) {
        let now = Date()
        rematerializationCount += 1

        let event = RematerializationEvent(
            itemPath: url.path,
            detectedAt: now,
            previousStatus: URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue,
            newStatus: newStatus
        )

        logger.log("watcher rematerialization path=\(url.lastPathComponent) status=\(newStatus) count=\(rematerializationCount) backoff=\(backoffSeconds)s")
        onRematerialization?(event)

        // Re-evict with backoff
        let backoff = backoffSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self else { return }
            let evictor = self.evictorFactory(self.logger)
            let snapshot = ICloudItemSnapshot(
                relativePath: url.lastPathComponent,
                absolutePath: url.path,
                localBytes: 0,
                isRegularFile: true,
                isPackage: false,
                isUbiquitous: true,
                isUploaded: true,
                isUploading: false,
                isDownloading: false,
                downloadingStatus: newStatus,
                hasDownloadError: false,
                hasUploadError: false,
                contentModificationDate: now
            )
            do {
                let result = try evictor.evict(items: [snapshot], dryRun: false)
                self.logger.log("watcher re-evict path=\(url.lastPathComponent) evicted=\(result.evictedCount) failed=\(result.failedCount)")
            } catch {
                self.logger.log("watcher re-evict failed path=\(url.lastPathComponent) error=\(error)")
            }
        }

        // Exponential backoff: double up to max
        if let lastAt = lastRematerializationAt, now.timeIntervalSince(lastAt) < 60 {
            backoffSeconds = min(backoffSeconds * 2, maxBackoffSeconds)
        } else {
            backoffSeconds = 1.0
        }
        lastRematerializationAt = now
    }
}

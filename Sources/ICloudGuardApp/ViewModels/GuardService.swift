import Foundation
import Network
import ICloudGuardCore

/// Lightweight background guard service.
/// Does NOT use GuardRunner (which requires a config.json file).
/// Instead, directly manages suppression, watcher, and pollution metrics.
actor GuardService {
    private let scopePath: String
    private let logger: Logger
    private let config: AppConfig
    private let configStore: ConfigStore
    private var suppression: DownloadSuppression?
    private var watcher: RematerializationWatcher?
    private var pollutionTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var networkEvictionDispatched = false
    private let eventHandler: (GuardServiceEvent) -> Void

    init(scopePath: String, eventHandler: @escaping (GuardServiceEvent) -> Void) {
        AppPaths.ensureHomeDir()
        self.scopePath = scopePath
        self.eventHandler = eventHandler
        self.logger = Logger(logPath: AppPaths.log.path)
        self.configStore = ConfigStore()
        self.config = configStore.load()
    }

    func start() {
        // Layer 1: Apply download suppression
        let suppressionConfig = DownloadSuppressionConfig(
            spotlightSuppression: config.suppression.spotlight,
            quickLookCacheClear: config.suppression.quicklook,
            materializeDatalessFiles: config.suppression.materializeDataless,
            scopePath: scopePath
        )
        let supp = DownloadSuppression(config: suppressionConfig, logger: logger)
        supp.apply()
        suppression = supp
        eventHandler(.suppressionApplied)

        // Layer 3: Start rematerialization watcher
        let w = RematerializationWatcher(
            logger: logger,
            evictorFactory: { logger in PackageAwareEvictor(logger: logger) }
        )
        w.onRematerialization = { [weak self] event in
            Task { await self?.handleRematerialization(event) }
        }
        w.start()
        watcher = w
        eventHandler(.watcherStarted)

        // Network change detection → auto-evict after settle
        startNetworkMonitor()

        // Lightweight pollution check (cheap stat scan, no content reads)
        schedulePollutionCheck()
    }

    func stop() {
        pollutionTimer?.invalidate()
        pollutionTimer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        watcher?.stop()
        watcher = nil
        suppression?.removeSpotlightSuppression()
        suppression = nil
        eventHandler(.watcherStopped)
    }

    // MARK: - Eviction

    func runEviction() {
        eventHandler(.evictionStarted)
        let handler = eventHandler
        let scope = scopePath
        let log = logger
        let batchLimit = config.eviction.batchLimit
        let protectedPaths = config.scope.protectedPaths

        Task.detached {
            let urls = collectEvictableURLs(
                scopePath: scope,
                keys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
                protectedPaths: protectedPaths,
                requireMaterialized: true
            )

            var evicted = 0
            var failed = 0
            let fm = FileManager.default

            for url in urls {
                guard evicted + failed < batchLimit else { break }
                do {
                    try fm.evictUbiquitousItem(at: url)
                    evicted += 1
                } catch {
                    failed += 1
                }
            }

            log.log("eviction evicted=\(evicted) failed=\(failed)")
            handler(.evictionCompleted)
        }
    }

    func panicEvict() {
        eventHandler(.evictionStarted)
        let handler = eventHandler
        let scope = scopePath
        let log = logger
        let panicLimit = config.eviction.panicLimit
        let protectedPaths = config.scope.protectedPaths

        Task.detached {
            let urls = collectEvictableURLs(
                scopePath: scope,
                keys: [.isRegularFileKey, .isUbiquitousItemKey],
                protectedPaths: protectedPaths,
                requireMaterialized: false
            )

            var evicted = 0
            var failed = 0
            let fm = FileManager.default

            for url in urls {
                guard evicted + failed < panicLimit else { break }
                do {
                    try fm.evictUbiquitousItem(at: url)
                    evicted += 1
                } catch {
                    failed += 1
                }
            }

            log.log("panic-eviction evicted=\(evicted) failed=\(failed)")
            handler(.evictionCompleted)
        }
    }

    // MARK: - Network Change Detection

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            if path.status == .satisfied && !self.networkEvictionDispatched {
                self.networkEvictionDispatched = true
                // Wait 30s for bird to settle after reconnection, then evict
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    await self.runEviction()
                    self.networkEvictionDispatched = false
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        networkMonitor = monitor
    }

    // MARK: - Pollution Check

    private func schedulePollutionCheck() {
        let interval = TimeInterval(config.watcher.pollutionCheckIntervalSeconds)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.checkPollution() }
        }
        pollutionTimer = timer
        Task { await checkPollution() }
    }

    private func checkPollution() {
        let scopeURL = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
        var materialized = 0
        var dataless = 0

        guard let enumerator = FileManager.default.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Collect URLs synchronously to avoid Swift 6 makeIterator issue
        let allURLs = enumerator.allObjects.compactMap { $0 as? URL }

        for url in allURLs {
            guard url.lastPathComponent.hasPrefix(".") == false else { continue }
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            if (st.st_flags & SF_DATALESS) != 0 {
                dataless += 1
            } else if st.st_size > 0 {
                materialized += 1
            }
            if materialized + dataless >= 10000 { break }
        }

        eventHandler(.pollutionUpdated(materialized: materialized, dataless: dataless))
    }

    // MARK: - Private

    private func handleRematerialization(_ event: RematerializationEvent) {
        eventHandler(.rematerializationDetected(event))
    }
}

// MARK: - URL Collection Helper

/// Collects evictable URLs synchronously from the iCloud Drive scope.
/// Separated from async context to avoid Swift 6 `makeIterator` warnings.
private func collectEvictableURLs(
    scopePath: String,
    keys: [URLResourceKey],
    protectedPaths: [String],
    requireMaterialized: Bool
) -> [URL] {
    let scopeURL = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)

    guard let enumerator = FileManager.default.enumerator(
        at: scopeURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ) else { return [] }

    let allURLs = enumerator.allObjects.compactMap { $0 as? URL }
    var result: [URL] = []

    for url in allURLs {
        guard url.lastPathComponent.hasPrefix(".") == false else { continue }

        // Check protected paths
        if isProtected(url: url, protectedPaths: protectedPaths) { continue }

        let values = try? url.resourceValues(forKeys: Set(keys))

        if requireMaterialized {
            guard values?.isRegularFile == true else { continue }
            guard values?.isUbiquitousItem == true else { continue }
            guard values?.ubiquitousItemDownloadingStatus == .current
                || values?.ubiquitousItemDownloadingStatus == .downloaded else { continue }
        } else {
            guard values?.isRegularFile == true else { continue }
            guard values?.isUbiquitousItem == true else { continue }
        }

        result.append(url)
    }

    return result
}

private func isProtected(url: URL, protectedPaths: [String]) -> Bool {
    let path = url.path
    for protected in protectedPaths {
        let expanded = NSString(string: protected).expandingTildeInPath
        if path == expanded || path.hasPrefix(expanded + "/") {
            return true
        }
    }
    return false
}

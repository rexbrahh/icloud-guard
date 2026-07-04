import Foundation
import Network
import ICloudGuardCore

actor GuardService {
    private let scopePath: String
    private let logger: Logger
    private let evictionLogger: Logger
    private var config: AppConfig
    private let configStore: ConfigStore
    private var suppression: DownloadSuppression?
    private var watcher: RematerializationWatcher?
    private var pollutionTimer: DispatchSourceTimer?
    private var networkMonitor: NWPathMonitor?
    private var networkEvictionDispatched = false
    private var isPaused = false
    private let eventHandler: (GuardServiceEvent) -> Void

    init(scopePath: String, eventHandler: @escaping (GuardServiceEvent) -> Void) {
        AppPaths.ensureHomeDir()
        AppPaths.seedDefaultConfigIfMissing()
        self.scopePath = scopePath
        self.eventHandler = eventHandler
        self.logger = Logger(logPath: AppPaths.log.path)
        self.evictionLogger = Logger(logPath: AppPaths.evictionLog.path)
        self.configStore = ConfigStore()
        self.config = configStore.load()
    }

    func start() {
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

        let w = RematerializationWatcher(
            logger: logger,
            evictorFactory: { logger in PackageAwareEvictor(logger: logger) }
        )
        w.onRematerialization = { [weak self] event in
            Task { [weak self] in await self?.handleRematerialization(event) }
        }
        w.start()
        watcher = w
        eventHandler(.watcherStarted)

        startNetworkMonitor()
        schedulePollutionCheck()
    }

    func stop() {
        pollutionTimer?.cancel()
        pollutionTimer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        watcher?.stop()
        watcher = nil
        suppression?.removeSpotlightSuppression()
        suppression = nil
        eventHandler(.watcherStopped)
    }

    func pause() {
        isPaused = true
        pollutionTimer?.cancel()
        pollutionTimer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        watcher?.stop()
        watcher = nil
        eventHandler(.watcherStopped)
    }

    func resume() {
        isPaused = false
        let w = RematerializationWatcher(
            logger: logger,
            evictorFactory: { logger in PackageAwareEvictor(logger: logger) }
        )
        w.onRematerialization = { [weak self] event in
            Task { [weak self] in await self?.handleRematerialization(event) }
        }
        w.start()
        watcher = w
        eventHandler(.watcherStarted)
        startNetworkMonitor()
        schedulePollutionCheck()
    }

    /// Reload config from disk and re-apply if changed.
    /// Called when AppConfigModel.onChange fires after a config mutation.
    func reloadConfig() {
        let newConfig = configStore.load()
        let oldConfig = config

        // Re-apply suppression if its settings changed
        if newConfig.suppression != oldConfig.suppression {
            suppression?.removeSpotlightSuppression()
            let suppressionConfig = DownloadSuppressionConfig(
                spotlightSuppression: newConfig.suppression.spotlight,
                quickLookCacheClear: newConfig.suppression.quicklook,
                materializeDatalessFiles: newConfig.suppression.materializeDataless,
                scopePath: scopePath
            )
            let supp = DownloadSuppression(config: suppressionConfig, logger: logger)
            supp.apply()
            suppression = supp
        }

        // Reschedule pollution timer if its interval changed
        if newConfig.watcher.pollutionCheckIntervalSeconds != oldConfig.watcher.pollutionCheckIntervalSeconds {
            pollutionTimer?.cancel()
            let interval = newConfig.watcher.pollutionCheckIntervalSeconds
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
            timer.setEventHandler { [weak self] in
                Task { [weak self] in await self?.checkPollution() }
            }
            timer.resume()
            pollutionTimer = timer
        }


        // Update the stored config
        config = newConfig
    }

    func runEviction() {
        eventHandler(.evictionStarted)
        let handler = eventHandler
        let scope = scopePath
        let log = logger
        let evLog = evictionLogger
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
            evLog.log("eviction command=evict evicted=\(evicted) failed=\(failed) reclaimed=0")
            await Notifier.shared.notifyEvictionComplete(evictedCount: evicted, reclaimedBytes: 0)
            handler(.evictionCompleted)
        }
    }

    func panicEvict() {
        eventHandler(.evictionStarted)
        let handler = eventHandler
        let scope = scopePath
        let log = logger
        let evLog = evictionLogger
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

            evLog.log("eviction command=panic-evict evicted=\(evicted) failed=\(failed) reclaimed=0")
            await Notifier.shared.notifyEvictionComplete(evictedCount: evicted, reclaimedBytes: 0)
            handler(.evictionCompleted)
        }
    }

    private func handleRematerialization(_ event: RematerializationEvent) async {
        await Notifier.shared.notifyRematerialization(path: event.itemPath)
        eventHandler(.rematerializationDetected(event))
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { [weak self] in
                guard let self else { return }
                let already = await self.networkEvictionDispatched
                guard !already else { return }
                await self.setNetworkDispatched(true)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self.runEviction()
                await self.setNetworkDispatched(false)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        networkMonitor = monitor
    }

    private func setNetworkDispatched(_ value: Bool) {
        networkEvictionDispatched = value
    }

    private func schedulePollutionCheck() {
        let interval = config.watcher.pollutionCheckIntervalSeconds
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            Task { [weak self] in await self?.checkPollution() }
        }
        timer.resume()
        pollutionTimer = timer
        Task { await checkPollution() }
    }

    private func checkPollution() async {
        let scopeURL = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
        var materialized = 0
        var dataless = 0

        guard let enumerator = FileManager.default.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Lazy iteration — never materialize all URLs into an array (439K+ files)
        autoreleasepool {
            for case let url as URL in enumerator {
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
        }

        let total = materialized + dataless
        let pollutionRatio = total > 0 ? Double(dataless) / Double(total) : 0
        if pollutionRatio > 0.7 {
            await Notifier.shared.notifyPollutionThreshold(ratio: pollutionRatio)
        }
        eventHandler(.pollutionUpdated(materialized: materialized, dataless: dataless))
    }
}

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

    var result: [URL] = []

    // Lazy iteration — never materialize all URLs into an array (439K+ files)
    autoreleasepool {
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix(".") == false else { continue }
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

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

    func reloadConfig() {
        let newConfig = configStore.load()
        let oldConfig = config

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
            var reclaimed: Int64 = 0
            let fm = FileManager.default

            for url in urls {
                guard evicted + failed < batchLimit else { break }
                let sizeBefore = fileSize(url: url)
                do {
                    try fm.evictUbiquitousItem(at: url)
                    evicted += 1
                    reclaimed += sizeBefore
                } catch {
                    failed += 1
                }
            }

            log.log("eviction evicted=\(evicted) failed=\(failed) reclaimed=\(reclaimed)")
            evLog.log("eviction command=evict evicted=\(evicted) failed=\(failed) reclaimed=\(reclaimed)")
            await Notifier.shared.notifyEvictionComplete(evictedCount: evicted, reclaimedBytes: reclaimed)
            handler(.evictionResult(evicted: evicted, reclaimed: reclaimed))
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
            var reclaimed: Int64 = 0
            let fm = FileManager.default

            for url in urls {
                guard evicted + failed < panicLimit else { break }
                let sizeBefore = fileSize(url: url)
                do {
                    try fm.evictUbiquitousItem(at: url)
                    evicted += 1
                    reclaimed += sizeBefore
                } catch {
                    failed += 1
                }
            }

            evLog.log("eviction command=panic-evict evicted=\(evicted) failed=\(failed) reclaimed=\(reclaimed)")
            await Notifier.shared.notifyEvictionComplete(evictedCount: evicted, reclaimedBytes: reclaimed)
            handler(.evictionResult(evicted: evicted, reclaimed: reclaimed))
            handler(.evictionCompleted)
        }
    }

    func previewEviction() {
        let scope = scopePath
        let batchLimit = config.eviction.batchLimit
        let protectedPaths = config.scope.protectedPaths
        let handler = eventHandler

        Task.detached {
            let urls = collectEvictableURLs(
                scopePath: scope,
                keys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
                protectedPaths: protectedPaths,
                requireMaterialized: true
            )
            let count = min(urls.count, batchLimit)
            let totalBytes = urls.prefix(batchLimit).reduce(Int64(0)) { $0 + fileSize(url: $1) }
            handler(.evictionResult(evicted: 0, reclaimed: totalBytes))
        }
    }

    func evictFolder(_ folderPath: String) {
        eventHandler(.evictionStarted)
        let handler = eventHandler
        let log = logger
        let evLog = evictionLogger
        let batchLimit = config.eviction.batchLimit
        let protectedPaths = config.scope.protectedPaths

        Task.detached {
            let scopeURL = URL(fileURLWithPath: NSString(string: folderPath).expandingTildeInPath, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: scopeURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
                options: [.skipsHiddenFiles]
            ) else { handler(.evictionCompleted); return }

            var evicted = 0
            var failed = 0
            var reclaimed: Int64 = 0
            let fm = FileManager.default

            autoreleasepool {
                for case let url as URL in enumerator {
                    guard evicted + failed < batchLimit else { break }
                    guard url.lastPathComponent.hasPrefix(".") == false else { continue }
                    if isProtected(url: url, protectedPaths: protectedPaths) { continue }
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                    guard values?.isRegularFile == true else { continue }
                    guard values?.isUbiquitousItem == true else { continue }
                    guard values?.ubiquitousItemDownloadingStatus == .current
                        || values?.ubiquitousItemDownloadingStatus == .downloaded else { continue }
                    let sizeBefore = fileSize(url: url)
                    do {
                        try fm.evictUbiquitousItem(at: url)
                        evicted += 1
                        reclaimed += sizeBefore
                    } catch { failed += 1 }
                }
            }

            log.log("folder-eviction path=\(folderPath) evicted=\(evicted) failed=\(failed) reclaimed=\(reclaimed)")
            evLog.log("eviction command=folder-evict path=\(folderPath) evicted=\(evicted) failed=\(failed) reclaimed=\(reclaimed)")
            await Notifier.shared.notifyEvictionComplete(evictedCount: evicted, reclaimedBytes: reclaimed)
            handler(.evictionResult(evicted: evicted, reclaimed: reclaimed))
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
        var folderSizes: [String: Int64] = [:]

        guard let enumerator = FileManager.default.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles]
        ) else { return }

        autoreleasepool {
            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix(".") == false else { continue }
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }

                let isDataless = (st.st_flags & SF_DATALESS) != 0
                if isDataless {
                    dataless += 1
                } else if st.st_size > 0 {
                    materialized += 1
                }

                // Track top-level folder sizes
                let relPath = url.path.replacingOccurrences(of: scopeURL.path + "/", with: "")
                let topFolder = relPath.split(separator: "/").first.map(String.init) ?? "(root)"
                if !isDataless {
                    folderSizes[topFolder, default: 0] += Int64(st.st_blocks) * 512
                }

                if materialized + dataless >= 10000 { break }
            }
        }

        let total = materialized + dataless
        let pollutionRatio = total > 0 ? Double(dataless) / Double(total) : 0
        if pollutionRatio > 0.7 {
            await Notifier.shared.notifyPollutionThreshold(ratio: pollutionRatio)
        }

        let freeBytes = freeDiskSpace(scopeURL: scopeURL)
        let topFolders = folderSizes
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, bytes: $0.value) }

        eventHandler(.pollutionUpdated(materialized: materialized, dataless: dataless, freeSpace: freeBytes, folders: Array(topFolders)))

        // Auto-evict on low disk
        let freeGiB = Double(freeBytes) / (1024 * 1024 * 1024)
        if !isPaused && freeGiB > 0 && freeGiB < Double(config.policy.remediateFreeGiB) {
            eventHandler(.evictionStarted)
            await runEviction()
            eventHandler(.evictionCompleted)
        }
    }
}

// MARK: - Helpers

private func freeDiskSpace(scopeURL: URL) -> Int64 {
    if let values = try? scopeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let bytes = values.volumeAvailableCapacityForImportantUsage {
        return Int64(bytes)
    }
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: scopeURL.path),
       let free = attrs[.systemFreeSize] as? NSNumber {
        return free.int64Value
    }
    return 0
}

private func fileSize(url: URL) -> Int64 {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return 0 }
    return Int64(st.st_blocks) * 512
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
        // Exact path or prefix match
        if path == expanded || path.hasPrefix(expanded + "/") {
            return true
        }
        // Glob pattern match (e.g. *.fcpbundle, Documents/**)
        if expanded.contains("*") || expanded.contains("?") {
            if fnmatch(expanded, path, 0) == 0 {
                return true
            }
            // Also match as relative path against URL components
            let relPath = url.lastPathComponent
            if fnmatch(expanded, relPath, 0) == 0 {
                return true
            }
        }
    }
    return false
}

import Foundation
import ICloudGuardCore

/// Lightweight background guard service.
/// Does NOT use GuardRunner (which requires a config.json file).
/// Instead, directly manages suppression, watcher, and pollution metrics.
actor GuardService {
    private let scopePath: String
    private let logger: Logger
    private var suppression: DownloadSuppression?
    private var watcher: RematerializationWatcher?
    private var pollutionTimer: Timer?
    private let eventHandler: (GuardServiceEvent) -> Void

    init(scopePath: String, eventHandler: @escaping (GuardServiceEvent) -> Void) {
        self.scopePath = scopePath
        self.eventHandler = eventHandler
        let logPath = "\(NSHomeDirectory())/Library/Logs/icloud-guard.log"
        self.logger = Logger(logPath: logPath)
    }

    func start() {
        // Layer 1: Apply download suppression
        let suppressionConfig = DownloadSuppressionConfig(
            spotlightSuppression: true,
            quickLookCacheClear: true,
            materializeDatalessFiles: false,
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

        // Lightweight pollution check every 5 minutes (cheap stat scan, no content reads)
        schedulePollutionCheck()
    }

    func stop() {
        pollutionTimer?.invalidate()
        pollutionTimer = nil
        watcher?.stop()
        watcher = nil
        suppression?.removeSpotlightSuppression()
        suppression = nil
        eventHandler(.watcherStopped)
    }

    func runEviction() {
        eventHandler(.evictionStarted)
        let handler = eventHandler
        let scope = scopePath
        let log = logger
        Task.detached {
            let fm = FileManager.default
            let scopeURL = URL(fileURLWithPath: NSString(string: scope).expandingTildeInPath, isDirectory: true)

            guard let enumerator = fm.enumerator(
                at: scopeURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
                options: [.skipsHiddenFiles]
            ) else {
                handler(.evictionCompleted)
                handler(.error("failed to enumerate iCloud Drive"))
                return
            }

            var evicted = 0
            var failed = 0

            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix(".") == false else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                guard values?.isRegularFile == true else { continue }
                guard values?.isUbiquitousItem == true else { continue }
                guard values?.ubiquitousItemDownloadingStatus == .current || values?.ubiquitousItemDownloadingStatus == .downloaded else { continue }

                do {
                    try fm.evictUbiquitousItem(at: url)
                    evicted += 1
                } catch {
                    failed += 1
                }

                if evicted + failed >= 500 { break }
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
        Task.detached {
            let fm = FileManager.default
            let scopeURL = URL(fileURLWithPath: NSString(string: scope).expandingTildeInPath, isDirectory: true)

            guard let enumerator = fm.enumerator(
                at: scopeURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isUbiquitousItemKey],
                options: [.skipsHiddenFiles]
            ) else {
                handler(.evictionCompleted)
                handler(.error("failed to enumerate iCloud Drive"))
                return
            }

            var evicted = 0
            var failed = 0

            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix(".") == false else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey])
                guard values?.isRegularFile == true, values?.isUbiquitousItem == true else { continue }

                do {
                    try fm.evictUbiquitousItem(at: url)
                    evicted += 1
                } catch {
                    failed += 1
                }

                if evicted + failed >= 2000 { break }
            }

            log.log("panic-eviction evicted=\(evicted) failed=\(failed)")
            handler(.evictionCompleted)
        }
    }

    private func completeEviction() {
        eventHandler(.evictionCompleted)
    }

    private func handleRematerialization(_ event: RematerializationEvent) {
        eventHandler(.rematerializationDetected(event))
    }

    private func schedulePollutionCheck() {
        let timer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { await self?.checkPollution() }
        }
        pollutionTimer = timer
        // Initial check
        Task { await checkPollution() }
    }

    /// Cheap stat-based pollution check. Uses lstat to count SF_DATALESS vs materialized files.
    /// No content reads, no NSFileCoordinator, no materialization triggers.
    private func checkPollution() {
        let scopeURL = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
        var materialized = 0
        var dataless = 0

        guard let enumerator = FileManager.default.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix(".") == false else { continue }
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            if (st.st_flags & SF_DATALESS) != 0 {
                dataless += 1
            } else if st.st_size > 0 {
                materialized += 1
            }
            // Cap at 10000 for snappiness
            if materialized + dataless >= 10000 { break }
        }

        eventHandler(.pollutionUpdated(materialized: materialized, dataless: dataless))
    }
}

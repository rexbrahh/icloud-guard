import Foundation
import ICloudGuardCore

public enum GuardRunKind: String, Sendable {
    case trim
    case panic
    case folder
    case preview
}

public struct GuardRunReport: Equatable, Sendable {
    public var kind: GuardRunKind
    public var reason: String
    public var candidateCount: Int
    public var evictedCount: Int
    public var failedCount: Int
    public var reclaimedBytes: Int64
    public var failureReasons: [String: Int]
    public var cancelled: Bool
    /// For preview runs: what would be reclaimed.
    public var previewBytes: Int64

    public init(
        kind: GuardRunKind,
        reason: String,
        candidateCount: Int = 0,
        evictedCount: Int = 0,
        failedCount: Int = 0,
        reclaimedBytes: Int64 = 0,
        failureReasons: [String: Int] = [:],
        cancelled: Bool = false,
        previewBytes: Int64 = 0
    ) {
        self.kind = kind
        self.reason = reason
        self.candidateCount = candidateCount
        self.evictedCount = evictedCount
        self.failedCount = failedCount
        self.reclaimedBytes = reclaimedBytes
        self.failureReasons = failureReasons
        self.cancelled = cancelled
        self.previewBytes = previewBytes
    }
}

public enum GuardServiceEvent {
    /// Fresh drive statistics (materialized/dataless counts, bytes, folders, free space).
    case statsUpdated(DriveStats)
    /// Live progress during a scan/eviction run.
    case progress(EvictionProgress)
    case runStarted(GuardRunKind)
    case runFinished(GuardRunReport)
    case suppressionApplied(Bool)
    case watchlistUpdated(count: Int)
    case rematerialized(paths: [String])
    case pausedChanged(Bool)
    case error(String)
}

/// The app's always-on guard service: fast scans, policy-driven auto-trim,
/// watchlist re-eviction, and manual trim/panic/preview/folder actions.
///
/// Safety contract: the only mutation ever performed on the iCloud scope is
/// `evictUbiquitousItem` (local-copy removal; cloud copy retained).
actor GuardService {
    private let scopePath: String
    private let logger: Logger
    private let evictionLogger: Logger
    private var config: AppConfig
    private let configStore: ConfigStore
    private let stateStore: StateStore
    private var suppression: DownloadSuppression?
    private var watchlist: WatchlistWatcher?
    private var scanTimer: DispatchSourceTimer?
    private let eventHandler: (GuardServiceEvent) -> Void

    private var isPaused = false
    private var isRunning = false
    private var isScanning = false
    private var activeCancellation: EvictionCancellation?
    private var lastStats: DriveStats?
    private var lastScanAt: Date?

    init(scopePath: String, eventHandler: @escaping (GuardServiceEvent) -> Void) {
        AppPaths.ensureHomeDir()
        self.scopePath = scopePath
        self.eventHandler = eventHandler
        self.logger = Logger(logPath: AppPaths.log.path)
        self.evictionLogger = Logger(logPath: AppPaths.evictionLog.path)
        self.configStore = ConfigStore()
        self.config = configStore.loadMigrating()
        self.stateStore = StateStore()
    }

    // MARK: - Lifecycle

    func start() {
        applySuppression(using: config)
        startWatchlist(using: config)
        scheduleScanTimer(intervalSeconds: config.watcher.pollutionCheckIntervalSeconds, fireImmediately: true)
    }

    func stop() {
        scanTimer?.cancel()
        scanTimer = nil
        watchlist?.stop()
        // NOTE: the Spotlight suppression marker intentionally stays in place.
        // It only comes down when the user disables suppression in Settings.
    }

    func pause() {
        isPaused = true
        scanTimer?.cancel()
        scanTimer = nil
        watchlist?.stop()
        eventHandler(.pausedChanged(true))
    }

    func resume() {
        isPaused = false
        startWatchlist(using: config)
        scheduleScanTimer(intervalSeconds: config.watcher.pollutionCheckIntervalSeconds, fireImmediately: true)
        eventHandler(.pausedChanged(false))
    }

    func reloadConfig() {
        let newConfig = configStore.loadMigrating()
        let oldConfig = config
        config = newConfig

        if newConfig.suppression != oldConfig.suppression {
            if oldConfig.suppression.spotlight && !newConfig.suppression.spotlight {
                suppression?.removeSpotlightSuppression()
            }
            applySuppression(using: newConfig)
        }

        if newConfig.watcher.backoffMaxSeconds != oldConfig.watcher.backoffMaxSeconds
            || newConfig.watcher.watchlistPollSeconds != oldConfig.watcher.watchlistPollSeconds
            || newConfig.scope.protectedPaths != oldConfig.scope.protectedPaths {
            watchlist?.stop()
            startWatchlist(using: newConfig)
        }

        if newConfig.watcher.pollutionCheckIntervalSeconds != oldConfig.watcher.pollutionCheckIntervalSeconds {
            scheduleScanTimer(intervalSeconds: newConfig.watcher.pollutionCheckIntervalSeconds, fireImmediately: false)
        }
    }

    // MARK: - Suppression & watchlist

    private func applySuppression(using config: AppConfig) {
        let suppressionConfig = DownloadSuppressionConfig(
            spotlightSuppression: config.suppression.spotlight,
            quickLookCacheClear: config.suppression.quicklook,
            materializeDatalessFiles: config.suppression.materializeDataless,
            scopePath: scopePath
        )
        let supp = DownloadSuppression(config: suppressionConfig, logger: logger)
        supp.apply()
        suppression = supp
        eventHandler(.suppressionApplied(true))
    }

    private func startWatchlist(using config: AppConfig) {
        let watcher = WatchlistWatcher(
            logger: logger,
            protectedPaths: ProtectedPathsMatcher(patterns: config.scope.protectedPaths),
            scopePath: scopePath,
            backoffMaxSeconds: TimeInterval(config.watcher.backoffMaxSeconds)
        )
        watcher.onRematerialization = { [weak self] paths in
            Task { [weak self] in
                guard let self else { return }
                await self.handleRematerialization(paths)
            }
        }
        watcher.onCountChange = { [weak self] count in
            Task { [weak self] in
                await self?.emitWatchlistCount(count)
            }
        }
        watcher.start(intervalSeconds: config.watcher.watchlistPollSeconds)
        watchlist = watcher
        eventHandler(.watchlistUpdated(count: watcher.count))
    }

    private func emitWatchlistCount(_ count: Int) {
        eventHandler(.watchlistUpdated(count: count))
    }

    private func handleRematerialization(_ paths: [String]) async {
        if let last = paths.last {
            await Notifier.shared.notifyRematerialization(path: last)
        }
        eventHandler(.rematerialized(paths: paths))
    }

    // MARK: - Scheduled scan + policy

    private func scheduleScanTimer(intervalSeconds: Int, fireImmediately: Bool) {
        scanTimer?.cancel()
        let interval = max(60, intervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.scheduledScan()
            }
        }
        timer.resume()
        scanTimer = timer

        if fireImmediately {
            Task { await scheduledScan() }
        }
    }

    /// The heartbeat: collect fresh stats, update the UI, persist a sample,
    /// and let the policy engine decide whether to trim.
    private func scheduledScan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        do {
            let stats = try await collectStats()
            lastStats = stats
            lastScanAt = Date()
            eventHandler(.statsUpdated(stats))

            guard !isPaused, !isRunning else { return }

            var state = (try? stateStore.load()) ?? GuardState()
            state.samples = Self.trimmedSamples(
                state.samples + [GuardSample(timestamp: Date(), localBytes: stats.materializedBytes, freeBytes: stats.freeBytes)]
            )
            try? stateStore.save(state)

            let policy = PolicyMapping.corePolicy(from: config).normalized()
            let scan = ScanResult(scopePath: scopePath, freeBytes: stats.freeBytes, localBytes: stats.materializedBytes, items: [])
            let decision = PolicyEngine.evaluate(scan: scan, state: state, config: guardConfig(for: policy), now: Date())

            switch decision.kind {
            case .targeted:
                logger.log("auto-trim reason=\(decision.reason) target=\(decision.reclaimTargetBytes)")
                _ = await runEviction(
                    kind: .trim,
                    reason: decision.reason,
                    byteBudget: decision.reclaimTargetBytes,
                    fileBudget: config.eviction.batchLimit
                )
            case .panic:
                logger.log("auto-panic reason=\(decision.reason)")
                _ = await runEviction(
                    kind: .panic,
                    reason: decision.reason,
                    byteBudget: nil,
                    fileBudget: config.eviction.panicLimit
                )
            case .none, .cooldown:
                break
            }
        } catch {
            logger.log("scan-failed error=\(error)")
            eventHandler(.error("Scan failed: \(error.localizedDescription)"))
        }
    }

    private func collectStats() async throws -> DriveStats {
        let scope = scopePath
        return try await Task.detached(priority: .utility) {
            try DriveStatsCollector.collect(scopePath: scope)
        }.value
    }

    // MARK: - Manual actions

    /// Manual trim toward the configured local-footprint target. Ignores
    /// cooldown (user-initiated) but respects the target: if already under,
    /// reports so instead of evicting needlessly.
    @discardableResult
    func trimNow(progress: ((EvictionProgress) -> Void)? = nil) async -> GuardRunReport {
        let policy = PolicyMapping.corePolicy(from: config).normalized()
        let stats: DriveStats
        do {
            stats = try await freshStats()
        } catch {
            eventHandler(.error("Scan failed: \(error.localizedDescription)"))
            return GuardRunReport(kind: .trim, reason: "scan failed: \(error.localizedDescription)")
        }
        let reclaimTarget = max(stats.materializedBytes - policy.targetLocalBytes, 0)

        guard reclaimTarget > 0 else {
            let report = GuardRunReport(
                kind: .trim,
                reason: "already under \(formatBytes(policy.targetLocalBytes)) target"
            )
            eventHandler(.runFinished(report))
            return report
        }

        return await runEviction(
            kind: .trim,
            reason: "trim toward \(formatBytes(policy.targetLocalBytes)) target",
            byteBudget: reclaimTarget,
            fileBudget: config.eviction.batchLimit,
            progress: progress
        )
    }

    /// Panic: evict everything eligible, up to the panic limit.
    @discardableResult
    func panicEvict(progress: ((EvictionProgress) -> Void)? = nil) async -> GuardRunReport {
        await runEviction(
            kind: .panic,
            reason: "panic eviction",
            byteBudget: nil,
            fileBudget: config.eviction.panicLimit,
            progress: progress
        )
    }

    /// Dry-run: count candidates and bytes without evicting anything.
    @discardableResult
    func preview() async -> GuardRunReport {
        guard !isRunning else {
            return GuardRunReport(kind: .preview, reason: "another run is active")
        }
        isRunning = true
        eventHandler(.runStarted(.preview))
        defer {
            isRunning = false
            activeCancellation = nil
        }

        let cancellation = EvictionCancellation()
        activeCancellation = cancellation
        let engine = EvictionEngine(logger: logger)

        do {
            let candidates = try await collectCandidates(engine: engine, cancellation: cancellation)
            let bytes = candidates.reduce(into: Int64(0)) { $0 += $1.allocatedBytes }
            let report = GuardRunReport(
                kind: .preview,
                reason: "dry run",
                candidateCount: candidates.count,
                previewBytes: bytes
            )
            eventHandler(.runFinished(report))
            return report
        } catch {
            eventHandler(.error("Preview failed: \(error.localizedDescription)"))
            return GuardRunReport(kind: .preview, reason: "failed: \(error.localizedDescription)")
        }
    }

    /// Evict all eligible files inside one top-level folder of the scope.
    @discardableResult
    func evictFolder(_ folderName: String) async -> GuardRunReport {
        await runEviction(
            kind: .folder,
            reason: "evict folder \(folderName)",
            byteBudget: nil,
            fileBudget: config.eviction.batchLimit,
            folderFilter: folderName
        )
    }

    func cancelRun() {
        activeCancellation?.cancel()
    }

    // MARK: - Eviction core

    private func freshStats() async throws -> DriveStats {
        if let lastStats, let lastScanAt, Date().timeIntervalSince(lastScanAt) < 60 {
            return lastStats
        }
        let stats = try await collectStats()
        lastStats = stats
        lastScanAt = Date()
        eventHandler(.statsUpdated(stats))
        return stats
    }

    private func collectCandidates(
        engine: EvictionEngine,
        cancellation: EvictionCancellation,
        progress: ((EvictionProgress) -> Void)? = nil
    ) async throws -> [EvictionCandidate] {
        let scope = scopePath
        let protected = ProtectedPathsMatcher(patterns: config.scope.protectedPaths)
        let handler = eventHandler
        return try await Task.detached(priority: .utility) {
            try engine.collectCandidates(
                scopePath: scope,
                protectedPaths: protected,
                cancellation: cancellation
            ) { update in
                handler(.progress(update))
                progress?(update)
            }
        }.value
    }

    private func runEviction(
        kind: GuardRunKind,
        reason: String,
        byteBudget: Int64?,
        fileBudget: Int,
        folderFilter: String? = nil,
        progress: ((EvictionProgress) -> Void)? = nil
    ) async -> GuardRunReport {
        guard !isRunning else {
            return GuardRunReport(kind: kind, reason: "another run is active")
        }
        isRunning = true
        eventHandler(.runStarted(kind))
        defer {
            isRunning = false
            activeCancellation = nil
        }

        let cancellation = EvictionCancellation()
        activeCancellation = cancellation
        let engine = EvictionEngine(logger: logger)

        do {
            var candidates = try await collectCandidates(engine: engine, cancellation: cancellation, progress: progress)

            if let folderFilter {
                candidates = candidates.filter { candidate in
                    candidate.relativePath.split(separator: "/").first.map(String.init) == folderFilter
                }
            }

            if cancellation.isCancelled {
                let report = GuardRunReport(kind: kind, reason: "cancelled", candidateCount: candidates.count, cancelled: true)
                eventHandler(.runFinished(report))
                return report
            }

            guard !candidates.isEmpty else {
                let report = GuardRunReport(kind: kind, reason: "nothing to evict")
                eventHandler(.runFinished(report))
                return report
            }

            let handler = eventHandler
            let outcome = await Task.detached(priority: .utility) {
                engine.evict(
                    candidates: candidates,
                    byteBudget: byteBudget,
                    fileBudget: fileBudget,
                    cancellation: cancellation
                ) { update in
                    handler(.progress(update))
                    progress?(update)
                }
            }.value

            // Register evicted paths for rematerialization defense.
            if !outcome.evictedPaths.isEmpty {
                watchlist?.add(paths: outcome.evictedPaths)
                eventHandler(.watchlistUpdated(count: watchlist?.count ?? 0))
            }

            let report = GuardRunReport(
                kind: kind,
                reason: reason,
                candidateCount: candidates.count,
                evictedCount: outcome.evictedCount,
                failedCount: outcome.failedCount,
                reclaimedBytes: outcome.reclaimedBytes,
                failureReasons: outcome.failureReasons,
                cancelled: outcome.cancelled
            )

            evictionLogger.log(
                "eviction command=\(kind.rawValue) evicted=\(outcome.evictedCount) failed=\(outcome.failedCount) " +
                "verifiedReclaimed=\(outcome.reclaimedBytes) reasons=\(outcome.failureReasons)"
            )

            // Persist remediation state (shared cooldown with CLI).
            var state = (try? stateStore.load()) ?? GuardState()
            state.lastRemediationAt = Date()
            state.lastSummary = GuardRunSummary(
                timestamp: Date(),
                action: kind == .panic ? .panic : .targeted,
                reason: reason,
                dryRun: false,
                candidateCount: candidates.count,
                evictedCount: outcome.evictedCount,
                failedEvictionCount: outcome.failedCount,
                reclaimedBytes: outcome.reclaimedBytes,
                remainingLocalBytes: lastStats?.materializedBytes ?? 0,
                remainingFreeBytes: lastStats?.freeBytes ?? 0,
                escalatedToPanic: false
            )
            try? stateStore.save(state)

            if outcome.evictedCount > 0 {
                await Notifier.shared.notifyEvictionComplete(
                    evictedCount: outcome.evictedCount,
                    reclaimedBytes: outcome.reclaimedBytes
                )
            }

            eventHandler(.runFinished(report))

            // Refresh stats in the background so the UI converges to truth.
            Task { await self.refreshStatsAfterRun() }

            return report
        } catch {
            logger.log("run-failed kind=\(kind.rawValue) error=\(error)")
            eventHandler(.error("Run failed: \(error.localizedDescription)"))
            return GuardRunReport(kind: kind, reason: "failed: \(error.localizedDescription)")
        }
    }

    private func refreshStatsAfterRun() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        if let stats = try? await collectStats() {
            lastStats = stats
            lastScanAt = Date()
            eventHandler(.statsUpdated(stats))
        }
    }

    // MARK: - IPC status

    /// Text status for the CLI, matching the local-runner format.
    func statusText() async -> String {
        do {
            let stats = try await freshStats()
            let policy = PolicyMapping.corePolicy(from: config).normalized()
            let state = (try? stateStore.load()) ?? GuardState()
            let scan = ScanResult(scopePath: scopePath, freeBytes: stats.freeBytes, localBytes: stats.materializedBytes, items: [])
            let decision = PolicyEngine.evaluate(scan: scan, state: state, config: guardConfig(for: policy), now: Date())

            var lines: [String] = []
            lines.append("Scope: \(scopePath)")
            lines.append("Local iCloud footprint: \(formatBytes(stats.materializedBytes)) (\(stats.materializedFiles) files)")
            lines.append("Evicted (dataless): \(stats.datalessFiles) files")
            lines.append("Free space: \(formatBytes(stats.freeBytes))")
            lines.append("Watchlist: \(watchlist?.count ?? 0) path(s)")
            lines.append("Recent growth (\(policy.growthWindowMinutes)m): \(formatBytes(decision.growthBytes))")
            lines.append("Next action: \(decision.kind.rawValue) (\(decision.reason))")
            if let seconds = decision.cooldownRemainingSeconds {
                lines.append("Cooldown remaining: \(seconds)s")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "status unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func guardConfig(for policy: PolicyConfig) -> GuardConfig {
        GuardConfig(
            label: "app.icloud-guard",
            logPath: AppPaths.log.path,
            lockPath: AppPaths.lock.path,
            scopePath: scopePath,
            statePath: AppPaths.state.path,
            notifications: NotificationConfig(enable: false),
            policy: policy
        )
    }

    static func trimmedSamples(_ samples: [GuardSample], now: Date = Date()) -> [GuardSample] {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        return Array(samples.filter { $0.timestamp >= cutoff }.suffix(288))
    }
}

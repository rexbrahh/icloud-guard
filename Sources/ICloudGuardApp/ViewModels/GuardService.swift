import Foundation
import ICloudGuardCore
import Darwin
import os

public enum GuardRunKind: String, Sendable {
    case trim
    case panic
    case folder
    case preview
}

public struct GuardRunReport: Equatable, Sendable {
    public var runID: String
    public var startedAt: Date
    public var trigger: GuardRunTrigger
    public var kind: GuardRunKind
    public var action: GuardDecisionKind
    public var reason: String
    public var candidateCount: Int
    public var plannedBytes: Int64
    public var evictedCount: Int
    public var pendingCount: Int
    public var pendingBytes: Int64
    public var failedCount: Int
    public var failedBytes: Int64
    public var reclaimedBytes: Int64
    public var failureReasons: [String: Int]
    public var pendingReasons: [String: Int]
    public var busyProcessDisplayNames: [String]
    public var cancelled: Bool
    public var dryRun: Bool
    /// For preview runs: what would be reclaimed.
    public var previewBytes: Int64
    public var postScanComplete: Bool
    public var freeSpaceAvailable: Bool
    public var statePersisted: Bool
    public var watchlistPersisted: Bool
    public var recoveryJournalPersisted: Bool
    public var exitCode: Int32
    public var requestedGoalBytes: Int64?

    public init(
        runID: String = UUID().uuidString.lowercased(),
        startedAt: Date = Date(),
        trigger: GuardRunTrigger = .appManual,
        kind: GuardRunKind,
        action: GuardDecisionKind = .none,
        reason: String,
        candidateCount: Int = 0,
        plannedBytes: Int64 = 0,
        evictedCount: Int = 0,
        pendingCount: Int = 0,
        pendingBytes: Int64 = 0,
        failedCount: Int = 0,
        failedBytes: Int64 = 0,
        reclaimedBytes: Int64 = 0,
        failureReasons: [String: Int] = [:],
        pendingReasons: [String: Int] = [:],
        busyProcessDisplayNames: [String] = [],
        cancelled: Bool = false,
        dryRun: Bool = false,
        previewBytes: Int64 = 0,
        postScanComplete: Bool = false,
        freeSpaceAvailable: Bool = false,
        statePersisted: Bool = false,
        watchlistPersisted: Bool = true,
        recoveryJournalPersisted: Bool = true,
        exitCode: Int32 = 0,
        requestedGoalBytes: Int64? = nil
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.trigger = trigger
        self.kind = kind
        self.action = action
        self.reason = reason
        self.candidateCount = candidateCount
        self.plannedBytes = plannedBytes
        self.evictedCount = evictedCount
        self.pendingCount = pendingCount
        self.pendingBytes = pendingBytes
        self.failedCount = failedCount
        self.failedBytes = failedBytes
        self.reclaimedBytes = reclaimedBytes
        self.failureReasons = failureReasons
        self.pendingReasons = pendingReasons
        self.busyProcessDisplayNames = busyProcessDisplayNames
        self.cancelled = cancelled
        self.dryRun = dryRun
        self.previewBytes = previewBytes
        self.postScanComplete = postScanComplete
        self.freeSpaceAvailable = freeSpaceAvailable
        self.statePersisted = statePersisted
        self.watchlistPersisted = watchlistPersisted
        self.recoveryJournalPersisted = recoveryJournalPersisted
        self.exitCode = exitCode
        self.requestedGoalBytes = requestedGoalBytes
    }
}

public enum GuardServiceEvent: Sendable {
    /// Fresh drive statistics (materialized/dataless counts, bytes, folders, free space).
    case statsUpdated(DriveStats)
    /// Background scan is walking the drive (files scanned so far).
    case scanProgress(scannedFiles: Int)
    /// Live progress during a scan/eviction run.
    case progress(EvictionProgress)
    case runStarted(GuardRunKind)
    case runFinished(GuardRunReport)
    case keepDownloadedFinished(GuardRunReceipt)
    case suppressionApplied(DownloadSuppressionResult)
    case watchlistUpdated(count: Int)
    case rematerialized(paths: [String])
    case fighting(paths: [String])
    case cooldownUpdated(seconds: Int?)
    case samplesUpdated([GuardSample])
    case pausedChanged(Bool)
    case error(String)
}

typealias GuardScanProvider = @Sendable (
    _ scopePath: String,
    _ protectedPaths: ProtectedPathsMatcher,
    _ shouldStop: @escaping @Sendable () -> Bool,
    _ onProgress: @escaping @Sendable (Int) -> Void
) throws -> ScanBundle

typealias GuardEvictProvider = @Sendable (
    _ candidates: [EvictionCandidate],
    _ scopePath: String,
    _ protectedPaths: ProtectedPathsMatcher,
    _ byteBudget: Int64?,
    _ fileBudget: Int,
    _ protectBusyPackages: Bool,
    _ cancellation: EvictionCancellation,
    _ onProgress: @escaping @Sendable (EvictionProgress) -> Void
) -> EvictionOutcome

typealias GuardSuppressionProvider = @Sendable (
    _ config: DownloadSuppressionConfig,
    _ cancellation: EvictionCancellation
) async -> DownloadSuppressionResult
typealias GuardSpotlightRemoval = @Sendable (_ scopePath: String) -> SuppressionMechanismResult
typealias GuardEvictionNotification = @Sendable (_ evictedCount: Int, _ reclaimedBytes: Int64) async -> Void
typealias GuardPartialFailureNotification = @Sendable (_ message: String) async -> Void

private final class GuardNotificationScopeBox: Sendable {
    private struct Value: Sendable {
        var id = "default"
        var generation: UInt64 = 0
    }
    private let value = OSAllocatedUnfairLock(initialState: Value())

    func set(id: String, generation: UInt64) {
        value.withLock { $0 = Value(id: id, generation: generation) }
    }

    var snapshot: (id: String, generation: UInt64) {
        value.withLock { ($0.id, $0.generation) }
    }
}
typealias GuardRuntimeConfigProvider = @Sendable () throws -> AppConfig
typealias GuardKeepDownloadedProvider = @Sendable (
    _ appHomeURL: URL,
    _ scopePath: String,
    _ patterns: [String],
    _ trigger: GuardRunTrigger,
    _ cancellation: EvictionCancellation
) throws -> KeepDownloadedExecution
typealias GuardEventHintMonitorFactory = @Sendable (
    _ handler: @escaping EventScanHintMonitor.Handler
) throws -> EventScanHintMonitor

enum GuardRuntimeConfigurationError: LocalizedError, Equatable {
    case scopeMismatch(expected: String, configured: String)

    var errorDescription: String? {
        switch self {
        case .scopeMismatch(let expected, let configured):
            return "runtime configuration scope \(configured) does not match service scope \(expected)"
        }
    }
}

private enum GuardServiceLifecycleMode {
    case stopped
    case manualReady
    case automatic
}

private struct GuardAdvisoryCandidateHint: Sendable {
    var path: String
    var identity: EvictionFileIdentity
}

enum GuardPartialFailureSummary {
    static func message(for report: GuardRunReport) -> String {
        var details: [String] = []
        if report.pendingCount > 0 { details.append("\(report.pendingCount) pending") }
        if report.failedCount > 0 { details.append("\(report.failedCount) failed") }
        if let goal = report.requestedGoalBytes, report.reclaimedBytes < goal {
            details.append("reclaim goal short by \(formatBytes(goal - report.reclaimedBytes))")
        }
        if report.evictedCount > 0 && !report.postScanComplete {
            details.append("post-run scan incomplete")
        }
        if !report.statePersisted { details.append("run state or receipt was not persisted") }
        if !report.watchlistPersisted { details.append("watchlist was not persisted") }
        if !report.recoveryJournalPersisted { details.append("recovery journal was not persisted") }
        let reasons = (report.failureReasons.merging(report.pendingReasons, uniquingKeysWith: +))
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .prefix(3)
            .map { "\($0.key) \($0.value)" }
        if !reasons.isEmpty { details.append("reasons: " + reasons.joined(separator: ", ")) }
        if details.isEmpty { details.append("run ended with exit code \(report.exitCode)") }
        return "Eviction needs attention: " + details.joined(separator: "; ")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

private final class ScanWaitResolution: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ScanBundle, Error>?
        var resolved = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<ScanBundle, Error>) {
        state.withLock { state in
            guard !state.resolved else { return }
            state.continuation = continuation
        }
    }

    @discardableResult
    func resolve(_ result: Result<ScanBundle, Error>) -> Bool {
        let continuation = state.withLock { state -> CheckedContinuation<ScanBundle, Error>? in
            guard !state.resolved else { return nil }
            state.resolved = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }
}

/// The app's always-on guard service: fast scans, policy-driven auto-trim,
/// watchlist re-eviction, and manual trim/panic/preview/folder actions.
///
/// Safety contract: the only mutation ever performed on the iCloud scope is
/// `evictUbiquitousItem` (local-copy removal; cloud copy retained).
actor GuardService {
    private let scopePath: String
    private let appHomeURL: URL
    private let logger: ICloudGuardCore.Logger
    private let evictionLogger: ICloudGuardCore.Logger
    private var config: AppConfig
    private let configStore: ConfigStore?
    private let runtimeConfigProvider: GuardRuntimeConfigProvider?
    private let stateStore: StateStore
    private var watchlist: WatchlistWatcher?
    private var scanTimer: DispatchSourceTimer?
    private let eventHandler: @Sendable (GuardServiceEvent) -> Void
    private let scanProvider: GuardScanProvider
    private let evictProvider: GuardEvictProvider
    private let suppressionProvider: GuardSuppressionProvider
    private let spotlightRemoval: GuardSpotlightRemoval
    private let evictionNotification: GuardEvictionNotification
    private let partialFailureNotification: GuardPartialFailureNotification
    private let keepDownloadedProvider: GuardKeepDownloadedProvider
    private var energyScheduler: EnergyAwareScheduler
    private let energySignalProvider: @Sendable () -> EnergySchedulingSignals
    private let eventHintMonitorFactory: GuardEventHintMonitorFactory
    private let automaticPanicLockPath: String?
    private let notificationScope = GuardNotificationScopeBox()

    private var isPaused = false
    private var isRunning = false
    private var lifecycleMode: GuardServiceLifecycleMode = .stopped
    private var activeCancellation: EvictionCancellation?
    private var activeScanTask: Task<ScanBundle, Error>?
    private var activeScanCancellation: EvictionCancellation?
    private var activeScanID = 0
    private var activeScanScopePath: String?
    private var eventHintMonitor: EventScanHintMonitor?
    private var eventHintsActive = false
    private var suppressionGeneration = 0
    private var lifecycleGeneration = 0
    private var watchlistGeneration = 0
    private var suppressionTask: Task<DownloadSuppressionResult, Never>?
    private var suppressionCancellation: EvictionCancellation?
    private var lastStats: DriveStats?
    private var lastScanAt: Date?
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        scopePath: String,
        appHomeURL: URL = AppPaths.homeDir,
        scanProvider: @escaping GuardScanProvider = { scope, protected, shouldStop, onProgress in
            try ScanOrchestrator.scan(
                scopePath: scope,
                protectedPaths: protected,
                shouldStop: shouldStop,
                onProgress: onProgress
            )
        },
        evictProvider: GuardEvictProvider? = nil,
        suppressionProvider: GuardSuppressionProvider? = nil,
        spotlightRemoval: GuardSpotlightRemoval? = nil,
        evictionNotification: GuardEvictionNotification? = nil,
        partialFailureNotification: GuardPartialFailureNotification? = nil,
        energySignalProvider: @escaping @Sendable () -> EnergySchedulingSignals = {
            NativeEnergySignals.current()
        },
        eventHintMonitorFactory: GuardEventHintMonitorFactory? = nil,
        runtimeConfigProvider: GuardRuntimeConfigProvider? = nil,
        automaticPanicLockPath: String? = nil,
        keepDownloadedProvider: GuardKeepDownloadedProvider? = nil,
        eventHandler: @escaping @Sendable (GuardServiceEvent) -> Void
    ) throws {
        try FileManager.default.createDirectory(at: appHomeURL, withIntermediateDirectories: true)
        self.scopePath = scopePath
        self.appHomeURL = appHomeURL
        self.eventHandler = eventHandler
        self.scanProvider = scanProvider
        let configStore: ConfigStore?
        let config: AppConfig
        if let runtimeConfigProvider {
            configStore = nil
            config = try runtimeConfigProvider()
            try Self.validateRuntimeConfigScope(config, serviceScopePath: scopePath)
        } else {
            let legacyStore = ConfigStore(configURL: appHomeURL.appendingPathComponent("config.toml"))
            configStore = legacyStore
            config = try legacyStore.loadMigratingValidated()
        }
        self.configStore = configStore
        self.runtimeConfigProvider = runtimeConfigProvider
        self.config = config
        self.energySignalProvider = energySignalProvider
        self.energyScheduler = EnergyAwareScheduler(policy: config.energy, signalProvider: energySignalProvider)
        self.eventHintMonitorFactory = eventHintMonitorFactory ?? { handler in
            try EventScanHintMonitor(scopePath: scopePath, handler: handler)
        }
        self.automaticPanicLockPath = automaticPanicLockPath
        self.keepDownloadedProvider = keepDownloadedProvider ?? { home, scope, patterns, trigger, cancellation in
            try KeepDownloadedOperations.enforce(
                appHomeURL: home,
                scopePath: scope,
                patterns: patterns,
                trigger: trigger,
                cancellation: cancellation
            )
        }
        let logger = ICloudGuardCore.Logger(logPath: appHomeURL.appendingPathComponent("icloud-guard.log").path)
        self.logger = logger
        self.evictionLogger = ICloudGuardCore.Logger(logPath: appHomeURL.appendingPathComponent("evictions.log").path)
        self.evictProvider = evictProvider ?? { candidates, scope, protected, byteBudget, fileBudget, protectBusyPackages, cancellation, onProgress in
            EvictionEngine(logger: logger).evict(
                candidates: candidates,
                scopePath: scope,
                protectedPaths: protected,
                byteBudget: byteBudget,
                fileBudget: fileBudget,
                cancellation: cancellation,
                protectBusyPackages: protectBusyPackages,
                onProgress: onProgress
            )
        }
        self.suppressionProvider = suppressionProvider ?? { config, cancellation in
            guard SystemIntegrationPolicy.isEnabled() else {
                return DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            }
            return await DownloadSuppression(config: config, logger: logger).apply(cancellation: cancellation)
        }
        self.spotlightRemoval = spotlightRemoval ?? { scopePath in
            guard SystemIntegrationPolicy.isEnabled() else { return .disabled }
            return DownloadSuppression(
                config: DownloadSuppressionConfig(scopePath: scopePath),
                logger: logger
            ).removeSpotlightSuppression()
        }
        let notificationScope = self.notificationScope
        self.evictionNotification = evictionNotification ?? { evictedCount, reclaimedBytes in
            let scope = notificationScope.snapshot
            await Notifier.shared.notifyEvictionComplete(
                evictedCount: evictedCount,
                reclaimedBytes: reclaimedBytes,
                scopeID: scope.id,
                scopeGeneration: scope.generation
            )
        }
        self.partialFailureNotification = partialFailureNotification ?? { message in
            let scope = notificationScope.snapshot
            await Notifier.shared.notifyPartialFailure(
                message: message,
                scopeID: scope.id,
                scopeGeneration: scope.generation
            )
        }
        self.stateStore = StateStore(statePath: appHomeURL.appendingPathComponent("state.json").path)
    }

    // MARK: - Lifecycle

    func bindNotificationProvenance(scopeID: String, generation: UInt64) {
        notificationScope.set(id: scopeID, generation: generation)
    }

    /// Loads manual-operation state without enabling any automatic work.
    /// Disabled scopes use this to make watchlist-aware trim/panic/preview/
    /// recovery/keep operations safe while leaving polling and scans stopped.
    func prepareForManualOperations() async throws {
        guard lifecycleMode == .stopped else { return }
        try loadRuntimeConfigForLifecycle()
        startWatchlist(using: config, polling: false)
        lifecycleMode = .manualReady
    }

    func start() async {
        guard lifecycleMode != .automatic else { return }
        let wasManualReady = lifecycleMode == .manualReady
        let lifecycle = lifecycleGeneration
        await Notifier.shared.configure(
            config.notifications,
            notificationsEnabled: UserDefaults.standard.bool(forKey: "notificationsEnabled")
        )
        await applySuppression(using: config)
        guard lifecycle == lifecycleGeneration else { return }
        if wasManualReady {
            watchlist?.start(intervalSeconds: config.watcher.watchlistPollSeconds)
        } else {
            startWatchlist(using: config, polling: true)
        }
        startEventHints()
        if let state = try? stateStore.load(), !state.samples.isEmpty {
            eventHandler(.samplesUpdated(state.samples))
        }
        scheduleScanTimer(intervalSeconds: config.watcher.pollutionCheckIntervalSeconds, fireImmediately: true)
        lifecycleMode = .automatic
    }

    func stop() async {
        lifecycleGeneration += 1
        stopEventHints()
        activeCancellation?.cancel()
        let activeScanTask = activeScanTask
        cancelSharedScan()
        suppressionGeneration += 1
        let activeSuppressionTask = suppressionTask
        suppressionCancellation?.cancel()
        suppressionTask?.cancel()
        suppressionCancellation = nil
        suppressionTask = nil
        scanTimer?.cancel()
        scanTimer = nil
        watchlistGeneration += 1
        watchlist?.stop()
        if let activeScanTask { _ = await activeScanTask.result }
        await waitForRunQuiescence()
        if let activeSuppressionTask { _ = await activeSuppressionTask.result }
        watchlist = nil
        lifecycleMode = .stopped
        // NOTE: the Spotlight suppression marker intentionally stays in place.
        // It only comes down when the user disables suppression in Settings.
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        activeCancellation?.cancel()
        stopEventHints()
        cancelSharedScan()
        scanTimer?.cancel()
        scanTimer = nil
        watchlistGeneration += 1
        watchlist?.stop()
        eventHandler(.pausedChanged(true))
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        guard lifecycleMode == .automatic else {
            eventHandler(.pausedChanged(false))
            return
        }
        startWatchlist(using: config, polling: true)
        startEventHints()
        scheduleScanTimer(intervalSeconds: config.watcher.pollutionCheckIntervalSeconds, fireImmediately: true)
        eventHandler(.pausedChanged(false))
    }

    func reloadConfig() async {
        let lifecycle = lifecycleGeneration
        let newConfig: AppConfig
        do {
            if let runtimeConfigProvider {
                newConfig = try runtimeConfigProvider()
                try Self.validateRuntimeConfigScope(newConfig, serviceScopePath: scopePath)
            } else {
                newConfig = try configStore!.loadMigratingValidated()
            }
        } catch {
            logger.log("config-reload-failed error=\(error)")
            eventHandler(.error(error.localizedDescription))
            return
        }
        let oldConfig = config
        config = newConfig
        energyScheduler = EnergyAwareScheduler(policy: newConfig.energy, signalProvider: energySignalProvider)
        await Notifier.shared.configure(
            newConfig.notifications,
            notificationsEnabled: UserDefaults.standard.bool(forKey: "notificationsEnabled")
        )

        if lifecycleMode != .manualReady, newConfig.suppression != oldConfig.suppression {
            await applySuppression(using: newConfig)
            guard lifecycle == lifecycleGeneration else { return }
        }

        if lifecycleMode != .stopped, !isPaused, (
            newConfig.watcher.backoffMaxSeconds != oldConfig.watcher.backoffMaxSeconds
            || newConfig.watcher.watchlistPollSeconds != oldConfig.watcher.watchlistPollSeconds
            || newConfig.watcher.watchlistMaxEntries != oldConfig.watcher.watchlistMaxEntries
            || newConfig.watcher.verifiedRetentionHours != oldConfig.watcher.verifiedRetentionHours
            || newConfig.watcher.pendingVerificationGraceSeconds != oldConfig.watcher.pendingVerificationGraceSeconds
            || newConfig.watcher.pendingRetryLimit != oldConfig.watcher.pendingRetryLimit
            || newConfig.watcher.maxFights != oldConfig.watcher.maxFights
            || newConfig.eviction.protectBusyPackages != oldConfig.eviction.protectBusyPackages
            || newConfig.scope.protectedPaths != oldConfig.scope.protectedPaths
            || newConfig.scope.keepDownloadedPaths != oldConfig.scope.keepDownloadedPaths
            || newConfig.scope.folderPolicies != oldConfig.scope.folderPolicies
        ) {
            watchlist?.stop()
            startWatchlist(using: newConfig, polling: lifecycleMode == .automatic)
        }

        if lifecycleMode == .automatic, !isPaused,
           newConfig.watcher.pollutionCheckIntervalSeconds != oldConfig.watcher.pollutionCheckIntervalSeconds {
            scheduleScanTimer(intervalSeconds: newConfig.watcher.pollutionCheckIntervalSeconds, fireImmediately: false)
        }
        if lifecycleMode == .automatic, !isPaused, eventHintsActive {
            stopEventHints()
            startEventHints()
        }
    }

    private func loadRuntimeConfigForLifecycle() throws {
        do {
            let newConfig: AppConfig
            if let runtimeConfigProvider {
                newConfig = try runtimeConfigProvider()
                try Self.validateRuntimeConfigScope(newConfig, serviceScopePath: scopePath)
            } else {
                newConfig = try configStore!.loadMigratingValidated()
            }
            config = newConfig
            energyScheduler = EnergyAwareScheduler(policy: newConfig.energy, signalProvider: energySignalProvider)
        } catch {
            logger.log("config-prepare-failed error=\(error)")
            eventHandler(.error(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Suppression & watchlist

    private func applySuppression(using config: AppConfig) async {
        suppressionGeneration += 1
        let generation = suppressionGeneration
        let previousTask = suppressionTask
        suppressionCancellation?.cancel()
        suppressionTask?.cancel()
        if let previousTask { _ = await previousTask.result }
        guard generation == suppressionGeneration else { return }

        let suppressionConfig = DownloadSuppressionConfig(
            spotlightSuppression: config.suppression.spotlight,
            quickLookCacheClear: config.suppression.quicklook,
            materializeDatalessFiles: config.suppression.materializeDataless,
            scopePath: scopePath
        )
        let removal = config.suppression.spotlight
            ? SuppressionMechanismResult.disabled
            : spotlightRemoval(scopePath)
        let cancellation = EvictionCancellation()
        suppressionCancellation = cancellation
        let provider = suppressionProvider
        let task = Task { await provider(suppressionConfig, cancellation) }
        suppressionTask = task
        var result = await task.value
        guard generation == suppressionGeneration, !cancellation.isCancelled else { return }
        suppressionTask = nil
        suppressionCancellation = nil
        if !config.suppression.spotlight { result.spotlight = removal }
        eventHandler(.suppressionApplied(result))
    }

    private func startWatchlist(using config: AppConfig, polling: Bool) {
        let generation = lifecycleGeneration
        watchlistGeneration += 1
        let watcherGeneration = watchlistGeneration
        let watcher = WatchlistWatcher(
            storageURL: appHomeURL.appendingPathComponent("watchlist.json"),
            logger: logger,
            protectedPaths: config.scope.evictionPolicyMatcher,
            scopePath: scopePath,
            maxEntries: config.watcher.watchlistMaxEntries,
            maxFights: config.watcher.maxFights,
            pendingRetryLimit: config.watcher.pendingRetryLimit,
            backoffMaxSeconds: TimeInterval(config.watcher.backoffMaxSeconds),
            pendingVerificationGraceSeconds: TimeInterval(config.watcher.pendingVerificationGraceSeconds),
            verifiedRetentionSeconds: TimeInterval(config.watcher.verifiedRetentionHours * 60 * 60),
            mutationLockPath: appHomeURL.appendingPathComponent("run.lock").path,
            protectBusyPackages: config.eviction.protectBusyPackages
        )
        watcher.onRematerialization = { [weak self] paths in
            Task { [weak self] in
                guard let self else { return }
                await self.handleRematerialization(
                    paths,
                    lifecycleGeneration: generation,
                    watcherGeneration: watcherGeneration
                )
            }
        }
        watcher.onFighting = { [weak self] paths in
            Task { [weak self] in
                await self?.handleFighting(
                    paths,
                    lifecycleGeneration: generation,
                    watcherGeneration: watcherGeneration
                )
            }
        }
        watcher.onCountChange = { [weak self] count in
            Task { [weak self] in
                await self?.emitWatchlistCount(
                    count,
                    lifecycleGeneration: generation,
                    watcherGeneration: watcherGeneration
                )
            }
        }
        if polling {
            watcher.start(intervalSeconds: config.watcher.watchlistPollSeconds)
        }
        watchlist = watcher
        eventHandler(.watchlistUpdated(count: watcher.count))
    }

    private func emitWatchlistCount(
        _ count: Int,
        lifecycleGeneration: Int,
        watcherGeneration: Int
    ) {
        guard lifecycleGeneration == self.lifecycleGeneration,
              watcherGeneration == self.watchlistGeneration else { return }
        eventHandler(.watchlistUpdated(count: count))
    }

    private func handleRematerialization(
        _ paths: [String],
        lifecycleGeneration: Int,
        watcherGeneration: Int
    ) async {
        guard lifecycleGeneration == self.lifecycleGeneration,
              watcherGeneration == self.watchlistGeneration else { return }
        if let last = paths.last {
            await Notifier.shared.notifyRematerialization(path: last)
        }
        guard lifecycleGeneration == self.lifecycleGeneration,
              watcherGeneration == self.watchlistGeneration else { return }
        eventHandler(.rematerialized(paths: paths))
    }

    private func handleFighting(
        _ paths: [String],
        lifecycleGeneration: Int,
        watcherGeneration: Int
    ) async {
        guard lifecycleGeneration == self.lifecycleGeneration,
              watcherGeneration == self.watchlistGeneration else { return }
        eventHandler(.fighting(paths: paths))
        let scope = notificationScope.snapshot
        await Notifier.shared.notifyFighting(
            count: paths.count,
            scopeID: scope.id,
            scopeGeneration: scope.generation
        )
    }

    private func startEventHints() {
        guard !eventHintsActive else { return }
        do {
            if eventHintMonitor == nil {
                eventHintMonitor = try eventHintMonitorFactory { [weak self] batch in
                    Task { [weak self] in await self?.handleEventScanHints(batch) }
                }
            }
            try eventHintMonitor?.start()
            eventHintsActive = true
        } catch {
            eventHintsActive = false
            logger.log("event-hints-start-failed error=\(error)")
            eventHandler(.error("Event scan hints unavailable; periodic scans remain active"))
        }
    }

    private func stopEventHints() {
        eventHintsActive = false
        eventHintMonitor?.stop()
    }

    private func handleEventScanHints(_ batch: EventScanHintBatch) async {
        guard eventHintsActive, !isPaused else { return }
        if batch.requiresFullReconciliation {
            await scheduledScan()
            return
        }

        // Event delivery is lossy. Scan only a bounded set of validated
        // directories for responsiveness, discard those partial statistics,
        // then use the authoritative full reconciliation for policy decisions.
        let targets = batch.targets.prefix(8).compactMap { $0.validatedURL(under: scopePath) }
        guard !targets.isEmpty else {
            await scheduledScan()
            return
        }
        var candidateHints: [GuardAdvisoryCandidateHint] = []
        for target in targets {
            guard eventHintsActive, !isPaused, !isRunning else { return }
            do {
                let targetedBundle = try await rawScanBundle(
                    at: target.path,
                    protectedPaths: config.scope.evictionPolicyMatcher,
                    cancellation: nil
                )
                for candidate in targetedBundle.candidates where candidateHints.count < 128 {
                    guard let identity = candidate.identity else { continue }
                    candidateHints.append(GuardAdvisoryCandidateHint(path: candidate.path, identity: identity))
                }
            } catch is CancellationError {
                return
            } catch {
                logger.log("event-target-scan-failed error=\(error)")
                break
            }
        }
        guard eventHintsActive, !isPaused else { return }
        await scheduledScan(advisoryCandidateHints: candidateHints)
    }

    // MARK: - Recovery and keep-downloaded operations

    func restoreLastRun() async throws -> RestorationExecution {
        if lifecycleMode == .stopped { try await prepareForManualOperations() }
        guard !isRunning else { throw RestorationService.RestorationError.contention }
        isRunning = true
        let cancellation = EvictionCancellation()
        activeCancellation = cancellation
        defer {
            finishRun()
        }
        let home = appHomeURL
        let scope = scopePath
        let execution = try await Task.detached(priority: .utility) {
            try RestorationOperations.restoreLastRun(
                appHomeURL: home,
                scopePath: scope,
                trigger: .appManual,
                cancellation: cancellation
            )
        }.value
        await Notifier.shared.notifyRestoreComplete(
            verified: execution.result.verifiedCount,
            pending: execution.result.pendingCount,
            failed: execution.result.failedCount
        )
        return execution
    }

    func enforceKeepDownloaded(trigger: GuardRunTrigger = .appManual) async throws -> KeepDownloadedExecution {
        if lifecycleMode == .stopped { try await prepareForManualOperations() }
        guard !isRunning else { throw KeepDownloadedOperationError.contention }
        isRunning = true
        let cancellation = EvictionCancellation()
        activeCancellation = cancellation
        defer {
            finishRun()
        }
        let home = appHomeURL
        let scope = scopePath
        let patterns = config.scope.keepDownloadedPaths
        let provider = keepDownloadedProvider
        let execution = try await Task.detached(priority: .utility) {
            try provider(home, scope, patterns, trigger, cancellation)
        }.value
        await Notifier.shared.notifyKeepDownloaded(
            verified: execution.outcome.verifiedCount,
            pending: execution.outcome.pendingCount,
            failed: execution.outcome.failedCount
        )
        eventHandler(.keepDownloadedFinished(execution.receipt))
        return execution
    }

    // MARK: - Scheduled scan + policy

    private func scheduleScanTimer(intervalSeconds: Int, fireImmediately: Bool) {
        scanTimer?.cancel()
        let interval = max(60, intervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .seconds(max(5, interval / 10)))
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

    /// The heartbeat: ONE tree walk producing stats + candidates, then the
    /// policy engine decides whether to trim — using those same candidates,
    /// so a scheduled trim never walks the drive twice.
    private func scheduledScan(advisoryCandidateHints: [GuardAdvisoryCandidateHint] = []) async {
        guard !isPaused, !isRunning else { return }

        do {
            let bundle = try await scanBundle(
                cancellation: nil,
                advisoryCandidateHints: advisoryCandidateHints
            )
            lastStats = bundle.stats
            lastScanAt = Date()
            eventHandler(.statsUpdated(bundle.stats))

            guard !isPaused, !isRunning else { return }

            let stateLock: AdvisoryFileLock
            do {
                stateLock = try AdvisoryFileLock(path: appHomeURL.appendingPathComponent("run.lock").path)
                try stateLock.writeOwnerPID()
            } catch AdvisoryFileLock.LockError.unavailable {
                logger.log("state-lock-contended phase=scheduled")
                return
            } catch {
                logger.log("state-lock-failed phase=scheduled error=\(error)")
                eventHandler(.error("State unavailable; automatic eviction disabled"))
                return
            }
            let state: GuardState
            do {
                state = try stateStore.update { latest in
                    if bundle.stats.scanComplete, bundle.stats.freeSpaceAvailable {
                        latest.samples = Self.trimmedSamples(
                            latest.samples + [GuardSample(timestamp: Date(), localBytes: bundle.stats.materializedBytes, freeBytes: bundle.stats.freeBytes)]
                        )
                    }
                }
            } catch {
                logger.log("state-save-failed phase=scheduled error=\(error)")
                eventHandler(.error("State could not be saved; automatic eviction disabled"))
                withExtendedLifetime(stateLock) {}
                return
            }
            stateLock.unlock()
            eventHandler(.samplesUpdated(state.samples))

            let policy = PolicyMapping.corePolicy(from: config).normalized()
            let scan = ScanResult(
                scopePath: scopePath,
                freeBytes: bundle.stats.freeBytes,
                localBytes: bundle.stats.materializedBytes,
                items: [],
                freeSpaceAvailable: bundle.stats.freeSpaceAvailable,
                scanComplete: bundle.stats.scanComplete
            )
            let decision = PolicyEngine.evaluate(scan: scan, state: state, config: guardConfig(for: policy), now: Date())
            eventHandler(.cooldownUpdated(seconds: decision.cooldownRemainingSeconds))
            let scheduledKeepDownloaded = !config.scope.keepDownloadedPaths.isEmpty
            let scheduledEnergyDecision = decision.kind == .targeted || scheduledKeepDownloaded
                ? energyScheduler.decision(for: .scheduled)
                : nil

            switch decision.kind {
            case .targeted:
                guard let energyDecision = scheduledEnergyDecision else { break }
                if energyDecision.shouldRun {
                    logger.log("auto-trim reason=\(decision.reason) target=\(decision.reclaimTargetBytes) energy=\(energyDecision.reason.rawValue)")
                    _ = await runEviction(
                        kind: .trim,
                        reason: decision.reason,
                        byteBudget: decision.reclaimTargetBytes,
                        fileBudget: config.eviction.batchLimit,
                        precollected: bundle,
                        automatic: true
                    )
                } else {
                    let reason = "automatic eviction deferred: \(energyDecision.reason.rawValue)"
                    logger.log("auto-trim-deferred policy=\(decision.reason) energy=\(energyDecision.reason.rawValue)")
                    let report = persistReport(
                        GuardRunReport(
                            trigger: .scheduled,
                            kind: .trim,
                            action: .targeted,
                            reason: reason
                        ),
                        preStats: bundle.stats,
                        stats: bundle.stats,
                        mutationLockHeld: false
                    )
                    eventHandler(.runFinished(report))
                }
            case .panic:
                var automaticPanicLock: AdvisoryFileLock?
                if let automaticPanicLockPath {
                    do {
                        automaticPanicLock = try AdvisoryFileLock(path: automaticPanicLockPath)
                        try automaticPanicLock?.writeOwnerPID()
                    } catch AdvisoryFileLock.LockError.unavailable {
                        finishAutomaticPanicWithoutMutation(
                            reason: "automatic panic deferred: another scope owns automatic panic remediation",
                            exitCode: 0,
                            bundle: bundle
                        )
                        break
                    } catch {
                        automaticPanicLock?.unlock()
                        logger.log("automatic-panic-lock-failed error=\(error)")
                        finishAutomaticPanicWithoutMutation(
                            reason: "automatic panic disabled: shared lock unavailable",
                            exitCode: 74,
                            bundle: bundle
                        )
                        break
                    }
                }
                await runAutomaticPanic(
                    bundle: bundle,
                    reason: decision.reason,
                    lease: automaticPanicLock
                )
            case .none, .cooldown:
                break
            }
            if scheduledKeepDownloaded, !isPaused, let energyDecision = scheduledEnergyDecision {
                if energyDecision.shouldRun {
                    do { _ = try await enforceKeepDownloaded(trigger: .scheduled) }
                    catch KeepDownloadedOperationError.contention { }
                    catch {
                        logger.log("keep-downloaded-failed error=\(error)")
                        eventHandler(.error("Keep-downloaded rules failed: \(error.localizedDescription)"))
                    }
                } else {
                    finishScheduledKeepDownloadedDeferral(energyDecision)
                }
            }
        } catch {
            logger.log("scan-failed error=\(error)")
            eventHandler(.error("Scan failed: \(error.localizedDescription)"))
        }
    }

    private func runAutomaticPanic(
        bundle: ScanBundle,
        reason: String,
        lease: AdvisoryFileLock?
    ) async {
        defer { lease?.unlock() }
        logger.log("auto-panic reason=\(reason)")
        _ = await runEviction(
            kind: .panic,
            reason: reason,
            byteBudget: nil,
            fileBudget: config.eviction.panicLimit,
            precollected: bundle,
            automatic: true
        )
    }

    private func finishAutomaticPanicWithoutMutation(
        reason: String,
        exitCode: Int32,
        bundle: ScanBundle
    ) {
        let report = persistReport(
            GuardRunReport(
                trigger: .scheduled,
                kind: .panic,
                action: .panic,
                reason: reason,
                exitCode: exitCode
            ),
            preStats: bundle.stats,
            stats: bundle.stats,
            mutationLockHeld: false
        )
        eventHandler(.runFinished(report))
    }

    private func finishScheduledKeepDownloadedDeferral(_ decision: EnergySchedulingDecision) {
        let reason = "keep-downloaded deferred: \(decision.reason.rawValue)"
        var receipt = GuardRunReceipt(
            startedAt: Date(),
            trigger: .scheduled,
            command: "keep-downloaded",
            requestedAction: "keep-downloaded",
            action: .none,
            dryRun: false,
            reason: reason,
            reasonMetadata: ["energy_reason": decision.reason.rawValue],
            sourceScopeIdentifier: PrivacyIdentifier.scope(scopePath),
            privacyScopePath: scopePath,
            exitCode: 0,
            status: .noAction,
            statePersisted: true,
            watchlistPersisted: true
        )
        do {
            let lock = try AdvisoryFileLock(path: appHomeURL.appendingPathComponent("run.lock").path)
            defer { lock.unlock() }
            try lock.writeOwnerPID()
            _ = try RunHistoryStore(url: appHomeURL.appendingPathComponent("history.json")).append(receipt)
            logger.log("keep-downloaded-deferred energy=\(decision.reason.rawValue)")
        } catch {
            logger.log("keep-downloaded-deferral-save-failed energy=\(decision.reason.rawValue) error=\(error)")
            receipt.exitCode = 74
            receipt.status = .failed
            receipt.statePersisted = false
        }
        eventHandler(.keepDownloadedFinished(receipt))
    }

    private static func validateRuntimeConfigScope(
        _ config: AppConfig,
        serviceScopePath: String
    ) throws {
        let expected = canonicalExistingPath(serviceScopePath)
        let configured = canonicalExistingPath(config.scope.path)
        guard let expected, let configured, expected == configured else {
            throw GuardRuntimeConfigurationError.scopeMismatch(
                expected: expected ?? serviceScopePath,
                configured: configured ?? config.scope.path
            )
        }
    }

    private static func canonicalExistingPath(_ path: String) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard expanded.withCString({ realpath($0, &resolved) }) != nil else { return nil }
        return String(cString: resolved)
    }

    /// One shared tree walk at a time. Concurrent status/menu/scheduler callers
    /// await the same immutable snapshot; pause cancels the underlying walk.
    private func scanBundle(
        cancellation callerCancellation: EvictionCancellation?,
        advisoryCandidateHints: [GuardAdvisoryCandidateHint] = []
    ) async throws -> ScanBundle {
        var bundle = try await rawScanBundle(
            at: scopePath,
            protectedPaths: config.scope.evictionPolicyMatcher,
            cancellation: callerCancellation
        )
        if !advisoryCandidateHints.isEmpty {
            let identitiesByPath = Dictionary(grouping: advisoryCandidateHints, by: \.path)
                .mapValues { $0.map(\.identity) }
            var hinted: [EvictionCandidate] = []
            var remaining: [EvictionCandidate] = []
            hinted.reserveCapacity(min(bundle.candidates.count, advisoryCandidateHints.count))
            remaining.reserveCapacity(bundle.candidates.count)
            for candidate in bundle.candidates {
                if let identity = candidate.identity,
                   identitiesByPath[candidate.path]?.contains(identity) == true {
                    hinted.append(candidate)
                } else {
                    remaining.append(candidate)
                }
            }
            bundle.candidates = hinted + remaining
        }
        // User folder policy remains authoritative. Its stable sort preserves
        // hint priority only among candidates with the same policy rank.
        bundle.candidates = config.scope.evictionPolicyMatcher.folderPolicies.prioritized(bundle.candidates)
        return bundle
    }

    /// Serializes both full and event-targeted scans. A full scan already
    /// subsumes a requested target; a target never satisfies a full request.
    private func rawScanBundle(
        at requestedScopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        cancellation callerCancellation: EvictionCancellation?
    ) async throws -> ScanBundle {
        if let activeScanTask {
            let scanID = activeScanID
            let activeScopePath = activeScanScopePath
            let bundle = try await awaitScan(activeScanTask, callerCancellation: callerCancellation)
            guard scanID == activeScanID else { throw CancellationError() }
            finishScan(id: scanID)
            if activeScopePath == requestedScopePath || activeScopePath == scopePath {
                return bundle
            }
            return try await rawScanBundle(
                at: requestedScopePath,
                protectedPaths: protectedPaths,
                cancellation: callerCancellation
            )
        }

        let scope = requestedScopePath
        let authoritativeScope = scopePath
        let protected = protectedPaths
        let handler = eventHandler
        let provider = scanProvider
        let scanCancellation = EvictionCancellation()
        activeScanID += 1
        let scanID = activeScanID
        let task = Task.detached(priority: .utility) {
            try provider(
                scope,
                protected,
                {
                    scanCancellation.isCancelled
                        || Task<Never, Never>.isCancelled
                },
                { files in
                    if scope == authoritativeScope {
                        handler(.scanProgress(scannedFiles: files))
                    }
                }
            )
        }
        activeScanTask = task
        activeScanCancellation = scanCancellation
        activeScanScopePath = scope
        Task { [weak self] in
            _ = await task.result
            await self?.finishScan(id: scanID)
        }
        do {
            let bundle = try await awaitScan(task, callerCancellation: callerCancellation)
            guard scanID == activeScanID else { throw CancellationError() }
            finishScan(id: scanID)
            return bundle
        } catch {
            if callerCancellation?.isCancelled != true { finishScan(id: scanID) }
            throw error
        }
    }

    private func awaitScan(
        _ task: Task<ScanBundle, Error>,
        callerCancellation: EvictionCancellation?
    ) async throws -> ScanBundle {
        guard let callerCancellation else { return try await task.value }
        if callerCancellation.isCancelled { throw CancellationError() }

        let resolution = ScanWaitResolution()
        let waitFinished = EvictionCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolution.install(continuation)
                Task {
                    let result = await task.result
                    if resolution.resolve(result) { waitFinished.cancel() }
                }
                Task.detached(priority: .utility) {
                    while !waitFinished.isCancelled {
                        if callerCancellation.isCancelled {
                            if resolution.resolve(.failure(CancellationError())) { waitFinished.cancel() }
                            return
                        }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
            }
        } onCancel: {
            callerCancellation.cancel()
        }
    }

    private func finishScan(id: Int) {
        guard id == activeScanID else { return }
        activeScanTask = nil
        activeScanCancellation = nil
        activeScanScopePath = nil
    }

    private func cancelSharedScan() {
        activeScanCancellation?.cancel()
        activeScanTask?.cancel()
        activeScanID += 1
        activeScanTask = nil
        activeScanCancellation = nil
        activeScanScopePath = nil
    }

    private func waitForRunQuiescence() async {
        guard isRunning else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    private func finishRun() {
        activeCancellation = nil
        isRunning = false
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    /// Menu-open hook: rescan only when the data is genuinely stale and
    /// nothing else is already walking the drive.
    func scanIfStale(maxAgeSeconds: TimeInterval) async {
        guard activeScanTask == nil, !isRunning, !isPaused else { return }
        if let last = lastScanAt, Date().timeIntervalSince(last) < maxAgeSeconds { return }
        switch lifecycleMode {
        case .automatic:
            await scheduledScan()
        case .manualReady:
            do {
                let bundle = try await scanBundle(cancellation: nil)
                lastStats = bundle.stats
                lastScanAt = Date()
                eventHandler(.statsUpdated(bundle.stats))
            } catch {
                logger.log("manual-ready-scan-failed error=\(error)")
                eventHandler(.error("Scan failed: \(error.localizedDescription)"))
            }
        case .stopped:
            return
        }
    }

    // MARK: - Manual actions

    /// Manual trim toward the configured local-footprint target. Ignores
    /// cooldown (user-initiated) but respects the target: if already under,
    /// reports so instead of evicting needlessly.
    @discardableResult
    func trimNow(
        progress: (@Sendable (EvictionProgress) -> Void)? = nil,
        cancellation: EvictionCancellation? = nil,
        trigger: GuardRunTrigger = .appManual
    ) async -> GuardRunReport {
        let policy = PolicyMapping.corePolicy(from: config).normalized()
        return await runEviction(
            kind: .trim,
            reason: "trim toward \(formatBytes(policy.targetLocalBytes)) target",
            byteBudget: nil,
            fileBudget: config.eviction.batchLimit,
            trimTargetBytes: policy.targetLocalBytes,
            progress: progress,
            cancellation: cancellation,
            trigger: trigger
        )
    }

    /// Panic: evict everything eligible, up to the panic limit.
    @discardableResult
    func panicEvict(
        progress: (@Sendable (EvictionProgress) -> Void)? = nil,
        cancellation: EvictionCancellation? = nil,
        trigger: GuardRunTrigger = .appManual
    ) async -> GuardRunReport {
        await runEviction(
            kind: .panic,
            reason: "panic eviction",
            byteBudget: nil,
            fileBudget: config.eviction.panicLimit,
            progress: progress,
            cancellation: cancellation,
            trigger: trigger
        )
    }

    /// Reclaim an explicit amount without changing the saved policy.
    @discardableResult
    func reclaim(
        bytes: Int64,
        dryRun: Bool,
        progress: (@Sendable (EvictionProgress) -> Void)? = nil,
        cancellation: EvictionCancellation? = nil
    ) async -> GuardRunReport {
        guard bytes > 0 else {
            let report = persistReport(
                GuardRunReport(kind: .trim, reason: "reclaim goal must be greater than zero", dryRun: dryRun, exitCode: 64),
                stats: nil,
                mutationLockHeld: false
            )
            eventHandler(.runFinished(report))
            return report
        }
        if dryRun {
            return await preview(byteGoal: bytes, cancellation: cancellation)
        }
        return await runEviction(
            kind: .trim,
            reason: "manual reclaim goal",
            byteBudget: bytes,
            reclaimGoalBytes: bytes,
            fileBudget: config.eviction.batchLimit,
            progress: progress,
            cancellation: cancellation
        )
    }

    /// Dry-run: count candidates and bytes without evicting anything.
    @discardableResult
    func preview(
        command: GuardCommand = .run,
        byteGoal: Int64? = nil,
        cancellation suppliedCancellation: EvictionCancellation? = nil,
        trigger: GuardRunTrigger = .appManual
    ) async -> GuardRunReport {
        let startedAt = Date()
        let requestedGoalBytes = byteGoal
        if lifecycleMode == .stopped {
            do {
                try await prepareForManualOperations()
            } catch {
                let report = persistReport(
                    GuardRunReport(
                        startedAt: startedAt,
                        trigger: trigger,
                        kind: .preview,
                        reason: "manual readiness failed: \(error.localizedDescription)",
                        dryRun: true,
                        exitCode: 74,
                        requestedGoalBytes: requestedGoalBytes
                    ),
                    stats: nil,
                    mutationLockHeld: false
                )
                eventHandler(.runFinished(report))
                return report
            }
        }
        guard !isPaused else {
            return persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: .preview, reason: "guard is paused", dryRun: true, exitCode: 75, requestedGoalBytes: requestedGoalBytes),
                stats: nil,
                mutationLockHeld: false
            )
        }
        guard !isRunning else {
            return persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: .preview, reason: "another run is active", dryRun: true, exitCode: 75, requestedGoalBytes: requestedGoalBytes),
                stats: nil,
                mutationLockHeld: false
            )
        }
        isRunning = true
        eventHandler(.runStarted(.preview))
        defer {
            finishRun()
        }

        let cancellation = suppliedCancellation ?? EvictionCancellation()
        activeCancellation = cancellation

        do {
            let bundle = try await scanBundle(cancellation: cancellation)
            if cancellation.isCancelled {
                let report = persistReport(
                    GuardRunReport(startedAt: startedAt, trigger: trigger, kind: .preview, reason: "cancelled", cancelled: true, dryRun: true, exitCode: 130, requestedGoalBytes: requestedGoalBytes),
                    stats: bundle.stats,
                    mutationLockHeld: false
                )
                eventHandler(.runFinished(report))
                return report
            }
            guard bundle.stats.scanComplete else {
                let report = persistReport(GuardRunReport(
                    startedAt: startedAt,
                    trigger: trigger,
                    kind: .preview,
                    reason: "scan incomplete; preview unavailable",
                    candidateCount: bundle.candidates.count,
                    dryRun: true,
                    exitCode: 1,
                    requestedGoalBytes: requestedGoalBytes
                ), stats: bundle.stats, mutationLockHeld: false)
                eventHandler(.runFinished(report))
                return report
            }
            let state = try stateStore.load()
            let policy = PolicyMapping.corePolicy(from: config).normalized()
            let scan = ScanResult(
                scopePath: scopePath,
                freeBytes: bundle.stats.freeBytes,
                localBytes: bundle.stats.materializedBytes,
                items: [],
                freeSpaceAvailable: bundle.stats.freeSpaceAvailable,
                scanComplete: bundle.stats.scanComplete
            )
            let decision = PolicyEngine.evaluate(
                scan: scan,
                state: state,
                config: guardConfig(for: policy),
                now: Date(),
                forcePanic: command == .panicEvict,
                manualRequest: true
            )
            let unresolved = Set((watchlist?.snapshot ?? []).filter { $0.pendingVerification || $0.suspended }.map(\.path))
            let eligibleCandidates = bundle.candidates.filter { !unresolved.contains($0.path) }
            let plan = byteGoal.map {
                EvictionDryRunPlanner.plan(
                    action: .targeted,
                    reason: "manual reclaim goal",
                    candidates: eligibleCandidates,
                    byteGoal: $0,
                    fileLimit: config.eviction.batchLimit
                )
            } ?? EvictionDryRunPlanner.plan(
                command: command,
                decision: decision,
                candidates: eligibleCandidates,
                batchLimit: config.eviction.batchLimit,
                panicLimit: config.eviction.panicLimit
            )
            let report = persistReport(GuardRunReport(
                startedAt: startedAt,
                trigger: trigger,
                kind: .preview,
                action: plan.action,
                reason: plan.reason,
                candidateCount: plan.plannedCount,
                plannedBytes: plan.plannedBytes,
                dryRun: true,
                previewBytes: plan.plannedBytes,
                exitCode: byteGoal.map { plan.plannedBytes >= $0 ? 0 : 1 } ?? 0,
                requestedGoalBytes: requestedGoalBytes
            ), stats: bundle.stats, mutationLockHeld: false)
            eventHandler(.runFinished(report))
            return report
        } catch {
            if cancellation.isCancelled {
                let report = persistReport(
                    GuardRunReport(startedAt: startedAt, trigger: trigger, kind: .preview, reason: "cancelled", cancelled: true, dryRun: true, exitCode: 130, requestedGoalBytes: requestedGoalBytes),
                    stats: nil,
                    mutationLockHeld: false
                )
                eventHandler(.runFinished(report))
                return report
            }
            eventHandler(.error("Preview failed: \(error.localizedDescription)"))
            let report = persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: .preview, reason: "failed: \(error.localizedDescription)", dryRun: true, exitCode: 1, requestedGoalBytes: requestedGoalBytes),
                stats: nil,
                mutationLockHeld: false
            )
            eventHandler(.runFinished(report))
            return report
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
        cancelSharedScan()
    }

    // MARK: - Eviction core

    private func runEviction(
        kind: GuardRunKind,
        reason: String,
        byteBudget: Int64?,
        reclaimGoalBytes: Int64? = nil,
        fileBudget: Int,
        folderFilter: String? = nil,
        precollected: ScanBundle? = nil,
        trimTargetBytes: Int64? = nil,
        progress: (@Sendable (EvictionProgress) -> Void)? = nil,
        automatic: Bool = false,
        cancellation suppliedCancellation: EvictionCancellation? = nil,
        trigger requestedTrigger: GuardRunTrigger = .appManual
    ) async -> GuardRunReport {
        let startedAt = Date()
        let trigger: GuardRunTrigger = automatic ? .scheduled : requestedTrigger
        if lifecycleMode == .stopped {
            do {
                try await prepareForManualOperations()
            } catch {
                let report = persistReport(
                    GuardRunReport(
                        startedAt: startedAt,
                        trigger: trigger,
                        kind: kind,
                        reason: "manual readiness failed: \(error.localizedDescription)",
                        exitCode: 74,
                        requestedGoalBytes: reclaimGoalBytes
                    ),
                    stats: nil,
                    mutationLockHeld: false
                )
                eventHandler(.runFinished(report))
                return report
            }
        }
        guard !isPaused else {
            let report = persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "guard is paused", exitCode: 75, requestedGoalBytes: reclaimGoalBytes),
                stats: nil,
                mutationLockHeld: false
            )
            return report
        }
        guard !isRunning else {
            let report = persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "another run is active", exitCode: 75, requestedGoalBytes: reclaimGoalBytes),
                stats: nil,
                mutationLockHeld: false
            )
            return report
        }
        isRunning = true
        eventHandler(.runStarted(kind))
        defer {
            finishRun()
        }

        let cancellation = suppliedCancellation ?? EvictionCancellation()
        activeCancellation = cancellation
        let mutationLock: AdvisoryFileLock
        do {
            mutationLock = try AdvisoryFileLock(path: appHomeURL.appendingPathComponent("run.lock").path)
            try mutationLock.writeOwnerPID()
        } catch AdvisoryFileLock.LockError.unavailable {
            let report = persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "another mutation owner is active", exitCode: 75, requestedGoalBytes: reclaimGoalBytes),
                stats: nil,
                mutationLockHeld: false
            )
            eventHandler(.runFinished(report))
            return report
        } catch {
            let report = persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "mutation lock failed: \(error.localizedDescription)", exitCode: 74, requestedGoalBytes: reclaimGoalBytes),
                stats: nil,
                mutationLockHeld: false
            )
            eventHandler(.runFinished(report))
            return report
        }
        defer { withExtendedLifetime(mutationLock) {} }

        do {
            let bundle: ScanBundle
            if let precollected {
                bundle = precollected
            } else {
                // One walk that also refreshes the stats shown in the UI.
                let scannedBundle = try await scanBundle(cancellation: cancellation)
                lastStats = scannedBundle.stats
                lastScanAt = Date()
                eventHandler(.statsUpdated(scannedBundle.stats))
                bundle = scannedBundle
            }

            if cancellation.isCancelled {
                let report = persistReport(
                    GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "cancelled", cancelled: true, exitCode: 130, requestedGoalBytes: reclaimGoalBytes),
                    stats: bundle.stats,
                    mutationLockHeld: true
                )
                eventHandler(.runFinished(report))
                return report
            }

            guard bundle.stats.scanComplete else {
                let report = persistReport(GuardRunReport(
                    startedAt: startedAt,
                    trigger: trigger,
                    kind: kind,
                    reason: "scan incomplete; eviction disabled",
                    candidateCount: bundle.candidates.count,
                    exitCode: 1,
                    requestedGoalBytes: reclaimGoalBytes
                ), stats: bundle.stats, mutationLockHeld: true)
                eventHandler(.runFinished(report))
                return report
            }

            var candidates = bundle.candidates
            var effectiveKind = kind
            var effectiveReason = reason
            var effectiveByteBudget = byteBudget
            var effectiveFileBudget = fileBudget

            guard let watchlist,
                  let pendingPaths = watchlist.refreshPendingPaths(mutationLockHeld: true) else {
                let report = persistReport(
                    GuardRunReport(
                        startedAt: startedAt,
                        trigger: trigger,
                        kind: kind,
                        reason: "watchlist unavailable; eviction disabled",
                        exitCode: 74,
                        requestedGoalBytes: reclaimGoalBytes
                    ),
                    stats: bundle.stats,
                    mutationLockHeld: true
                )
                eventHandler(.runFinished(report))
                return report
            }

            if let trimTargetBytes {
                effectiveByteBudget = max(bundle.stats.materializedBytes - trimTargetBytes, 0)
                guard effectiveByteBudget! > 0 else {
                    let report = persistReport(
                        GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "already under \(formatBytes(trimTargetBytes)) target"),
                        stats: bundle.stats,
                        mutationLockHeld: true
                    )
                    eventHandler(.runFinished(report))
                    return report
                }
            }

            if let folderFilter {
                candidates = candidates.filter { candidate in
                    candidate.relativePath.split(separator: "/").first.map(String.init) == folderFilter
                }
            }

            if !automatic {
                candidates.removeAll { pendingPaths.contains($0.path) }
            }

            if automatic {
                let freshState = try stateStore.load()
                let scan = ScanResult(
                    scopePath: scopePath,
                    freeBytes: bundle.stats.freeBytes,
                    localBytes: bundle.stats.materializedBytes,
                    items: [],
                    freeSpaceAvailable: bundle.stats.freeSpaceAvailable,
                    scanComplete: bundle.stats.scanComplete
                )
                let policy = PolicyMapping.corePolicy(from: config).normalized()
                let gate = AutomaticRemediationGate.evaluate(
                    scan: scan,
                    state: freshState,
                    config: guardConfig(for: policy),
                    candidates: candidates,
                    pendingPaths: pendingPaths,
                    now: Date()
                )
                eventHandler(.cooldownUpdated(seconds: gate.decision.cooldownRemainingSeconds))
                candidates = gate.candidates

                switch gate.decision.kind {
                case .none, .cooldown:
                    let report = persistReport(
                        GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, action: gate.decision.kind, reason: gate.decision.reason),
                        stats: bundle.stats,
                        mutationLockHeld: true
                    )
                    eventHandler(.runFinished(report))
                    return report
                case .targeted:
                    effectiveKind = .trim
                    effectiveReason = gate.decision.reason
                    effectiveByteBudget = gate.decision.reclaimTargetBytes
                    effectiveFileBudget = config.eviction.batchLimit
                case .panic:
                    effectiveKind = .panic
                    effectiveReason = gate.decision.reason
                    effectiveByteBudget = nil
                    effectiveFileBudget = config.eviction.panicLimit
                }
            }

            guard !candidates.isEmpty else {
                let report = persistReport(
                    GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "nothing to evict", requestedGoalBytes: reclaimGoalBytes),
                    stats: bundle.stats,
                    mutationLockHeld: true
                )
                eventHandler(.runFinished(report))
                return report
            }

            let handler = eventHandler
            let mutationScope = scopePath
            let mutationProtectedPaths = config.scope.evictionPolicyMatcher
            let protectBusyPackages = config.eviction.protectBusyPackages
            let evict = evictProvider
            let mutationCandidates = candidates
            let recoveryCandidates = candidates
            let outcome = await Task.detached(priority: .utility) {
                evict(
                    mutationCandidates,
                    mutationScope,
                    mutationProtectedPaths,
                    effectiveByteBudget,
                    effectiveFileBudget,
                    protectBusyPackages,
                    cancellation
                ) { update in
                    handler(.progress(update))
                    progress?(update)
                }
            }.value

            // Register evicted paths for rematerialization defense.
            var watchlistPersisted = true
            if !outcome.evictedPaths.isEmpty || !outcome.pendingPaths.isEmpty {
                let evictedSaved = watchlist.add(
                    paths: outcome.evictedPaths,
                    identities: outcome.evictedIdentities,
                    mutationLockHeld: true
                )
                let pendingSaved = watchlist.addPending(
                    paths: outcome.pendingPaths,
                    identities: outcome.pendingIdentities,
                    mutationLockHeld: true
                )
                watchlistPersisted = evictedSaved.allAcceptedAndPersisted
                    && pendingSaved.allAcceptedAndPersisted
                    && !watchlist.hasUnsavedChanges
                eventHandler(.watchlistUpdated(count: watchlist.count))
            }

            var report = GuardRunReport(
                startedAt: startedAt,
                trigger: trigger,
                kind: effectiveKind,
                action: effectiveKind == .panic ? .panic : .targeted,
                reason: effectiveReason,
                candidateCount: outcome.processedCount,
                plannedBytes: outcome.processedBytes,
                evictedCount: outcome.evictedCount,
                pendingCount: outcome.pendingCount,
                pendingBytes: outcome.pendingBytes,
                failedCount: outcome.failedCount,
                failedBytes: outcome.failedBytes,
                reclaimedBytes: outcome.reclaimedBytes,
                failureReasons: outcome.failureReasons,
                pendingReasons: outcome.pendingReasons,
                busyProcessDisplayNames: outcome.busyProcessDisplayNames,
                cancelled: outcome.cancelled,
                exitCode: outcome.cancelled ? 130 : ((outcome.pendingCount > 0 || outcome.failedCount > 0) ? 1 : 0),
                requestedGoalBytes: reclaimGoalBytes
            )
            if let reclaimGoalBytes, outcome.reclaimedBytes < reclaimGoalBytes {
                report.exitCode = 1
            }
            if !watchlistPersisted {
                report.statePersisted = false
                report.watchlistPersisted = false
                report.exitCode = 74
                evictionLogger.log("receipt-save-failed component=watchlist command=\(kind.rawValue)")
            }

            if outcome.evictedCount > 0 {
                do {
                    try RecoveryJournalStore(
                        url: appHomeURL.appendingPathComponent("recovery.json"),
                        maximumEntries: config.watcher.watchlistMaxEntries
                    ).recordVerifiedMutations(
                        runID: report.runID,
                        scopePath: scopePath,
                        candidates: recoveryCandidates,
                        outcome: outcome
                    )
                } catch {
                    report.recoveryJournalPersisted = false
                    report.exitCode = 74
                    evictionLogger.log("recovery-journal-save-failed run=\(report.runID) error=\(error)")
                }
            }

            evictionLogger.log(
                "eviction command=\(kind.rawValue) evicted=\(outcome.evictedCount) pending=\(outcome.pendingCount) failed=\(outcome.failedCount) " +
                "verifiedReclaimed=\(outcome.reclaimedBytes) reasons=\(outcome.failureReasons)"
            )

            // Only a meaningful, verified remediation earns a post-run scan
            // and cooldown. A cached pre-run scan is never labeled remaining.
            var postStats: DriveStats?
            if outcome.evictedCount > 0, !outcome.cancelled {
                do {
                    let stats = try await scanBundle(cancellation: cancellation).stats
                    postStats = stats
                    lastStats = stats
                    lastScanAt = Date()
                    eventHandler(.statsUpdated(stats))
                    if !stats.scanComplete { report.exitCode = 1 }
                } catch {
                    logger.log("post-run-scan-failed error=\(error)")
                    report.exitCode = 1
                }
            }
            report.postScanComplete = postStats?.scanComplete ?? false
            report.freeSpaceAvailable = postStats?.freeSpaceAvailable ?? false

            let receiptReport = persistReport(report, preStats: bundle.stats, stats: postStats, mutationLockHeld: true)
            report = receiptReport
            if !watchlistPersisted {
                report.statePersisted = false
                report.watchlistPersisted = false
                report.exitCode = 74
            }
            if !report.statePersisted {
                evictionLogger.log(
                    "receipt-save-failed command=\(kind.rawValue) evicted=\(outcome.evictedCount) " +
                    "pending=\(outcome.pendingCount) failed=\(outcome.failedCount) reclaimed=\(outcome.reclaimedBytes) " +
                    "postComplete=\(report.postScanComplete) freeAvailable=\(report.freeSpaceAvailable)"
                )
            }

            // The mutation and its durable receipt are complete. Do not hold
            // the cross-process lock while awaiting notification permission or
            // user-notification delivery.
            mutationLock.unlock()
            if report.exitCode == 0, outcome.evictedCount > 0, !outcome.cancelled {
                await evictionNotification(outcome.evictedCount, outcome.reclaimedBytes)
            } else if report.exitCode != 0, !outcome.cancelled {
                await partialFailureNotification(GuardPartialFailureSummary.message(for: report))
            }

            eventHandler(.runFinished(report))

            return report
        } catch {
            if cancellation.isCancelled {
                let report = persistReport(
                    GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "cancelled", cancelled: true, exitCode: 130, requestedGoalBytes: reclaimGoalBytes),
                    stats: nil,
                    mutationLockHeld: true
                )
                eventHandler(.runFinished(report))
                return report
            }
            logger.log("run-failed kind=\(kind.rawValue) error=\(error)")
            eventHandler(.error("Run failed: \(error.localizedDescription)"))
            let report = persistReport(
                GuardRunReport(startedAt: startedAt, trigger: trigger, kind: kind, reason: "failed: \(error.localizedDescription)", exitCode: 1, requestedGoalBytes: reclaimGoalBytes),
                stats: nil,
                mutationLockHeld: true
            )
            eventHandler(.runFinished(report))
            return report
        }
    }

    private func persistReport(
        _ input: GuardRunReport,
        preStats: DriveStats? = nil,
        stats: DriveStats?,
        mutationLockHeld: Bool
    ) -> GuardRunReport {
        var report = input
        report.reason = ReceiptPrivacy.prepare(
            reason: report.reason,
            scopePath: scopePath,
            requestedGoalBytes: report.requestedGoalBytes
        ).reason
        if let stats {
            report.postScanComplete = stats.scanComplete
            report.freeSpaceAvailable = stats.freeSpaceAvailable
        }
        var ownedLock: AdvisoryFileLock?
        let historyStore = RunHistoryStore(url: appHomeURL.appendingPathComponent("history.json"))
        do {
            let legacySummary = try? stateStore.load().lastSummary
            let summary = GuardRunSummary(
                timestamp: Date(),
                action: report.action,
                reason: report.reason,
                dryRun: report.dryRun,
                candidateCount: report.candidateCount,
                evictedCount: report.evictedCount,
                pendingEvictionCount: report.pendingCount,
                failedEvictionCount: report.failedCount,
                reclaimedBytes: report.reclaimedBytes,
                remainingLocalBytes: stats?.materializedBytes ?? 0,
                remainingFreeBytes: stats?.freeBytes ?? 0,
                postScanComplete: report.postScanComplete,
                freeSpaceAvailable: report.freeSpaceAvailable,
                escalatedToPanic: false
            )
            let command = report.requestedGoalBytes == nil ? report.kind.rawValue : "reclaim"
            var receipt = GuardRunReceipt(
                summary: summary,
                startedAt: report.startedAt,
                trigger: report.trigger,
                command: command,
                requestedAction: command,
                scopePath: scopePath,
                preScan: preStats ?? stats,
                plannedBytes: report.plannedBytes > 0 ? report.plannedBytes : report.previewBytes,
                pendingBytes: report.pendingBytes,
                failedBytes: report.failedBytes,
                requestedGoalBytes: report.requestedGoalBytes,
                cancelled: report.cancelled,
                exitCode: report.exitCode,
                statePersisted: false,
                watchlistPersisted: report.watchlistPersisted
            )
            receipt.id = report.runID
            var metadata = receipt.reasonMetadata ?? [:]
            if !report.busyProcessDisplayNames.isEmpty {
                metadata["busy_processes"] = report.busyProcessDisplayNames.prefix(5).joined(separator: ", ")
            }
            metadata["recovery_journal"] = report.recoveryJournalPersisted ? "persisted" : "failed"
            receipt.reasonMetadata = metadata
            if !mutationLockHeld {
                ownedLock = try AdvisoryFileLock(path: appHomeURL.appendingPathComponent("run.lock").path)
                try ownedLock?.writeOwnerPID()
            }
            try RunPersistenceTransaction.perform(
                receipt: &receipt,
                saveState: {
                    try stateStore.update { state in
                        state.lastSummary = summary
                        if report.evictedCount > 0, !report.cancelled {
                            state.lastRemediationAt = Date()
                        }
                    }
                },
                appendReceipt: { finalReceipt in
                    _ = try historyStore.append(finalReceipt, legacySummary: legacySummary)
                }
            )
            report.statePersisted = true
        } catch AdvisoryFileLock.LockError.unavailable {
            logger.log("receipt-lock-contended command=\(report.kind.rawValue)")
            report.statePersisted = false
            report.exitCode = 75
            let command = report.requestedGoalBytes == nil ? report.kind.rawValue : "reclaim"
            var receipt = GuardRunReceipt(
                summary: GuardRunSummary(
                    timestamp: Date(),
                    action: report.action,
                    reason: report.reason,
                    dryRun: report.dryRun,
                    candidateCount: report.candidateCount,
                    evictedCount: report.evictedCount,
                    pendingEvictionCount: report.pendingCount,
                    failedEvictionCount: report.failedCount,
                    reclaimedBytes: report.reclaimedBytes,
                    remainingLocalBytes: stats?.materializedBytes ?? 0,
                    remainingFreeBytes: stats?.freeBytes ?? 0,
                    postScanComplete: report.postScanComplete,
                    freeSpaceAvailable: report.freeSpaceAvailable,
                    escalatedToPanic: false
                ),
                startedAt: report.startedAt,
                trigger: report.trigger,
                command: command,
                requestedAction: command,
                scopePath: scopePath,
                preScan: preStats ?? stats,
                plannedBytes: report.plannedBytes > 0 ? report.plannedBytes : report.previewBytes,
                pendingBytes: report.pendingBytes,
                failedBytes: report.failedBytes,
                requestedGoalBytes: report.requestedGoalBytes,
                cancelled: report.cancelled,
                exitCode: 75,
                statePersisted: false,
                watchlistPersisted: report.watchlistPersisted
            )
            receipt.id = report.runID
            receipt.status = .contended
            do {
                _ = try historyStore.append(receipt)
            } catch {
                logger.log("receipt-save-failed command=\(report.kind.rawValue) error=\(error)")
                report.exitCode = 74
            }
        } catch let failure as RunPersistenceTransaction.Failure {
            logger.log("terminal-persistence-failed command=\(report.kind.rawValue) error=\(failure)")
            report.statePersisted = failure.statePersisted
            report.exitCode = 74
        } catch {
            logger.log("state-save-failed phase=receipt command=\(report.kind.rawValue) error=\(error)")
            report.statePersisted = false
            report.exitCode = 74
        }
        withExtendedLifetime(ownedLock) {}
        return report
    }

    // MARK: - IPC status

    struct StatusResult: Sendable {
        var text: String
        var telemetry: GuardRunTelemetry?
        var exitCode: Int
    }

    func statusResult() async -> StatusResult {
        do {
            let bundle = try await scanBundle(cancellation: nil)
            let stats = bundle.stats
            lastStats = stats
            lastScanAt = Date()
            eventHandler(.statsUpdated(stats))
            let policy = PolicyMapping.corePolicy(from: config).normalized()
            let state = try stateStore.load()
            let scan = ScanResult(
                scopePath: scopePath,
                freeBytes: stats.freeBytes,
                localBytes: stats.materializedBytes,
                items: [],
                freeSpaceAvailable: stats.freeSpaceAvailable,
                scanComplete: stats.scanComplete
            )
            let decision = PolicyEngine.evaluate(scan: scan, state: state, config: guardConfig(for: policy), now: Date())

            var lines: [String] = []
            lines.append("Scope: \(scopePath)")
            lines.append("Local iCloud footprint: \(formatBytes(stats.materializedBytes)) (\(stats.materializedFiles) files)")
            lines.append("Evicted (dataless): \(stats.datalessFiles) files")
            lines.append("Free space: \(stats.freeSpaceAvailable ? formatBytes(stats.freeBytes) : "unavailable")")
            if !stats.scanComplete {
                lines.append("Scan incomplete: skipped=\(stats.skippedDirectories) errors=\(stats.scanReadErrors)")
            }
            lines.append("Watchlist: \(watchlist?.count ?? 0) path(s)")
            lines.append("Recent growth (\(policy.growthWindowMinutes)m): \(formatBytes(decision.growthBytes))")
            lines.append("Next action: \(decision.kind.rawValue) (\(decision.reason))")
            if let seconds = decision.cooldownRemainingSeconds {
                lines.append("Cooldown remaining: \(seconds)s")
            }
            return StatusResult(
                text: lines.joined(separator: "\n"),
                telemetry: GuardRunTelemetry(stats),
                exitCode: stats.scanComplete ? 0 : 65
            )
        } catch {
            return StatusResult(text: "status unavailable: \(error.localizedDescription)", telemetry: nil, exitCode: 69)
        }
    }

    /// Text status for human CLI compatibility.
    func statusText() async -> String { await statusResult().text }

    // MARK: - Helpers

    private func guardConfig(for policy: PolicyConfig) -> GuardConfig {
        GuardConfig(
            label: "app.icloud-guard",
            logPath: appHomeURL.appendingPathComponent("icloud-guard.log").path,
            lockPath: appHomeURL.appendingPathComponent("run.lock").path,
            scopePath: scopePath,
            statePath: appHomeURL.appendingPathComponent("state.json").path,
            notifications: NotificationConfig(enable: false),
            policy: policy
        )
    }

    static func trimmedSamples(_ samples: [GuardSample], now: Date = Date()) -> [GuardSample] {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        return Array(samples.filter { $0.timestamp >= cutoff }.suffix(288))
    }
}

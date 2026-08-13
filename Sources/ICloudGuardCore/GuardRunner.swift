import Darwin
import Foundation
import os

public protocol GuardLogging: AnyObject {
    func log(_ message: String)
}

public struct GuardRunnerResult: Equatable, Sendable {
    public var exitCode: Int32
    public var receipt: GuardRunReceipt?

    public init(exitCode: Int32, receipt: GuardRunReceipt? = nil) {
        self.exitCode = exitCode
        self.receipt = receipt
    }
}

/// CLI fallback runner — used when the menu bar app is not running and the
/// CLI cannot reach it over IPC. Shares the exact same engine, policy, and
/// state files as the app so behavior is identical no matter who executes.
public final class GuardRunner {
    private let engineFactory: (GuardLogging) -> EvictionEngine
    private let scanProvider: (EvictionEngine, String, ProtectedPathsMatcher, EvictionCancellation?) throws -> ScanBundle
    private let cancellation: EvictionCancellation?

    public init() {
        self.engineFactory = { logger in EvictionEngine(logger: logger) }
        self.scanProvider = { engine, scope, protected, cancellation in
            try engine.collectScanBundle(scopePath: scope, protectedPaths: protected, cancellation: cancellation)
        }
        self.cancellation = nil
    }

    init(
        engineFactory: @escaping (GuardLogging) -> EvictionEngine,
        cancellation: EvictionCancellation? = nil,
        scanProvider: ((EvictionEngine, String, ProtectedPathsMatcher, EvictionCancellation?) throws -> ScanBundle)? = nil
    ) {
        self.engineFactory = engineFactory
        self.cancellation = cancellation
        self.scanProvider = scanProvider ?? { engine, scope, protected, cancellation in
            try engine.collectScanBundle(scopePath: scope, protectedPaths: protected, cancellation: cancellation)
        }
    }

    public func run(
        command: GuardCommand,
        configPath: String?,
        dryRun: Bool,
        reclaimGoalBytes: Int64? = nil,
        quiet: Bool = false
    ) throws -> Int32 {
        try runResult(
            command: command,
            configPath: configPath,
            dryRun: dryRun,
            reclaimGoalBytes: reclaimGoalBytes,
            quiet: quiet
        ).exitCode
    }

    public func runResult(
        command: GuardCommand,
        configPath: String?,
        dryRun: Bool,
        reclaimGoalBytes: Int64? = nil,
        quiet: Bool = false,
        receiptCommand: String? = nil,
        requestedAction: String? = nil
    ) throws -> GuardRunnerResult {
        if let reclaimGoalBytes, reclaimGoalBytes <= 0 { throw GuardError.usage("reclaim goal must be greater than zero") }
        let resolvedConfigPath = configPath ?? defaultConfigPath()
        let configURL = URL(fileURLWithPath: NSString(string: resolvedConfigPath).expandingTildeInPath)
        let appConfig = try ConfigStore(configURL: configURL).loadMigratingValidated()
        let configDir = configURL.deletingLastPathComponent()
        return try runResult(
            command: command,
            appConfig: appConfig,
            storageDirectory: configDir,
            dryRun: dryRun,
            reclaimGoalBytes: reclaimGoalBytes,
            quiet: quiet,
            receiptCommand: receiptCommand,
            requestedAction: requestedAction
        )
    }

    /// Executes with a caller-supplied validated config and isolated scope
    /// storage. This avoids mutable on-disk config clones between selection and
    /// acquisition of the scope operation lock.
    public func runResult(
        command: GuardCommand,
        config: AppConfig,
        scopePaths: AppPaths.ScopePaths,
        dryRun: Bool,
        reclaimGoalBytes: Int64? = nil,
        quiet: Bool = false,
        receiptCommand: String? = nil,
        requestedAction: String? = nil
    ) throws -> GuardRunnerResult {
        try AppPaths.ensureScopeDir(scopePaths)
        return try runResult(
            command: command,
            appConfig: config,
            storageDirectory: scopePaths.root,
            dryRun: dryRun,
            reclaimGoalBytes: reclaimGoalBytes,
            quiet: quiet,
            receiptCommand: receiptCommand,
            requestedAction: requestedAction
        )
    }

    private func runResult(
        command: GuardCommand,
        appConfig: AppConfig,
        storageDirectory configDir: URL,
        dryRun: Bool,
        reclaimGoalBytes: Int64?,
        quiet: Bool,
        receiptCommand: String?,
        requestedAction: String?
    ) throws -> GuardRunnerResult {
        if let reclaimGoalBytes, reclaimGoalBytes <= 0 { throw GuardError.usage("reclaim goal must be greater than zero") }
        let policy = PolicyMapping.corePolicy(from: appConfig).normalized()

        let logger = Logger(
            logPath: configDir.appendingPathComponent("icloud-guard.log").path,
            writesToStandardOutput: !quiet
        )
        let stateStore = StateStore(statePath: configDir.appendingPathComponent("state.json").path)
        let lockPath = configDir.appendingPathComponent("run.lock").path
        let historyStore = RunHistoryStore(url: configDir.appendingPathComponent("history.json"))
        let startedAt = Date()

        do {
            switch command {
            case .status:
                let exitCode = try withLock(lockPath: lockPath) {
                    try self.executeStatus(
                        scopePath: appConfig.scope.path,
                        policy: policy,
                        logger: logger,
                        stateStore: stateStore
                    )
                }
                return GuardRunnerResult(exitCode: exitCode)
            case .run, .panicEvict:
                return try withLock(lockPath: lockPath) {
                    try self.sanitizeState(stateStore: stateStore)
                    return try self.executeRemediation(
                        command: command,
                        receiptCommand: receiptCommand ?? command.rawValue,
                        requestedAction: requestedAction ?? receiptCommand ?? command.rawValue,
                        scopePath: appConfig.scope.path,
                        policy: policy,
                        batchLimit: appConfig.eviction.batchLimit,
                        panicLimit: appConfig.eviction.panicLimit,
                        protectBusyPackages: appConfig.eviction.protectBusyPackages,
                        watcherConfig: appConfig.watcher,
                        reclaimGoalBytes: reclaimGoalBytes,
                        dryRun: dryRun,
                        quiet: quiet,
                        logger: logger,
                        stateStore: stateStore,
                        historyStore: historyStore,
                        storageDirectory: configDir
                    )
                }
            }
        } catch GuardError.lockUnavailable(let message) {
            logger.log("skip reason=lock-contention command=\(command.rawValue)")
            if !quiet { print(message) }
            let receipt = recordFailureReceipt(
                historyStore: historyStore,
                startedAt: startedAt,
                command: command,
                receiptCommand: receiptCommand ?? command.rawValue,
                requestedAction: requestedAction ?? receiptCommand ?? command.rawValue,
                requestedGoalBytes: reclaimGoalBytes,
                dryRun: dryRun,
                scopePath: appConfig.scope.path,
                reason: message,
                exitCode: 75,
                status: .contended,
                logger: logger
            )
            return GuardRunnerResult(exitCode: receipt == nil ? 74 : 75, receipt: receipt)
        } catch let failure as RunPersistenceTransaction.Failure where failure.receiptPersisted {
            logger.log("terminal-persistence-failed command=\(command.rawValue) error=\(failure)")
            return GuardRunnerResult(exitCode: 74)
        } catch {
            let code = terminalExitCode(for: error)
            logger.log("terminal-failed command=\(command.rawValue) exit=\(code) error=\(error)")
            guard recordFailureReceipt(
                historyStore: historyStore,
                startedAt: startedAt,
                command: command,
                receiptCommand: receiptCommand ?? command.rawValue,
                requestedAction: requestedAction ?? receiptCommand ?? command.rawValue,
                requestedGoalBytes: reclaimGoalBytes,
                dryRun: dryRun,
                scopePath: appConfig.scope.path,
                reason: "failed: \(error.localizedDescription)",
                exitCode: code,
                status: code == 130 ? .cancelled : .failed,
                logger: logger
            ) != nil else { return GuardRunnerResult(exitCode: 74) }
            throw error
        }
    }

    // MARK: - Status

    private func executeStatus(
        scopePath: String,
        policy: PolicyConfig,
        logger: Logger,
        stateStore: StateStore
    ) throws -> Int32 {
        let startedAt = Date()
        logger.log("scan-start command=status")
        let stats = try withWatchdog(timeoutSeconds: 900, logger: logger) {
            try DriveStatsCollector.collect(scopePath: scopePath)
        }
        logger.log("scan-complete local=\(stats.materializedBytes) free=\(stats.freeSpaceAvailable ? String(stats.freeBytes) : "unavailable") complete=\(stats.scanComplete) elapsedMs=\(elapsedMilliseconds(since: startedAt))")

        let state = try stateStore.load()
        let scan = ScanResult(
            scopePath: scopePath,
            freeBytes: stats.freeBytes,
            localBytes: stats.materializedBytes,
            items: [],
            freeSpaceAvailable: stats.freeSpaceAvailable,
            scanComplete: stats.scanComplete
        )
        let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config(for: policy), now: Date())
        logger.log("status local=\(stats.materializedBytes) free=\(stats.freeBytes) decision=\(decision.kind.rawValue) growth=\(decision.growthBytes)")

        print("Scope: \(scopePath)")
        print("Local iCloud footprint: \(formatBytes(stats.materializedBytes)) (\(stats.materializedFiles) files)")
        print("Evicted (dataless): \(stats.datalessFiles) files")
        print("Free space: \(stats.freeSpaceAvailable ? formatBytes(stats.freeBytes) : "unavailable")")
        if !stats.scanComplete {
            print("Scan incomplete: skipped=\(stats.skippedDirectories) errors=\(stats.scanReadErrors)")
        }
        print("Recent growth (\(policy.growthWindowMinutes)m): \(formatBytes(decision.growthBytes))")
        print("Next action: \(decision.kind.rawValue) (\(decision.reason))")
        if let seconds = decision.cooldownRemainingSeconds {
            print("Cooldown remaining: \(seconds)s")
        }
        if let summary = state.lastSummary {
            print("Last summary: \(summary.action.rawValue) at \(ISO8601DateFormatter().string(from: summary.timestamp))")
        }
        return stats.scanComplete ? 0 : 65
    }

    // MARK: - Remediation

    private func executeRemediation(
        command: GuardCommand,
        receiptCommand: String,
        requestedAction: String,
        scopePath: String,
        policy: PolicyConfig,
        batchLimit: Int,
        panicLimit: Int,
        protectBusyPackages: Bool,
        watcherConfig: AppConfig.WatcherConfig,
        reclaimGoalBytes: Int64?,
        dryRun: Bool,
        quiet: Bool,
        logger: Logger,
        stateStore: StateStore,
        historyStore: RunHistoryStore,
        storageDirectory: URL
    ) throws -> GuardRunnerResult {
        let now = Date()
        var state = try stateStore.load()
        state.activeLock = ActiveLock(pid: getpid(), startedAt: now)
        try stateStore.save(state)
        logger.log("scan-start command=\(command.rawValue) dryRun=\(dryRun)")

        // Generous ceiling: fileproviderd churn after a large eviction can
        // slow the post-run scan dramatically. The watchdog exists to kill
        // truly hung runs, not to rush healthy ones.
        let watchdog = RunWatchdog(timeoutSeconds: max(policy.sampleIntervalSeconds * 6, 1800), logger: logger)
        defer {
            watchdog.cancel()
            var clearedState = (try? stateStore.load()) ?? state
            clearedState.activeLock = nil
            do {
                try stateStore.save(clearedState)
            } catch {
                logger.log("active-lock-clear-failed error=\(error)")
            }
        }

        let engine = engineFactory(logger)

        // One tree walk feeds both policy and candidates. Eviction still
        // revalidates each identity immediately before the FileProvider call.
        let protected = ProtectedPathsMatcher(
            protectedPaths: policy.protectedPaths,
            keepDownloadedPatterns: policy.keepDownloadedPaths,
            folderPolicies: policy.folderPolicies
        )
        var scanBundle = try scanProvider(engine, scopePath, protected, cancellation)
        scanBundle.candidates = protected.folderPolicies.prioritized(scanBundle.candidates)
        let stats = scanBundle.stats
        if stats.scanComplete, stats.freeSpaceAvailable {
            state.samples = trimSamples(
                state.samples + [GuardSample(timestamp: now, localBytes: stats.materializedBytes, freeBytes: stats.freeBytes)],
                now: now
            )
        }
        let scan = ScanResult(
            scopePath: scopePath,
            freeBytes: stats.freeBytes,
            localBytes: stats.materializedBytes,
            items: [],
            freeSpaceAvailable: stats.freeSpaceAvailable,
            scanComplete: stats.scanComplete
        )
        var decision = PolicyEngine.evaluate(
            scan: scan,
            state: state,
            config: config(for: policy),
            now: now,
            forcePanic: command == .panicEvict,
            manualRequest: true
        )
        if let reclaimGoalBytes {
            let (predictedFree, overflow) = stats.freeBytes.addingReportingOverflow(reclaimGoalBytes)
            decision = GuardDecision(
                kind: .targeted,
                reason: "manual reclaim goal",
                candidates: [],
                reclaimTargetBytes: reclaimGoalBytes,
                predictedLocalBytes: max(stats.materializedBytes - reclaimGoalBytes, 0),
                predictedFreeBytes: overflow ? .max : predictedFree,
                cooldownRemainingSeconds: nil,
                growthBytes: decision.growthBytes
            )
        }

        guard decision.kind == .targeted || decision.kind == .panic else {
            let summary = GuardRunSummary(
                timestamp: now,
                action: decision.kind,
                reason: decision.reason,
                dryRun: dryRun,
                candidateCount: 0,
                evictedCount: 0,
                failedEvictionCount: 0,
                reclaimedBytes: 0,
                remainingLocalBytes: stats.materializedBytes,
                remainingFreeBytes: stats.freeBytes,
                postScanComplete: stats.scanComplete,
                freeSpaceAvailable: stats.freeSpaceAvailable,
                escalatedToPanic: false
            )
            let exitCode: Int32 = stats.scanComplete ? 0 : 65
            let receipt = try persistTerminal(
                summary: summary, startedAt: now, command: command, scopePath: scopePath,
                preStats: stats, plannedBytes: 0, exitCode: exitCode,
                state: &state, stateStore: stateStore, historyStore: historyStore,
                watchlistPersisted: true, receiptCommand: receiptCommand,
                requestedAction: requestedAction, requestedGoalBytes: reclaimGoalBytes
            )
            logger.log("noop action=\(decision.kind.rawValue) reason=\(decision.reason)")
            if !quiet { printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, startingFreeAvailable: stats.freeSpaceAvailable, reason: decision.reason) }
            return GuardRunnerResult(exitCode: exitCode, receipt: receipt)
        }

        guard scanBundle.stats.scanComplete else {
            let summary = GuardRunSummary(
                timestamp: now,
                action: .none,
                reason: "candidate scan incomplete; eviction disabled",
                dryRun: dryRun,
                candidateCount: scanBundle.candidates.count,
                evictedCount: 0,
                failedEvictionCount: 0,
                reclaimedBytes: 0,
                remainingLocalBytes: 0,
                remainingFreeBytes: 0,
                postScanComplete: false,
                freeSpaceAvailable: false,
                escalatedToPanic: false
            )
            do {
                let receipt = try persistTerminal(
                    summary: summary, startedAt: now, command: command, scopePath: scopePath,
                    preStats: stats, plannedBytes: 0, exitCode: 65,
                    state: &state, stateStore: stateStore, historyStore: historyStore,
                    watchlistPersisted: true, receiptCommand: receiptCommand,
                    requestedAction: requestedAction, requestedGoalBytes: reclaimGoalBytes
                )
                if !quiet { printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, startingFreeAvailable: stats.freeSpaceAvailable, reason: summary.reason) }
                return GuardRunnerResult(exitCode: 65, receipt: receipt)
            } catch {
                logger.log("receipt-save-failed action=none reason=candidate-scan-incomplete error=\(error)")
                if !quiet { printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, startingFreeAvailable: stats.freeSpaceAvailable, reason: summary.reason) }
                return GuardRunnerResult(exitCode: 74)
            }
        }
        let watchlistEntries = try WatchlistInspectionService.loadEntries(
            storageURL: storageDirectory.appendingPathComponent("watchlist.json"),
            scopePath: scopePath
        )
        let unresolvedPaths = Set(watchlistEntries.filter { $0.pendingVerification || $0.suspended }.map(\.path))
        let candidates = scanBundle.candidates.filter { !unresolvedPaths.contains($0.path) }
        let candidateBytes = candidates.reduce(into: Int64(0)) { $0 += $1.allocatedBytes }
        logger.log("candidates count=\(candidates.count) bytes=\(candidateBytes) decision=\(decision.kind.rawValue)")

        if candidates.isEmpty {
            let summary = GuardRunSummary(
                timestamp: now,
                action: decision.kind,
                reason: decision.reason,
                dryRun: dryRun,
                candidateCount: 0,
                evictedCount: 0,
                failedEvictionCount: 0,
                reclaimedBytes: 0,
                remainingLocalBytes: stats.materializedBytes,
                remainingFreeBytes: stats.freeBytes,
                postScanComplete: stats.scanComplete,
                freeSpaceAvailable: stats.freeSpaceAvailable,
                escalatedToPanic: false
            )
            let exitCode: Int32 = reclaimGoalBytes == nil ? 0 : 1
            let receipt = try persistTerminal(
                summary: summary, startedAt: now, command: command, scopePath: scopePath,
                preStats: stats, plannedBytes: 0, exitCode: exitCode,
                state: &state, stateStore: stateStore, historyStore: historyStore,
                watchlistPersisted: true, receiptCommand: receiptCommand,
                requestedAction: requestedAction, requestedGoalBytes: reclaimGoalBytes
            )
            logger.log("noop action=\(decision.kind.rawValue) reason=no-candidates")
            if !quiet { printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, startingFreeAvailable: stats.freeSpaceAvailable, reason: decision.reason) }
            return GuardRunnerResult(exitCode: exitCode, receipt: receipt)
        }

        // Eviction (or dry-run report)
        let byteBudget: Int64? = decision.kind == .panic ? nil : decision.reclaimTargetBytes
        let fileBudget = decision.kind == .panic ? panicLimit : batchLimit

        if dryRun {
            let plan = reclaimGoalBytes.map {
                EvictionDryRunPlanner.plan(
                    action: .targeted,
                    reason: "manual reclaim goal",
                    candidates: candidates,
                    byteGoal: $0,
                    fileLimit: batchLimit
                )
            } ?? EvictionDryRunPlanner.plan(
                command: command,
                decision: decision,
                candidates: candidates,
                batchLimit: batchLimit,
                panicLimit: panicLimit
            )
            if !quiet {
                print("Dry run: would evict \(plan.plannedCount) file(s), reclaiming \(formatBytes(plan.plannedBytes))")
                for candidate in plan.candidates.prefix(20) {
                    print("  \(candidate.relativePath) (\(formatBytes(candidate.allocatedBytes)))")
                }
                if plan.plannedCount > 20 {
                    print("  … and \(plan.plannedCount - 20) more")
                }
            }
            let summary = GuardRunSummary(
                timestamp: now,
                action: plan.action,
                reason: plan.reason,
                dryRun: true,
                candidateCount: plan.plannedCount,
                evictedCount: 0,
                failedEvictionCount: 0,
                reclaimedBytes: 0,
                remainingLocalBytes: scanBundle.stats.materializedBytes,
                remainingFreeBytes: scanBundle.stats.freeBytes,
                postScanComplete: scanBundle.stats.scanComplete,
                freeSpaceAvailable: scanBundle.stats.freeSpaceAvailable,
                escalatedToPanic: false
            )
            let exitCode: Int32 = reclaimGoalBytes.map { plan.plannedBytes >= $0 ? 0 : 1 } ?? 0
            do {
                let receipt = try persistTerminal(
                    summary: summary, startedAt: now, command: command, scopePath: scopePath,
                    preStats: stats, plannedBytes: plan.plannedBytes, exitCode: exitCode,
                    state: &state, stateStore: stateStore, historyStore: historyStore,
                    watchlistPersisted: true, receiptCommand: receiptCommand,
                    requestedAction: requestedAction, requestedGoalBytes: reclaimGoalBytes
                )
                return GuardRunnerResult(exitCode: exitCode, receipt: receipt)
            } catch {
                logger.log("receipt-save-failed action=\(decision.kind.rawValue) dryRun=true error=\(error)")
                return GuardRunnerResult(exitCode: 74)
            }
        }

        let outcome = engine.evict(
            candidates: candidates,
            scopePath: scopePath,
            protectedPaths: protected,
            byteBudget: byteBudget,
            fileBudget: fileBudget,
            cancellation: cancellation,
            protectBusyPackages: protectBusyPackages
        )
        let runID = UUID().uuidString.lowercased()
        var recoveryJournalPersisted = true
        if outcome.evictedCount > 0 {
            do {
                try RecoveryJournalStore(
                    url: storageDirectory.appendingPathComponent("recovery.json"),
                    maximumEntries: watcherConfig.watchlistMaxEntries
                ).recordVerifiedMutations(
                    runID: runID,
                    scopePath: scopePath,
                    candidates: candidates,
                    outcome: outcome
                )
            } catch {
                recoveryJournalPersisted = false
                logger.log("recovery-journal-save-failed run=\(runID) error=\(error)")
            }
        }

        // Feed the shared watchlist so the app re-evicts anything that bounces back.
        var watchlistPersisted = true
        if !outcome.evictedPaths.isEmpty || !outcome.pendingPaths.isEmpty {
            let watchlist = WatchlistWatcher(
                storageURL: storageDirectory.appendingPathComponent("watchlist.json"),
                logger: logger,
                protectedPaths: protected,
                scopePath: scopePath,
                maxEntries: watcherConfig.watchlistMaxEntries,
                maxFights: watcherConfig.maxFights,
                pendingRetryLimit: watcherConfig.pendingRetryLimit,
                backoffMaxSeconds: TimeInterval(watcherConfig.backoffMaxSeconds),
                pendingVerificationGraceSeconds: TimeInterval(watcherConfig.pendingVerificationGraceSeconds),
                verifiedRetentionSeconds: TimeInterval(watcherConfig.verifiedRetentionHours * 60 * 60),
                mutationLockPath: storageDirectory.appendingPathComponent("run.lock").path,
                mutationLockHeld: true,
                protectBusyPackages: protectBusyPackages
            )
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
            if !watchlistPersisted {
                logger.log("receipt-save-failed component=watchlist error=\(watchlist.lastPersistenceError ?? "unknown")")
            }
        }

        var postStats: DriveStats?
        if outcome.evictedCount > 0, !outcome.cancelled {
            do {
                postStats = try DriveStatsCollector.collect(scopePath: scopePath)
            } catch {
                logger.log("post-run-scan-failed action=\(decision.kind.rawValue) error=\(error)")
            }
        }
        let summary = GuardRunSummary(
            timestamp: now,
            action: decision.kind,
            reason: decision.reason,
            dryRun: dryRun,
            candidateCount: outcome.processedCount,
            evictedCount: outcome.evictedCount,
            pendingEvictionCount: outcome.pendingCount,
            failedEvictionCount: outcome.failedCount,
            reclaimedBytes: outcome.reclaimedBytes,
            remainingLocalBytes: postStats?.materializedBytes ?? 0,
            remainingFreeBytes: postStats?.freeBytes ?? 0,
            postScanComplete: postStats?.scanComplete ?? false,
            freeSpaceAvailable: postStats?.freeSpaceAvailable ?? false,
            escalatedToPanic: false
        )
        if outcome.evictedCount > 0, !outcome.cancelled {
            state.lastRemediationAt = now
        }
        var exitCode: Int32 = 0
        if !watchlistPersisted || !recoveryJournalPersisted { exitCode = 74 }
        else if outcome.cancelled { exitCode = 130 }
        else if outcome.pendingCount > 0 || outcome.failedCount > 0 { exitCode = 1 }
        else if let reclaimGoalBytes, outcome.reclaimedBytes < reclaimGoalBytes { exitCode = 1 }
        else if outcome.evictedCount > 0, postStats?.scanComplete != true { exitCode = 65 }
        do {
            let receipt = try persistTerminal(
                summary: summary, startedAt: now, command: command, scopePath: scopePath,
                preStats: stats, plannedBytes: outcome.processedBytes,
                pendingBytes: outcome.pendingBytes,
                failedBytes: outcome.failedBytes,
                cancelled: outcome.cancelled, exitCode: exitCode,
                state: &state, stateStore: stateStore, historyStore: historyStore,
                watchlistPersisted: watchlistPersisted, receiptCommand: receiptCommand,
                requestedAction: requestedAction, requestedGoalBytes: reclaimGoalBytes,
                runID: runID,
                reasonMetadata: [
                    "recovery_journal": recoveryJournalPersisted ? "persisted" : "failed",
                    "busy_processes": outcome.busyProcessDisplayNames.prefix(5).joined(separator: ", ")
                ].filter { !$0.value.isEmpty }
            )
            logger.log("remediation action=\(decision.kind.rawValue) reclaimed=\(outcome.reclaimedBytes) evicted=\(outcome.evictedCount) pending=\(outcome.pendingCount) failed=\(outcome.failedCount)")
            if !quiet { printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, startingFreeAvailable: stats.freeSpaceAvailable, reason: decision.reason) }
            return GuardRunnerResult(exitCode: exitCode, receipt: receipt)
        } catch {
            logger.log(
                "receipt-save-failed action=\(decision.kind.rawValue) evicted=\(outcome.evictedCount) " +
                "pending=\(outcome.pendingCount) failed=\(outcome.failedCount) reclaimed=\(outcome.reclaimedBytes) " +
                "postComplete=\(summary.postScanComplete) freeAvailable=\(summary.freeSpaceAvailable) error=\(error)"
            )
            if !quiet { printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, startingFreeAvailable: stats.freeSpaceAvailable, reason: decision.reason) }
            return GuardRunnerResult(exitCode: 74)
        }
    }

    private func recordFailureReceipt(
        historyStore: RunHistoryStore,
        startedAt: Date,
        command: GuardCommand,
        receiptCommand: String,
        requestedAction: String,
        requestedGoalBytes: Int64?,
        dryRun: Bool,
        scopePath: String,
        reason: String,
        exitCode: Int32,
        status: GuardRunStatus,
        logger: Logger
    ) -> GuardRunReceipt? {
        let receipt = GuardRunReceipt(
            startedAt: startedAt,
            endedAt: Date(),
            trigger: .cli,
            command: receiptCommand,
            requestedAction: requestedAction,
            action: .none,
            dryRun: dryRun,
            reason: reason,
            requestedGoalBytes: requestedGoalBytes,
            sourceScopeIdentifier: PrivacyIdentifier.scope(scopePath),
            privacyScopePath: scopePath,
            cancelled: exitCode == 130,
            exitCode: exitCode,
            status: status,
            statePersisted: false,
            watchlistPersisted: false
        )
        do {
            _ = try historyStore.append(receipt)
            return receipt
        } catch {
            logger.log("receipt-save-failed command=\(command.rawValue) error=\(error)")
            return nil
        }
    }

    private func terminalExitCode(for error: Error) -> Int32 {
        if error is CancellationError { return 130 }
        if error is ConfigStore.ConfigError { return 78 }
        if error is RunHistoryStore.HistoryError || error is RunPersistenceTransaction.Failure { return 74 }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain { return 74 }
        return 69
    }

    // MARK: - Plumbing (lock, watchdog, samples)

    private func persistTerminal(
        summary: GuardRunSummary,
        startedAt: Date,
        command: GuardCommand,
        scopePath: String,
        preStats: DriveStats?,
        plannedBytes: Int64,
        pendingBytes: Int64 = 0,
        failedBytes: Int64 = 0,
        cancelled: Bool = false,
        exitCode: Int32,
        state: inout GuardState,
        stateStore: StateStore,
        historyStore: RunHistoryStore,
        watchlistPersisted: Bool,
        receiptCommand: String? = nil,
        requestedAction: String? = nil,
        requestedGoalBytes: Int64? = nil,
        runID: String? = nil,
        reasonMetadata: [String: String] = [:]
    ) throws -> GuardRunReceipt {
        let legacySummary = state.lastSummary
        var receipt = GuardRunReceipt(
            summary: summary,
            startedAt: startedAt,
            trigger: .cli,
            command: receiptCommand ?? command.rawValue,
            requestedAction: requestedAction ?? receiptCommand ?? command.rawValue,
            scopePath: scopePath,
            preScan: preStats,
            plannedBytes: plannedBytes,
            pendingBytes: pendingBytes,
            failedBytes: failedBytes,
            requestedGoalBytes: requestedGoalBytes,
            cancelled: cancelled,
            exitCode: exitCode,
            statePersisted: false,
            watchlistPersisted: watchlistPersisted
        )
        if let runID { receipt.id = runID }
        if !reasonMetadata.isEmpty {
            var metadata = receipt.reasonMetadata ?? [:]
            for (key, value) in reasonMetadata { metadata[key] = value }
            receipt.reasonMetadata = metadata
        }
        receipt.endedAt = Date()
        state.lastSummary = summary
        try RunPersistenceTransaction.perform(
            receipt: &receipt,
            saveState: { try stateStore.save(state) },
            appendReceipt: { finalReceipt in
                _ = try historyStore.append(finalReceipt, legacySummary: legacySummary)
            }
        )
        return receipt
    }

    private func config(for policy: PolicyConfig) -> GuardConfig {
        GuardConfig(
            label: "org.nix-community.home.icloud-guard",
            logPath: AppPaths.log.path,
            lockPath: AppPaths.lock.path,
            scopePath: "",
            statePath: AppPaths.state.path,
            notifications: NotificationConfig(enable: false),
            policy: policy
        )
    }

    private func defaultConfigPath() -> String {
        AppPaths.config.path
    }

    private func withLock<T>(
        lockPath: String,
        body: () throws -> T
    ) throws -> T {
        let url = URL(fileURLWithPath: NSString(string: lockPath).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            let lock = try AdvisoryFileLock(path: url.path)
            try lock.writeOwnerPID()
            defer { withExtendedLifetime(lock) {} }
            return try body()
        } catch AdvisoryFileLock.LockError.unavailable {
            throw GuardError.lockUnavailable("another icloud-guard run is already active")
        } catch AdvisoryFileLock.LockError.system(let errorNumber) {
            throw GuardError.runtime("failed to acquire lock at \(url.path): \(String(cString: strerror(errorNumber)))")
        }
    }

    private func sanitizeState(stateStore: StateStore) throws {
        var state = try stateStore.load()
        guard let activeLock = state.activeLock, !isProcessAlive(activeLock.pid) else {
            return
        }

        state.activeLock = nil
        try stateStore.save(state)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    private func trimSamples(_ samples: [GuardSample], now: Date) -> [GuardSample] {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        return Array(samples.filter { $0.timestamp >= cutoff }.suffix(288))
    }

    private func printSummary(
        summary: GuardRunSummary,
        startingLocal: Int64,
        startingFree: Int64,
        startingFreeAvailable: Bool,
        reason: String
    ) {
        print("Action: \(summary.action.rawValue)")
        print("Reason: \(reason)")
        print("Dry run: \(summary.dryRun ? "yes" : "no")")
        print("Starting local footprint: \(formatBytes(startingLocal))")
        print("Starting free space: \(startingFreeAvailable ? formatBytes(startingFree) : "unavailable")")
        print("Candidates selected: \(summary.candidateCount)")
        print("Evicted count: \(summary.evictedCount)")
        print("Pending verification: \(summary.pendingEvictionCount)")
        print("Failed evictions: \(summary.failedEvictionCount)")
        print("Reclaimed bytes: \(formatBytes(summary.reclaimedBytes))")
        print("Remaining local footprint: \(summary.postScanComplete ? formatBytes(summary.remainingLocalBytes) : "unavailable")")
        print("Remaining free space: \(summary.freeSpaceAvailable ? formatBytes(summary.remainingFreeBytes) : "unavailable")")
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    private func withWatchdog<T>(timeoutSeconds: Int, logger: Logger, body: () throws -> T) throws -> T {
        let watchdog = RunWatchdog(timeoutSeconds: timeoutSeconds, logger: logger)
        defer {
            watchdog.cancel()
        }

        return try body()
    }
}

/// Thread-safe synchronous logger. The unfair lock is the sole owner of the
/// mutable file handle and byte count; immutable `logURL` is safe to read
/// concurrently.
public final class Logger: GuardLogging, Sendable {
    private struct State {
        var fileHandle: FileHandle?
        var bytesWritten: Int64 = 0
    }

    private let logURL: URL
    private let writesToStandardOutput: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maxFileSize: Int64 = 10 * 1024 * 1024

    public init(logPath: String, writesToStandardOutput: Bool = true) {
        self.logURL = URL(fileURLWithPath: NSString(string: logPath).expandingTildeInPath)
        self.writesToStandardOutput = writesToStandardOutput
    }

    public func log(_ message: String) {
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if writesToStandardOutput { fputs(rendered, stdout) }

        state.withLock { state in
            ensureHandle(state: &state)
            if state.bytesWritten >= maxFileSize {
                rotate(state: &state)
            }
            guard let handle = state.fileHandle else { return }
            guard let data = rendered.data(using: .utf8) else { return }
            do {
                try handle.write(contentsOf: data)
                state.bytesWritten += Int64(data.count)
            } catch {
                state.fileHandle = nil
                fputs("[icloud-guard] log write failed: \(error)\n", stderr)
            }
        }
    }

    private func ensureHandle(state: inout State) {
        guard state.fileHandle == nil else { return }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        let endOffset = (try? handle.seekToEnd()) ?? 0
        state.bytesWritten = Int64(endOffset)
        state.fileHandle = handle
    }

    private func rotate(state: inout State) {
        try? state.fileHandle?.close()
        state.fileHandle = nil
        let backupPath = logURL.path + ".1"
        try? FileManager.default.removeItem(atPath: backupPath)
        try? FileManager.default.moveItem(atPath: logURL.path, toPath: backupPath)
        state.bytesWritten = 0
        ensureHandle(state: &state)
    }

    deinit {
        state.withLock { state in
            try? state.fileHandle?.close()
            state.fileHandle = nil
        }
    }
}

private final class RunWatchdog {
    private let workItem: DispatchWorkItem

    init(timeoutSeconds: Int, logger: Logger) {
        self.workItem = DispatchWorkItem {
            logger.log("watchdog-timeout timeoutSeconds=\(timeoutSeconds) pid=\(getpid())")
            fflush(stdout)
            fflush(stderr)
            _exit(124)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds),
            execute: workItem
        )
    }

    func cancel() {
        workItem.cancel()
    }
}

import Darwin
import Foundation

public protocol GuardLogging: AnyObject {
    func log(_ message: String)
}

/// CLI fallback runner — used when the menu bar app is not running and the
/// CLI cannot reach it over IPC. Shares the exact same engine, policy, and
/// state files as the app so behavior is identical no matter who executes.
public final class GuardRunner {
    private let engineFactory: (GuardLogging) -> EvictionEngine

    public init() {
        self.engineFactory = { logger in EvictionEngine(logger: logger) }
    }

    init(engineFactory: @escaping (GuardLogging) -> EvictionEngine) {
        self.engineFactory = engineFactory
    }

    public func run(command: GuardCommand, configPath: String?, dryRun: Bool) throws -> Int32 {
        let resolvedConfigPath = configPath ?? defaultConfigPath()
        let configURL = URL(fileURLWithPath: NSString(string: resolvedConfigPath).expandingTildeInPath)
        let appConfig = ConfigStore(configURL: configURL).loadMigrating()
        let policy = PolicyMapping.corePolicy(from: appConfig).normalized()
        let configDir = configURL.deletingLastPathComponent()

        let logger = Logger(logPath: configDir.appendingPathComponent("icloud-guard.log").path)
        let stateStore = StateStore(statePath: configDir.appendingPathComponent("state.json").path)
        let lockPath = configDir.appendingPathComponent("run.lock").path
        try sanitizeState(stateStore: stateStore)

        switch command {
        case .status:
            return try executeStatus(
                scopePath: appConfig.scope.path,
                policy: policy,
                logger: logger,
                stateStore: stateStore
            )
        case .run, .panicEvict:
            do {
                return try withLock(lockPath: lockPath, logger: logger, stateStore: stateStore) {
                    try self.executeRemediation(
                        command: command,
                        scopePath: appConfig.scope.path,
                        policy: policy,
                        batchLimit: appConfig.eviction.batchLimit,
                        panicLimit: appConfig.eviction.panicLimit,
                        dryRun: dryRun,
                        logger: logger,
                        stateStore: stateStore
                    )
                }
            } catch GuardError.lockUnavailable(let message) {
                logger.log("skip reason=lock-contention command=\(command.rawValue)")
                print(message)
                return 0
            }
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
        logger.log("scan-complete local=\(stats.materializedBytes) free=\(stats.freeBytes) elapsedMs=\(elapsedMilliseconds(since: startedAt))")

        let state = try stateStore.load()
        let scan = ScanResult(scopePath: scopePath, freeBytes: stats.freeBytes, localBytes: stats.materializedBytes, items: [])
        let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config(for: policy), now: Date())
        logger.log("status local=\(stats.materializedBytes) free=\(stats.freeBytes) decision=\(decision.kind.rawValue) growth=\(decision.growthBytes)")

        print("Scope: \(scopePath)")
        print("Local iCloud footprint: \(formatBytes(stats.materializedBytes)) (\(stats.materializedFiles) files)")
        print("Evicted (dataless): \(stats.datalessFiles) files")
        print("Free space: \(formatBytes(stats.freeBytes))")
        print("Recent growth (\(policy.growthWindowMinutes)m): \(formatBytes(decision.growthBytes))")
        print("Next action: \(decision.kind.rawValue) (\(decision.reason))")
        if let seconds = decision.cooldownRemainingSeconds {
            print("Cooldown remaining: \(seconds)s")
        }
        if let summary = state.lastSummary {
            print("Last summary: \(summary.action.rawValue) at \(ISO8601DateFormatter().string(from: summary.timestamp))")
        }
        return 0
    }

    // MARK: - Remediation

    private func executeRemediation(
        command: GuardCommand,
        scopePath: String,
        policy: PolicyConfig,
        batchLimit: Int,
        panicLimit: Int,
        dryRun: Bool,
        logger: Logger,
        stateStore: StateStore
    ) throws -> Int32 {
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
            try? stateStore.save(clearedState)
        }

        let engine = engineFactory(logger)

        // Phase 1: usage scan + policy decision
        let stats = try DriveStatsCollector.collect(scopePath: scopePath)
        state.samples = trimSamples(
            state.samples + [GuardSample(timestamp: now, localBytes: stats.materializedBytes, freeBytes: stats.freeBytes)],
            now: now
        )
        let scan = ScanResult(scopePath: scopePath, freeBytes: stats.freeBytes, localBytes: stats.materializedBytes, items: [])
        let decision = PolicyEngine.evaluate(
            scan: scan,
            state: state,
            config: config(for: policy),
            now: now,
            forcePanic: command == .panicEvict
        )

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
                escalatedToPanic: false
            )
            state.lastSummary = summary
            try stateStore.save(state)
            logger.log("noop action=\(decision.kind.rawValue) reason=\(decision.reason)")
            printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, reason: decision.reason)
            return 0
        }

        // Phase 2: candidate collection
        let protected = ProtectedPathsMatcher(patterns: policy.protectedPaths)
        let candidates = try engine.collectCandidates(scopePath: scopePath, protectedPaths: protected)
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
                escalatedToPanic: false
            )
            state.lastSummary = summary
            try stateStore.save(state)
            logger.log("noop action=\(decision.kind.rawValue) reason=no-candidates")
            printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, reason: decision.reason)
            return 0
        }

        // Phase 3: eviction (or dry-run report)
        let byteBudget: Int64? = decision.kind == .panic ? nil : decision.reclaimTargetBytes
        let fileBudget = decision.kind == .panic ? panicLimit : batchLimit

        if dryRun {
            var planned: Int64 = 0
            var plannedCount = 0
            for candidate in candidates {
                if plannedCount >= fileBudget { break }
                if let byteBudget, planned >= byteBudget { break }
                planned += candidate.allocatedBytes
                plannedCount += 1
            }
            print("Dry run: would evict \(plannedCount) file(s), reclaiming \(formatBytes(planned))")
            for candidate in candidates.prefix(20) {
                print("  \(candidate.relativePath) (\(formatBytes(candidate.allocatedBytes)))")
            }
            if candidates.count > 20 {
                print("  … and \(candidates.count - 20) more")
            }
            return 0
        }

        let outcome = engine.evict(candidates: candidates, byteBudget: byteBudget, fileBudget: fileBudget)

        // Feed the shared watchlist so the app re-evicts anything that bounces back.
        if !outcome.evictedPaths.isEmpty {
            let watchlist = WatchlistWatcher(logger: logger, protectedPaths: protected, scopePath: scopePath)
            watchlist.add(paths: outcome.evictedPaths)
        }

        let postStats = try DriveStatsCollector.collect(scopePath: scopePath)
        let summary = GuardRunSummary(
            timestamp: now,
            action: decision.kind,
            reason: decision.reason,
            dryRun: dryRun,
            candidateCount: candidates.count,
            evictedCount: outcome.evictedCount,
            failedEvictionCount: outcome.failedCount,
            reclaimedBytes: outcome.reclaimedBytes,
            remainingLocalBytes: postStats.materializedBytes,
            remainingFreeBytes: postStats.freeBytes,
            escalatedToPanic: false
        )
        state.lastSummary = summary
        state.lastRemediationAt = now
        try stateStore.save(state)

        logger.log("remediation action=\(decision.kind.rawValue) reclaimed=\(outcome.reclaimedBytes) evicted=\(outcome.evictedCount) failed=\(outcome.failedCount)")
        printSummary(summary: summary, startingLocal: stats.materializedBytes, startingFree: stats.freeBytes, reason: decision.reason)
        return 0
    }

    // MARK: - Plumbing (lock, watchdog, samples)

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
        logger: Logger,
        stateStore: StateStore,
        body: () throws -> T
    ) throws -> T {
        let url = URL(fileURLWithPath: NSString(string: lockPath).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        while true {
            let fileDescriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o644)
            if fileDescriptor != -1 {
                let contents = "\(getpid())\n"
                _ = contents.withCString { pointer in
                    write(fileDescriptor, pointer, strlen(pointer))
                }

                defer {
                    close(fileDescriptor)
                    unlink(url.path)
                }

                return try body()
            }

            let lockErrno = errno
            guard lockErrno == EEXIST else {
                throw GuardError.runtime("failed to acquire lock at \(url.path): \(String(cString: strerror(lockErrno)))")
            }

            if try reclaimStaleLockIfNeeded(lockURL: url, logger: logger, stateStore: stateStore) {
                continue
            }

            var state = try stateStore.load()
            state.lastLockContentionAt = Date()
            try stateStore.save(state)
            throw GuardError.lockUnavailable("another icloud-guard run is already active")
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

    private func reclaimStaleLockIfNeeded(
        lockURL: URL,
        logger: Logger,
        stateStore: StateStore
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: lockURL.path) else {
            return true
        }

        let data = try? Data(contentsOf: lockURL)
        let pidText = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidText, let pid = Int32(pidText), pid > 0 else {
            try removeLockFile(lockURL: lockURL)
            logger.log("reclaimed-stale-lock reason=unparseable")
            return true
        }

        guard !isProcessAlive(pid) else {
            return false
        }

        try removeLockFile(lockURL: lockURL)

        var state = try stateStore.load()
        if state.activeLock?.pid == pid {
            state.activeLock = nil
        }
        try stateStore.save(state)
        logger.log("reclaimed-stale-lock pid=\(pid)")
        return true
    }

    private func removeLockFile(lockURL: URL) throws {
        do {
            try FileManager.default.removeItem(at: lockURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        }
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

    private func printSummary(summary: GuardRunSummary, startingLocal: Int64, startingFree: Int64, reason: String) {
        print("Action: \(summary.action.rawValue)")
        print("Reason: \(reason)")
        print("Dry run: \(summary.dryRun ? "yes" : "no")")
        print("Starting local footprint: \(formatBytes(startingLocal))")
        print("Starting free space: \(formatBytes(startingFree))")
        print("Candidates selected: \(summary.candidateCount)")
        print("Evicted count: \(summary.evictedCount)")
        print("Failed evictions: \(summary.failedEvictionCount)")
        print("Reclaimed bytes: \(formatBytes(summary.reclaimedBytes))")
        print("Remaining local footprint: \(formatBytes(summary.remainingLocalBytes))")
        print("Remaining free space: \(formatBytes(summary.remainingFreeBytes))")
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

public final class Logger: GuardLogging {
    private let logURL: URL
    private let formatter = ISO8601DateFormatter()
    private let queue = DispatchQueue(label: "icloud-guard.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var bytesWritten: Int64 = 0
    private let maxFileSize: Int64 = 10 * 1024 * 1024

    public init(logPath: String) {
        self.logURL = URL(fileURLWithPath: NSString(string: logPath).expandingTildeInPath)
    }

    public func log(_ message: String) {
        let rendered = "[\(formatter.string(from: Date()))] \(message)\n"
        fputs(rendered, stdout)

        queue.sync {
            ensureHandle()
            if bytesWritten >= maxFileSize {
                rotate()
            }
            guard let handle = fileHandle else { return }
            guard let data = rendered.data(using: .utf8) else { return }
            do {
                try handle.write(contentsOf: data)
                bytesWritten += Int64(data.count)
            } catch {
                fileHandle = nil
                fputs("[icloud-guard] log write failed: \(error)\n", stderr)
            }
        }
    }

    private func ensureHandle() {
        guard fileHandle == nil else { return }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        let endOffset = (try? handle.seekToEnd()) ?? 0
        bytesWritten = Int64(endOffset)
        fileHandle = handle
    }

    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil
        let backupPath = logURL.path + ".1"
        try? FileManager.default.removeItem(atPath: backupPath)
        try? FileManager.default.moveItem(atPath: logURL.path, toPath: backupPath)
        bytesWritten = 0
        ensureHandle()
    }

    deinit {
        try? fileHandle?.close()
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

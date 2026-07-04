import Darwin
import Foundation

public protocol GuardLogging: AnyObject {
    func log(_ message: String)
}

public protocol ICloudScanning {
    func scan(scopePath: String, mode: ScanMode) throws -> ScanResult
    func selectTargetedCandidates(
        scopePath: String,
        reclaimTargetBytes: Int64,
        protectedPaths: [String]
    ) throws -> TargetedSelectionResult
}

public struct EvictionResult: Equatable, Sendable {
    public let evictedCount: Int
    public let failedCount: Int

    public init(evictedCount: Int, failedCount: Int) {
        self.evictedCount = evictedCount
        self.failedCount = failedCount
    }
}

public protocol ICloudEvicting {
    func evict(items: [ICloudItemSnapshot], dryRun: Bool) throws -> EvictionResult
}

public final class GuardRunner {
    private let scannerFactory: () -> ICloudScanning
    private let evictorFactory: (GuardLogging) -> ICloudEvicting

    public init() {
        self.scannerFactory = { ICloudScanner() }
        self.evictorFactory = { logger in Evictor(logger: logger) }
    }

    init(
        scannerFactory: @escaping () -> ICloudScanning,
        evictorFactory: @escaping (GuardLogging) -> ICloudEvicting
    ) {
        self.scannerFactory = scannerFactory
        self.evictorFactory = evictorFactory
    }

    public func run(command: GuardCommand, configPath: String?, dryRun: Bool) throws -> Int32 {
        let resolvedConfigPath = configPath ?? defaultConfigPath()
        let config = try loadConfig(path: resolvedConfigPath)
        let logger = Logger(logPath: config.logPath)
        let stateStore = StateStore(statePath: config.statePath)
        try sanitizeState(stateStore: stateStore)

        switch command {
        case .status:
            let state = try stateStore.load()
            logger.log("scan-start command=\(command.rawValue) dryRun=\(dryRun)")
            let scanStartedAt = Date()
            let scan = try withWatchdog(timeoutSeconds: statusWatchdogTimeoutSeconds(for: config), logger: logger) {
                try ICloudScanner().scan(scopePath: config.scopePath, mode: .usageOnly)
            }
            logger.log("scan-complete phase=usage local=\(scan.localBytes) free=\(scan.freeBytes) elapsedMs=\(elapsedMilliseconds(since: scanStartedAt))")
            let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config, now: Date())
            logger.log("status local=\(scan.localBytes) free=\(scan.freeBytes) decision=\(decision.kind.rawValue) growth=\(decision.growthBytes)")
            printStatus(scan: scan, decision: decision, state: state, growthWindowMinutes: config.policy.growthWindowMinutes)
            return 0
        case .run, .panicEvict:
            do {
                return try withLock(lockPath: config.lockPath, logger: logger, stateStore: stateStore) {
                    try self.execute(command: command, config: config, dryRun: dryRun, logger: logger, stateStore: stateStore)
                }
            } catch GuardError.lockUnavailable(let message) {
                logger.log("skip reason=lock-contention command=\(command.rawValue)")
                print(message)
                return 0
            }
        }
    }

    private func execute(
        command: GuardCommand,
        config: GuardConfig,
        dryRun: Bool,
        logger: Logger,
        stateStore: StateStore
    ) throws -> Int32 {
        let now = Date()
        var state = try stateStore.load()
        state.activeLock = ActiveLock(pid: getpid(), startedAt: now)
        try stateStore.save(state)
        logger.log("scan-start command=\(command.rawValue) dryRun=\(dryRun)")
        let watchdog = RunWatchdog(
            timeoutSeconds: runWatchdogTimeoutSeconds(for: config),
            logger: logger
        )

        defer {
            watchdog.cancel()
            var clearedState = (try? stateStore.load()) ?? state
            clearedState.activeLock = nil
            try? stateStore.save(clearedState)
        }

        let scanner = scannerFactory()
        let evictor = evictorFactory(logger)
        let usageScanStartedAt = Date()
        let usageScan = try scanner.scan(scopePath: config.scopePath, mode: .usageOnly)
        logger.log("scan-complete phase=usage local=\(usageScan.localBytes) free=\(usageScan.freeBytes) elapsedMs=\(elapsedMilliseconds(since: usageScanStartedAt))")
        state.samples = trimSamples(state.samples + [GuardSample(timestamp: now, localBytes: usageScan.localBytes, freeBytes: usageScan.freeBytes)], now: now)

        let preliminaryDecision = PolicyEngine.evaluate(
            scan: usageScan,
            state: state,
            config: config,
            now: now,
            forcePanic: command == .panicEvict
        )

        let initialScan: ScanResult
        let decision: GuardDecision

        if preliminaryDecision.kind == .panic {
            let detailedScanStartedAt = Date()
            do {
                initialScan = try scanner.scan(scopePath: config.scopePath, mode: .candidateSelection)
            } catch {
                logScanFailure(logger: logger, phase: "candidates", error: error)
                throw error
            }
            logger.log("scan-complete phase=candidates local=\(initialScan.localBytes) free=\(initialScan.freeBytes) items=\(initialScan.items.count) elapsedMs=\(elapsedMilliseconds(since: detailedScanStartedAt))")
            decision = PolicyEngine.evaluate(
                scan: initialScan,
                state: state,
                config: config,
                now: now,
                forcePanic: command == .panicEvict
            )
        } else if preliminaryDecision.kind == .targeted {
            let targetedScanStartedAt = Date()
            let selection: TargetedSelectionResult
            do {
                selection = try scanner.selectTargetedCandidates(
                    scopePath: config.scopePath,
                    reclaimTargetBytes: preliminaryDecision.reclaimTargetBytes,
                    protectedPaths: config.policy.protectedPaths
                )
            } catch {
                logScanFailure(logger: logger, phase: "targeted-candidates", error: error)
                throw error
            }
            let reclaimedBytes = selection.items.reduce(into: Int64(0)) { partialResult, item in
                partialResult += item.localBytes
            }
            logger.log(
                "scan-complete phase=targeted-candidates target=\(preliminaryDecision.reclaimTargetBytes) " +
                "inspected=\(selection.inspectedCount) selected=\(selection.items.count) reclaimed=\(reclaimedBytes) " +
                "elapsedMs=\(elapsedMilliseconds(since: targetedScanStartedAt))"
            )

            initialScan = usageScan
            decision = GuardDecision(
                kind: .targeted,
                reason: preliminaryDecision.reason,
                candidates: selection.items,
                reclaimTargetBytes: preliminaryDecision.reclaimTargetBytes,
                predictedLocalBytes: max(usageScan.localBytes - reclaimedBytes, 0),
                predictedFreeBytes: usageScan.freeBytes + reclaimedBytes,
                cooldownRemainingSeconds: nil,
                growthBytes: preliminaryDecision.growthBytes
            )
        } else {
            initialScan = usageScan
            decision = preliminaryDecision
        }

        if decision.kind == .none || decision.kind == .cooldown {
            let summary = GuardRunSummary(
                timestamp: now,
                action: decision.kind,
                reason: decision.reason,
                dryRun: dryRun,
                candidateCount: decision.candidates.count,
                evictedCount: 0,
                failedEvictionCount: 0,
                reclaimedBytes: 0,
                remainingLocalBytes: initialScan.localBytes,
                remainingFreeBytes: initialScan.freeBytes,
                escalatedToPanic: false
            )
            state.lastSummary = summary
            try stateStore.save(state)
            logger.log("noop action=\(decision.kind.rawValue) reason=\(decision.reason)")
            printSummary(scan: initialScan, decision: decision, summary: summary)
            return 0
        }

        if decision.candidates.isEmpty {
            let summary = GuardRunSummary(
                timestamp: now,
                action: decision.kind,
                reason: decision.reason,
                dryRun: dryRun,
                candidateCount: 0,
                evictedCount: 0,
                failedEvictionCount: 0,
                reclaimedBytes: 0,
                remainingLocalBytes: initialScan.localBytes,
                remainingFreeBytes: initialScan.freeBytes,
                escalatedToPanic: false
            )
            state.lastSummary = summary
            try stateStore.save(state)
            logger.log("noop action=\(decision.kind.rawValue) reason=\(decision.reason) candidates=0")
            printSummary(scan: initialScan, decision: decision, summary: summary)
            return 0
        }

        if config.notifications.enable {
            Notifier().notify(
                title: "iCloud Guard",
                subtitle: decision.kind == .panic ? "Emergency eviction" : "Targeted trim",
                body: "\(decision.reason). \(decision.candidates.count) candidate(s), \(formatBytes(decision.reclaimTargetBytes)) potential reclaim."
            )
        }

        var selected = decision.candidates
        var reclaimedBytes = selected.reduce(into: Int64(0)) { partialResult, item in
            partialResult += item.localBytes
        }
        var evictionResult = dryRun ? EvictionResult(evictedCount: 0, failedCount: 0) : try evictor.evict(items: selected, dryRun: dryRun)
        var evictedCount = evictionResult.evictedCount
        var failedEvictionCount = evictionResult.failedCount
        var escalatedToPanic = false

        var finalLocalBytes = decision.predictedLocalBytes
        var finalFreeBytes = decision.predictedFreeBytes

        if !dryRun {
            let postScan = try scanner.scan(scopePath: config.scopePath, mode: .usageOnly)
            finalLocalBytes = postScan.localBytes
            finalFreeBytes = postScan.freeBytes
        }

        if decision.kind == .targeted
            && (finalLocalBytes > config.policy.trimLocalBytes || finalFreeBytes < config.policy.warnFreeBytes)
        {
            let panicScanStartedAt = Date()
            let panicScan: ScanResult
            do {
                panicScan = try scanner.scan(scopePath: config.scopePath, mode: .candidateSelection)
            } catch {
                logScanFailure(logger: logger, phase: "panic-candidates", error: error)
                throw error
            }
            logger.log("scan-complete phase=panic-candidates local=\(panicScan.localBytes) free=\(panicScan.freeBytes) items=\(panicScan.items.count) elapsedMs=\(elapsedMilliseconds(since: panicScanStartedAt))")
            let panicCandidates = PolicyEngine.panicCandidates(scan: panicScan, config: config.policy)
                .filter { panicCandidate in
                    !selected.contains(where: { $0.relativePath == panicCandidate.relativePath })
                }

            if !panicCandidates.isEmpty {
                escalatedToPanic = true
                if config.notifications.enable {
                    Notifier().notify(
                        title: "iCloud Guard",
                        subtitle: "Escalating to panic eviction",
                        body: "Targeted trim was insufficient. Evicting \(panicCandidates.count) additional item(s)."
                    )
                }

                selected += panicCandidates
                reclaimedBytes += panicCandidates.reduce(into: Int64(0)) { partialResult, item in
                    partialResult += item.localBytes
                }
                if !dryRun {
                    evictionResult = try evictor.evict(items: panicCandidates, dryRun: dryRun)
                    evictedCount += evictionResult.evictedCount
                    failedEvictionCount += evictionResult.failedCount
                }

                if !dryRun {
                    let postPanicScan = try scanner.scan(scopePath: config.scopePath, mode: .usageOnly)
                    finalLocalBytes = postPanicScan.localBytes
                    finalFreeBytes = postPanicScan.freeBytes
                } else {
                    finalLocalBytes = max(initialScan.localBytes - reclaimedBytes, 0)
                    finalFreeBytes = initialScan.freeBytes + reclaimedBytes
                }
            }
        }

        let finalAction: GuardDecisionKind = escalatedToPanic ? .panic : decision.kind
        let summary = GuardRunSummary(
            timestamp: now,
            action: finalAction,
            reason: decision.reason,
            dryRun: dryRun,
            candidateCount: selected.count,
            evictedCount: evictedCount,
            failedEvictionCount: failedEvictionCount,
            reclaimedBytes: reclaimedBytes,
            remainingLocalBytes: finalLocalBytes,
            remainingFreeBytes: finalFreeBytes,
            escalatedToPanic: escalatedToPanic
        )

        state.lastSummary = summary
        if !dryRun {
            state.lastRemediationAt = now
        }
        try stateStore.save(state)

        logger.log("remediation action=\(finalAction.rawValue) reason=\(decision.reason) dryRun=\(dryRun) reclaimed=\(reclaimedBytes) count=\(selected.count) failed=\(failedEvictionCount)")
        printSummary(scan: initialScan, decision: decision, summary: summary)

        if config.notifications.enable {
            let verb = dryRun ? "Planned" : "Reclaimed"
            Notifier().notify(
                title: "iCloud Guard",
                subtitle: finalAction == .panic ? "Panic eviction finished" : "Trim finished",
                body: "\(verb) \(formatBytes(summary.reclaimedBytes)); local iCloud now \(formatBytes(summary.remainingLocalBytes)); free space \(formatBytes(summary.remainingFreeBytes))."
            )
        }

        return 0
    }

    private func loadConfig(path: String) throws -> GuardConfig {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GuardConfig.self, from: data)
    }

    private func defaultConfigPath() -> String {
        let xdgPath = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(NSHomeDirectory())/.config"
        return "\(xdgPath)/r3x/icloud-guard/config.json"
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

    private func printStatus(scan: ScanResult, decision: GuardDecision, state: GuardState, growthWindowMinutes: Int) {
        print("Scope: \(scan.scopePath)")
        print("Local iCloud footprint: \(formatBytes(scan.localBytes))")
        print("Free space: \(formatBytes(scan.freeBytes))")
        print("Recent growth (\(growthWindowMinutes)m): \(formatBytes(decision.growthBytes))")
        print("Next action: \(decision.kind.rawValue) (\(decision.reason))")
        if let seconds = decision.cooldownRemainingSeconds {
            print("Cooldown remaining: \(seconds)s")
        }
        if let summary = state.lastSummary {
            print("Last summary: \(summary.action.rawValue) at \(ISO8601DateFormatter().string(from: summary.timestamp))")
        }
    }

    private func printSummary(scan: ScanResult, decision: GuardDecision, summary: GuardRunSummary) {
        print("Action: \(summary.action.rawValue)")
        print("Reason: \(decision.reason)")
        print("Dry run: \(summary.dryRun ? "yes" : "no")")
        print("Starting local footprint: \(formatBytes(scan.localBytes))")
        print("Starting free space: \(formatBytes(scan.freeBytes))")
        print("Candidates selected: \(summary.candidateCount)")
        print("Evicted count: \(summary.evictedCount)")
        print("Failed evictions: \(summary.failedEvictionCount)")
        print("Reclaimed bytes: \(formatBytes(summary.reclaimedBytes))")
        print("Remaining local footprint: \(formatBytes(summary.remainingLocalBytes))")
        print("Remaining free space: \(formatBytes(summary.remainingFreeBytes))")
        print("Escalated to panic: \(summary.escalatedToPanic ? "yes" : "no")")
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    private func logScanFailure(logger: GuardLogging, phase: String, error: Error) {
        logger.log("scan-failure phase=\(phase) error=\(error)")
    }

    private func statusWatchdogTimeoutSeconds(for config: GuardConfig) -> Int {
        max(config.policy.sampleIntervalSeconds - 60, 120)
    }

    private func runWatchdogTimeoutSeconds(for config: GuardConfig) -> Int {
        // Allow one skipped interval if remediation is making forward progress.
        max(config.policy.sampleIntervalSeconds + 60, 180)
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

    public init(logPath: String) {
        self.logURL = URL(fileURLWithPath: NSString(string: logPath).expandingTildeInPath)
    }

    public func log(_ message: String) {
        let rendered = "[\(formatter.string(from: Date()))] \(message)\n"
        fputs(rendered, stdout)

        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            if let data = rendered.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            fputs("[icloud-guard] failed to append to log: \(error)\n", stderr)
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

private final class StateStore {
    private let stateURL: URL

    init(statePath: String) {
        self.stateURL = URL(fileURLWithPath: NSString(string: statePath).expandingTildeInPath)
    }

    func load() throws -> GuardState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return GuardState()
        }

        let data = try Data(contentsOf: stateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GuardState.self, from: data)
    }

    func save(_ state: GuardState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }
}

private final class Notifier {
    func notify(title: String, subtitle: String, body: String) {
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\" subtitle \"\(escape(subtitle))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

final class Evictor: ICloudEvicting {
    private let fileManager = FileManager.default
    private let logger: GuardLogging

    init(logger: GuardLogging) {
        self.logger = logger
    }

    func evict(items: [ICloudItemSnapshot], dryRun: Bool) throws -> EvictionResult {
        if dryRun {
            for item in items {
                logger.log("dry-run evict \(item.relativePath) bytes=\(item.localBytes)")
            }
            return EvictionResult(evictedCount: 0, failedCount: 0)
        }

        var evictedCount = 0
        var failedCount = 0
        for item in items {
            let url = URL(fileURLWithPath: item.absolutePath)
            do {
                try fileManager.evictUbiquitousItem(at: url)
                evictedCount += 1
                logger.log("evicted \(item.relativePath) bytes=\(item.localBytes)")
            } catch {
                failedCount += 1
                logger.log("failed to evict \(item.relativePath): \(error)")
            }
        }
        return EvictionResult(evictedCount: evictedCount, failedCount: failedCount)
    }
}

final class ICloudScanner: ICloudScanning {
    private let fileManager = FileManager.default
    private let targetedRankingKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isPackageKey,
        .contentModificationDateKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
    ]
    private let usageOnlyKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isPackageKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
    ]
    private let candidateSelectionKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isPackageKey,
        .isUbiquitousItemKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemUploadingErrorKey,
        .contentModificationDateKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
    ]

    func scan(scopePath: String, mode: ScanMode = .candidateSelection) throws -> ScanResult {
        let scopeURL = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
        let freeBytes = try resolveFreeBytes(scopeURL: scopeURL)

        if mode == .usageOnly {
            let localBytes = try scanUsageOnly(scopeURL: scopeURL)
            return ScanResult(scopePath: scopeURL.path, freeBytes: freeBytes, localBytes: localBytes, items: [])
        }

        let keys = resourceKeys(for: mode)

        guard let enumerator = fileManager.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw GuardError.runtime("failed to enumerate \(scopeURL.path)")
        }

        var items: [ICloudItemSnapshot] = []
        var localBytes: Int64 = 0

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else {
                continue
            }

            let allocatedBytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            localBytes += allocatedBytes

            guard mode == .candidateSelection else {
                continue
            }

            let relativePath = relativePath(from: scopeURL, to: fileURL)
            let snapshot = ICloudItemSnapshot(
                relativePath: relativePath,
                absolutePath: fileURL.path,
                localBytes: allocatedBytes,
                isRegularFile: values.isRegularFile ?? false,
                isPackage: values.isPackage ?? false,
                isUbiquitous: values.isUbiquitousItem ?? false,
                isUploaded: values.ubiquitousItemIsUploaded ?? false,
                isUploading: values.ubiquitousItemIsUploading ?? false,
                isDownloading: values.ubiquitousItemIsDownloading ?? false,
                downloadingStatus: values.ubiquitousItemDownloadingStatus?.rawValue,
                hasDownloadError: values.ubiquitousItemDownloadingError != nil,
                hasUploadError: values.ubiquitousItemUploadingError != nil,
                contentModificationDate: values.contentModificationDate
            )

            items.append(snapshot)
        }

        return ScanResult(scopePath: scopeURL.path, freeBytes: freeBytes, localBytes: localBytes, items: items)
    }

    func selectTargetedCandidates(
        scopePath: String,
        reclaimTargetBytes: Int64,
        protectedPaths: [String]
    ) throws -> TargetedSelectionResult {
        guard reclaimTargetBytes > 0 else {
            return TargetedSelectionResult(items: [], inspectedCount: 0)
        }

        let scopeURL = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
        let rankedFiles = try rankFilesForTargetedSelection(scopeURL: scopeURL)

        var items: [ICloudItemSnapshot] = []
        var reclaimedBytes: Int64 = 0
        var inspectedCount = 0
        var selectedPackageRoots: [String] = []

        for rankedFile in rankedFiles {
            if isInsideSelectedPackage(relativePath: rankedFile.relativePath, selectedPackageRoots: selectedPackageRoots) {
                continue
            }

            if isProtected(relativePath: rankedFile.relativePath, protectedPaths: protectedPaths) {
                continue
            }

            inspectedCount += 1
            let snapshot = try snapshotForEvictionEligibility(scopeURL: scopeURL, rankedFile: rankedFile)
            guard snapshot.isEligibleForEviction(protectedPaths: protectedPaths) else {
                continue
            }

            items.append(snapshot)
            reclaimedBytes += snapshot.localBytes
            if snapshot.isPackage {
                selectedPackageRoots.append(snapshot.normalizedRelativePath)
            }

            if reclaimedBytes >= reclaimTargetBytes {
                break
            }
        }

        return TargetedSelectionResult(items: items, inspectedCount: inspectedCount)
    }

    private func scanUsageOnly(scopeURL: URL) throws -> Int64 {
        try scanDirectoryUsage(path: scopeURL.path, isRoot: true)
    }

    private func scanDirectoryUsage(path: String, isRoot: Bool = false) throws -> Int64 {
        guard let directory = opendir(path) else {
            if isRoot {
                throw GuardError.runtime("failed to enumerate \(path)")
            }
            return 0
        }

        defer {
            closedir(directory)
        }

        var localBytes: Int64 = 0

        while let entryPointer = readdir(directory) {
            let entry = entryPointer.pointee
            let name = withUnsafePointer(to: entry.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) {
                    String(cString: $0)
                }
            }

            if name == "." || name == ".." || name.hasPrefix(".") {
                continue
            }

            let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            var statInfo = stat()
            let result = childPath.withCString { pathPointer in
                lstat(pathPointer, &statInfo)
            }

            guard result == 0 else {
                continue
            }

            let fileType = statInfo.st_mode & S_IFMT
            if fileType == S_IFDIR {
                localBytes += try scanDirectoryUsage(path: childPath)
                continue
            }

            guard fileType == S_IFREG else {
                continue
            }

            localBytes += Int64(statInfo.st_blocks) * 512
        }

        return localBytes
    }

    private func rankFilesForTargetedSelection(scopeURL: URL) throws -> [RankedFile] {
        guard let enumerator = fileManager.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: targetedRankingKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw GuardError.runtime("failed to enumerate \(scopeURL.path)")
        }

        var rankedFiles: [RankedFile] = []
        let rootPath = scopeURL.standardizedFileURL.path
        var packageCandidates: [String: RankedFile] = [:]

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(targetedRankingKeys))
            let standardizedPath = fileURL.standardizedFileURL.path
            let relativePath = relativePath(from: scopeURL, to: fileURL)

            if values.isPackage == true {
                packageCandidates[standardizedPath] = RankedFile(
                    url: fileURL,
                    relativePath: relativePath,
                    localBytes: 0,
                    contentModificationDate: values.contentModificationDate
                )
            }

            guard values.isRegularFile == true else {
                continue
            }

            let localBytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let packagePaths = packageCandidatePaths(
                for: fileURL,
                rootPath: rootPath,
                packageCandidates: packageCandidates
            )

            // Evict package roots as a single unit instead of chipping away at their internals.
            if packagePaths.isEmpty {
                rankedFiles.append(
                    RankedFile(
                        url: fileURL,
                        relativePath: relativePath,
                        localBytes: localBytes,
                        contentModificationDate: values.contentModificationDate
                    )
                )
            }

            for packagePath in packagePaths {
                guard var candidate = packageCandidates[packagePath] else {
                    continue
                }
                candidate.localBytes += localBytes
                packageCandidates[packagePath] = candidate
            }
        }

        rankedFiles.append(contentsOf: packageCandidates.values.filter { $0.localBytes > 0 })

        return rankedFiles.sorted {
            if $0.localBytes == $1.localBytes {
                let lhsDate = $0.contentModificationDate ?? .distantPast
                let rhsDate = $1.contentModificationDate ?? .distantPast
                if lhsDate == rhsDate {
                    return $0.relativePath < $1.relativePath
                }
                return lhsDate < rhsDate
            }

            return $0.localBytes > $1.localBytes
        }
    }

    private func snapshotForEvictionEligibility(scopeURL: URL, rankedFile: RankedFile) throws -> ICloudItemSnapshot {
        let values = try rankedFile.url.resourceValues(forKeys: Set(candidateSelectionKeys))
        let allocatedBytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(rankedFile.localBytes))
        return ICloudItemSnapshot(
            relativePath: rankedFile.relativePath,
            absolutePath: rankedFile.url.path,
            localBytes: allocatedBytes,
            isRegularFile: values.isRegularFile ?? true,
            isPackage: values.isPackage ?? false,
            isUbiquitous: values.isUbiquitousItem ?? false,
            isUploaded: values.ubiquitousItemIsUploaded ?? false,
            isUploading: values.ubiquitousItemIsUploading ?? false,
            isDownloading: values.ubiquitousItemIsDownloading ?? false,
            downloadingStatus: values.ubiquitousItemDownloadingStatus?.rawValue,
            hasDownloadError: values.ubiquitousItemDownloadingError != nil,
            hasUploadError: values.ubiquitousItemUploadingError != nil,
            contentModificationDate: values.contentModificationDate ?? rankedFile.contentModificationDate
        )
    }

    private func isProtected(relativePath: String, protectedPaths: [String]) -> Bool {
        let candidate = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        for protectedPath in protectedPaths {
            let normalized = protectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty else {
                continue
            }

            if candidate == normalized || candidate.hasPrefix(normalized + "/") {
                return true
            }
        }

        return false
    }

    private func packageCandidatePaths(
        for fileURL: URL,
        rootPath: String,
        packageCandidates: [String: RankedFile]
    ) -> [String] {
        var matches: [String] = []
        var currentURL = fileURL.deletingLastPathComponent().standardizedFileURL

        while true {
            let currentPath = currentURL.path
            if packageCandidates[currentPath] != nil {
                matches.append(currentPath)
            }
            if currentPath == rootPath {
                break
            }

            let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
            if parentURL.path == currentPath {
                break
            }
            currentURL = parentURL
        }

        return matches
    }

    private func isInsideSelectedPackage(relativePath: String, selectedPackageRoots: [String]) -> Bool {
        let candidate = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        for selectedPackageRoot in selectedPackageRoots {
            if candidate == selectedPackageRoot || candidate.hasPrefix(selectedPackageRoot + "/") {
                return true
            }
        }

        return false
    }

    private func resourceKeys(for mode: ScanMode) -> [URLResourceKey] {
        switch mode {
        case .usageOnly:
            return usageOnlyKeys
        case .candidateSelection:
            return candidateSelectionKeys
        }
    }

    private func resolveFreeBytes(scopeURL: URL) throws -> Int64 {
        let values = try scopeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage {
            return Int64(bytes)
        }

        let attrs = try fileManager.attributesOfFileSystem(forPath: scopeURL.path)
        if let freeSize = attrs[.systemFreeSize] as? NSNumber {
            return freeSize.int64Value
        }

        throw GuardError.runtime("unable to determine free space for \(scopeURL.path)")
    }

    private func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let relativeComponents = fileComponents.dropFirst(rootComponents.count)
        return relativeComponents.joined(separator: "/")
    }
}

public enum ScanMode {
    case usageOnly
    case candidateSelection
}

private struct RankedFile {
    let url: URL
    let relativePath: String
    var localBytes: Int64
    let contentModificationDate: Date?
}

public struct TargetedSelectionResult {
    public let items: [ICloudItemSnapshot]
    public let inspectedCount: Int

    public init(items: [ICloudItemSnapshot], inspectedCount: Int) {
        self.items = items
        self.inspectedCount = inspectedCount
    }
}

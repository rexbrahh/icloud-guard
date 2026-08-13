import Foundation

public struct PreviewThresholds: Codable, Equatable, Sendable {
    public var targetLocalBytes: Int64
    public var trimLocalBytes: Int64
    public var warnFreeBytes: Int64
    public var remediateFreeBytes: Int64
    public var panicFreeBytes: Int64
    public var growthTriggerBytes: Int64
    public var cooldownMinutes: Int
}

public struct PreviewCandidate: Codable, Equatable, Sendable {
    public var pathIdentifier: String
    public var displayPath: String
    public var bytes: Int64
    public var package: Bool
}

public struct ExplainablePreview: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var runID: String
    public var action: GuardDecisionKind
    public var reason: String
    public var thresholds: PreviewThresholds
    public var targetBytes: Int64
    public var plannedCount: Int
    public var plannedBytes: Int64
    public var candidates: [PreviewCandidate]
    public var exclusions: [String: Int]
    public var warnings: [String]
    public var scan: GuardRunTelemetry
    public var receiptPersisted: Bool
}

public final class ExplainablePreviewService: Sendable {
    public typealias Scan = @Sendable (String, ProtectedPathsMatcher) throws -> ScanBundle

    private let scan: Scan
    private let now: @Sendable () -> Date

    public init(
        scan: @escaping Scan = { scope, protected in
            try ScanOrchestrator.scan(scopePath: scope, protectedPaths: protected)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scan = scan
        self.now = now
    }

    public func run(
        configURL: URL = AppPaths.config,
        appHome: URL = AppPaths.homeDir,
        command: GuardCommand = .run,
        trigger: GuardRunTrigger = .cli
    ) throws -> ExplainablePreview {
        let config = try ConfigStore(configURL: configURL).loadValidated()
        return try run(config: config, appHome: appHome, command: command, trigger: trigger)
    }

    public func run(
        config: AppConfig,
        appHome: URL,
        command: GuardCommand = .run,
        trigger: GuardRunTrigger = .cli
    ) throws -> ExplainablePreview {
        let startedAt = now()
        let policy = PolicyMapping.corePolicy(from: config).normalized()
        let protected = config.scope.evictionPolicyMatcher
        var bundle = try scan(config.scope.path, protected)
        bundle.candidates = protected.folderPolicies.prioritized(bundle.candidates)
        let watchlist = try WatchlistInspectionService.loadEntries(
            storageURL: appHome.appendingPathComponent("watchlist.json"),
            scopePath: config.scope.path
        )
        let pending = Set(watchlist.filter { $0.pendingVerification && !$0.suspended }.map(\.path))
        let suspended = Set(watchlist.filter(\.suspended).map(\.path))
        let pendingCandidates = bundle.candidates.filter { pending.contains($0.path) }
        bundle.candidates.removeAll { pending.contains($0.path) }
        let suspendedCandidates = bundle.candidates.filter { suspended.contains($0.path) }
        bundle.candidates.removeAll { suspended.contains($0.path) }
        bundle.exclusions[.pending, default: 0] += pendingCandidates.count
        bundle.exclusions[.suspended, default: 0] += suspendedCandidates.count

        let state = try StateStore(statePath: appHome.appendingPathComponent("state.json").path).load()
        let scanResult = ScanResult(
            scopePath: config.scope.path,
            freeBytes: bundle.stats.freeBytes,
            localBytes: bundle.stats.materializedBytes,
            items: [],
            freeSpaceAvailable: bundle.stats.freeSpaceAvailable,
            scanComplete: bundle.stats.scanComplete
        )
        let decision = PolicyEngine.evaluate(
            scan: scanResult,
            state: state,
            config: GuardConfig(
                label: "app.icloud-guard",
                logPath: appHome.appendingPathComponent("icloud-guard.log").path,
                lockPath: appHome.appendingPathComponent("run.lock").path,
                scopePath: config.scope.path,
                statePath: appHome.appendingPathComponent("state.json").path,
                notifications: NotificationConfig(enable: false),
                policy: policy
            ),
            now: startedAt,
            forcePanic: command == .panicEvict,
            manualRequest: true
        )
        let plan = EvictionDryRunPlanner.plan(
            command: command,
            decision: decision,
            candidates: bundle.stats.scanComplete ? bundle.candidates : [],
            batchLimit: config.eviction.batchLimit,
            panicLimit: config.eviction.panicLimit
        )
        var warnings: [String] = []
        if !bundle.stats.scanComplete { warnings.append("Scan is incomplete; no eviction can run safely.") }
        if !bundle.stats.freeSpaceAvailable { warnings.append("Free-space telemetry is unavailable.") }
        if bundle.stats.skippedDirectories > 0 { warnings.append("\(bundle.stats.skippedDirectories) directorie(s) were skipped.") }
        if bundle.stats.scanReadErrors > 0 { warnings.append("\(bundle.stats.scanReadErrors) scan read error(s) occurred.") }

        let runID = UUID().uuidString.lowercased()
        var result = ExplainablePreview(
            runID: runID,
            action: plan.action,
            reason: plan.reason,
            thresholds: PreviewThresholds(
                targetLocalBytes: policy.targetLocalBytes,
                trimLocalBytes: policy.trimLocalBytes,
                warnFreeBytes: policy.warnFreeBytes,
                remediateFreeBytes: policy.remediateFreeBytes,
                panicFreeBytes: policy.panicFreeBytes,
                growthTriggerBytes: policy.growthTriggerBytes,
                cooldownMinutes: policy.cooldownMinutes
            ),
            targetBytes: decision.reclaimTargetBytes,
            plannedCount: plan.plannedCount,
            plannedBytes: plan.plannedBytes,
            candidates: plan.candidates.map {
                let identifier = String(PrivacyIdentifier.hash($0.path).prefix(24))
                return PreviewCandidate(
                    pathIdentifier: identifier,
                    displayPath: "path:\(identifier)",
                    bytes: $0.allocatedBytes,
                    package: $0.isPackageRoot
                )
            },
            exclusions: Dictionary(uniqueKeysWithValues: PreviewExclusionReason.allCases.map {
                ($0.rawValue, bundle.exclusions[$0, default: 0])
            }),
            warnings: warnings,
            scan: GuardRunTelemetry(bundle.stats),
            receiptPersisted: false
        )
        let receipt = GuardRunReceipt(
            id: runID,
            startedAt: startedAt,
            endedAt: now(),
            trigger: trigger,
            command: "explain",
            requestedAction: command.rawValue,
            action: plan.action,
            dryRun: true,
            reason: plan.reason,
            sourceScopeIdentifier: PrivacyIdentifier.scope(config.scope.path),
            preScan: GuardRunTelemetry(bundle.stats),
            postScan: GuardRunTelemetry(bundle.stats),
            plannedCount: plan.plannedCount,
            plannedBytes: plan.plannedBytes,
            exitCode: bundle.stats.scanComplete ? 0 : 65,
            status: bundle.stats.scanComplete ? .succeeded : .failed,
            statePersisted: false,
            watchlistPersisted: true
        )
        _ = try RunHistoryStore(url: appHome.appendingPathComponent("history.json")).append(
            receipt,
            legacySummary: state.lastSummary
        )
        result.receiptPersisted = true
        return result
    }
}

import Foundation

public struct EvictionDryRunPlan: Equatable, Sendable {
    public var action: GuardDecisionKind
    public var reason: String
    public var candidates: [EvictionCandidate]
    public var plannedBytes: Int64

    public var plannedCount: Int { candidates.count }

    public init(action: GuardDecisionKind, reason: String, candidates: [EvictionCandidate], plannedBytes: Int64) {
        self.action = action
        self.reason = reason
        self.candidates = candidates
        self.plannedBytes = plannedBytes
    }
}

public enum EvictionDryRunPlanner {
    public static func plan(
        command: GuardCommand,
        decision: GuardDecision,
        candidates: [EvictionCandidate],
        batchLimit: Int,
        panicLimit: Int
    ) -> EvictionDryRunPlan {
        guard decision.kind == .targeted || decision.kind == .panic else {
            return EvictionDryRunPlan(action: decision.kind, reason: decision.reason, candidates: [], plannedBytes: 0)
        }
        let isPanic = command == .panicEvict || decision.kind == .panic
        let fileLimit = isPanic ? panicLimit : batchLimit
        let byteLimit = isPanic ? nil : decision.reclaimTargetBytes
        var selected: [EvictionCandidate] = []
        var bytes: Int64 = 0
        for candidate in candidates {
            if selected.count >= max(0, fileLimit) { break }
            if let byteLimit, bytes >= byteLimit { break }
            selected.append(candidate)
            bytes += candidate.allocatedBytes
        }
        return EvictionDryRunPlan(action: decision.kind, reason: decision.reason, candidates: selected, plannedBytes: bytes)
    }

    public static func plan(
        action: GuardDecisionKind,
        reason: String,
        candidates: [EvictionCandidate],
        byteGoal: Int64,
        fileLimit: Int
    ) -> EvictionDryRunPlan {
        guard byteGoal > 0, fileLimit > 0 else {
            return EvictionDryRunPlan(action: action, reason: reason, candidates: [], plannedBytes: 0)
        }
        var selected: [EvictionCandidate] = []
        var bytes: Int64 = 0
        for candidate in candidates {
            guard selected.count < fileLimit, bytes < byteGoal else { break }
            selected.append(candidate)
            let (sum, overflow) = bytes.addingReportingOverflow(candidate.allocatedBytes)
            bytes = overflow ? .max : sum
        }
        return EvictionDryRunPlan(action: action, reason: reason, candidates: selected, plannedBytes: bytes)
    }
}

public enum HumanByteCount {
    public static func parse(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let suffixes: [(String, Int64)] = [
            ("tib", 1_099_511_627_776), ("tb", 1_000_000_000_000),
            ("gib", 1_073_741_824), ("gb", 1_000_000_000),
            ("mib", 1_048_576), ("mb", 1_000_000),
            ("kib", 1_024), ("kb", 1_000), ("b", 1),
        ]
        let match = suffixes.first { trimmed.hasSuffix($0.0) }
        let multiplier = match?.1 ?? 1
        let number = match.map { String(trimmed.dropLast($0.0.count)) } ?? trimmed
        guard let decimal = Decimal(string: number.trimmingCharacters(in: .whitespaces)), decimal > 0 else { return nil }
        let product = decimal * Decimal(multiplier)
        guard product <= Decimal(Int64.max) else { return nil }
        let rounded = NSDecimalNumber(decimal: product).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        let bytes = rounded.int64Value
        return bytes > 0 ? bytes : nil
    }
}

public struct AutomaticRemediationGateResult: Equatable, Sendable {
    public var decision: GuardDecision
    public var candidates: [EvictionCandidate]

    public init(decision: GuardDecision, candidates: [EvictionCandidate]) {
        self.decision = decision
        self.candidates = candidates
    }
}

/// Re-check the mutable policy inputs while the caller owns the mutation lock.
public enum AutomaticRemediationGate {
    public static func evaluate(
        scan: ScanResult,
        state: GuardState,
        config: GuardConfig,
        candidates: [EvictionCandidate],
        pendingPaths: Set<String>,
        now: Date
    ) -> AutomaticRemediationGateResult {
        let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config, now: now)
        let eligible = candidates.filter {
            !pendingPaths.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path)
        }
        return AutomaticRemediationGateResult(decision: decision, candidates: eligible)
    }
}

public enum PolicyEngine {
    public static func evaluate(
        scan: ScanResult,
        state: GuardState,
        config: GuardConfig,
        now: Date,
        forcePanic: Bool = false,
        manualRequest: Bool = false
    ) -> GuardDecision {
        let policy = config.policy.normalized()
        let eligible = prioritizedCandidates(
            from: scan,
            protectedPaths: policy.protectedPaths,
            keepDownloadedPaths: policy.keepDownloadedPaths,
            folderPolicies: policy.folderPolicies
        )
        let growthBytes = calculateGrowthBytes(samples: state.samples, now: now, config: policy)
        let targetedReason = remediationReason(scan: scan, growthBytes: growthBytes, config: policy)

        guard scan.scanComplete else {
            return noAction(reason: "scan incomplete; eviction disabled", scan: scan, growthBytes: growthBytes)
        }

        if forcePanic {
            return panicDecision(reason: "manual panic eviction", scan: scan, eligible: eligible, growthBytes: growthBytes)
        }

        // Automatic remediation must fail closed when disk telemetry is
        // unavailable: local-usage and growth triggers cannot prove that an
        // eviction is currently warranted. Explicit manual requests retain
        // their local-target semantics.
        guard scan.freeSpaceAvailable || manualRequest else {
            return noAction(reason: "free space unavailable; automatic eviction disabled", scan: scan, growthBytes: growthBytes)
        }

        if scan.freeSpaceAvailable, scan.freeBytes < policy.panicFreeBytes {
            return panicDecision(reason: "free space below panic floor", scan: scan, eligible: eligible, growthBytes: growthBytes)
        }

        guard let reason = targetedReason else {
            return GuardDecision(
                kind: .none,
                reason: "healthy",
                candidates: [],
                reclaimTargetBytes: 0,
                predictedLocalBytes: scan.localBytes,
                predictedFreeBytes: scan.freeBytes,
                cooldownRemainingSeconds: nil,
                growthBytes: growthBytes
            )
        }

        if let cooldownRemainingSeconds = cooldownRemainingSeconds(state: state, now: now, config: policy) {
            return GuardDecision(
                kind: .cooldown,
                reason: reason,
                candidates: [],
                reclaimTargetBytes: 0,
                predictedLocalBytes: scan.localBytes,
                predictedFreeBytes: scan.freeBytes,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                growthBytes: growthBytes
            )
        }

        let targetedCandidates = selectTargetedCandidates(scan: scan, config: policy, eligible: eligible)
        let reclaimedBytes = targetedCandidates.reduce(into: Int64(0)) { partialResult, item in
            partialResult += item.localBytes
        }

        return GuardDecision(
            kind: .targeted,
            reason: reason,
            candidates: targetedCandidates,
            reclaimTargetBytes: targetedReclaimTargetBytes(scan: scan, config: policy),
            predictedLocalBytes: max(scan.localBytes - reclaimedBytes, 0),
            predictedFreeBytes: scan.freeBytes + reclaimedBytes,
            cooldownRemainingSeconds: nil,
            growthBytes: growthBytes
        )
    }

    public static func prioritizedCandidates(
        from scan: ScanResult,
        protectedPaths: [String],
        keepDownloadedPaths: [String] = [],
        folderPolicies: [FolderPolicyRule] = []
    ) -> [ICloudItemSnapshot] {
        let matcher = ProtectedPathsMatcher(
            protectedPaths: protectedPaths,
            keepDownloadedPatterns: keepDownloadedPaths,
            folderPolicies: folderPolicies
        )
        return scan.items
            .filter {
                $0.isEligibleForEviction(protectedPaths: [])
                    && !matcher.isProtected(path: $0.absolutePath, relativePath: $0.relativePath)
            }
            .sorted {
                let lhsRank = matcher.priorityRank(relativePath: $0.relativePath)
                let rhsRank = matcher.priorityRank(relativePath: $1.relativePath)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
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

    public static func selectTargetedCandidates(
        scan: ScanResult,
        config: PolicyConfig,
        eligible: [ICloudItemSnapshot]? = nil
    ) -> [ICloudItemSnapshot] {
        let normalizedConfig = config.normalized()
        let candidates = eligible ?? prioritizedCandidates(
            from: scan,
            protectedPaths: normalizedConfig.protectedPaths,
            keepDownloadedPaths: normalizedConfig.keepDownloadedPaths,
            folderPolicies: normalizedConfig.folderPolicies
        )
        let reclaimTarget = targetedReclaimTargetBytes(scan: scan, config: normalizedConfig)

        if reclaimTarget <= 0 {
            return []
        }

        var selected: [ICloudItemSnapshot] = []
        var reclaimedBytes: Int64 = 0

        for candidate in candidates {
            selected.append(candidate)
            reclaimedBytes += candidate.localBytes

            if reclaimedBytes >= reclaimTarget {
                break
            }
        }

        return selected
    }

    public static func panicCandidates(scan: ScanResult, config: PolicyConfig) -> [ICloudItemSnapshot] {
        let normalized = config.normalized()
        return prioritizedCandidates(
            from: scan,
            protectedPaths: normalized.protectedPaths,
            keepDownloadedPaths: normalized.keepDownloadedPaths,
            folderPolicies: normalized.folderPolicies
        )
    }

    public static func calculateGrowthBytes(samples: [GuardSample], now: Date, config: PolicyConfig) -> Int64 {
        let normalizedConfig = config.normalized()
        let threshold = now.addingTimeInterval(TimeInterval(-normalizedConfig.growthWindowMinutes * 60))
        guard let earliest = samples
            .filter({ $0.timestamp >= threshold })
            .sorted(by: { $0.timestamp < $1.timestamp })
            .first
        else {
            return 0
        }

        guard let latest = samples.max(by: { $0.timestamp < $1.timestamp }) else {
            return 0
        }

        return max(latest.localBytes - earliest.localBytes, 0)
    }

    public static func cooldownRemainingSeconds(state: GuardState, now: Date, config: PolicyConfig) -> Int? {
        guard let lastRemediationAt = state.lastRemediationAt else {
            return nil
        }

        let normalizedConfig = config.normalized()
        let remaining = Int(lastRemediationAt.addingTimeInterval(TimeInterval(normalizedConfig.cooldownMinutes * 60)).timeIntervalSince(now))
        return remaining > 0 ? remaining : nil
    }

    public static func targetedReclaimTargetBytes(scan: ScanResult, config: PolicyConfig) -> Int64 {
        let normalizedConfig = config.normalized()
        let localOverflow = max(scan.localBytes - normalizedConfig.targetLocalBytes, 0)
        let freeSpaceShortfall = scan.freeSpaceAvailable
            ? max(normalizedConfig.warnFreeBytes - scan.freeBytes, 0)
            : 0
        return max(localOverflow, freeSpaceShortfall)
    }

    private static func remediationReason(scan: ScanResult, growthBytes: Int64, config: PolicyConfig) -> String? {
        let normalizedConfig = config.normalized()
        if scan.localBytes > normalizedConfig.trimLocalBytes {
            return "local iCloud usage exceeded trim threshold"
        }

        if scan.freeSpaceAvailable, scan.freeBytes < normalizedConfig.remediateFreeBytes {
            return "free space below remediation floor"
        }

        if growthBytes > normalizedConfig.growthTriggerBytes {
            return "local iCloud usage grew too quickly"
        }

        return nil
    }

    private static func panicDecision(
        reason: String,
        scan: ScanResult,
        eligible: [ICloudItemSnapshot],
        growthBytes: Int64
    ) -> GuardDecision {
        let reclaimedBytes = eligible.reduce(into: Int64(0)) { partialResult, item in
            partialResult += item.localBytes
        }

        return GuardDecision(
            kind: .panic,
            reason: reason,
            candidates: eligible,
            reclaimTargetBytes: reclaimedBytes,
            predictedLocalBytes: max(scan.localBytes - reclaimedBytes, 0),
            predictedFreeBytes: scan.freeBytes + reclaimedBytes,
            cooldownRemainingSeconds: nil,
            growthBytes: growthBytes
        )
    }

    private static func noAction(reason: String, scan: ScanResult, growthBytes: Int64) -> GuardDecision {
        GuardDecision(
            kind: .none,
            reason: reason,
            candidates: [],
            reclaimTargetBytes: 0,
            predictedLocalBytes: scan.localBytes,
            predictedFreeBytes: scan.freeBytes,
            cooldownRemainingSeconds: nil,
            growthBytes: growthBytes
        )
    }
}

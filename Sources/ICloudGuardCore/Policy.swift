import Foundation

public enum PolicyEngine {
    public static func evaluate(
        scan: ScanResult,
        state: GuardState,
        config: GuardConfig,
        now: Date,
        forcePanic: Bool = false
    ) -> GuardDecision {
        let policy = config.policy.normalized()
        let eligible = prioritizedCandidates(from: scan, protectedPaths: policy.protectedPaths)
        let growthBytes = calculateGrowthBytes(samples: state.samples, now: now, config: policy)
        let targetedReason = remediationReason(scan: scan, growthBytes: growthBytes, config: policy)

        if forcePanic {
            return panicDecision(reason: "manual panic eviction", scan: scan, eligible: eligible, growthBytes: growthBytes)
        }

        if scan.freeBytes < policy.panicFreeBytes {
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

    public static func prioritizedCandidates(from scan: ScanResult, protectedPaths: [String]) -> [ICloudItemSnapshot] {
        scan.items
            .filter { $0.isEligibleForEviction(protectedPaths: protectedPaths) }
            .sorted {
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
        let candidates = eligible ?? prioritizedCandidates(from: scan, protectedPaths: normalizedConfig.protectedPaths)
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
        prioritizedCandidates(from: scan, protectedPaths: config.normalized().protectedPaths)
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
        let freeSpaceShortfall = max(normalizedConfig.warnFreeBytes - scan.freeBytes, 0)
        return max(localOverflow, freeSpaceShortfall)
    }

    private static func remediationReason(scan: ScanResult, growthBytes: Int64, config: PolicyConfig) -> String? {
        let normalizedConfig = config.normalized()
        if scan.localBytes > normalizedConfig.trimLocalBytes {
            return "local iCloud usage exceeded trim threshold"
        }

        if scan.freeBytes < normalizedConfig.remediateFreeBytes {
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
}

import Foundation

public let bytesPerGiB: Int64 = 1024 * 1024 * 1024

public struct GuardConfig: Codable, Equatable, Sendable {
    public var label: String
    public var logPath: String
    public var lockPath: String
    public var scopePath: String
    public var statePath: String
    public var notifications: NotificationConfig
    public var policy: PolicyConfig

    public init(
        label: String,
        logPath: String,
        lockPath: String,
        scopePath: String,
        statePath: String,
        notifications: NotificationConfig,
        policy: PolicyConfig
    ) {
        self.label = label
        self.logPath = logPath
        self.lockPath = lockPath
        self.scopePath = scopePath
        self.statePath = statePath
        self.notifications = notifications
        self.policy = policy
    }
}

public struct NotificationConfig: Codable, Equatable, Sendable {
    public var enable: Bool

    public init(enable: Bool) {
        self.enable = enable
    }
}

public struct PolicyConfig: Codable, Equatable, Sendable {
    public var sampleIntervalSeconds: Int
    public var targetLocalGiB: Int
    public var trimLocalGiB: Int
    public var warnFreeGiB: Int
    public var remediateFreeGiB: Int
    public var panicFreeGiB: Int
    public var growthTriggerGiB: Int
    public var growthWindowMinutes: Int
    public var cooldownMinutes: Int
    public var protectedPaths: [String]

    public init(
        sampleIntervalSeconds: Int,
        targetLocalGiB: Int,
        trimLocalGiB: Int,
        warnFreeGiB: Int,
        remediateFreeGiB: Int,
        panicFreeGiB: Int,
        growthTriggerGiB: Int,
        growthWindowMinutes: Int,
        cooldownMinutes: Int,
        protectedPaths: [String]
    ) {
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.targetLocalGiB = targetLocalGiB
        self.trimLocalGiB = trimLocalGiB
        self.warnFreeGiB = warnFreeGiB
        self.remediateFreeGiB = remediateFreeGiB
        self.panicFreeGiB = panicFreeGiB
        self.growthTriggerGiB = growthTriggerGiB
        self.growthWindowMinutes = growthWindowMinutes
        self.cooldownMinutes = cooldownMinutes
        self.protectedPaths = protectedPaths
    }

    public var targetLocalBytes: Int64 { Int64(targetLocalGiB) * bytesPerGiB }
    public var trimLocalBytes: Int64 { Int64(trimLocalGiB) * bytesPerGiB }
    public var warnFreeBytes: Int64 { Int64(warnFreeGiB) * bytesPerGiB }
    public var remediateFreeBytes: Int64 { Int64(remediateFreeGiB) * bytesPerGiB }
    public var panicFreeBytes: Int64 { Int64(panicFreeGiB) * bytesPerGiB }
    public var growthTriggerBytes: Int64 { Int64(growthTriggerGiB) * bytesPerGiB }
}

public struct GuardSample: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var localBytes: Int64
    public var freeBytes: Int64

    public init(timestamp: Date, localBytes: Int64, freeBytes: Int64) {
        self.timestamp = timestamp
        self.localBytes = localBytes
        self.freeBytes = freeBytes
    }
}

public struct ActiveLock: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

public struct GuardRunSummary: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var action: GuardDecisionKind
    public var reason: String
    public var dryRun: Bool
    public var candidateCount: Int
    public var evictedCount: Int
    public var failedEvictionCount: Int
    public var reclaimedBytes: Int64
    public var remainingLocalBytes: Int64
    public var remainingFreeBytes: Int64
    public var escalatedToPanic: Bool

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case action
        case reason
        case dryRun
        case candidateCount
        case evictedCount
        case failedEvictionCount
        case reclaimedBytes
        case remainingLocalBytes
        case remainingFreeBytes
        case escalatedToPanic
    }

    public init(
        timestamp: Date,
        action: GuardDecisionKind,
        reason: String,
        dryRun: Bool,
        candidateCount: Int,
        evictedCount: Int,
        failedEvictionCount: Int,
        reclaimedBytes: Int64,
        remainingLocalBytes: Int64,
        remainingFreeBytes: Int64,
        escalatedToPanic: Bool
    ) {
        self.timestamp = timestamp
        self.action = action
        self.reason = reason
        self.dryRun = dryRun
        self.candidateCount = candidateCount
        self.evictedCount = evictedCount
        self.failedEvictionCount = failedEvictionCount
        self.reclaimedBytes = reclaimedBytes
        self.remainingLocalBytes = remainingLocalBytes
        self.remainingFreeBytes = remainingFreeBytes
        self.escalatedToPanic = escalatedToPanic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.action = try container.decode(GuardDecisionKind.self, forKey: .action)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.dryRun = try container.decode(Bool.self, forKey: .dryRun)
        self.candidateCount = try container.decode(Int.self, forKey: .candidateCount)
        self.evictedCount = try container.decode(Int.self, forKey: .evictedCount)
        self.failedEvictionCount = try container.decodeIfPresent(Int.self, forKey: .failedEvictionCount) ?? 0
        self.reclaimedBytes = try container.decode(Int64.self, forKey: .reclaimedBytes)
        self.remainingLocalBytes = try container.decode(Int64.self, forKey: .remainingLocalBytes)
        self.remainingFreeBytes = try container.decode(Int64.self, forKey: .remainingFreeBytes)
        self.escalatedToPanic = try container.decodeIfPresent(Bool.self, forKey: .escalatedToPanic) ?? false
    }
}

public struct GuardState: Codable, Equatable, Sendable {
    public var samples: [GuardSample]
    public var lastRemediationAt: Date?
    public var lastLockContentionAt: Date?
    public var activeLock: ActiveLock?
    public var lastSummary: GuardRunSummary?

    public init(
        samples: [GuardSample] = [],
        lastRemediationAt: Date? = nil,
        lastLockContentionAt: Date? = nil,
        activeLock: ActiveLock? = nil,
        lastSummary: GuardRunSummary? = nil
    ) {
        self.samples = samples
        self.lastRemediationAt = lastRemediationAt
        self.lastLockContentionAt = lastLockContentionAt
        self.activeLock = activeLock
        self.lastSummary = lastSummary
    }
}

public struct ICloudItemSnapshot: Codable, Equatable, Sendable {
    public var relativePath: String
    public var absolutePath: String
    public var localBytes: Int64
    public var isRegularFile: Bool
    public var isPackage: Bool
    public var isUbiquitous: Bool
    public var isUploaded: Bool
    public var isUploading: Bool
    public var isDownloading: Bool
    public var downloadingStatus: String?
    public var hasDownloadError: Bool
    public var hasUploadError: Bool
    public var contentModificationDate: Date?

    public init(
        relativePath: String,
        absolutePath: String,
        localBytes: Int64,
        isRegularFile: Bool,
        isPackage: Bool,
        isUbiquitous: Bool,
        isUploaded: Bool,
        isUploading: Bool,
        isDownloading: Bool,
        downloadingStatus: String?,
        hasDownloadError: Bool,
        hasUploadError: Bool,
        contentModificationDate: Date?
    ) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.localBytes = localBytes
        self.isRegularFile = isRegularFile
        self.isPackage = isPackage
        self.isUbiquitous = isUbiquitous
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.isDownloading = isDownloading
        self.downloadingStatus = downloadingStatus
        self.hasDownloadError = hasDownloadError
        self.hasUploadError = hasUploadError
        self.contentModificationDate = contentModificationDate
    }

    public var normalizedRelativePath: String {
        relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public var isLocallyResident: Bool {
        if localBytes > 0 {
            return true
        }

        return downloadingStatus == URLUbiquitousItemDownloadingStatus.current.rawValue
            || downloadingStatus == URLUbiquitousItemDownloadingStatus.downloaded.rawValue
    }

    public func isProtected(by protectedPaths: [String]) -> Bool {
        let candidate = normalizedRelativePath

        for protectedPath in protectedPaths {
            let normalized = protectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            if normalized.isEmpty {
                continue
            }

            if candidate == normalized || candidate.hasPrefix(normalized + "/") {
                return true
            }
        }

        return false
    }

    public func evictionEligibilityBlockers(protectedPaths: [String]) -> [EvictionEligibilityBlocker] {
        var blockers: [EvictionEligibilityBlocker] = []

        if !isRegularFile && !isPackage {
            blockers.append(.notRegularFile)
        }
        if !isUbiquitous {
            blockers.append(.notUbiquitous)
        }
        if !isLocallyResident {
            blockers.append(.notLocallyResident)
        }
        // File provider metadata is often stale or package-scoped here; eviction itself remains the authority.
        if isUploading {
            blockers.append(.uploading)
        }
        if isDownloading {
            blockers.append(.downloading)
        }
        if hasDownloadError {
            blockers.append(.downloadError)
        }
        if hasUploadError {
            blockers.append(.uploadError)
        }
        if isProtected(by: protectedPaths) {
            blockers.append(.protectedPath)
        }

        return blockers
    }

    public func isEligibleForEviction(protectedPaths: [String]) -> Bool {
        evictionEligibilityBlockers(protectedPaths: protectedPaths).isEmpty
    }
}

public enum EvictionEligibilityBlocker: String, Codable, Equatable, Sendable {
    case notRegularFile
    case package
    case notUbiquitous
    case notLocallyResident
    case notUploaded
    case uploading
    case downloading
    case downloadError
    case uploadError
    case protectedPath
}

public struct ScanResult: Codable, Equatable, Sendable {
    public var scopePath: String
    public var freeBytes: Int64
    public var localBytes: Int64
    public var items: [ICloudItemSnapshot]

    public init(scopePath: String, freeBytes: Int64, localBytes: Int64, items: [ICloudItemSnapshot]) {
        self.scopePath = scopePath
        self.freeBytes = freeBytes
        self.localBytes = localBytes
        self.items = items
    }
}

public enum GuardDecisionKind: String, Codable, Equatable, Sendable {
    case none
    case targeted
    case panic
    case cooldown
}

public struct GuardDecision: Equatable, Sendable {
    public var kind: GuardDecisionKind
    public var reason: String
    public var candidates: [ICloudItemSnapshot]
    public var reclaimTargetBytes: Int64
    public var predictedLocalBytes: Int64
    public var predictedFreeBytes: Int64
    public var cooldownRemainingSeconds: Int?
    public var growthBytes: Int64

    public init(
        kind: GuardDecisionKind,
        reason: String,
        candidates: [ICloudItemSnapshot],
        reclaimTargetBytes: Int64,
        predictedLocalBytes: Int64,
        predictedFreeBytes: Int64,
        cooldownRemainingSeconds: Int?,
        growthBytes: Int64
    ) {
        self.kind = kind
        self.reason = reason
        self.candidates = candidates
        self.reclaimTargetBytes = reclaimTargetBytes
        self.predictedLocalBytes = predictedLocalBytes
        self.predictedFreeBytes = predictedFreeBytes
        self.cooldownRemainingSeconds = cooldownRemainingSeconds
        self.growthBytes = growthBytes
    }
}

public struct RemediationResult: Equatable, Sendable {
    public var summary: GuardRunSummary
    public var selected: [ICloudItemSnapshot]

    public init(summary: GuardRunSummary, selected: [ICloudItemSnapshot]) {
        self.summary = summary
        self.selected = selected
    }
}

public enum GuardCommand: String, Equatable, Sendable {
    case status
    case run
    case panicEvict = "panic-evict"
}

public enum GuardError: Error, CustomStringConvertible {
    case usage(String)
    case lockUnavailable(String)
    case runtime(String)

    public var description: String {
        switch self {
        case .usage(let message), .lockUnavailable(let message), .runtime(let message):
            return message
        }
    }
}

public func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .binary
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

// MARK: - Download Suppression

public struct DownloadSuppressionConfig: Codable, Equatable, Sendable {
    public var spotlightSuppression: Bool
    public var quickLookCacheClear: Bool
    public var materializeDatalessFiles: Bool
    public var scopePath: String

    public init(
        spotlightSuppression: Bool = true,
        quickLookCacheClear: Bool = true,
        materializeDatalessFiles: Bool = false,
        scopePath: String = ""
    ) {
        self.spotlightSuppression = spotlightSuppression
        self.quickLookCacheClear = quickLookCacheClear
        self.materializeDatalessFiles = materializeDatalessFiles
        self.scopePath = scopePath
    }
}

// MARK: - Rematerialization

public struct RematerializationEvent: Codable, Equatable, Sendable {
    public var itemPath: String
    public var detectedAt: Date
    public var previousStatus: String
    public var newStatus: String

    public init(itemPath: String, detectedAt: Date, previousStatus: String, newStatus: String) {
        self.itemPath = itemPath
        self.detectedAt = detectedAt
        self.previousStatus = previousStatus
        self.newStatus = newStatus
    }
}

// MARK: - Eviction Verification

public struct EvictionVerification: Equatable, Sendable {
    public var absolutePath: String
    public var isDataless: Bool
    public var fileAllocatedSize: Int64
    public var fileSize: Int64

    public init(absolutePath: String, isDataless: Bool, fileAllocatedSize: Int64, fileSize: Int64) {
        self.absolutePath = absolutePath
        self.isDataless = isDataless
        self.fileAllocatedSize = fileAllocatedSize
        self.fileSize = fileSize
    }

    public var isVerifiedDataless: Bool {
        isDataless && fileAllocatedSize == 0 && fileSize > 0
    }
}

// APFS SF_DATALESS flag (st_flags bit 30, 0x40000000)
public let SF_DATALESS: UInt32 = 0x40000000

import Darwin
import Foundation

/// Aggregate statistics from a drive scan — the single source of truth for
/// both the menu bar UI and policy decisions.
public struct DriveStats: Equatable, Sendable {
    /// Materialized (locally resident) regular files.
    public var materializedFiles: Int = 0
    /// Evicted (dataless) regular files.
    public var datalessFiles: Int = 0
    /// Bytes occupied on disk by materialized files.
    public var materializedBytes: Int64 = 0
    /// Free bytes on the volume (capacity available for important usage).
    public var freeBytes: Int64 = 0
    /// False when both volume-capacity probes failed. A zero value is only
    /// actionable when this flag is true.
    public var freeSpaceAvailable: Bool = false
    /// False when any directory was skipped, a read failed, or cancellation
    /// stopped the walk before completion.
    public var scanComplete: Bool = false
    public var skippedDirectories: Int = 0
    public var scanReadErrors: Int = 0
    /// Top-level folders by materialized bytes, descending.
    public var topFolders: [FolderUsage] = []
    /// Wall-clock seconds the scan took.
    public var scanDurationSeconds: Double = 0
    /// When the scan finished.
    public var completedAt: Date = .distantPast

    public init() {}

    public var totalFiles: Int { materializedFiles + datalessFiles }

    /// Share of scanned files that are materialized (0…1). 0 when nothing scanned.
    public var materializedRatio: Double {
        totalFiles > 0 ? Double(materializedFiles) / Double(totalFiles) : 0
    }
}

public struct FolderUsage: Equatable, Sendable {
    public let name: String
    public let bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

/// Collects `DriveStats` from a single bulk scan. Regular files only —
/// directories never pollute the materialized/evicted counts.
public enum DriveStatsCollector {
    public static func collect(
        scopePath: String,
        topFolderLimit: Int = 5,
        shouldStop: () -> Bool = { false },
        onEntry: ((BulkScanEntry) -> Void)? = nil
    ) throws -> DriveStats {
        var stats = DriveStats()
        var folderBytes: [String: Int64] = [:]
        let startedAt = Date()

        let scanSummary = try BulkScanner.scan(rootPath: scopePath, shouldStop: shouldStop) { entry in
            onEntry?(entry)
            guard entry.isRegularFile else { return } // directories are never counted

            if entry.isDataless {
                stats.datalessFiles += 1
            } else {
                stats.materializedFiles += 1
                stats.materializedBytes += entry.allocatedBytes
                let topFolder = entry.relativePath.split(separator: "/").first.map(String.init) ?? "(root)"
                folderBytes[topFolder, default: 0] += entry.allocatedBytes
            }
        }

        if let freeBytes = Self.freeDiskBytes(scopePath: scopePath) {
            stats.freeBytes = freeBytes
            stats.freeSpaceAvailable = true
        }
        stats.scanComplete = scanSummary.isComplete
        stats.skippedDirectories = scanSummary.skippedDirectories
        stats.scanReadErrors = scanSummary.readErrors
        stats.topFolders = folderBytes
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(topFolderLimit)
            .map { FolderUsage(name: $0.key, bytes: $0.value) }
        stats.scanDurationSeconds = Date().timeIntervalSince(startedAt)
        stats.completedAt = Date()
        return stats
    }

    public static func freeDiskBytes(scopePath: String) -> Int64? {
        let scopeURL = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
        if let values = try? scopeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            return Int64(bytes)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: scopeURL.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }
}

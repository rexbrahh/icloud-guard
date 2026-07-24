import AppKit
import Foundation

/// The product of one full tree walk: drive statistics AND eviction
/// candidates, collected together so a trim never needs to walk the drive
/// twice.
public struct ScanBundle: Sendable {
    public var stats: DriveStats
    public var candidates: [EvictionCandidate]

    public init(stats: DriveStats, candidates: [EvictionCandidate]) {
        self.stats = stats
        self.candidates = candidates
    }
}

/// One `BulkScanner` walk feeding both aggregations:
/// - `DriveStats` (materialized/dataless counts, bytes, top folders, free space)
/// - `[EvictionCandidate]` (eligible files + package roots, sorted for eviction)
public enum ScanOrchestrator {
    public static func scan(
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        topFolderLimit: Int = 5,
        shouldStop: () -> Bool = { false },
        onProgress: ((Int) -> Void)? = nil
    ) throws -> ScanBundle {
        var stats = DriveStats()
        var folderBytes: [String: Int64] = [:]

        var plainCandidates: [EvictionCandidate] = []
        var packageDirectories: Set<String> = []
        var packageAggregates: [String: (relativePath: String, bytes: Int64, oldest: Date?, protected: Bool)] = [:]
        // Package-ness is a property of the extension's UTI declaration —
        // cache per extension to avoid repeated LaunchServices lookups.
        var packageKindByExtension: [String: Bool] = [:]

        var scannedFiles = 0
        var lastProgressAt = Date.distantPast
        let startedAt = Date()

        try BulkScanner.scan(rootPath: scopePath, shouldStop: shouldStop) { entry in
            if entry.isDirectory {
                let ext = URL(fileURLWithPath: entry.path).pathExtension
                if !ext.isEmpty {
                    let isPackage: Bool
                    if let cached = packageKindByExtension[ext] {
                        isPackage = cached
                    } else {
                        isPackage = NSWorkspace.shared.isFilePackage(atPath: entry.path)
                        packageKindByExtension[ext] = isPackage
                    }
                    if isPackage {
                        packageDirectories.insert(entry.path)
                    }
                }
                return
            }

            scannedFiles += 1

            if entry.isDataless {
                stats.datalessFiles += 1
            } else if entry.allocatedBytes > 0 {
                stats.materializedFiles += 1
                stats.materializedBytes += entry.allocatedBytes
                let topFolder = entry.relativePath.split(separator: "/").first.map(String.init) ?? "(root)"
                folderBytes[topFolder, default: 0] += entry.allocatedBytes

                let isProtected = protectedPaths.isProtected(path: entry.path, relativePath: entry.relativePath)
                if let packageRoot = nearestPackageAncestor(of: entry.path, in: packageDirectories) {
                    var aggregate = packageAggregates[packageRoot]
                        ?? (relativePath: entry.relativePath, bytes: 0, oldest: nil, protected: false)
                    aggregate.bytes += entry.allocatedBytes
                    if let date = entry.modificationDate, aggregate.oldest == nil || date < aggregate.oldest! {
                        aggregate.oldest = date
                    }
                    if isProtected {
                        aggregate.protected = true
                    }
                    packageAggregates[packageRoot] = aggregate
                } else if !isProtected {
                    plainCandidates.append(EvictionCandidate(
                        path: entry.path,
                        relativePath: entry.relativePath,
                        allocatedBytes: entry.allocatedBytes,
                        modificationDate: entry.modificationDate
                    ))
                }
            }

            let now = Date()
            if now.timeIntervalSince(lastProgressAt) >= 0.5 {
                lastProgressAt = now
                onProgress?(scannedFiles)
            }
        }

        stats.freeBytes = DriveStatsCollector.freeDiskBytes(scopePath: scopePath)
        stats.topFolders = folderBytes
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(topFolderLimit)
            .map { FolderUsage(name: $0.key, bytes: $0.value) }
        stats.scanDurationSeconds = Date().timeIntervalSince(startedAt)
        stats.completedAt = Date()

        let packageCandidates: [EvictionCandidate] = packageAggregates.compactMap { path, aggregate in
            guard !aggregate.protected else { return nil }
            guard !protectedPaths.isProtected(path: path, relativePath: aggregate.relativePath) else { return nil }
            return EvictionCandidate(
                path: path,
                relativePath: aggregate.relativePath,
                allocatedBytes: aggregate.bytes,
                modificationDate: aggregate.oldest,
                isPackageRoot: true
            )
        }

        var candidates = plainCandidates + packageCandidates
        candidates.sort { lhs, rhs in
            if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
            let lhsDate = lhs.modificationDate ?? .distantPast
            let rhsDate = rhs.modificationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.relativePath < rhs.relativePath
        }

        onProgress?(scannedFiles)
        return ScanBundle(stats: stats, candidates: candidates)
    }

    /// Nearest ancestor directory of `path` that is a known package, if any.
    private static func nearestPackageAncestor(of path: String, in packageDirectories: Set<String>) -> String? {
        guard !packageDirectories.isEmpty else { return nil }
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            if packageDirectories.contains(current) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }
}

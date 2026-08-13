import AppKit
import Foundation

public enum PreviewExclusionReason: String, Codable, CaseIterable, Sendable {
    case protected
    case recent
    case dataless
    case pending
    case suspended
    case scope
    case package
    case incomplete
}

/// The product of one full tree walk: drive statistics AND eviction
/// candidates, collected together so a trim never needs to walk the drive
/// twice.
public struct ScanBundle: Sendable {
    public var stats: DriveStats
    public var candidates: [EvictionCandidate]
    public var exclusions: [PreviewExclusionReason: Int]

    public init(
        stats: DriveStats,
        candidates: [EvictionCandidate],
        exclusions: [PreviewExclusionReason: Int] = [:]
    ) {
        self.stats = stats
        self.candidates = candidates
        self.exclusions = exclusions
    }
}

/// One `BulkScanner` walk feeding both aggregations:
/// - `DriveStats` (materialized/dataless counts, bytes, top folders, free space)
/// - `[EvictionCandidate]` (eligible files + package roots, sorted for eviction)
public enum ScanOrchestrator {
    typealias BulkScanProvider = (
        _ rootPath: String,
        _ shouldStop: () -> Bool,
        _ onEntry: (BulkScanEntry) -> Void
    ) throws -> BulkScanSummary

    public static func scan(
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        topFolderLimit: Int = 5,
        shouldStop: @escaping () -> Bool = { false },
        onProgress: ((Int) -> Void)? = nil
    ) throws -> ScanBundle {
        try scan(
            scopePath: scopePath,
            protectedPaths: protectedPaths,
            topFolderLimit: topFolderLimit,
            shouldStop: shouldStop,
            onProgress: onProgress,
            bulkScan: { rootPath, stop, onEntry in
                try BulkScanner.scan(rootPath: rootPath, shouldStop: stop, onEntry: onEntry)
            },
            isFilePackage: { NSWorkspace.shared.isFilePackage(atPath: $0) },
            freeDiskBytes: DriveStatsCollector.freeDiskBytes
        )
    }

    static func scan(
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        topFolderLimit: Int = 5,
        shouldStop: @escaping () -> Bool = { false },
        onProgress: ((Int) -> Void)? = nil,
        bulkScan: BulkScanProvider,
        isFilePackage: @escaping (String) -> Bool,
        freeDiskBytes: @escaping (String) -> Int64?
    ) throws -> ScanBundle {
        var stats = DriveStats()
        var folderBytes: [String: Int64] = [:]

        var plainCandidates: [EvictionCandidate] = []
        var packageDirectories: Set<String> = []
        var packageIdentities: [String: EvictionFileIdentity] = [:]
        var packageAggregates: [String: (relativePath: String, bytes: Int64, oldest: Date?, protected: Bool)] = [:]
        // Package-ness is a property of the extension's UTI declaration —
        // cache per extension to avoid repeated LaunchServices lookups.
        var packageKindByExtension: [String: Bool] = [:]
        var exclusions: [PreviewExclusionReason: Int] = [:]

        var scannedFiles = 0
        var lastProgressAt = Date.distantPast
        let startedAt = Date()

        let scanSummary = try bulkScan(scopePath, shouldStop) { entry in
            if entry.isDirectory {
                let ext = URL(fileURLWithPath: entry.path).pathExtension
                if !ext.isEmpty {
                    let isPackage: Bool
                    if let cached = packageKindByExtension[ext] {
                        isPackage = cached
                    } else {
                        isPackage = isFilePackage(entry.path)
                        packageKindByExtension[ext] = isPackage
                    }
                    if isPackage {
                        packageDirectories.insert(entry.path)
                        if let identity = entry.identity { packageIdentities[entry.path] = identity }
                    }
                }
                return
            }

            scannedFiles += 1

            let isProtected = protectedPaths.isProtected(path: entry.path, relativePath: entry.relativePath)
            let packageRoot = nearestPackageAncestor(of: entry.path, in: packageDirectories)
            if let packageRoot {
                let packageRelativePath = relativePath(of: packageRoot, under: scopePath)
                var aggregate = packageAggregates[packageRoot]
                    ?? (relativePath: packageRelativePath, bytes: 0, oldest: nil, protected: false)
                if isProtected { aggregate.protected = true }
                packageAggregates[packageRoot] = aggregate
            }

            if entry.isDataless {
                stats.datalessFiles += 1
                if isProtected {
                    exclusions[.protected, default: 0] += 1
                } else {
                    exclusions[.dataless, default: 0] += 1
                }
            } else {
                stats.materializedFiles += 1
                stats.materializedBytes += entry.allocatedBytes
                let topFolder = entry.relativePath.split(separator: "/").first.map(String.init) ?? "(root)"
                folderBytes[topFolder, default: 0] += entry.allocatedBytes

                if let packageRoot {
                    if isProtected {
                        exclusions[.protected, default: 0] += 1
                    } else {
                        exclusions[.package, default: 0] += 1
                    }
                    var aggregate = packageAggregates[packageRoot]!
                    aggregate.bytes += entry.allocatedBytes
                    if let date = entry.modificationDate, aggregate.oldest == nil || date < aggregate.oldest! {
                        aggregate.oldest = date
                    }
                    packageAggregates[packageRoot] = aggregate
                } else if isProtected {
                    exclusions[.protected, default: 0] += 1
                } else if entry.allocatedBytes > 0 {
                    plainCandidates.append(EvictionCandidate(
                        path: entry.path,
                        relativePath: entry.relativePath,
                        allocatedBytes: entry.allocatedBytes,
                        modificationDate: entry.modificationDate,
                        identity: entry.identity
                    ))
                }
            }

            let now = Date()
            if now.timeIntervalSince(lastProgressAt) >= 0.5 {
                lastProgressAt = now
                onProgress?(scannedFiles)
            }
        }

        if let freeBytes = freeDiskBytes(scopePath) {
            stats.freeBytes = freeBytes
            stats.freeSpaceAvailable = true
        }
        stats.scanComplete = scanSummary.isComplete
        stats.skippedDirectories = scanSummary.skippedDirectories
        stats.scanReadErrors = scanSummary.readErrors
        if scanSummary.skippedDirectories > 0 { exclusions[.scope] = scanSummary.skippedDirectories }
        if scanSummary.readErrors > 0 { exclusions[.incomplete] = scanSummary.readErrors }
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
            guard aggregate.bytes > 0 else { return nil }
            guard !protectedPaths.isProtected(path: path, relativePath: aggregate.relativePath) else { return nil }
            return EvictionCandidate(
                path: path,
                relativePath: aggregate.relativePath,
                allocatedBytes: aggregate.bytes,
                modificationDate: aggregate.oldest,
                isPackageRoot: true,
                identity: packageIdentities[path]
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
        return ScanBundle(stats: stats, candidates: candidates, exclusions: exclusions)
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

    private static func relativePath(of path: String, under rootPath: String) -> String {
        let root = URL(fileURLWithPath: NSString(string: rootPath).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return URL(fileURLWithPath: path).lastPathComponent }
        return String(candidate.dropFirst(root.count + 1))
    }
}

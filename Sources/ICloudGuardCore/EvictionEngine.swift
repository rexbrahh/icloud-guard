import AppKit
import Darwin
import Foundation

/// A file or package eligible for eviction.
///
/// On macOS 26 `evictUbiquitousItem` refuses package *contents* (the items
/// don't exist as individual FileProvider entries) — packages are evicted as
/// a single unit at their root. Package contents are therefore aggregated
/// into one package-root candidate.
public struct EvictionCandidate: Equatable, Sendable {
    public let path: String
    public let relativePath: String
    public let allocatedBytes: Int64
    public let modificationDate: Date?
    /// True when this candidate is a package/bundle root (e.g. .app, .fcpbundle).
    public let isPackageRoot: Bool

    public init(path: String, relativePath: String, allocatedBytes: Int64, modificationDate: Date?, isPackageRoot: Bool = false) {
        self.path = path
        self.relativePath = relativePath
        self.allocatedBytes = allocatedBytes
        self.modificationDate = modificationDate
        self.isPackageRoot = isPackageRoot
    }
}

public enum EvictionPhase: String, Equatable, Sendable {
    case scanning
    case evicting
    case done
    case cancelled
}

/// Live progress for a scan/eviction run. Published at most ~5 times per
/// second by the engine; also emitted on phase changes and completion.
public struct EvictionProgress: Equatable, Sendable {
    public var phase: EvictionPhase = .scanning
    public var scannedFiles: Int = 0
    public var candidateCount: Int = 0
    public var candidateBytes: Int64 = 0
    public var evictedCount: Int = 0
    public var failedCount: Int = 0
    /// Verified bytes actually freed (post-eviction lstat delta).
    public var reclaimedBytes: Int64 = 0
    public var currentPath: String?
    /// Failure reason → count, e.g. "busy" → 3.
    public var failureReasons: [String: Int] = [:]

    public init() {}

    public init(
        phase: EvictionPhase,
        scannedFiles: Int = 0,
        candidateCount: Int = 0,
        candidateBytes: Int64 = 0,
        evictedCount: Int = 0,
        failedCount: Int = 0,
        reclaimedBytes: Int64 = 0,
        currentPath: String? = nil,
        failureReasons: [String: Int] = [:]
    ) {
        self.phase = phase
        self.scannedFiles = scannedFiles
        self.candidateCount = candidateCount
        self.candidateBytes = candidateBytes
        self.evictedCount = evictedCount
        self.failedCount = failedCount
        self.reclaimedBytes = reclaimedBytes
        self.currentPath = currentPath
        self.failureReasons = failureReasons
    }

    /// One-line summary of the dominant failure reason, if any.
    public var failureSummary: String? {
        guard let topReason = failureReasons.max(by: { $0.value < $1.value })?.key else { return nil }
        return "\(failedCount) failed (mostly \(topReason))"
    }
}

/// Thread-safe cooperative cancellation token.
public final class EvictionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public struct EvictionOutcome: Equatable, Sendable {
    public var evictedCount: Int
    public var failedCount: Int
    public var reclaimedBytes: Int64
    public var failureReasons: [String: Int]
    public var cancelled: Bool
    /// Paths verified evicted — feed these to the rematerialization watchlist.
    public var evictedPaths: [String]

    public init(
        evictedCount: Int,
        failedCount: Int,
        reclaimedBytes: Int64,
        failureReasons: [String: Int],
        cancelled: Bool,
        evictedPaths: [String]
    ) {
        self.evictedCount = evictedCount
        self.failedCount = failedCount
        self.reclaimedBytes = reclaimedBytes
        self.failureReasons = failureReasons
        self.cancelled = cancelled
        self.evictedPaths = evictedPaths
    }
}

/// The single eviction engine used by the app, the watchlist watcher, and the CLI.
///
/// Safety contract: the ONLY mutation ever performed on the iCloud scope is
/// `FileManager.evictUbiquitousItem(at:)`, which removes the local copy while
/// retaining the cloud copy. Nothing is ever deleted, trashed, or unlinked.
public final class EvictionEngine {
    private let logger: GuardLogging
    private let fileManager = FileManager.default
    private let progressInterval: TimeInterval = 0.2

    public init(logger: GuardLogging) {
        self.logger = logger
    }

    // MARK: - Candidate collection

    /// Bulk-scan the scope and return all eviction candidates, sorted by
    /// size descending then oldest-modified first.
    ///
    /// Package directories (.app, .fcpbundle, …) are detected with
    /// `NSWorkspace.isFilePackage` and collapsed into single package-root
    /// candidates with aggregated bytes. A package is excluded entirely if
    /// any of its contents match a protected path.
    public func collectCandidates(
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        cancellation: EvictionCancellation? = nil,
        onProgress: ((EvictionProgress) -> Void)? = nil
    ) throws -> [EvictionCandidate] {
        var plainCandidates: [EvictionCandidate] = []
        var packageDirectories: Set<String> = []
        var packageAggregates: [String: (relativePath: String, bytes: Int64, oldest: Date?, protected: Bool)] = [:]
        // Package-ness is a property of the extension's UTI declaration —
        // cache per extension to avoid repeated LaunchServices lookups.
        var packageKindByExtension: [String: Bool] = [:]
        var progress = EvictionProgress(phase: .scanning)
        var lastProgressAt = Date.distantPast

        try BulkScanner.scan(
            rootPath: scopePath,
            shouldStop: { cancellation?.isCancelled ?? false }
        ) { entry in
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
                    }
                }
                return
            }

            progress.scannedFiles += 1

            if entry.isLocallyResidentFile {
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

                progress.candidateCount = plainCandidates.count + packageAggregates.count
                progress.candidateBytes += entry.allocatedBytes
            }

            let now = Date()
            if now.timeIntervalSince(lastProgressAt) >= progressInterval {
                lastProgressAt = now
                onProgress?(progress)
            }
        }

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

        progress.candidateCount = candidates.count
        progress.candidateBytes = candidates.reduce(into: Int64(0)) { $0 += $1.allocatedBytes }
        onProgress?(progress)
        return candidates
    }

    // MARK: - Eviction

    /// Evict candidates (already sorted or will be treated in given order),
    /// stopping when `byteBudget` is reached or `fileBudget` files have been
    /// processed. Every successful eviction is verified with lstat; reclaimed
    /// bytes reflect the verified on-disk delta.
    public func evict(
        candidates: [EvictionCandidate],
        byteBudget: Int64? = nil,
        fileBudget: Int? = nil,
        cancellation: EvictionCancellation? = nil,
        onProgress: ((EvictionProgress) -> Void)? = nil
    ) -> EvictionOutcome {
        var progress = EvictionProgress(phase: .evicting)
        progress.candidateCount = candidates.count
        progress.candidateBytes = candidates.reduce(into: Int64(0)) { $0 += $1.allocatedBytes }

        var evictedPaths: [String] = []
        var processed = 0
        var wasCancelled = false
        var lastProgressAt = Date.distantPast

        for candidate in candidates {
            if cancellation?.isCancelled == true {
                wasCancelled = true
                break
            }
            if let fileBudget, processed >= fileBudget { break }
            if let byteBudget, progress.reclaimedBytes >= byteBudget { break }

            processed += 1
            progress.currentPath = candidate.relativePath
            let result = evictOne(candidate)
            switch result {
            case .evicted(let freedBytes):
                progress.evictedCount += 1
                progress.reclaimedBytes += freedBytes
                evictedPaths.append(candidate.path)
            case .failed(let reason):
                progress.failedCount += 1
                progress.failureReasons[reason, default: 0] += 1
            }

            let now = Date()
            if now.timeIntervalSince(lastProgressAt) >= progressInterval {
                lastProgressAt = now
                onProgress?(progress)
            }
        }

        progress.phase = wasCancelled ? .cancelled : .done
        progress.currentPath = nil
        onProgress?(progress)

        logger.log(
            "eviction-run evicted=\(progress.evictedCount) failed=\(progress.failedCount) " +
            "verifiedReclaimed=\(progress.reclaimedBytes) cancelled=\(wasCancelled) " +
            "reasons=\(progress.failureReasons)"
        )

        return EvictionOutcome(
            evictedCount: progress.evictedCount,
            failedCount: progress.failedCount,
            reclaimedBytes: progress.reclaimedBytes,
            failureReasons: progress.failureReasons,
            cancelled: wasCancelled,
            evictedPaths: evictedPaths
        )
    }

    // MARK: - Single-file eviction

    /// Nearest ancestor directory of `path` that is a known package, if any.
    private func nearestPackageAncestor(of path: String, in packageDirectories: Set<String>) -> String? {
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

    private func isFilePackage(_ path: String) -> Bool {
        NSWorkspace.shared.isFilePackage(atPath: path)
    }

    private enum SingleEvictionResult {
        case evicted(freedBytes: Int64)
        case failed(reason: String)
    }

    private func evictOne(_ candidate: EvictionCandidate) -> SingleEvictionResult {
        let url = URL(fileURLWithPath: candidate.path)

        do {
            try fileManager.evictUbiquitousItem(at: url)
        } catch {
            let reason = categorizeFailure(error)
            logger.log("evict-failed path=\(candidate.relativePath) reason=\(reason) error=\(error)")
            return .failed(reason: reason)
        }

        // Verify: a successful eviction drops the SF_DATALESS flag onto the
        // file and frees its blocks. The API can also succeed on an
        // already-dataless file — freed bytes are then 0.
        let blocksBefore = candidate.allocatedBytes
        if let statInfo = BulkScanner.lstatPath(candidate.path) {
            let isDataless = (statInfo.st_flags & SF_DATALESS) != 0
            let blocksAfter = Int64(statInfo.st_blocks) * 512
            let freed = max(blocksBefore - blocksAfter, 0)
            if isDataless || freed > 0 || blocksBefore == 0 {
                return .evicted(freedBytes: freed)
            }
            // API succeeded but the file is still fully resident — treat as
            // evicted (the daemon may finish asynchronously) with 0 verified bytes.
            return .evicted(freedBytes: 0)
        }

        // lstat failed post-eviction — count success with unverifiable bytes.
        return .evicted(freedBytes: 0)
    }

    /// Map an eviction error to a short, stable reason string for UI/logs.
    private func categorizeFailure(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "vanished"
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "permission"
            case NSFileReadInvalidFileNameError:
                return "not-icloud"
            case 255:
                return "busy" // "couldn't be locked" — package in use by an app
            case 512:
                return "provider-refused"
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EBUSY): return "busy"
            case Int(ENOENT): return "vanished"
            case Int(EPERM), Int(EACCES): return "permission"
            default: break
            }
        }
        let description = nsError.localizedDescription.lowercased()
        if description.contains("busy") || description.contains("locked") { return "busy" }
        if description.contains("upload") { return "not-uploaded" }
        if description.contains("permission") { return "permission" }
        return "error-\(nsError.domain):\(nsError.code)"
    }
}

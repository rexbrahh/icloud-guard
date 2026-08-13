import Darwin
import Foundation
import os

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
    /// Device/inode/type captured by the scan that selected this candidate.
    public let identity: EvictionFileIdentity?

    public init(
        path: String,
        relativePath: String,
        allocatedBytes: Int64,
        modificationDate: Date?,
        isPackageRoot: Bool = false,
        identity: EvictionFileIdentity? = nil
    ) {
        self.path = path
        self.relativePath = relativePath
        self.allocatedBytes = allocatedBytes
        self.modificationDate = modificationDate
        self.isPackageRoot = isPackageRoot
        self.identity = identity
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
    public var pendingCount: Int = 0
    /// Verified bytes actually freed (post-eviction lstat delta).
    public var reclaimedBytes: Int64 = 0
    public var currentPath: String?
    /// Failure reason → count, e.g. "busy" → 3.
    public var failureReasons: [String: Int] = [:]
    public var pendingReasons: [String: Int] = [:]
    /// Privacy-bounded basenames of processes holding package contents open.
    public var busyProcessDisplayNames: [String] = []
    /// Byte goal of the run, when trimming toward a target. Drives the
    /// byte-based progress fraction in the UI.
    public var byteBudget: Int64?

    public init() {}

    public init(
        phase: EvictionPhase,
        scannedFiles: Int = 0,
        candidateCount: Int = 0,
        candidateBytes: Int64 = 0,
        evictedCount: Int = 0,
        failedCount: Int = 0,
        pendingCount: Int = 0,
        reclaimedBytes: Int64 = 0,
        currentPath: String? = nil,
        failureReasons: [String: Int] = [:],
        pendingReasons: [String: Int] = [:],
        busyProcessDisplayNames: [String] = [],
        byteBudget: Int64? = nil
    ) {
        self.phase = phase
        self.scannedFiles = scannedFiles
        self.candidateCount = candidateCount
        self.candidateBytes = candidateBytes
        self.evictedCount = evictedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
        self.reclaimedBytes = reclaimedBytes
        self.currentPath = currentPath
        self.failureReasons = failureReasons
        self.pendingReasons = pendingReasons
        self.busyProcessDisplayNames = busyProcessDisplayNames
        self.byteBudget = byteBudget
    }

    /// One-line summary of the dominant failure reason, if any.
    public var failureSummary: String? {
        guard let topReason = failureReasons.max(by: { $0.value < $1.value })?.key else { return nil }
        return "\(failedCount) failed (mostly \(topReason))"
    }
}

/// Thread-safe cooperative cancellation token.
public final class EvictionCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    public func cancel() {
        cancelled.withLock { $0 = true }
    }
}

public struct EvictionOutcome: Equatable, Sendable {
    public var processedCount: Int
    public var processedBytes: Int64
    public var evictedCount: Int
    public var failedCount: Int
    public var pendingCount: Int
    public var pendingBytes: Int64
    public var failedBytes: Int64
    public var reclaimedBytes: Int64
    public var failureReasons: [String: Int]
    public var pendingReasons: [String: Int]
    public var busyProcessDisplayNames: [String]
    public var cancelled: Bool
    /// Paths verified evicted — feed these to the rematerialization watchlist.
    public var evictedPaths: [String]
    public var evictedIdentities: [String: EvictionFileIdentity]
    /// Paths whose eviction request was accepted but could not yet be
    /// verified. These must remain on the watchlist until later verification.
    public var pendingPaths: [String]
    public var pendingIdentities: [String: EvictionFileIdentity]

    public init(
        evictedCount: Int,
        failedCount: Int,
        pendingCount: Int = 0,
        processedCount: Int? = nil,
        processedBytes: Int64 = 0,
        pendingBytes: Int64 = 0,
        failedBytes: Int64 = 0,
        reclaimedBytes: Int64,
        failureReasons: [String: Int],
        pendingReasons: [String: Int] = [:],
        busyProcessDisplayNames: [String] = [],
        cancelled: Bool,
        evictedPaths: [String],
        pendingPaths: [String] = [],
        evictedIdentities: [String: EvictionFileIdentity] = [:],
        pendingIdentities: [String: EvictionFileIdentity] = [:]
    ) {
        self.processedCount = processedCount ?? (evictedCount + failedCount + pendingCount)
        self.processedBytes = processedBytes
        self.evictedCount = evictedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
        self.pendingBytes = pendingBytes
        self.failedBytes = failedBytes
        self.reclaimedBytes = reclaimedBytes
        self.failureReasons = failureReasons
        self.pendingReasons = pendingReasons
        self.busyProcessDisplayNames = busyProcessDisplayNames
        self.cancelled = cancelled
        self.evictedPaths = evictedPaths
        self.pendingPaths = pendingPaths
        self.evictedIdentities = evictedIdentities
        self.pendingIdentities = pendingIdentities
    }
}

public enum EvictionItemResult: Equatable, Sendable {
    case verified(reclaimedBytes: Int64)
    case pending(reason: String)
    case blockedBusy(processDisplayNames: [String])
    case failed(reason: String)
}

/// The single eviction engine used by the app, the watchlist watcher, and the CLI.
///
/// Safety contract: the ONLY mutation ever performed on the iCloud scope is
/// `FileManager.evictUbiquitousItem(at:)`, which removes the local copy while
/// retaining the cloud copy. Nothing is ever deleted, trashed, or unlinked.
public final class EvictionEngine {
    private let logger: GuardLogging
    private let evictItem: (URL) throws -> Void
    private let footprint: (String) -> EvictionFootprintReadResult
    private let verificationDelay: () -> Void
    private let mutationValidator: (EvictionCandidate, String, ProtectedPathsMatcher) -> String?
    private let inspectBusyPackage: (String) -> BusyPackageInspection
    private let progressInterval: TimeInterval = 0.2
    private let verificationAttempts = 5

    public init(logger: GuardLogging) {
        self.logger = logger
        self.evictItem = { try FileManager.default.evictUbiquitousItem(at: $0) }
        self.footprint = EvictionFootprint.measureResult
        self.verificationDelay = { usleep(100_000) }
        self.mutationValidator = Self.validateCandidateForMutation
        let inspector = BusyPackageInspector()
        self.inspectBusyPackage = { inspector.inspect(packagePath: $0) }
    }

    init(
        logger: GuardLogging,
        evictItem: @escaping (URL) throws -> Void,
        footprint: @escaping (String) -> EvictionFootprint?,
        verificationDelay: @escaping () -> Void = {},
        mutationValidator: @escaping (EvictionCandidate, String, ProtectedPathsMatcher) -> String? = EvictionEngine.validateCandidateForMutation,
        inspectBusyPackage: @escaping (String) -> BusyPackageInspection = { _ in .clear }
    ) {
        self.logger = logger
        self.evictItem = evictItem
        self.footprint = { path in
            if let measured = footprint(path) { return .found(measured) }
            return .failed("verification-unavailable")
        }
        self.verificationDelay = verificationDelay
        self.mutationValidator = mutationValidator
        self.inspectBusyPackage = inspectBusyPackage
    }

    init(
        logger: GuardLogging,
        evictItem: @escaping (URL) throws -> Void,
        footprintResult: @escaping (String) -> EvictionFootprintReadResult,
        verificationDelay: @escaping () -> Void = {},
        mutationValidator: @escaping (EvictionCandidate, String, ProtectedPathsMatcher) -> String? = EvictionEngine.validateCandidateForMutation,
        inspectBusyPackage: @escaping (String) -> BusyPackageInspection = { _ in .clear }
    ) {
        self.logger = logger
        self.evictItem = evictItem
        self.footprint = footprintResult
        self.verificationDelay = verificationDelay
        self.mutationValidator = mutationValidator
        self.inspectBusyPackage = inspectBusyPackage
    }

    // MARK: - Candidate collection

    /// Bulk-scan the scope and return all eviction candidates, sorted by
    /// size descending then oldest-modified first.
    ///
    /// Thin wrapper over `ScanOrchestrator` (which collects drive stats in
    /// the same walk). Packages (.app, .fcpbundle, …) are collapsed into
    /// single package-root candidates with aggregated bytes; a package is
    /// excluded entirely if any of its contents match a protected path.
    public func collectScanBundle(
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        cancellation: EvictionCancellation? = nil,
        onProgress: ((EvictionProgress) -> Void)? = nil
    ) throws -> ScanBundle {
        var progress = EvictionProgress(phase: .scanning)
        let bundle = try ScanOrchestrator.scan(
            scopePath: scopePath,
            protectedPaths: protectedPaths,
            shouldStop: { cancellation?.isCancelled ?? false }
        ) { scannedFiles in
            progress.scannedFiles = scannedFiles
            onProgress?(progress)
        }

        progress.candidateCount = bundle.candidates.count
        progress.candidateBytes = bundle.candidates.reduce(into: Int64(0)) { $0 += $1.allocatedBytes }
        onProgress?(progress)
        return bundle
    }

    // MARK: - Eviction

    /// Evict candidates (already sorted or will be treated in given order),
    /// stopping when `byteBudget` is reached or `fileBudget` files have been
    /// processed. Every successful eviction is verified with lstat; reclaimed
    /// bytes reflect the verified on-disk delta.
    public func evict(
        candidates: [EvictionCandidate],
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        byteBudget: Int64? = nil,
        fileBudget: Int? = nil,
        cancellation: EvictionCancellation? = nil,
        protectBusyPackages: Bool = true,
        onProgress: ((EvictionProgress) -> Void)? = nil
    ) -> EvictionOutcome {
        var progress = EvictionProgress(phase: .evicting, byteBudget: byteBudget)
        progress.candidateCount = candidates.count
        progress.candidateBytes = candidates.reduce(into: Int64(0)) { $0 += $1.allocatedBytes }

        var evictedPaths: [String] = []
        var pendingPaths: [String] = []
        var evictedIdentities: [String: EvictionFileIdentity] = [:]
        var pendingIdentities: [String: EvictionFileIdentity] = [:]
        var processed = 0
        var processedBytes: Int64 = 0
        var pendingBytes: Int64 = 0
        var failedBytes: Int64 = 0
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
            processedBytes += candidate.allocatedBytes
            progress.currentPath = candidate.relativePath
            let result = evictCandidate(
                candidate,
                scopePath: scopePath,
                protectedPaths: protectedPaths,
                protectBusyPackages: protectBusyPackages
            )
            switch result {
            case .verified(let freedBytes):
                progress.evictedCount += 1
                progress.reclaimedBytes += freedBytes
                evictedPaths.append(candidate.path)
                evictedIdentities[candidate.path] = candidate.identity
            case .pending(let reason):
                pendingBytes += candidate.allocatedBytes
                progress.pendingCount += 1
                progress.pendingReasons[reason, default: 0] += 1
                pendingPaths.append(candidate.path)
                pendingIdentities[candidate.path] = candidate.identity
            case .blockedBusy(let processDisplayNames):
                failedBytes += candidate.allocatedBytes
                progress.failedCount += 1
                progress.failureReasons["busy-package", default: 0] += 1
                progress.busyProcessDisplayNames = Array(
                    Set(progress.busyProcessDisplayNames + processDisplayNames)
                ).sorted()
            case .failed(let reason):
                failedBytes += candidate.allocatedBytes
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
            "eviction-run evicted=\(progress.evictedCount) pending=\(progress.pendingCount) failed=\(progress.failedCount) " +
            "verifiedReclaimed=\(progress.reclaimedBytes) cancelled=\(wasCancelled) " +
            "reasons=\(progress.failureReasons)"
        )

        return EvictionOutcome(
            evictedCount: progress.evictedCount,
            failedCount: progress.failedCount,
            pendingCount: progress.pendingCount,
            processedCount: processed,
            processedBytes: processedBytes,
            pendingBytes: pendingBytes,
            failedBytes: failedBytes,
            reclaimedBytes: progress.reclaimedBytes,
            failureReasons: progress.failureReasons,
            pendingReasons: progress.pendingReasons,
            busyProcessDisplayNames: progress.busyProcessDisplayNames,
            cancelled: wasCancelled,
            evictedPaths: evictedPaths,
            pendingPaths: pendingPaths,
            evictedIdentities: evictedIdentities,
            pendingIdentities: pendingIdentities
        )
    }

    // MARK: - Single-file eviction

    func evictCandidate(
        _ candidate: EvictionCandidate,
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher,
        protectBusyPackages: Bool = true
    ) -> EvictionItemResult {
        if let reason = mutationValidator(candidate, scopePath, protectedPaths) {
            logger.log("evict-failed path=\(candidate.relativePath) reason=\(reason) phase=precondition")
            return .failed(reason: reason)
        }
        let url = URL(fileURLWithPath: candidate.path)
        let before: EvictionFootprint
        switch footprint(candidate.path) {
        case .found(let measured):
            before = measured
        case .vanished:
            logger.log("evict-failed path=\(candidate.relativePath) reason=vanished phase=before")
            return .failed(reason: "vanished")
        case .failed(let reason):
            logger.log("evict-failed path=\(candidate.relativePath) reason=verification-unavailable phase=before")
            return .failed(reason: reason)
        }

        if let beforeIdentity = before.identity,
           let candidateIdentity = candidate.identity,
           beforeIdentity != candidateIdentity {
            logger.log("evict-failed path=\(candidate.relativePath) reason=stale-identity phase=footprint")
            return .failed(reason: "stale-identity")
        }

        guard before.allocatedBytes > 0,
              candidate.isPackageRoot || !before.isDataless else {
            logger.log("evict-failed path=\(candidate.relativePath) reason=already-evicted phase=precondition")
            return .failed(reason: "already-evicted")
        }

        // Final identity/type/path check is intentionally adjacent to the
        // FileProvider call. No success may be attributed to a replacement.
        if let reason = mutationValidator(candidate, scopePath, protectedPaths) {
            logger.log("evict-failed path=\(candidate.relativePath) reason=\(reason) phase=pre-api")
            return .failed(reason: reason)
        }

        if candidate.isPackageRoot && protectBusyPackages {
            switch inspectBusyPackage(candidate.path) {
            case .clear:
                break
            case .busy(let assistance):
                logger.log("evict-failed path=\(candidate.relativePath) reason=busy-package phase=pre-api")
                return .blockedBusy(processDisplayNames: assistance.processDisplayNames)
            case .unavailable(let reason):
                let stableReason = "busy-inspection-\(reason.rawValue)"
                logger.log("evict-failed path=\(candidate.relativePath) reason=\(stableReason) phase=pre-api")
                return .failed(reason: stableReason)
            }
            // Busy inspection may take long enough for the package path to be
            // replaced. Re-run the shared validator immediately adjacent to
            // FileProvider after every successful inspection.
            if let reason = mutationValidator(candidate, scopePath, protectedPaths) {
                logger.log("evict-failed path=\(candidate.relativePath) reason=\(reason) phase=post-busy-pre-api")
                return .failed(reason: reason)
            }
        }

        do {
            try evictItem(url)
        } catch {
            let reason = categorizeFailure(error)
            logger.log("evict-failed path=\(candidate.relativePath) reason=\(reason) error=\(error)")
            return .failed(reason: reason)
        }

        // FileProvider completion can lag the API return. Count success only
        // after a bounded metadata-only postcondition check.
        for attempt in 0..<verificationAttempts {
            switch footprint(candidate.path) {
            case .found(let after) where after.verifiesEviction(from: before):
                return .verified(reclaimedBytes: max(before.allocatedBytes - after.allocatedBytes, 0))
            case .found(let after) where before.identity != nil && after.identity != nil && before.identity != after.identity:
                logger.log("evict-pending path=\(candidate.relativePath) reason=identity-changed-postcondition")
                return .pending(reason: "identity-changed-postcondition")
            case .found, .vanished, .failed:
                break
            }
            if attempt + 1 < verificationAttempts { verificationDelay() }
        }

        logger.log("evict-pending path=\(candidate.relativePath) reason=unverified-postcondition")
        return .pending(reason: "unverified-postcondition")
    }

    static func validateCandidateForMutation(
        _ candidate: EvictionCandidate,
        scopePath: String,
        protectedPaths: ProtectedPathsMatcher
    ) -> String? {
        let expandedScope = NSString(string: scopePath).expandingTildeInPath
        let canonicalScope = URL(fileURLWithPath: expandedScope, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
        guard candidatePath.hasPrefix(canonicalScope + "/") else { return "outside-scope" }

        let relativePath = String(candidatePath.dropFirst(canonicalScope.count + 1))
        guard relativePath == candidate.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            return "stale-relative-path"
        }
        guard !protectedPaths.isProtected(path: candidatePath, relativePath: relativePath) else {
            return "protected-path"
        }
        guard let expectedIdentity = candidate.identity else { return "missing-identity" }

        var scopeStat = stat()
        guard canonicalScope.withCString({ lstat($0, &scopeStat) }) == 0,
              scopeStat.st_mode & S_IFMT == S_IFDIR else {
            return "unsafe-scope"
        }

        var current = canonicalScope
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current += "/\(component)"
            var info = stat()
            guard current.withCString({ lstat($0, &info) }) == 0 else { return "vanished" }
            let type = info.st_mode & S_IFMT
            if index + 1 < components.count {
                guard type == S_IFDIR else { return "unsafe-ancestor" }
            } else if candidate.isPackageRoot {
                guard type == S_IFDIR else { return "stale-type" }
                guard EvictionFileIdentity.from(info) == expectedIdentity else { return "stale-identity" }
            } else {
                guard type == S_IFREG else { return type == S_IFLNK ? "symlink" : "stale-type" }
                guard EvictionFileIdentity.from(info) == expectedIdentity else { return "stale-identity" }
            }
        }

        if candidate.isPackageRoot {
            var protectedDescendant = false
            do {
                let summary = try BulkScanner.scan(rootPath: candidatePath) { entry in
                    guard entry.isRegularFile else { return }
                    let scopeRelative = relativePath + "/" + entry.relativePath
                    if protectedPaths.isProtected(path: entry.path, relativePath: scopeRelative) {
                        protectedDescendant = true
                    }
                }
                guard summary.isComplete else { return "incomplete-package-recheck" }
            } catch {
                return "incomplete-package-recheck"
            }
            if protectedDescendant { return "protected-path" }

            // Confirm no package ancestor changed while its descendants were
            // inspected, immediately before handing the path to FileProvider.
            current = canonicalScope
            for (index, component) in components.enumerated() {
                current += "/\(component)"
                var info = stat()
                guard current.withCString({ lstat($0, &info) }) == 0,
                      info.st_mode & S_IFMT == S_IFDIR else {
                    return "unsafe-ancestor"
                }
                if index + 1 == components.count,
                   EvictionFileIdentity.from(info) != expectedIdentity {
                    return "stale-identity"
                }
            }
        }
        return nil
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

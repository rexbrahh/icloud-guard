import Darwin
import Foundation

public enum RecoveryJournalStatus: String, Codable, Sendable {
    case eligible
    case pending
    case verified
    case failed
}

/// A privacy-preserving record of one verified eviction. Absolute paths are
/// deliberately excluded: restoring reconstructs the target from a freshly
/// canonicalized scope and this scope-relative path.
public struct RecoveryJournalEntry: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    public var runID: String
    public var scopeIdentifier: String
    public var relativePath: String
    public var isPackageRoot: Bool
    public var identity: EvictionFileIdentity
    public var status: RecoveryJournalStatus
    public var retries: Int
    public var lastReason: String?

    public init(
        runID: String,
        scopeIdentifier: String,
        relativePath: String,
        isPackageRoot: Bool,
        identity: EvictionFileIdentity,
        status: RecoveryJournalStatus = .eligible,
        retries: Int = 0,
        lastReason: String? = nil
    ) {
        self.schema = Self.schemaVersion
        self.runID = runID
        self.scopeIdentifier = scopeIdentifier
        self.relativePath = relativePath
        self.isPackageRoot = isPackageRoot
        self.identity = identity
        self.status = status
        self.retries = retries
        self.lastReason = lastReason
    }
}

public final class RecoveryJournalStore: Sendable {
    public enum JournalError: LocalizedError, Equatable, Sendable {
        case corrupt(String)
        case invalidMutation(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .corrupt(let reason): return "recovery journal is corrupt: \(reason)"
            case .invalidMutation(let reason): return "recovery mutation is invalid: \(reason)"
            case .io(let reason): return "recovery journal I/O failed: \(reason)"
            }
        }
    }

    private struct Document: Codable {
        var schema = 1
        var entries: [RecoveryJournalEntry]
    }

    public static let maximumRetries = 3
    static let maximumJournalBytes: UInt64 = 8 * 1024 * 1024
    private static let absoluteMaximumEntries = 20_000
    private static let maximumTextLength = 4_096

    private let url: URL
    private let lockPath: String
    private let maximumBytes: UInt64
    public let maximumEntries: Int

    public init(url: URL, maximumEntries: Int = 5_000) {
        self.url = url
        self.lockPath = url.deletingPathExtension().appendingPathExtension("lock").path
        self.maximumBytes = Self.maximumJournalBytes
        self.maximumEntries = max(1, min(maximumEntries, Self.absoluteMaximumEntries))
    }

    init(url: URL, maximumEntries: Int, maximumBytes: UInt64) {
        self.url = url
        self.lockPath = url.deletingPathExtension().appendingPathExtension("lock").path
        self.maximumBytes = max(1, min(maximumBytes, Self.maximumJournalBytes))
        self.maximumEntries = max(1, min(maximumEntries, Self.absoluteMaximumEntries))
    }

    public func load() throws -> [RecoveryJournalEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let snapshot: SecureRegularFile.Snapshot
        do {
            snapshot = try SecureRegularFile.read(url, maximumBytes: maximumBytes)
        } catch let SecureRegularFile.ReadError.tooLarge(size) {
            throw JournalError.corrupt("file exceeds safety limit (\(size) bytes)")
        } catch {
            throw JournalError.io("file is not a readable regular file")
        }
        guard snapshot.permissions & 0o077 == 0 else {
            throw JournalError.io("file permissions are not private")
        }

        let decoder = JSONDecoder()
        do {
            let document = try decoder.decode(Document.self, from: snapshot.data)
            guard document.schema == 1 else {
                throw JournalError.corrupt("unsupported schema \(document.schema)")
            }
            return try validated(document.entries)
        } catch let error as JournalError {
            throw error
        } catch {
            throw JournalError.corrupt("invalid JSON document")
        }
    }

    /// Records only paths the eviction engine reported as verified. Candidate
    /// metadata supplies the package flag while the outcome supplies the
    /// post-mutation identity authority.
    @discardableResult
    public func recordVerifiedMutations(
        runID: String,
        scopePath: String,
        candidates: [EvictionCandidate],
        outcome: EvictionOutcome
    ) throws -> [RecoveryJournalEntry] {
        guard outcome.evictedCount == outcome.evictedPaths.count else {
            throw JournalError.invalidMutation("verified path count mismatch")
        }
        let canonicalScope = Self.canonicalScope(scopePath)
        let scopeIdentifier = PrivacyIdentifier.scope(canonicalScope)
        var candidatesByPath: [String: EvictionCandidate] = [:]
        for candidate in candidates {
            guard candidatesByPath.updateValue(candidate, forKey: candidate.path) == nil else {
                throw JournalError.invalidMutation("duplicate candidate path")
            }
        }
        var additions: [RecoveryJournalEntry] = []

        for path in outcome.evictedPaths {
            guard let candidate = candidatesByPath[path],
                  let identity = outcome.evictedIdentities[path],
                  candidate.identity == identity else {
                throw JournalError.invalidMutation("verified candidate identity mismatch")
            }
            let relativePath = try Self.checkedRelativePath(
                candidate.relativePath,
                candidatePath: candidate.path,
                canonicalScope: canonicalScope
            )
            additions.append(RecoveryJournalEntry(
                runID: runID,
                scopeIdentifier: scopeIdentifier,
                relativePath: relativePath,
                isPackageRoot: candidate.isPackageRoot,
                identity: identity
            ))
        }
        guard additions.count <= maximumEntries else {
            throw JournalError.invalidMutation("verified run exceeds journal capacity")
        }
        return try merge(additions)
    }

    @discardableResult
    func update(_ replacement: RecoveryJournalEntry) throws -> [RecoveryJournalEntry] {
        try withLock {
            var entries = try load()
            let key = Self.key(replacement)
            guard let index = entries.firstIndex(where: { Self.key($0) == key }) else {
                throw JournalError.io("entry disappeared during update")
            }
            entries[index] = replacement
            try save(entries)
            return entries
        }
    }

    private func merge(_ additions: [RecoveryJournalEntry]) throws -> [RecoveryJournalEntry] {
        try withLock {
            var entries = try load()
            let existing = Set(entries.map(Self.key))
            entries.append(contentsOf: additions.filter { !existing.contains(Self.key($0)) })
            entries = Array(entries.suffix(maximumEntries))
            try save(try validated(entries))
            return entries
        }
    }

    private func save(_ entries: [RecoveryJournalEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Document(entries: entries))
            guard UInt64(data.count) <= maximumBytes else {
                throw JournalError.corrupt("encoded journal exceeds safety limit")
            }
            try RunHistoryStore.atomicWrite(data, to: url)
        } catch let error as JournalError {
            throw error
        } catch {
            throw JournalError.io("cannot write journal")
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lock: AdvisoryFileLock
        do { lock = try AdvisoryFileLock(path: lockPath) }
        catch AdvisoryFileLock.LockError.unavailable { throw JournalError.io("journal is busy") }
        catch { throw JournalError.io("cannot acquire journal lock") }
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }

    private func validated(_ entries: [RecoveryJournalEntry]) throws -> [RecoveryJournalEntry] {
        guard entries.count <= maximumEntries else { throw JournalError.corrupt("too many entries") }
        var keys = Set<String>()
        for entry in entries {
            guard entry.schema == RecoveryJournalEntry.schemaVersion,
                  !entry.runID.isEmpty,
                  entry.runID.count <= Self.maximumTextLength,
                  !entry.scopeIdentifier.isEmpty,
                  entry.scopeIdentifier.count <= 128,
                  entry.relativePath.count <= Self.maximumTextLength,
                  entry.retries >= 0,
                  entry.retries <= Self.maximumRetries,
                  (entry.lastReason?.count ?? 0) <= 128 else {
                throw JournalError.corrupt("invalid entry fields")
            }
            guard (try? Self.validateRelativePath(entry.relativePath)) != nil else {
                throw JournalError.corrupt("invalid relative path")
            }
            guard keys.insert(Self.key(entry)).inserted else {
                throw JournalError.corrupt("duplicate entry")
            }
        }
        return entries
    }

    private static func key(_ entry: RecoveryJournalEntry) -> String {
        entry.runID + "\u{0}" + entry.scopeIdentifier + "\u{0}" + entry.relativePath
    }

    static func canonicalScope(_ scopePath: String) -> String {
        URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func validateRelativePath(_ relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            throw JournalError.invalidMutation("invalid relative path")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw JournalError.invalidMutation("invalid relative path")
        }
    }

    private static func checkedRelativePath(
        _ relativePath: String,
        candidatePath: String,
        canonicalScope: String
    ) throws -> String {
        try validateRelativePath(relativePath)
        let target = URL(fileURLWithPath: canonicalScope, isDirectory: true)
            .appendingPathComponent(relativePath).standardizedFileURL.path
        guard target == URL(fileURLWithPath: candidatePath).standardizedFileURL.path,
              target.hasPrefix(canonicalScope + "/") else {
            throw JournalError.invalidMutation("candidate is outside scope")
        }
        return relativePath
    }
}

public struct RestorationMetadata: Equatable, Sendable {
    public var isUbiquitous: Bool
    public var isDownloaded: Bool
    public var isDownloading: Bool
    public var hasDownloadError: Bool

    public init(
        isUbiquitous: Bool,
        isDownloaded: Bool,
        isDownloading: Bool = false,
        hasDownloadError: Bool = false
    ) {
        self.isUbiquitous = isUbiquitous
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.hasDownloadError = hasDownloadError
    }
}

public enum RestorationMetadataReadResult: Equatable, Sendable {
    case found(RestorationMetadata)
    case unavailable
}

public enum RestorationItemStatus: String, Codable, Equatable, Sendable {
    case verified
    case pending
    case failed
}

public struct RestorationItemResult: Codable, Equatable, Sendable {
    public var relativePath: String
    public var status: RestorationItemStatus
    public var reason: String

    public init(relativePath: String, status: RestorationItemStatus, reason: String) {
        self.relativePath = relativePath
        self.status = status
        self.reason = reason
    }
}

public struct RestorationResult: Codable, Equatable, Sendable {
    public var runID: String?
    public var items: [RestorationItemResult]
    public var cancelled: Bool

    public init(runID: String?, items: [RestorationItemResult], cancelled: Bool = false) {
        self.runID = runID
        self.items = items
        self.cancelled = cancelled
    }

    public var verifiedCount: Int { items.count { $0.status == .verified } }
    public var pendingCount: Int { items.count { $0.status == .pending } }
    public var failedCount: Int { items.count { $0.status == .failed } }
}

public struct RestorationExecution: Codable, Equatable, Sendable {
    public var result: RestorationResult
    public var receipt: GuardRunReceipt

    public init(result: RestorationResult, receipt: GuardRunReceipt) {
        self.result = result
        self.receipt = receipt
    }
}

public enum RestorationOperations {
    public static func restoreLastRun(
        appHomeURL: URL = AppPaths.homeDir,
        scopePath: String,
        trigger: GuardRunTrigger,
        cancellation: EvictionCancellation? = nil
    ) throws -> RestorationExecution {
        let mutationLock: AdvisoryFileLock
        do {
            mutationLock = try AdvisoryFileLock(path: appHomeURL.appendingPathComponent("run.lock").path)
            try mutationLock.writeOwnerPID()
        } catch AdvisoryFileLock.LockError.unavailable {
            throw RestorationService.RestorationError.contention
        } catch {
            throw RestorationService.RestorationError.lock("system error")
        }
        defer { withExtendedLifetime(mutationLock) {} }
        let historyStore = RunHistoryStore(url: appHomeURL.appendingPathComponent("history.json"))
        let service = RestorationService(
            journalStore: RecoveryJournalStore(url: appHomeURL.appendingPathComponent("recovery.json")),
            historyStore: historyStore,
            mutationLockPath: appHomeURL.appendingPathComponent("run.lock").path
        )
        let startedAt = Date()
        let result = try service.restoreLastVerifiedRun(
            scopePath: scopePath,
            mutationLockHeld: true,
            cancellation: cancellation
        )
        let exitCode: Int32
        let status: GuardRunStatus
        let reason: String
        if result.cancelled {
            exitCode = 130
            status = .cancelled
            reason = "restore cancelled"
        } else if result.items.isEmpty {
            exitCode = 0
            status = .noAction
            reason = "no verified run is available to restore"
        } else if result.failedCount > 0 || (result.pendingCount > 0 && result.verifiedCount > 0) {
            exitCode = 1
            status = .partial
            reason = "restore completed with residual items"
        } else if result.pendingCount > 0 {
            exitCode = 1
            status = .pending
            reason = "restore requests are pending verification"
        } else {
            exitCode = 0
            status = .succeeded
            reason = "last verified run restored locally"
        }
        var metadata: [String: String] = [:]
        if let restoredRunID = result.runID { metadata["restored_run_id"] = restoredRunID }
        let receipt = GuardRunReceipt(
            startedAt: startedAt,
            trigger: trigger,
            command: "restore-last",
            requestedAction: "restore-last",
            action: .none,
            dryRun: false,
            reason: reason,
            reasonMetadata: metadata,
            sourceScopeIdentifier: PrivacyIdentifier.scope(scopePath),
            privacyScopePath: scopePath,
            plannedCount: result.items.count,
            verifiedCount: result.verifiedCount,
            pendingCount: result.pendingCount,
            failedCount: result.failedCount,
            cancelled: result.cancelled,
            exitCode: exitCode,
            status: status,
            statePersisted: true,
            watchlistPersisted: true
        )
        _ = try historyStore.append(receipt)
        return RestorationExecution(result: result, receipt: receipt)
    }
}

public final class RestorationService {
    public enum RestorationError: LocalizedError, Equatable, Sendable {
        case contention
        case lock(String)

        public var errorDescription: String? {
            switch self {
            case .contention: return "another mutation owner is active"
            case .lock(let reason): return "cannot acquire recovery lock: \(reason)"
            }
        }
    }

    private let journalStore: RecoveryJournalStore
    private let historyStore: RunHistoryStore
    private let mutationLockPath: String
    private let requestDownload: (URL) throws -> Void
    private let metadata: (URL) -> RestorationMetadataReadResult
    private let identity: (String) -> EvictionFileIdentity?
    private let delay: () -> Void
    private let verificationAttempts: Int

    public init(
        journalStore: RecoveryJournalStore,
        historyStore: RunHistoryStore,
        mutationLockPath: String = AppPaths.lock.path
    ) {
        self.journalStore = journalStore
        self.historyStore = historyStore
        self.mutationLockPath = mutationLockPath
        self.requestDownload = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }
        self.metadata = Self.readMetadata
        self.identity = EvictionFileIdentity.capture
        self.delay = { usleep(100_000) }
        self.verificationAttempts = 5
    }

    init(
        journalStore: RecoveryJournalStore,
        historyStore: RunHistoryStore,
        mutationLockPath: String,
        verificationAttempts: Int = 5,
        requestDownload: @escaping (URL) throws -> Void,
        metadata: @escaping (URL) -> RestorationMetadataReadResult,
        identity: @escaping (String) -> EvictionFileIdentity?,
        delay: @escaping () -> Void = {}
    ) {
        self.journalStore = journalStore
        self.historyStore = historyStore
        self.mutationLockPath = mutationLockPath
        self.requestDownload = requestDownload
        self.metadata = metadata
        self.identity = identity
        self.delay = delay
        self.verificationAttempts = max(1, min(verificationAttempts, 10))
    }

    public func restoreLastVerifiedRun(
        scopePath: String,
        mutationLockHeld: Bool = false,
        cancellation: EvictionCancellation? = nil
    ) throws -> RestorationResult {
        var ownedLock: AdvisoryFileLock?
        if !mutationLockHeld {
            do {
                ownedLock = try AdvisoryFileLock(path: mutationLockPath)
                try ownedLock?.writeOwnerPID()
            } catch AdvisoryFileLock.LockError.unavailable {
                throw RestorationError.contention
            } catch {
                throw RestorationError.lock("system error")
            }
        }
        defer { withExtendedLifetime(ownedLock) {} }
        return try restoreLocked(scopePath: scopePath, cancellation: cancellation)
    }

    private func restoreLocked(
        scopePath: String,
        cancellation: EvictionCancellation?
    ) throws -> RestorationResult {
        let canonicalScope = RecoveryJournalStore.canonicalScope(scopePath)
        let scopeIdentifier = PrivacyIdentifier.scope(canonicalScope)
        let entries = try journalStore.load()
        let receipts = try historyStore.load()
        var entryCountsByRunID: [String: Int] = [:]
        for entry in entries where entry.scopeIdentifier == scopeIdentifier {
            entryCountsByRunID[entry.runID, default: 0] += 1
        }
        guard let receipt = receipts.reversed().first(where: { receipt in
            receipt.sourceScopeIdentifier == scopeIdentifier
                && !receipt.dryRun
                && receipt.verifiedCount > 0
                && entryCountsByRunID[receipt.id] == receipt.verifiedCount
        }) else {
            return RestorationResult(runID: nil, items: [])
        }
        let runEntries = entries.filter {
            $0.runID == receipt.id && $0.scopeIdentifier == scopeIdentifier
        }

        var results: [RestorationItemResult] = []
        var wasCancelled = false
        for entry in runEntries {
            if cancellation?.isCancelled == true {
                wasCancelled = true
                break
            }
            var updated = entry
            let attempt = restore(entry, canonicalScope: canonicalScope, cancellation: cancellation)
            if attempt.failedRequest {
                updated.retries = min(updated.retries + 1, RecoveryJournalStore.maximumRetries)
            }
            updated.status = attempt.result.status.journalStatus
            updated.lastReason = attempt.result.reason
            _ = try journalStore.update(updated)
            results.append(attempt.result)
            if cancellation?.isCancelled == true {
                wasCancelled = true
                break
            }
        }
        return RestorationResult(runID: receipt.id, items: results, cancelled: wasCancelled)
    }

    private struct RestoreAttempt {
        var result: RestorationItemResult
        var failedRequest: Bool = false
    }

    private func restore(
        _ entry: RecoveryJournalEntry,
        canonicalScope: String,
        cancellation: EvictionCancellation?
    ) -> RestoreAttempt {
        let target = URL(fileURLWithPath: canonicalScope, isDirectory: true)
            .appendingPathComponent(entry.relativePath).standardizedFileURL
        if let reason = validateTarget(entry, target: target, canonicalScope: canonicalScope) {
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .failed, reason: reason
            ))
        }

        switch metadata(target) {
        case .found(let value) where value.hasDownloadError:
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .failed, reason: "download-error"
            ))
        case .found(let value) where !value.isUbiquitous:
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .failed, reason: "not-icloud"
            ))
        case .found(let value) where value.isDownloaded:
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .verified, reason: "already-downloaded"
            ))
        case .found(let value) where value.isDownloading:
            return RestoreAttempt(result: verify(
                entry, target: target, cancellation: cancellation, pendingReason: "download-in-progress"
            ))
        case .unavailable:
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .pending, reason: "metadata-unavailable"
            ))
        case .found:
            break
        }
        if cancellation?.isCancelled == true {
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .pending, reason: "cancelled"
            ))
        }
        guard entry.retries < RecoveryJournalStore.maximumRetries else {
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .failed, reason: "retry-limit"
            ))
        }

        // Keep the final identity/path/type validation adjacent to the only
        // mutating FileProvider call.
        if let reason = validateTarget(entry, target: target, canonicalScope: canonicalScope) {
            return RestoreAttempt(result: RestorationItemResult(
                relativePath: entry.relativePath, status: .failed, reason: reason
            ))
        }
        do {
            try requestDownload(target)
        } catch {
            return RestoreAttempt(
                result: RestorationItemResult(
                    relativePath: entry.relativePath, status: .failed, reason: "request-failed"
                ),
                failedRequest: true
            )
        }

        return RestoreAttempt(result: verify(
            entry, target: target, cancellation: cancellation, pendingReason: "unverified-download"
        ))
    }

    private func verify(
        _ entry: RecoveryJournalEntry,
        target: URL,
        cancellation: EvictionCancellation?,
        pendingReason: String
    ) -> RestorationItemResult {
        for attempt in 0..<verificationAttempts {
            if cancellation?.isCancelled == true {
                return RestorationItemResult(relativePath: entry.relativePath, status: .pending, reason: "cancelled")
            }
            guard identity(target.path) == entry.identity else {
                return RestorationItemResult(relativePath: entry.relativePath, status: .failed, reason: "stale-identity")
            }
            switch metadata(target) {
            case .found(let value) where value.hasDownloadError:
                return RestorationItemResult(relativePath: entry.relativePath, status: .failed, reason: "download-error")
            case .found(let value) where !value.isUbiquitous:
                return RestorationItemResult(relativePath: entry.relativePath, status: .failed, reason: "not-icloud")
            case .found(let value) where value.isDownloaded:
                return RestorationItemResult(relativePath: entry.relativePath, status: .verified, reason: "downloaded")
            case .found, .unavailable:
                break
            }
            if attempt + 1 < verificationAttempts { delay() }
        }
        return RestorationItemResult(relativePath: entry.relativePath, status: .pending, reason: pendingReason)
    }

    private func validateTarget(
        _ entry: RecoveryJournalEntry,
        target: URL,
        canonicalScope: String
    ) -> String? {
        guard (try? RecoveryJournalStore.validateRelativePath(entry.relativePath)) != nil,
              target.path.hasPrefix(canonicalScope + "/") else {
            return "outside-scope"
        }

        var scopeInfo = stat()
        guard canonicalScope.withCString({ lstat($0, &scopeInfo) }) == 0,
              scopeInfo.st_mode & S_IFMT == S_IFDIR else {
            return "unsafe-scope"
        }

        var current = canonicalScope
        let components = entry.relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current += "/\(component)"
            var info = stat()
            guard current.withCString({ lstat($0, &info) }) == 0 else { return "vanished" }
            let kind = info.st_mode & S_IFMT
            if index + 1 < components.count {
                guard kind == S_IFDIR else { return "unsafe-ancestor" }
            } else if entry.isPackageRoot {
                guard kind == S_IFDIR else { return kind == S_IFLNK ? "symlink" : "stale-type" }
            } else {
                guard kind == S_IFREG else { return kind == S_IFLNK ? "symlink" : "stale-type" }
            }
        }
        return identity(target.path) == entry.identity ? nil : "stale-identity"
    }

    private static func readMetadata(_ url: URL) -> RestorationMetadataReadResult {
        do {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemDownloadingErrorKey,
            ])
            let status = values.ubiquitousItemDownloadingStatus
            return .found(RestorationMetadata(
                isUbiquitous: values.isUbiquitousItem ?? false,
                isDownloaded: status == URLUbiquitousItemDownloadingStatus.current
                    || status == URLUbiquitousItemDownloadingStatus.downloaded,
                isDownloading: values.ubiquitousItemIsDownloading ?? false,
                hasDownloadError: values.ubiquitousItemDownloadingError != nil
            ))
        } catch {
            return .unavailable
        }
    }
}

private extension RestorationItemStatus {
    var journalStatus: RecoveryJournalStatus {
        switch self {
        case .verified: return .verified
        case .pending: return .pending
        case .failed: return .failed
        }
    }
}

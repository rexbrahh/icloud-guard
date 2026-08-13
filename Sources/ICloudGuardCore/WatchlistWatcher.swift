import Darwin
import Foundation

/// A path we evicted and now watch for rematerialization.
public struct WatchlistEntry: Codable, Equatable, Sendable {
    public var path: String
    public var addedAt: Date
    /// How many times this file has rematerialized and been re-evicted.
    public var reEvictCount: Int
    /// Consecutive polls where the file stayed dataless.
    public var stableDatalessChecks: Int
    /// Earliest time the entry should be checked again (backoff).
    public var nextCheckAt: Date
    /// The eviction API accepted the request, but the local postcondition was
    /// not yet observable. The watcher must verify this later.
    public var pendingVerification: Bool
    /// When the most recent accepted-but-unverified request was issued.
    public var pendingSince: Date?
    /// Accepted requests that remained unverifiable after their grace window.
    public var pendingRetryCount: Int
    /// Hard stop after repeated accepted-but-unverifiable requests.
    public var suspended: Bool
    /// The exact filesystem object accepted by FileProvider.
    public var identity: EvictionFileIdentity?
    /// Monotonic request version used to resolve cross-process dirty merges.
    public var requestGeneration: UInt64
    /// Time of the most recent accepted or explicitly recorded eviction.
    public var requestTimestamp: Date
    /// Most recent mutation attempt, including a failed attempt.
    public var lastAttemptAt: Date?
    /// Last observable error. Empty after a verified request.
    public var lastError: String?
    /// Time at which a dataless postcondition was last verified.
    public var verifiedAt: Date?
    /// A replacement object now occupies the recorded path.
    public var identityMismatch: Bool
    /// Stable reason for a hard stop.
    public var suspensionReason: String?

    public init(
        path: String,
        addedAt: Date,
        reEvictCount: Int = 0,
        stableDatalessChecks: Int = 0,
        nextCheckAt: Date,
        pendingVerification: Bool = false,
        pendingSince: Date? = nil,
        pendingRetryCount: Int = 0,
        suspended: Bool = false,
        identity: EvictionFileIdentity? = nil,
        requestGeneration: UInt64 = 0,
        requestTimestamp: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        verifiedAt: Date? = nil,
        identityMismatch: Bool = false,
        suspensionReason: String? = nil
    ) {
        self.path = path
        self.addedAt = addedAt
        self.reEvictCount = reEvictCount
        self.stableDatalessChecks = stableDatalessChecks
        self.nextCheckAt = nextCheckAt
        self.pendingVerification = pendingVerification
        self.pendingSince = pendingSince ?? (pendingVerification ? addedAt : nil)
        self.pendingRetryCount = pendingRetryCount
        self.suspended = suspended
        self.identity = identity
        self.requestGeneration = requestGeneration
        self.requestTimestamp = requestTimestamp ?? pendingSince ?? addedAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.verifiedAt = verifiedAt
        self.identityMismatch = identityMismatch
        self.suspensionReason = suspensionReason
    }

    private enum CodingKeys: String, CodingKey {
        case path, addedAt, reEvictCount, stableDatalessChecks, nextCheckAt, pendingVerification, pendingSince
        case pendingRetryCount, suspended, identity, requestGeneration, requestTimestamp
        case lastAttemptAt, lastError, verifiedAt, identityMismatch, suspensionReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        reEvictCount = try container.decodeIfPresent(Int.self, forKey: .reEvictCount) ?? 0
        stableDatalessChecks = try container.decodeIfPresent(Int.self, forKey: .stableDatalessChecks) ?? 0
        nextCheckAt = try container.decode(Date.self, forKey: .nextCheckAt)
        pendingVerification = try container.decodeIfPresent(Bool.self, forKey: .pendingVerification) ?? false
        pendingSince = try container.decodeIfPresent(Date.self, forKey: .pendingSince)
            ?? (pendingVerification ? addedAt : nil)
        pendingRetryCount = try container.decodeIfPresent(Int.self, forKey: .pendingRetryCount) ?? 0
        suspended = try container.decodeIfPresent(Bool.self, forKey: .suspended) ?? false
        identity = try container.decodeIfPresent(EvictionFileIdentity.self, forKey: .identity)
        requestGeneration = try container.decodeIfPresent(UInt64.self, forKey: .requestGeneration) ?? 0
        requestTimestamp = try container.decodeIfPresent(Date.self, forKey: .requestTimestamp)
            ?? pendingSince
            ?? addedAt
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        verifiedAt = try container.decodeIfPresent(Date.self, forKey: .verifiedAt)
        identityMismatch = try container.decodeIfPresent(Bool.self, forKey: .identityMismatch) ?? false
        suspensionReason = try container.decodeIfPresent(String.self, forKey: .suspensionReason)
    }
}

/// Minimal stat view the watcher needs — injectable for tests.
public struct WatchlistStat: Equatable, Sendable {
    public let isDataless: Bool
    public let allocatedBytes: Int64
    public let isDirectory: Bool
    public let identity: EvictionFileIdentity?

    public init(
        isDataless: Bool,
        allocatedBytes: Int64,
        isDirectory: Bool = false,
        identity: EvictionFileIdentity? = nil
    ) {
        self.isDataless = isDataless
        self.allocatedBytes = allocatedBytes
        self.isDirectory = isDirectory
        self.identity = identity
    }
}

public enum WatchlistStatResult: Equatable, Sendable {
    case found(WatchlistStat)
    case vanished
    case failed(String)
}

public struct WatchlistPollOutcome: Equatable, Sendable {
    public var checked: Int = 0
    public var reEvictedPaths: [String] = []
    public var verifiedPendingPaths: [String] = []
    public var removedPaths: [String] = []
    public var fightingPaths: [String] = []

    public init() {}
}

public struct WatchlistAddResult: Equatable, Sendable {
    public var acceptedPaths: [String]
    public var rejectedPaths: [String]
    public var persisted: Bool
    public var prunedPaths: [String]

    public init(
        acceptedPaths: [String] = [],
        rejectedPaths: [String] = [],
        persisted: Bool = false,
        prunedPaths: [String] = []
    ) {
        self.acceptedPaths = acceptedPaths
        self.rejectedPaths = rejectedPaths
        self.persisted = persisted
        self.prunedPaths = prunedPaths
    }

    public var allAcceptedAndPersisted: Bool {
        rejectedPaths.isEmpty && persisted
    }
}

public struct WatchlistRetentionReport: Equatable, Sendable {
    public var prunedPaths: [String]
    public var rejectedCount: Int
    public var persisted: Bool
    public var error: String?

    public init(prunedPaths: [String] = [], rejectedCount: Int = 0, persisted: Bool = true, error: String? = nil) {
        self.prunedPaths = prunedPaths
        self.rejectedCount = rejectedCount
        self.persisted = persisted
        self.error = error
    }
}

public enum WatchlistLoadHealth: Equatable, Sendable {
    case missing
    case loaded
    case failed(String)
}

/// Layer 3 (redesigned): watchlist-based rematerialization defense.
///
/// After each eviction the evicted paths are recorded here. A timer polls
/// them with `lstat(2)` (microseconds per path, no Spotlight dependency,
/// works while Spotlight suppression is active). A path that becomes
/// resident again is re-evicted with exponential backoff. Paths that stay
/// dataless graduate out of the list; paths that keep rematerializing are
/// flagged as "fighting" so the UI can surface the iCloud tug-of-war.
///
/// Persistence: JSON at ~/.icloud-guard/watchlist.json, LRU-capped.
public final class WatchlistWatcher {
    public static let defaultMaxEntries = 5000
    public static let defaultStableChecksToRemove = 12
    public static let defaultMaxFights = 10

    /// Called with paths that rematerialized and were re-evicted.
    public var onRematerialization: (([String]) -> Void)?
    /// Called with paths that are stuck in an eviction/rematerialization war.
    public var onFighting: (([String]) -> Void)?
    /// Called when the watchlist count changes.
    public var onCountChange: ((Int) -> Void)?

    private let storageURL: URL
    private let logger: GuardLogging
    private let protectedPaths: ProtectedPathsMatcher
    private let scopePath: String
    private let maxEntries: Int
    private let stableChecksToRemove: Int
    private let maxFights: Int
    private let pendingRetryLimit: Int
    private let backoffMaxSeconds: TimeInterval
    private let pendingVerificationGraceSeconds: TimeInterval
    private let verifiedRetentionSeconds: TimeInterval
    private let statProvider: (String) -> WatchlistStatResult
    private let engine: EvictionEngine
    private let mutationLockPath: String
    private let protectBusyPackages: Bool
    private let beforeMutation: (@Sendable () -> Void)?
    private let nowProvider: @Sendable () -> Date

    private let lock = NSLock()
    private let pollMutationGate = NSLock()
    private let pollGroup = DispatchGroup()
    private var entries: [String: WatchlistEntry] = [:] // path → entry
    private var insertionOrder: [String] = []           // FIFO for LRU eviction
    private var removedSinceSave: Set<String> = []
    private var timer: DispatchSourceTimer?
    private var timerCancellation: EvictionCancellation?
    private var dirty = false
    private var persistenceError: String?
    private var storageLoadHealth: WatchlistLoadHealth = .missing
    private var retentionReport = WatchlistRetentionReport()

    public init(
        storageURL: URL = AppPaths.watchlist,
        logger: GuardLogging,
        protectedPaths: ProtectedPathsMatcher = ProtectedPathsMatcher(patterns: []),
        scopePath: String = "",
        maxEntries: Int = WatchlistWatcher.defaultMaxEntries,
        stableChecksToRemove: Int = WatchlistWatcher.defaultStableChecksToRemove,
        maxFights: Int = WatchlistWatcher.defaultMaxFights,
        pendingRetryLimit: Int? = nil,
        backoffMaxSeconds: TimeInterval = 60,
        pendingVerificationGraceSeconds: TimeInterval = 30,
        verifiedRetentionSeconds: TimeInterval = 0,
        statProvider: ((String) -> WatchlistStat?)? = nil,
        statResultProvider: ((String) -> WatchlistStatResult)? = nil,
        evict: ((String) -> Bool)? = nil,
        mutationValidator: ((EvictionCandidate, String, ProtectedPathsMatcher) -> String?)? = nil,
        inspectBusyPackage: ((String) -> BusyPackageInspection)? = nil,
        beforeMutation: (@Sendable () -> Void)? = nil,
        mutationLockPath: String = AppPaths.lock.path,
        mutationLockHeld: Bool = false,
        protectBusyPackages: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageURL = storageURL
        self.logger = logger
        self.protectedPaths = protectedPaths
        let expandedScope = NSString(string: scopePath).expandingTildeInPath
        self.scopePath = expandedScope.isEmpty
            ? ""
            : URL(fileURLWithPath: expandedScope, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        self.maxEntries = max(1, maxEntries)
        self.stableChecksToRemove = max(1, stableChecksToRemove)
        self.maxFights = max(1, maxFights)
        self.pendingRetryLimit = max(1, pendingRetryLimit ?? maxFights)
        self.backoffMaxSeconds = max(1, backoffMaxSeconds)
        self.pendingVerificationGraceSeconds = max(1, pendingVerificationGraceSeconds)
        self.verifiedRetentionSeconds = max(0, verifiedRetentionSeconds)
        self.mutationLockPath = mutationLockPath
        self.protectBusyPackages = protectBusyPackages
        self.beforeMutation = beforeMutation
        self.nowProvider = now
        if let statResultProvider {
            self.statProvider = statResultProvider
        } else if let statProvider {
            self.statProvider = { path in
                if let stat = statProvider(path) { return .found(stat) }
                return .vanished
            }
        } else {
            self.statProvider = { path in
                switch EvictionFootprint.measureResult(path: path) {
                case .found(let footprint):
                    return .found(WatchlistStat(
                        isDataless: footprint.isDataless,
                        allocatedBytes: footprint.allocatedBytes,
                        isDirectory: footprint.isDirectory,
                        identity: footprint.identity
                    ))
                case .vanished: return .vanished
                case .failed(let reason): return .failed(reason)
                }
            }
        }
        let effectiveStatProvider = self.statProvider
        let usesInjectedFilesystem = statProvider != nil || statResultProvider != nil || evict != nil
        let busyInspector = BusyPackageInspector()
        let effectiveMutationValidator = mutationValidator ?? (usesInjectedFilesystem
            ? { candidate, scope, protected in
                let normalizedScope = URL(fileURLWithPath: scope).standardizedFileURL.path
                let normalizedPath = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
                guard normalizedPath.hasPrefix(normalizedScope + "/") else { return "outside-scope" }
                let relative = String(normalizedPath.dropFirst(normalizedScope.count + 1))
                guard relative == candidate.relativePath,
                      !protected.isProtected(path: normalizedPath, relativePath: relative) else {
                    return "protected-path"
                }
                guard case .found(let stat) = effectiveStatProvider(normalizedPath),
                      stat.isDirectory == candidate.isPackageRoot else {
                    return "stale-type"
                }
                return nil
            }
            : EvictionEngine.validateCandidateForMutation)
        let effectiveBusyInspection = inspectBusyPackage ?? (usesInjectedFilesystem
            ? { _ in .clear }
            : { busyInspector.inspect(packagePath: $0) })
        self.engine = EvictionEngine(
            logger: logger,
            evictItem: { url in
                if let evict, !evict(url.path) {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                if evict == nil { try FileManager.default.evictUbiquitousItem(at: url) }
            },
            footprintResult: { path in
                switch effectiveStatProvider(path) {
                case .found(let stat):
                    return .found(EvictionFootprint(
                        allocatedBytes: stat.allocatedBytes,
                        isDataless: stat.isDataless,
                        isDirectory: stat.isDirectory,
                        identity: stat.identity
                    ))
                case .vanished: return .vanished
                case .failed(let reason): return .failed(reason)
                }
            },
            verificationDelay: { usleep(100_000) },
            mutationValidator: effectiveMutationValidator,
            inspectBusyPackage: effectiveBusyInspection
        )
        if mutationLockHeld {
            load()
        } else {
            do {
                let loadLock = try AdvisoryFileLock(path: mutationLockPath)
                load()
                withExtendedLifetime(loadLock) {}
            } catch {
                recordPersistenceError("watchlist-lock-failed phase=load error=\(error)")
            }
        }
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Public API

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Paths currently flagged as fighting iCloud (re-evicted > maxFights).
    public var fightingPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter {
            WatchlistFightPolicy.isFighting(count: $0.reEvictCount, maxFights: maxFights) || $0.suspended
        }.map(\.path).sorted()
    }

    public var hasUnsavedChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }

    public var lastPersistenceError: String? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceError
    }

    public var loadHealth: WatchlistLoadHealth {
        lock.lock()
        defer { lock.unlock() }
        return storageLoadHealth
    }

    public var lastRetentionReport: WatchlistRetentionReport {
        lock.lock()
        defer { lock.unlock() }
        return retentionReport
    }

    public var snapshot: [WatchlistEntry] {
        lock.lock()
        defer { lock.unlock() }
        return insertionOrder.compactMap { entries[$0] }
    }

    /// Record freshly evicted paths. Already-listed paths keep their history.
    @discardableResult
    public func add(
        paths: [String],
        identities: [String: EvictionFileIdentity] = [:],
        now: Date = Date(),
        mutationLockHeld: Bool = false
    ) -> WatchlistAddResult {
        add(paths: paths, identities: identities, pendingVerification: false, now: now, mutationLockHeld: mutationLockHeld)
    }

    @discardableResult
    public func addPending(
        paths: [String],
        identities: [String: EvictionFileIdentity] = [:],
        now: Date = Date(),
        mutationLockHeld: Bool = false
    ) -> WatchlistAddResult {
        add(paths: paths, identities: identities, pendingVerification: true, now: now, mutationLockHeld: mutationLockHeld)
    }

    private func add(
        paths: [String],
        identities: [String: EvictionFileIdentity],
        pendingVerification: Bool,
        now: Date,
        mutationLockHeld: Bool
    ) -> WatchlistAddResult {
        guard !paths.isEmpty else { return WatchlistAddResult(persisted: true) }
        var ownedMutationLock: AdvisoryFileLock?
        if !mutationLockHeld {
            do {
                ownedMutationLock = try AdvisoryFileLock(path: mutationLockPath)
                try ownedMutationLock?.writeOwnerPID()
            } catch {
                recordPersistenceError("watchlist-lock-failed phase=add error=\(error)")
                return WatchlistAddResult(rejectedPaths: paths, persisted: false)
            }
        }
        lock.lock()
        if case .failed = storageLoadHealth {
            lock.unlock()
            withExtendedLifetime(ownedMutationLock) {}
            return WatchlistAddResult(rejectedPaths: paths, persisted: false)
        }
        guard mergePersistedLocked() else {
            lock.unlock()
            withExtendedLifetime(ownedMutationLock) {}
            return WatchlistAddResult(rejectedPaths: paths, persisted: false)
        }
        var requested: [(raw: String, path: String, identity: EvictionFileIdentity?)] = []
        var rejected: [String] = []
        var seen = Set<String>()
        for rawPath in paths {
            guard let path = normalizedPathInScope(rawPath) else {
                rejected.append(rawPath)
                continue
            }
            guard seen.insert(path).inserted else { continue }
            requested.append((rawPath, path, identities[path] ?? identities[rawPath]))
        }
        let pruned = pruneEligibleLocked(now: now, targetCount: maxEntries)
        var available = max(maxEntries - entries.count, 0)
        let acceptedRequests = requested.filter { request in
            if entries[request.path] != nil { return true }
            guard available > 0 else {
                rejected.append(request.raw)
                return false
            }
            available -= 1
            return true
        }

        var changed = false
        for request in acceptedRequests {
            let path = request.path
            if var existing = entries[path] {
                existing.identity = request.identity ?? existing.identity
                recordAcceptedRequest(&existing, at: now)
                entries[path] = existing
                changed = true
                if pendingVerification {
                    existing.pendingVerification = true
                    existing.pendingSince = now
                    existing.pendingRetryCount = 0
                    existing.suspended = false
                    existing.suspensionReason = nil
                    existing.identityMismatch = false
                    existing.lastError = nil
                    existing.verifiedAt = nil
                    existing.nextCheckAt = now.addingTimeInterval(min(5, backoffMaxSeconds))
                    entries[path] = existing
                    changed = true
                }
            } else {
                entries[path] = WatchlistEntry(
                    path: path,
                    addedAt: now,
                    nextCheckAt: pendingVerification ? now.addingTimeInterval(min(5, backoffMaxSeconds)) : now,
                    pendingVerification: pendingVerification,
                    pendingSince: pendingVerification ? now : nil,
                    pendingRetryCount: 0,
                    suspended: false,
                    identity: request.identity ?? currentIdentity(path),
                    requestGeneration: 1,
                    requestTimestamp: now
                )
                insertionOrder.append(path)
                changed = true
            }
        }
        if changed || dirty {
            dirty = true
            saveLocked()
        }
        let newCount = entries.count
        let persisted = !dirty
        retentionReport = WatchlistRetentionReport(
            prunedPaths: pruned,
            rejectedCount: rejected.count,
            persisted: persisted,
            error: persistenceError
        )
        lock.unlock()
        withExtendedLifetime(ownedMutationLock) {}
        if changed { onCountChange?(newCount) }
        return WatchlistAddResult(
            acceptedPaths: persisted ? acceptedRequests.map(\.path) : [],
            rejectedPaths: persisted ? rejected : paths,
            persisted: persisted,
            prunedPaths: pruned
        )
    }

    /// Reload under the caller's mutation transaction and return paths whose
    /// accepted eviction is still awaiting verification.
    public func refreshPendingPaths(mutationLockHeld: Bool = false) -> Set<String>? {
        var ownedMutationLock: AdvisoryFileLock?
        if !mutationLockHeld {
            do {
                ownedMutationLock = try AdvisoryFileLock(path: mutationLockPath)
            } catch {
                recordPersistenceError("watchlist-lock-failed phase=refresh error=\(error)")
                return nil
            }
        }
        lock.lock()
        if case .failed = storageLoadHealth {
            lock.unlock()
            withExtendedLifetime(ownedMutationLock) {}
            return nil
        }
        guard mergePersistedLocked() else {
            lock.unlock()
            withExtendedLifetime(ownedMutationLock) {}
            return nil
        }
        let paths = Set(entries.values.filter { $0.pendingVerification || $0.suspended }.map(\.path))
        lock.unlock()
        withExtendedLifetime(ownedMutationLock) {}
        return paths
    }

    /// Start polling every `intervalSeconds`.
    public func start(intervalSeconds: Int) {
        stop()
        let interval = max(1, intervalSeconds)
        let cancellation = EvictionCancellation()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollGroup.enter()
            defer { self.pollGroup.leave() }
            _ = self.pollOnce(now: Date(), cancellation: cancellation)
        }
        lock.lock()
        self.timer = timer
        timerCancellation = cancellation
        lock.unlock()
        timer.resume()
        logger.log("watchlist started interval=\(interval)s entries=\(count)")
    }

    public func stop() {
        lock.lock()
        let activeTimer = timer
        let cancellation = timerCancellation
        self.timer = nil
        timerCancellation = nil
        lock.unlock()
        activeTimer?.cancel()
        pollMutationGate.lock()
        cancellation?.cancel()
        pollMutationGate.unlock()
        pollGroup.wait()
    }

    /// One poll cycle: check all due entries, re-evict rematerialized ones.
    /// Synchronous; safe to call from any queue.
    @discardableResult
    public func pollOnce(now: Date = Date()) -> WatchlistPollOutcome {
        pollOnce(now: now, cancellation: EvictionCancellation())
    }

    private func pollOnce(now: Date, cancellation: EvictionCancellation) -> WatchlistPollOutcome {
        guard !cancellation.isCancelled else { return WatchlistPollOutcome() }
        let mutationLock: AdvisoryFileLock
        do {
            mutationLock = try AdvisoryFileLock(path: mutationLockPath)
            try mutationLock.writeOwnerPID()
        } catch {
            logger.log("watchlist-lock-failed phase=poll error=\(error)")
            return WatchlistPollOutcome()
        }
        defer { withExtendedLifetime(mutationLock) {} }

        lock.lock()
        guard mergePersistedLocked() else {
            lock.unlock()
            return WatchlistPollOutcome()
        }
        let due = entries.values.filter { $0.nextCheckAt <= now }.map(\.path).sorted()
        let pruned = pruneEligibleLocked(now: now, targetCount: maxEntries)
        retentionReport = WatchlistRetentionReport(prunedPaths: pruned, persisted: !dirty, error: persistenceError)
        let needsIdleSave = due.isEmpty && dirty
        lock.unlock()

        if needsIdleSave {
            pollMutationGate.lock()
            if !cancellation.isCancelled {
                lock.lock()
                if dirty { saveLocked() }
                lock.unlock()
            }
            pollMutationGate.unlock()
        }

        var outcome = WatchlistPollOutcome()
        guard !due.isEmpty else { return outcome }

        var rematerialized: [String] = []

        pollLoop: for path in due {
            if cancellation.isCancelled { break }
            outcome.checked += 1

            // Path became protected since it was added — stop watching it.
            guard let normalizedPath = normalizedPathInScope(path) else {
                beforeMutation?()
                pollMutationGate.lock()
                if !cancellation.isCancelled {
                    removeEntry(path)
                    outcome.removedPaths.append(path)
                }
                pollMutationGate.unlock()
                continue
            }
            let relativePath = String(normalizedPath.dropFirst(scopePath.count + 1))
            if protectedPaths.isProtected(path: path, relativePath: relativePath) {
                beforeMutation?()
                pollMutationGate.lock()
                if !cancellation.isCancelled {
                    removeEntry(path)
                    outcome.removedPaths.append(path)
                }
                pollMutationGate.unlock()
                continue
            }

            let statResult = statProvider(path)
            // stop() may have been waiting on a blocking metadata provider.
            // Observe its cancellation before interpreting any result,
            // including vanished/failed results that mutate persisted state.
            if cancellation.isCancelled { break }

            let stat: WatchlistStat
            switch statResult {
            case .vanished:
                // A confirmed ENOENT is the only metadata result that means
                // the entry can safely leave the watchlist.
                beforeMutation?()
                pollMutationGate.lock()
                guard !cancellation.isCancelled else {
                    pollMutationGate.unlock()
                    break pollLoop
                }
                lock.lock()
                entries.removeValue(forKey: path)
                insertionOrder.removeAll { $0 == path }
                removedSinceSave.insert(path)
                dirty = true
                saveLocked()
                lock.unlock()
                pollMutationGate.unlock()
                outcome.removedPaths.append(path)
                continue
            case .failed(let reason):
                beforeMutation?()
                pollMutationGate.lock()
                guard !cancellation.isCancelled else {
                    pollMutationGate.unlock()
                    break pollLoop
                }
                logger.log("watchlist-stat-failed path=\(path) reason=\(reason)")
                lock.lock()
                if var entry = entries[path] {
                    entry.lastError = reason
                    entry.nextCheckAt = now.addingTimeInterval(min(30, backoffMaxSeconds))
                    entries[path] = entry
                    dirty = true
                    saveLocked()
                }
                lock.unlock()
                pollMutationGate.unlock()
                continue
            case .found(let measured):
                stat = measured
            }

            // stop()/pause may race a blocking metadata read. Never cross the
            // mutation boundary after that poll generation was cancelled.
            if cancellation.isCancelled { break }

            // Every observation derived from `.found` commits through the
            // same gate as eviction and persistence. Metadata reads remain
            // outside the gate so a blocked provider can still be cancelled.
            beforeMutation?()
            pollMutationGate.lock()
            guard !cancellation.isCancelled else {
                pollMutationGate.unlock()
                break
            }

            lock.lock()
            guard var observedEntry = entries[path] else {
                lock.unlock()
                pollMutationGate.unlock()
                continue
            }
            if let expectedIdentity = observedEntry.identity {
                guard stat.identity == expectedIdentity else {
                    observedEntry.identityMismatch = true
                    observedEntry.suspended = true
                    observedEntry.suspensionReason = "identity-mismatch"
                    observedEntry.lastError = "filesystem identity changed"
                    observedEntry.pendingVerification = false
                    observedEntry.pendingSince = nil
                    observedEntry.nextCheckAt = .distantFuture
                    entries[path] = observedEntry
                    dirty = true
                    saveLocked()
                    lock.unlock()
                    logger.log("watchlist-identity-changed path=\(path)")
                    outcome.fightingPaths.append(path)
                    pollMutationGate.unlock()
                    continue
                }
            } else {
                observedEntry.identity = stat.identity
                observedEntry.nextCheckAt = now.addingTimeInterval(min(5, backoffMaxSeconds))
                entries[path] = observedEntry
                dirty = true
                saveLocked()
                lock.unlock()
                pollMutationGate.unlock()
                continue
            }
            lock.unlock()

            let isResident = stat.allocatedBytes > 0 && (stat.isDirectory || !stat.isDataless)

            if !isResident {
                lock.lock()
                if var entry = entries[path] {
                    if entry.pendingVerification {
                        entry.pendingVerification = false
                        entry.pendingSince = nil
                        entry.pendingRetryCount = 0
                        entry.suspended = false
                        entry.suspensionReason = nil
                        outcome.verifiedPendingPaths.append(path)
                    }
                    if entry.verifiedAt == nil { entry.verifiedAt = now }
                    entry.lastError = nil
                    entry.stableDatalessChecks += 1
                    if entry.stableDatalessChecks >= stableChecksToRemove,
                       now.timeIntervalSince(entry.verifiedAt ?? entry.addedAt) >= verifiedRetentionSeconds {
                        entries.removeValue(forKey: path)
                        insertionOrder.removeAll { $0 == path }
                        removedSinceSave.insert(path)
                        outcome.removedPaths.append(path)
                    } else {
                        entry.nextCheckAt = now
                        entries[path] = entry
                    }
                    dirty = true
                }
                if dirty { saveLocked() }
                lock.unlock()
                pollMutationGate.unlock()
                continue
            }

            // An accepted FileProvider request can remain observably resident
            // for a short period. Observe throughout that grace window rather
            // than issuing the same mutation again on the next poll.
            lock.lock()
            if var entry = entries[path], entry.pendingVerification {
                let retryAt = (entry.pendingSince ?? entry.addedAt)
                    .addingTimeInterval(pendingVerificationGraceSeconds)
                if now < retryAt {
                    entry.nextCheckAt = retryAt
                    entries[path] = entry
                    dirty = true
                    saveLocked()
                    lock.unlock()
                    pollMutationGate.unlock()
                    continue
                }
                // Grace expired: this poll is the deliberate retry boundary.
                entry.pendingVerification = false
                entry.pendingSince = nil
                entries[path] = entry
                dirty = true
            }
            lock.unlock()

            // Rematerialized — re-evict through the shared verified engine,
            // under the same cross-process advisory lock as app/CLI runs.
            let candidate = EvictionCandidate(
                path: path,
                relativePath: relativePath,
                allocatedBytes: stat.allocatedBytes,
                modificationDate: nil,
                isPackageRoot: stat.isDirectory,
                identity: stat.identity
            )
            let evictionResult = engine.evictCandidate(
                candidate,
                scopePath: scopePath,
                protectedPaths: protectedPaths,
                protectBusyPackages: protectBusyPackages
            )
            lock.lock()
            if var entry = entries[path] {
                entry.lastAttemptAt = now
                entry.stableDatalessChecks = 0
                switch evictionResult {
                case .verified:
                    recordAcceptedRequest(&entry, at: now)
                    entry.pendingVerification = false
                    entry.pendingSince = nil
                    entry.pendingRetryCount = 0
                    entry.suspended = false
                    entry.suspensionReason = nil
                    entry.identityMismatch = false
                    entry.lastError = nil
                    entry.verifiedAt = now
                    entry.reEvictCount += 1
                    let backoff = min(pow(2.0, Double(entry.reEvictCount)), backoffMaxSeconds)
                    entry.nextCheckAt = now.addingTimeInterval(backoff)
                    rematerialized.append(path)
                    outcome.reEvictedPaths.append(path)
                    if WatchlistFightPolicy.isFighting(count: entry.reEvictCount, maxFights: maxFights) {
                        outcome.fightingPaths.append(path)
                    }
                case .pending:
                    recordAcceptedRequest(&entry, at: now)
                    entry.pendingVerification = true
                    entry.pendingSince = now
                    entry.pendingRetryCount += 1
                    entry.lastError = "eviction accepted; verification pending"
                    entry.verifiedAt = nil
                    if entry.pendingRetryCount >= pendingRetryLimit {
                        entry.suspended = true
                        entry.suspensionReason = "pending-retry-limit"
                        entry.nextCheckAt = .distantFuture
                        outcome.fightingPaths.append(path)
                    } else {
                        let backoff = min(
                            pow(2.0, Double(entry.pendingRetryCount)) * 5,
                            backoffMaxSeconds
                        )
                        entry.nextCheckAt = now.addingTimeInterval(max(pendingVerificationGraceSeconds, backoff))
                    }
                case .blockedBusy(let processDisplayNames):
                    let names = processDisplayNames.prefix(5).joined(separator: ", ")
                    entry.lastError = names.isEmpty ? "busy-package" : "busy-package: close \(names)"
                    entry.nextCheckAt = now.addingTimeInterval(min(30, backoffMaxSeconds))
                    outcome.fightingPaths.append(path)
                case .failed(let reason):
                    // Re-eviction failed — retry soon but not hot-looping.
                    entry.lastError = reason
                    entry.nextCheckAt = now.addingTimeInterval(min(30, backoffMaxSeconds))
                }
                entries[path] = entry
                dirty = true
            }
            if dirty { saveLocked() }
            lock.unlock()
            pollMutationGate.unlock()
        }

        pollMutationGate.lock()
        guard !cancellation.isCancelled else {
            pollMutationGate.unlock()
            mutationLock.unlock()
            return outcome
        }
        lock.lock()
        if dirty { saveLocked() }
        lock.unlock()
        pollMutationGate.unlock()

        // User interaction and notifications are deliberately outside the
        // cross-process mutation critical section.
        mutationLock.unlock()

        if !rematerialized.isEmpty {
            logger.log("watchlist rematerialized=\(rematerialized.count) reEvicted=\(outcome.reEvictedPaths.count) fighting=\(outcome.fightingPaths.count)")
            onRematerialization?(rematerialized)
            onCountChange?(count)
        }

        if !outcome.verifiedPendingPaths.isEmpty {
            logger.log("watchlist-pending-verified count=\(outcome.verifiedPendingPaths.count)")
        }

        if !outcome.fightingPaths.isEmpty {
            onFighting?(outcome.fightingPaths)
        }

        return outcome
    }

    // MARK: - Persistence

    private func load() {
        let data: Data
        do {
            data = try WatchlistStorage.readData(at: storageURL)
        } catch {
            if case SecureRegularFile.ReadError.open(let errorNumber) = error, errorNumber == ENOENT {
                lock.lock()
                storageLoadHealth = .missing
                lock.unlock()
            } else {
                recordLoadFailure("watchlist-load-failed path=\(storageURL.path) error=\(error)")
            }
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: [WatchlistEntry]
        do {
            decoded = try decoder.decode([WatchlistEntry].self, from: data)
        } catch {
            recordLoadFailure("watchlist-decode-failed path=\(storageURL.path) error=\(error)")
            return
        }
        lock.lock()
        storageLoadHealth = .loaded
        var rejectedCount = 0
        for entry in decoded {
            let validation = WatchlistSemanticValidator.validate(entry, scopePath: scopePath, now: nowProvider())
            guard let normalizedEntry = validation.entry else {
                rejectedCount += 1
                continue
            }
            entries[normalizedEntry.path] = normalizedEntry
            if !insertionOrder.contains(normalizedEntry.path) {
                insertionOrder.append(normalizedEntry.path)
            }
        }
        let pruned = pruneEligibleLocked(now: nowProvider(), targetCount: maxEntries)
        let changed = rejectedCount > 0 || !pruned.isEmpty
        retentionReport = WatchlistRetentionReport(
            prunedPaths: pruned,
            rejectedCount: rejectedCount,
            persisted: !changed,
            error: persistenceError
        )
        if changed {
            dirty = true
            saveLocked()
        }
        lock.unlock()
    }

    /// Must be called with `lock` held.
    private func saveLocked() {
        let all = insertionOrder.compactMap { entries[$0] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(all)
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: [.atomic])
            dirty = false
            removedSinceSave.removeAll()
            persistenceError = nil
        } catch {
            dirty = true
            let message = "watchlist-save-failed path=\(storageURL.path) error=\(error)"
            persistenceError = message
            logger.log(message)
        }
    }

    private func normalizedPathInScope(_ path: String) -> String? {
        guard !scopePath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard normalized.hasPrefix(scopePath + "/") else { return nil }
        return normalized
    }

    private func removeEntry(_ path: String) {
        lock.lock()
        entries.removeValue(forKey: path)
        insertionOrder.removeAll { $0 == path }
        removedSinceSave.insert(path)
        dirty = true
        lock.unlock()
    }

    private func recordPersistenceError(_ message: String) {
        lock.lock()
        persistenceError = message
        lock.unlock()
        logger.log(message)
    }

    private func recordLoadFailure(_ message: String) {
        lock.lock()
        storageLoadHealth = .failed(message)
        persistenceError = message
        lock.unlock()
        logger.log(message)
    }

    /// Must be called while holding both the in-process lock and the shared
    /// advisory lock. Merge newer additions instead of overwriting them with
    /// this watcher's long-lived snapshot; pending state is conservative.
    private func mergePersistedLocked() -> Bool {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return true }
        let data: Data
        do {
            data = try WatchlistStorage.readData(at: storageURL)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError { return true }
            let message = "watchlist-load-failed path=\(storageURL.path) error=\(error)"
            persistenceError = message
            logger.log(message)
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted: [WatchlistEntry]
        do {
            persisted = try decoder.decode([WatchlistEntry].self, from: data)
        } catch {
            let message = "watchlist-decode-failed path=\(storageURL.path) error=\(error)"
            persistenceError = message
            logger.log(message)
            return false
        }

        if !dirty {
            entries.removeAll(keepingCapacity: true)
            insertionOrder.removeAll(keepingCapacity: true)
            removedSinceSave.removeAll()
        }

        for rawEntry in persisted {
            let validation = WatchlistSemanticValidator.validate(rawEntry, scopePath: scopePath, now: nowProvider())
            guard let diskEntry = validation.entry,
                  !removedSinceSave.contains(diskEntry.path) else { continue }
            let path = diskEntry.path
            if var local = entries[path] {
                let localRequestIsNewer = local.requestGeneration > diskEntry.requestGeneration
                if !localRequestIsNewer {
                    local.identity = diskEntry.identity
                    local.requestGeneration = diskEntry.requestGeneration
                    local.requestTimestamp = diskEntry.requestTimestamp
                }
                local.pendingVerification = local.pendingVerification || diskEntry.pendingVerification
                if local.pendingVerification {
                    local.pendingSince = [local.pendingSince, diskEntry.pendingSince].compactMap { $0 }.max()
                } else {
                    local.pendingSince = nil
                }
                local.reEvictCount = max(local.reEvictCount, diskEntry.reEvictCount)
                local.pendingRetryCount = max(local.pendingRetryCount, diskEntry.pendingRetryCount)
                local.suspended = local.suspended || diskEntry.suspended
                local.stableDatalessChecks = min(local.stableDatalessChecks, diskEntry.stableDatalessChecks)
                local.addedAt = min(local.addedAt, diskEntry.addedAt)
                local.nextCheckAt = min(local.nextCheckAt, diskEntry.nextCheckAt)
                entries[path] = local
            } else {
                entries[path] = diskEntry
                insertionOrder.append(path)
            }
        }
        let pruned = pruneEligibleLocked(now: nowProvider(), targetCount: maxEntries)
        if !pruned.isEmpty {
            retentionReport = WatchlistRetentionReport(prunedPaths: pruned, persisted: false, error: persistenceError)
        }
        return true
    }

    private func currentIdentity(_ path: String) -> EvictionFileIdentity? {
        guard case .found(let stat) = statProvider(path) else { return nil }
        return stat.identity
    }

    private func recordAcceptedRequest(_ entry: inout WatchlistEntry, at timestamp: Date) {
        if entry.requestGeneration < UInt64.max { entry.requestGeneration += 1 }
        entry.requestTimestamp = timestamp
    }

    /// Must be called with `lock` held. Pending and suspended entries are
    /// never capacity-pruned because they still represent unresolved work.
    @discardableResult
    private func pruneEligibleLocked(now: Date, targetCount: Int) -> [String] {
        let cutoff = now.addingTimeInterval(-verifiedRetentionSeconds)
        let removable = insertionOrder.filter { path in
            guard let entry = entries[path],
                  !entry.pendingVerification,
                  !entry.suspended,
                  !entry.identityMismatch,
                  entry.lastError == nil,
                  !WatchlistFightPolicy.isFighting(count: entry.reEvictCount, maxFights: maxFights),
                  entry.stableDatalessChecks >= stableChecksToRemove else { return false }
            guard let verifiedAt = entry.verifiedAt else { return false }
            guard entry.addedAt <= now, entry.requestTimestamp <= now, verifiedAt <= now else { return false }
            return verifiedAt <= cutoff
        }
        var pruned: [String] = []
        for path in removable where entries.count > targetCount || (entries[path]?.verifiedAt ?? .distantFuture) <= cutoff {
            entries.removeValue(forKey: path)
            insertionOrder.removeAll { $0 == path }
            removedSinceSave.insert(path)
            dirty = true
            pruned.append(path)
        }
        return pruned
    }
}

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

    public init(
        path: String,
        addedAt: Date,
        reEvictCount: Int = 0,
        stableDatalessChecks: Int = 0,
        nextCheckAt: Date
    ) {
        self.path = path
        self.addedAt = addedAt
        self.reEvictCount = reEvictCount
        self.stableDatalessChecks = stableDatalessChecks
        self.nextCheckAt = nextCheckAt
    }
}

/// Minimal stat view the watcher needs — injectable for tests.
public struct WatchlistStat: Equatable, Sendable {
    public let isDataless: Bool
    public let allocatedBytes: Int64

    public init(isDataless: Bool, allocatedBytes: Int64) {
        self.isDataless = isDataless
        self.allocatedBytes = allocatedBytes
    }
}

public struct WatchlistPollOutcome: Equatable, Sendable {
    public var checked: Int = 0
    public var reEvictedPaths: [String] = []
    public var removedPaths: [String] = []
    public var fightingPaths: [String] = []

    public init() {}
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
    private let backoffMaxSeconds: TimeInterval
    private let statProvider: (String) -> WatchlistStat?
    private let evict: (String) -> Bool

    private let lock = NSLock()
    private var entries: [String: WatchlistEntry] = [:] // path → entry
    private var insertionOrder: [String] = []           // FIFO for LRU eviction
    private var timer: DispatchSourceTimer?
    private var dirty = false

    public init(
        storageURL: URL = AppPaths.watchlist,
        logger: GuardLogging,
        protectedPaths: ProtectedPathsMatcher = ProtectedPathsMatcher(patterns: []),
        scopePath: String = "",
        maxEntries: Int = WatchlistWatcher.defaultMaxEntries,
        stableChecksToRemove: Int = WatchlistWatcher.defaultStableChecksToRemove,
        maxFights: Int = WatchlistWatcher.defaultMaxFights,
        backoffMaxSeconds: TimeInterval = 60,
        statProvider: ((String) -> WatchlistStat?)? = nil,
        evict: ((String) -> Bool)? = nil
    ) {
        self.storageURL = storageURL
        self.logger = logger
        self.protectedPaths = protectedPaths
        self.scopePath = NSString(string: scopePath).expandingTildeInPath
        self.maxEntries = max(1, maxEntries)
        self.stableChecksToRemove = max(1, stableChecksToRemove)
        self.maxFights = max(1, maxFights)
        self.backoffMaxSeconds = max(1, backoffMaxSeconds)
        self.statProvider = statProvider ?? { path in
            guard let info = BulkScanner.lstatPath(path) else { return nil }
            return WatchlistStat(
                isDataless: (info.st_flags & SF_DATALESS) != 0,
                allocatedBytes: Int64(info.st_blocks) * 512
            )
        }
        self.evict = evict ?? { path in
            do {
                try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
                return true
            } catch {
                return false
            }
        }
        load()
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
        return entries.values.filter { $0.reEvictCount > maxFights }.map(\.path).sorted()
    }

    /// Record freshly evicted paths. Already-listed paths keep their history.
    public func add(paths: [String], now: Date = Date()) {
        guard !paths.isEmpty else { return }
        lock.lock()
        var changed = false
        for path in paths where entries[path] == nil {
            entries[path] = WatchlistEntry(path: path, addedAt: now, nextCheckAt: now)
            insertionOrder.append(path)
            changed = true
        }
        // LRU cap: drop oldest entries
        while insertionOrder.count > maxEntries {
            let oldest = insertionOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        if changed {
            dirty = true
            saveLocked()
        }
        let newCount = entries.count
        lock.unlock()
        if changed { onCountChange?(newCount) }
    }

    /// Start polling every `intervalSeconds`.
    public func start(intervalSeconds: Int) {
        stop()
        let interval = max(1, intervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            _ = self?.pollOnce()
        }
        timer.resume()
        self.timer = timer
        logger.log("watchlist started interval=\(interval)s entries=\(count)")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One poll cycle: check all due entries, re-evict rematerialized ones.
    /// Synchronous; safe to call from any queue.
    @discardableResult
    public func pollOnce(now: Date = Date()) -> WatchlistPollOutcome {
        lock.lock()
        let due = entries.values.filter { $0.nextCheckAt <= now }.map(\.path).sorted()
        lock.unlock()

        var outcome = WatchlistPollOutcome()
        guard !due.isEmpty else { return outcome }

        var rematerialized: [String] = []

        for path in due {
            outcome.checked += 1

            // Path became protected since it was added — stop watching it.
            let relativePath: String
            if !scopePath.isEmpty, path.hasPrefix(scopePath + "/") {
                relativePath = String(path.dropFirst(scopePath.count + 1))
            } else {
                relativePath = path
            }
            if protectedPaths.isProtected(path: path, relativePath: relativePath) {
                lock.lock()
                entries.removeValue(forKey: path)
                insertionOrder.removeAll { $0 == path }
                dirty = true
                lock.unlock()
                outcome.removedPaths.append(path)
                continue
            }

            guard let stat = statProvider(path) else {
                // File vanished (moved/deleted elsewhere) — nothing to guard.
                lock.lock()
                entries.removeValue(forKey: path)
                insertionOrder.removeAll { $0 == path }
                dirty = true
                lock.unlock()
                outcome.removedPaths.append(path)
                continue
            }

            let isResident = !stat.isDataless && stat.allocatedBytes > 0

            if !isResident {
                lock.lock()
                if var entry = entries[path] {
                    entry.stableDatalessChecks += 1
                    if entry.stableDatalessChecks >= stableChecksToRemove {
                        entries.removeValue(forKey: path)
                        insertionOrder.removeAll { $0 == path }
                        outcome.removedPaths.append(path)
                    } else {
                        entry.nextCheckAt = now
                        entries[path] = entry
                    }
                    dirty = true
                }
                lock.unlock()
                continue
            }

            // Rematerialized — re-evict with exponential backoff.
            let evicted = evict(path)
            lock.lock()
            if var entry = entries[path] {
                entry.stableDatalessChecks = 0
                if evicted {
                    entry.reEvictCount += 1
                    let backoff = min(pow(2.0, Double(entry.reEvictCount)), backoffMaxSeconds)
                    entry.nextCheckAt = now.addingTimeInterval(backoff)
                    rematerialized.append(path)
                    outcome.reEvictedPaths.append(path)
                    if entry.reEvictCount > maxFights {
                        outcome.fightingPaths.append(path)
                    }
                } else {
                    // Re-eviction failed — retry soon but not hot-looping.
                    entry.nextCheckAt = now.addingTimeInterval(min(30, backoffMaxSeconds))
                }
                entries[path] = entry
                dirty = true
            }
            lock.unlock()
        }

        lock.lock()
        if dirty { saveLocked() }
        lock.unlock()

        if !rematerialized.isEmpty {
            logger.log("watchlist rematerialized=\(rematerialized.count) reEvicted=\(outcome.reEvictedPaths.count) fighting=\(outcome.fightingPaths.count)")
            onRematerialization?(rematerialized)
            onCountChange?(count)
        }

        if !outcome.fightingPaths.isEmpty {
            onFighting?(outcome.fightingPaths)
        }

        return outcome
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([WatchlistEntry].self, from: data) else { return }
        lock.lock()
        for entry in decoded {
            entries[entry.path] = entry
            if !insertionOrder.contains(entry.path) {
                insertionOrder.append(entry.path)
            }
        }
        lock.unlock()
    }

    /// Must be called with `lock` held.
    private func saveLocked() {
        dirty = false
        let all = insertionOrder.compactMap { entries[$0] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: [.atomic])
    }
}

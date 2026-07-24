import Foundation
import XCTest
@testable import ICloudGuardCore

final class WatchlistWatcherTests: XCTestCase {
    private var tempDir: URL!
    private var storageURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storageURL = tempDir.appendingPathComponent("watchlist.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private final class FakeFS {
        /// path → stat (nil = file vanished)
        var stats: [String: WatchlistStat?] = [:]
        var evictedPaths: [String] = []
        /// After an eviction, files become dataless unless flipped again.
        var evictSucceeds = true

        func stat(_ path: String) -> WatchlistStat? {
            stats[path] ?? nil
        }

        func evict(_ path: String) -> Bool {
            guard evictSucceeds else { return false }
            evictedPaths.append(path)
            stats[path] = WatchlistStat(isDataless: true, allocatedBytes: 0)
            return true
        }
    }

    private func makeWatcher(
        fakeFS: FakeFS,
        maxEntries: Int = 100,
        stableChecksToRemove: Int = 3,
        maxFights: Int = 2,
        protectedPatterns: [String] = []
    ) -> WatchlistWatcher {
        WatchlistWatcher(
            storageURL: storageURL,
            logger: TestLogger(),
            protectedPaths: ProtectedPathsMatcher(patterns: protectedPatterns),
            scopePath: "/scope",
            maxEntries: maxEntries,
            stableChecksToRemove: stableChecksToRemove,
            maxFights: maxFights,
            backoffMaxSeconds: 60,
            statProvider: { fakeFS.stat($0) },
            evict: { fakeFS.evict($0) }
        )
    }

    func testRematerializedFileIsReEvictedWithBackoff() {
        let fs = FakeFS()
        fs.stats["/scope/a.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4096)

        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/a.bin"], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(watcher.count, 1)

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(outcome.reEvictedPaths, ["/scope/a.bin"])
        XCTAssertEqual(fs.evictedPaths, ["/scope/a.bin"])

        // Backoff: the entry is not due again immediately.
        let immediate = watcher.pollOnce(now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(immediate.checked, 0)
    }

    func testStableDatalessFileGraduatesOutOfWatchlist() {
        let fs = FakeFS()
        fs.stats["/scope/b.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0)

        let watcher = makeWatcher(fakeFS: fs, stableChecksToRemove: 3)
        watcher.add(paths: ["/scope/b.bin"], now: Date(timeIntervalSince1970: 0))

        for tick in 1...3 {
            _ = watcher.pollOnce(now: Date(timeIntervalSince1970: TimeInterval(tick)))
        }
        XCTAssertEqual(watcher.count, 0)
    }

    func testVanishedFileIsRemovedQuietly() {
        let fs = FakeFS()
        fs.stats["/scope/gone.bin"] = nil

        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/gone.bin"], now: Date(timeIntervalSince1970: 0))

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(outcome.removedPaths, ["/scope/gone.bin"])
        XCTAssertEqual(watcher.count, 0)
    }

    func testProtectedPathIsRemovedWithoutEviction() {
        let fs = FakeFS()
        fs.stats["/scope/Keep/c.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4096)

        let watcher = makeWatcher(fakeFS: fs, protectedPatterns: ["Keep"])
        watcher.add(paths: ["/scope/Keep/c.bin"], now: Date(timeIntervalSince1970: 0))

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(outcome.removedPaths, ["/scope/Keep/c.bin"])
        XCTAssertTrue(fs.evictedPaths.isEmpty)
    }

    func testFightingFilesAreFlaggedAfterMaxFights() {
        let fs = FakeFS()
        let watcher = makeWatcher(fakeFS: fs, maxFights: 2)
        watcher.add(paths: ["/scope/fight.bin"], now: Date(timeIntervalSince1970: 0))

        // File keeps rematerializing: after each re-evict, flip it back to resident.
        var sawFighting = false
        for tick in 1...10 {
            fs.stats["/scope/fight.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4096)
            let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: TimeInterval(tick * 120)))
            if !outcome.fightingPaths.isEmpty {
                sawFighting = true
                break
            }
        }
        XCTAssertTrue(sawFighting)
        XCTAssertFalse(watcher.fightingPaths.isEmpty)
    }

    func testLRUCapDropsOldestEntries() {
        let fs = FakeFS()
        let watcher = makeWatcher(fakeFS: fs, maxEntries: 3)
        watcher.add(paths: ["/scope/1", "/scope/2", "/scope/3", "/scope/4"], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(watcher.count, 3)
    }

    func testPersistenceRoundTrip() {
        let fs = FakeFS()
        fs.stats["/scope/p.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0)
        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/p.bin"], now: Date(timeIntervalSince1970: 0))

        let reloaded = makeWatcher(fakeFS: fs)
        XCTAssertEqual(reloaded.count, 1)
    }

    func testFailedReEvictionRetriesSoonWithoutHotLoop() {
        let fs = FakeFS()
        fs.evictSucceeds = false
        fs.stats["/scope/x.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4096)

        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/x.bin"], now: Date(timeIntervalSince1970: 0))

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(outcome.reEvictedPaths.isEmpty)
        XCTAssertEqual(watcher.count, 1) // still watched
    }
}

final class ConfigMigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLegacyConfigMissingKeysIsBackfilledAndPersisted() throws {
        // A config written by an old version: no watchlist_poll_seconds,
        // legacy metadata_watcher_enabled present.
        let legacy = """
        [suppression]
        spotlight = true
        quicklook = true
        materialize_dataless = false

        [watcher]
        metadata_watcher_enabled = false
        backoff_max_seconds = 60
        pollution_check_interval_seconds = 300

        [scope]
        path = "~/Library/Mobile Documents/com~apple~CloudDocs"
        protected_paths = []
        """
        let url = tempDir.appendingPathComponent("config.toml")
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        let config = store.loadMigrating()

        // New keys get defaults — features must never be silently off.
        XCTAssertEqual(config.watcher.watchlistPollSeconds, 10)

        // The file on disk is rewritten without the legacy key.
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("metadata_watcher_enabled"))
        XCTAssertTrue(rewritten.contains("watchlist_poll_seconds"))
    }

    func testMigrationPreservesExplicitValues() throws {
        let url = tempDir.appendingPathComponent("config.toml")
        let store = ConfigStore(configURL: url)
        var config = AppConfig()
        config.policy.targetLocalGiB = 15
        config.policy.trimLocalGiB = 13 // intentionally inconsistent
        config.eviction.batchLimit = 300
        try store.save(config)

        let migrated = ConfigStore(configURL: url).loadMigrating()
        XCTAssertEqual(migrated.policy.targetLocalGiB, 15)
        XCTAssertEqual(migrated.eviction.batchLimit, 300)
        // Normalization is persisted: trim becomes target + 1.
        XCTAssertEqual(migrated.policy.trimLocalGiB, 16)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("trim_local_gib = 16"))
    }

    func testLoadMigratingSeedsMissingFile() throws {
        let url = tempDir.appendingPathComponent("fresh.toml")
        let config = ConfigStore(configURL: url).loadMigrating()
        XCTAssertEqual(config.policy.targetLocalGiB, 5)
        XCTAssertEqual(config.policy.trimLocalGiB, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class TestLogger: GuardLogging {
    var messages: [String] = []
    func log(_ message: String) { messages.append(message) }
}

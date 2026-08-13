import Foundation
import os
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
        var evictionChangesState = true

        private func fallbackIdentity(_ path: String) -> EvictionFileIdentity {
            EvictionFileIdentity(device: 1, inode: UInt64(bitPattern: Int64(path.hashValue)), kind: .regular)
        }

        func stat(_ path: String) -> WatchlistStat? {
            guard let stored = stats[path] ?? nil else { return nil }
            return WatchlistStat(
                isDataless: stored.isDataless,
                allocatedBytes: stored.allocatedBytes,
                isDirectory: stored.isDirectory,
                identity: stored.identity ?? fallbackIdentity(path)
            )
        }

        func evict(_ path: String) -> Bool {
            guard evictSucceeds else { return false }
            evictedPaths.append(path)
            if evictionChangesState {
                stats[path] = WatchlistStat(
                    isDataless: true,
                    allocatedBytes: 0,
                    identity: stat(path)?.identity
                )
            }
            return true
        }
    }

    private func makeWatcher(
        fakeFS: FakeFS,
        maxEntries: Int = 100,
        stableChecksToRemove: Int = 3,
        maxFights: Int = 2,
        protectedPatterns: [String] = [],
        storage: URL? = nil,
        pendingVerificationGraceSeconds: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> WatchlistWatcher {
        WatchlistWatcher(
            storageURL: storage ?? storageURL,
            logger: TestLogger(),
            protectedPaths: ProtectedPathsMatcher(patterns: protectedPatterns),
            scopePath: "/scope",
            maxEntries: maxEntries,
            stableChecksToRemove: stableChecksToRemove,
            maxFights: maxFights,
            backoffMaxSeconds: 60,
            pendingVerificationGraceSeconds: pendingVerificationGraceSeconds,
            statProvider: { fakeFS.stat($0) },
            evict: { fakeFS.evict($0) },
            mutationLockPath: tempDir.appendingPathComponent("run.lock").path,
            now: now
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

    func testPackageReplacementDuringBusyInspectionIsRejectedBeforeWatchlistEviction() throws {
        let path = "/scope/Project.package"
        let identity = EvictionFileIdentity(device: 1, inode: 42, kind: .directory)
        var replaced = false
        var validationCalls = 0
        var evictionCalls = 0
        let watcher = WatchlistWatcher(
            storageURL: storageURL,
            logger: TestLogger(),
            scopePath: "/scope",
            statResultProvider: { _ in .found(WatchlistStat(
                isDataless: false,
                allocatedBytes: 4_096,
                isDirectory: true,
                identity: identity
            )) },
            evict: { _ in evictionCalls += 1; return true },
            mutationValidator: { _, _, _ in
                validationCalls += 1
                return replaced ? "stale-identity" : nil
            },
            inspectBusyPackage: { _ in replaced = true; return .clear },
            mutationLockPath: tempDir.appendingPathComponent("run.lock").path
        )
        XCTAssertTrue(watcher.add(
            paths: [path], identities: [path: identity], now: Date(timeIntervalSince1970: 0)
        ).persisted)

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(validationCalls, 3)
        XCTAssertEqual(evictionCalls, 0)
        XCTAssertTrue(outcome.reEvictedPaths.isEmpty)
        let persisted = try JSONDecoder.withISO8601.decode(
            [WatchlistEntry].self, from: Data(contentsOf: storageURL)
        )
        XCTAssertEqual(persisted.first?.lastError, "stale-identity")
    }

    func testResidentPendingEntryIsObservedWithoutImmediateDuplicateEviction() {
        let fs = FakeFS()
        fs.stats["/scope/pending.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4_096)
        let watcher = makeWatcher(fakeFS: fs, pendingVerificationGraceSeconds: 30)
        watcher.addPending(paths: ["/scope/pending.bin"], now: Date(timeIntervalSince1970: 0))

        let duringGrace = watcher.pollOnce(now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(duringGrace.checked, 1)
        XCTAssertTrue(fs.evictedPaths.isEmpty)

        let beforeRetry = watcher.pollOnce(now: Date(timeIntervalSince1970: 29))
        XCTAssertEqual(beforeRetry.checked, 0)
        XCTAssertTrue(fs.evictedPaths.isEmpty)

        let afterGrace = watcher.pollOnce(now: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(afterGrace.reEvictedPaths, ["/scope/pending.bin"])
        XCTAssertEqual(fs.evictedPaths, ["/scope/pending.bin"])
    }

    func testRepeatedPendingRetriesBackOffThenSuspend() throws {
        let fs = FakeFS()
        fs.evictionChangesState = false
        fs.stats["/scope/stuck.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4_096)
        let watcher = makeWatcher(
            fakeFS: fs,
            maxFights: 2,
            pendingVerificationGraceSeconds: 1
        )
        watcher.addPending(paths: ["/scope/stuck.bin"], now: Date(timeIntervalSince1970: 0))

        _ = watcher.pollOnce(now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(fs.evictedPaths.count, 1)
        XCTAssertEqual(watcher.pollOnce(now: Date(timeIntervalSince1970: 14)).checked, 0)

        let suspended = watcher.pollOnce(now: Date(timeIntervalSince1970: 15))
        XCTAssertEqual(fs.evictedPaths.count, 2)
        XCTAssertEqual(suspended.fightingPaths, ["/scope/stuck.bin"])
        XCTAssertEqual(watcher.pollOnce(now: Date(timeIntervalSince1970: 10_000)).checked, 0)
        XCTAssertEqual(watcher.fightingPaths, ["/scope/stuck.bin"])

        let persisted = try JSONDecoder.withISO8601.decode(
            [WatchlistEntry].self,
            from: Data(contentsOf: storageURL)
        )
        XCTAssertEqual(persisted.first?.pendingRetryCount, 2)
        XCTAssertEqual(persisted.first?.pendingSince, Date(timeIntervalSince1970: 15))
        XCTAssertEqual(persisted.first?.suspended, true)
    }

    func testAddReportsRejectedPathsSeparatelyFromDurability() {
        let watcher = makeWatcher(fakeFS: FakeFS())

        let result = watcher.add(paths: ["/scope/inside.bin", "/outside/rejected.bin"])

        XCTAssertEqual(result.acceptedPaths, ["/scope/inside.bin"])
        XCTAssertEqual(result.rejectedPaths, ["/outside/rejected.bin"])
        XCTAssertTrue(result.persisted)
        XCTAssertFalse(result.allAcceptedAndPersisted)
    }

    func testConstructorContentionCannotEraseConcurrentPendingAddition() throws {
        var owner: AdvisoryFileLock? = try AdvisoryFileLock(path: tempDir.appendingPathComponent("run.lock").path)
        let watcher = makeWatcher(fakeFS: FakeFS())
        XCTAssertEqual(watcher.count, 0)

        let pending = WatchlistEntry(
            path: "/scope/concurrent.bin",
            addedAt: Date(timeIntervalSince1970: 1),
            nextCheckAt: Date(timeIntervalSince1970: 6),
            pendingVerification: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([pending]).write(to: storageURL, options: .atomic)
        owner = nil

        XCTAssertEqual(watcher.refreshPendingPaths(), Set(["/scope/concurrent.bin"]))
        let persisted = try JSONDecoder.withISO8601.decode(
            [WatchlistEntry].self,
            from: Data(contentsOf: storageURL)
        )
        XCTAssertEqual(persisted.map(\.path), ["/scope/concurrent.bin"])
        _ = owner
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

    func testCapRejectsMaxEntriesPlusOneWithoutDroppingDurableEntries() throws {
        let fs = FakeFS()
        let watcher = makeWatcher(fakeFS: fs, maxEntries: 3)
        let result = watcher.add(paths: ["/scope/1", "/scope/2", "/scope/3", "/scope/4"], now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(watcher.count, 3)
        XCTAssertEqual(result.acceptedPaths, ["/scope/1", "/scope/2", "/scope/3"])
        XCTAssertEqual(result.rejectedPaths, ["/scope/4"])
        XCTAssertFalse(result.allAcceptedAndPersisted)
        let persisted = try JSONDecoder.withISO8601.decode([WatchlistEntry].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(persisted.map(\.path), ["/scope/1", "/scope/2", "/scope/3"])
    }

    func testPendingIdentityReplacementIsSuspendedWithoutRetry() {
        let fs = FakeFS()
        let original = EvictionFileIdentity(device: 1, inode: 10, kind: .regular)
        let replacement = EvictionFileIdentity(device: 1, inode: 11, kind: .regular)
        fs.stats["/scope/pending.bin"] = WatchlistStat(
            isDataless: false,
            allocatedBytes: 4_096,
            identity: replacement
        )
        let watcher = makeWatcher(fakeFS: fs)
        watcher.addPending(
            paths: ["/scope/pending.bin"],
            identities: ["/scope/pending.bin": original],
            now: Date(timeIntervalSince1970: 0)
        )

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 6))

        XCTAssertEqual(outcome.fightingPaths, ["/scope/pending.bin"])
        XCTAssertEqual(watcher.count, 1)
        XCTAssertTrue(watcher.snapshot.first?.identityMismatch == true)
        XCTAssertTrue(fs.evictedPaths.isEmpty)
    }

    func testVerifiedWatchedReplacementIsSuspendedAndNeverReEvicted() {
        let fs = FakeFS()
        let original = EvictionFileIdentity(device: 1, inode: 20, kind: .regular)
        fs.stats["/scope/watched.bin"] = WatchlistStat(
            isDataless: false,
            allocatedBytes: 4_096,
            identity: original
        )
        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(
            paths: ["/scope/watched.bin"],
            identities: ["/scope/watched.bin": original],
            now: Date(timeIntervalSince1970: 0)
        )
        fs.stats["/scope/watched.bin"] = WatchlistStat(
            isDataless: false,
            allocatedBytes: 4_096,
            identity: EvictionFileIdentity(device: 1, inode: 21, kind: .regular)
        )

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(outcome.fightingPaths, ["/scope/watched.bin"])
        XCTAssertEqual(watcher.count, 1)
        XCTAssertTrue(watcher.snapshot.first?.identityMismatch == true)
        XCTAssertTrue(fs.evictedPaths.isEmpty)
    }

    func testExplicitNewEvictionUpdatesExistingWatchedIdentity() throws {
        let fs = FakeFS()
        let old = EvictionFileIdentity(device: 1, inode: 30, kind: .regular)
        let current = EvictionFileIdentity(device: 1, inode: 31, kind: .regular)
        fs.stats["/scope/watched.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0, identity: current)
        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/watched.bin"], identities: ["/scope/watched.bin": old])

        XCTAssertTrue(watcher.add(
            paths: ["/scope/watched.bin"],
            identities: ["/scope/watched.bin": current]
        ).allAcceptedAndPersisted)

        let persisted = try JSONDecoder.withISO8601.decode([WatchlistEntry].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(persisted.first?.identity, current)
    }

    func testLegacyIdentityIsEstablishedWithoutMutation() throws {
        let legacy = WatchlistEntry(
            path: "/scope/legacy.bin",
            addedAt: Date(timeIntervalSince1970: 0),
            nextCheckAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacy]).write(to: storageURL)
        let fs = FakeFS()
        fs.stats["/scope/legacy.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4_096)
        let watcher = makeWatcher(fakeFS: fs)

        _ = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))

        XCTAssertTrue(fs.evictedPaths.isEmpty)
        let persisted = try JSONDecoder.withISO8601.decode([WatchlistEntry].self, from: Data(contentsOf: storageURL))
        XCTAssertNotNil(persisted.first?.identity)
    }

    func testPersistenceRoundTrip() {
        let fs = FakeFS()
        fs.stats["/scope/p.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0)
        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/p.bin"], now: Date(timeIntervalSince1970: 0))

        let reloaded = makeWatcher(fakeFS: fs)
        XCTAssertEqual(reloaded.count, 1)
    }

    func testFuturePendingEntrySurvivesClockRollbackWithoutRewriteOrRetry() throws {
        let future = Date(timeIntervalSince1970: 1_000)
        let rolledBack = Date(timeIntervalSince1970: 500)
        let entry = WatchlistEntry(
            path: "/scope/future.bin",
            addedAt: future,
            nextCheckAt: Date(timeIntervalSince1970: 0),
            pendingVerification: true,
            pendingSince: future,
            requestTimestamp: future
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(to: storageURL)
        let persistedBefore = try Data(contentsOf: storageURL)
        let fs = FakeFS()
        fs.stats["/scope/future.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4_096)

        let watcher = makeWatcher(fakeFS: fs, now: { rolledBack })
        let outcome = watcher.pollOnce(now: rolledBack)

        XCTAssertEqual(watcher.count, 1)
        XCTAssertEqual(watcher.snapshot.first?.pendingVerification, true)
        XCTAssertGreaterThanOrEqual(watcher.snapshot.first?.nextCheckAt ?? .distantPast, future)
        XCTAssertEqual(outcome.checked, 0)
        XCTAssertTrue(fs.evictedPaths.isEmpty)
        XCTAssertFalse(watcher.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: storageURL), persistedBefore)
    }

    func testFutureVerifiedEntrySurvivesClockRollbackWithoutRewriteOrPrune() throws {
        let future = Date(timeIntervalSince1970: 1_000)
        let rolledBack = Date(timeIntervalSince1970: 500)
        let entry = WatchlistEntry(
            path: "/scope/future-verified.bin",
            addedAt: Date(timeIntervalSince1970: 0),
            stableDatalessChecks: 3,
            nextCheckAt: Date(timeIntervalSince1970: 0),
            requestTimestamp: future,
            verifiedAt: future
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(to: storageURL)
        let persistedBefore = try Data(contentsOf: storageURL)
        let fs = FakeFS()
        fs.stats["/scope/future-verified.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0)

        let watcher = makeWatcher(fakeFS: fs, now: { rolledBack })
        let outcome = watcher.pollOnce(now: rolledBack)

        XCTAssertEqual(watcher.count, 1)
        XCTAssertEqual(watcher.snapshot.first?.verifiedAt, future)
        XCTAssertGreaterThanOrEqual(watcher.snapshot.first?.nextCheckAt ?? .distantPast, future)
        XCTAssertEqual(outcome.checked, 0)
        XCTAssertTrue(outcome.removedPaths.isEmpty)
        XCTAssertFalse(watcher.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: storageURL), persistedBefore)
    }

    func testStaleWatcherDoesNotEraseNewPendingPath() throws {
        let fs = FakeFS()
        fs.stats["/scope/existing.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0)
        fs.stats["/scope/pending.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4_096)
        let staleWatcher = makeWatcher(fakeFS: fs)
        let cliWatcher = makeWatcher(fakeFS: fs)

        XCTAssertTrue(cliWatcher.addPending(paths: ["/scope/pending.bin"], now: Date(timeIntervalSince1970: 0)).allAcceptedAndPersisted)
        XCTAssertTrue(staleWatcher.add(paths: ["/scope/existing.bin"], now: Date(timeIntervalSince1970: 1)).allAcceptedAndPersisted)

        let persisted = try JSONDecoder.withISO8601.decode(
            [WatchlistEntry].self,
            from: Data(contentsOf: storageURL)
        )
        XCTAssertEqual(Set(persisted.map(\.path)), Set(["/scope/existing.bin", "/scope/pending.bin"]))
        XCTAssertEqual(persisted.first { $0.path == "/scope/pending.bin" }?.pendingVerification, true)
    }

    func testEqualGenerationPersistedIdentityWinsDespiteOlderTimestamp() throws {
        let fs = FakeFS()
        let old = EvictionFileIdentity(device: 1, inode: 40, kind: .regular)
        let current = EvictionFileIdentity(device: 1, inode: 41, kind: .regular)
        fs.stats["/scope/watched.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0, identity: current)
        let blockingParent = tempDir.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingParent)
        let sharedStorage = blockingParent.appendingPathComponent("watchlist.json")
        let staleWatcher = makeWatcher(fakeFS: fs, storage: sharedStorage)

        XCTAssertFalse(staleWatcher.add(
            paths: ["/scope/watched.bin"],
            identities: ["/scope/watched.bin": old],
            now: Date(timeIntervalSince1970: 2)
        ).persisted)
        try FileManager.default.removeItem(at: blockingParent)
        try FileManager.default.createDirectory(at: blockingParent, withIntermediateDirectories: false)
        let currentWatcher = makeWatcher(fakeFS: fs, storage: sharedStorage)
        XCTAssertTrue(currentWatcher.add(
            paths: ["/scope/watched.bin"],
            identities: ["/scope/watched.bin": current],
            now: Date(timeIntervalSince1970: 1)
        ).allAcceptedAndPersisted)

        let outcome = staleWatcher.pollOnce(now: Date(timeIntervalSince1970: 3))

        XCTAssertTrue(outcome.removedPaths.isEmpty)
        XCTAssertTrue(fs.evictedPaths.isEmpty)
        let persisted = try JSONDecoder.withISO8601.decode(
            [WatchlistEntry].self,
            from: Data(contentsOf: sharedStorage)
        )
        XCTAssertEqual(persisted.first?.identity, current)
        XCTAssertEqual(persisted.first?.requestGeneration, 1)
        XCTAssertEqual(persisted.first?.requestTimestamp, Date(timeIntervalSince1970: 1))
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

    func testSuccessfulAPIWithoutDatalessPostconditionIsNotReEvicted() {
        let fs = FakeFS()
        fs.evictionChangesState = false
        fs.stats["/scope/pending.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4096)
        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/pending.bin"], now: Date(timeIntervalSince1970: 0))

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))

        XCTAssertTrue(outcome.reEvictedPaths.isEmpty)
        XCTAssertEqual(fs.evictedPaths, ["/scope/pending.bin"])
        XCTAssertTrue(watcher.fightingPaths.isEmpty)

        let duringGrace = watcher.pollOnce(now: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(duringGrace.checked, 0)
        XCTAssertEqual(fs.evictedPaths, ["/scope/pending.bin"])
    }

    func testPendingEntryIsVerifiedLaterWithoutAnotherMutation() {
        let fs = FakeFS()
        fs.stats["/scope/pending.bin"] = WatchlistStat(isDataless: true, allocatedBytes: 0)
        let watcher = makeWatcher(fakeFS: fs)
        watcher.addPending(paths: ["/scope/pending.bin"], now: Date(timeIntervalSince1970: 0))

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 6))

        XCTAssertEqual(outcome.verifiedPendingPaths, ["/scope/pending.bin"])
        XCTAssertTrue(fs.evictedPaths.isEmpty)
        XCTAssertEqual(watcher.count, 1)
    }

    func testStatFailureRetainsEntryInsteadOfTreatingItAsVanished() {
        let watcher = WatchlistWatcher(
            storageURL: storageURL,
            logger: TestLogger(),
            scopePath: "/scope",
            statResultProvider: { _ in .failed("permission") },
            evict: { _ in XCTFail("must not mutate after a stat error"); return false },
            mutationLockPath: tempDir.appendingPathComponent("run.lock").path
        )
        watcher.add(paths: ["/scope/unreadable.bin"], now: Date(timeIntervalSince1970: 0))

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))

        XCTAssertTrue(outcome.removedPaths.isEmpty)
        XCTAssertEqual(watcher.count, 1)
    }

    func testAdvisoryLockContentionPreventsCrossOwnerReEviction() throws {
        let fs = FakeFS()
        fs.stats["/scope/a.bin"] = WatchlistStat(isDataless: false, allocatedBytes: 4096)
        let lockPath = tempDir.appendingPathComponent("run.lock").path
        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/a.bin"], now: Date(timeIntervalSince1970: 0))
        let owner = try AdvisoryFileLock(path: lockPath)

        let outcome = watcher.pollOnce(now: Date(timeIntervalSince1970: 1))

        XCTAssertTrue(outcome.reEvictedPaths.isEmpty)
        XCTAssertTrue(fs.evictedPaths.isEmpty)
        XCTAssertEqual(watcher.count, 1)
        withExtendedLifetime(owner) {}
    }

    func testLoadedUnresolvedWatchlistIsPreservedWhenCapacityCannotPruneSafely() throws {
        let entries = (0..<5).map {
            WatchlistEntry(path: "/scope/\($0).bin", addedAt: .distantPast, nextCheckAt: .distantFuture)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: storageURL)

        let watcher = makeWatcher(fakeFS: FakeFS(), maxEntries: 2)

        XCTAssertEqual(watcher.count, 5)
        let persisted = try JSONDecoder.withISO8601.decode([WatchlistEntry].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(persisted.map(\.path), entries.map(\.path))
    }

    func testCapacityPrunesOnlyOldStableVerifiedEntries() throws {
        let old = Date(timeIntervalSince1970: 100)
        let entries = [
            WatchlistEntry(path: "/scope/pending.bin", addedAt: old, nextCheckAt: old, pendingVerification: true),
            WatchlistEntry(path: "/scope/mismatch.bin", addedAt: old, stableDatalessChecks: 3, nextCheckAt: old, verifiedAt: old, identityMismatch: true),
            WatchlistEntry(path: "/scope/verified-1.bin", addedAt: old, stableDatalessChecks: 3, nextCheckAt: old, verifiedAt: old),
            WatchlistEntry(path: "/scope/verified-2.bin", addedAt: old, stableDatalessChecks: 3, nextCheckAt: old, verifiedAt: old),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: storageURL)

        let watcher = makeWatcher(fakeFS: FakeFS(), maxEntries: 2)

        XCTAssertEqual(Set(watcher.snapshot.map(\.path)), Set(["/scope/pending.bin", "/scope/mismatch.bin"]))
        XCTAssertEqual(Set(watcher.lastRetentionReport.prunedPaths), Set(["/scope/verified-1.bin", "/scope/verified-2.bin"]))
    }

    func testCorruptWatchlistIsPreservedAndReported() throws {
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: storageURL)

        let watcher = makeWatcher(fakeFS: FakeFS())

        XCTAssertNotNil(watcher.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: storageURL), corrupt)
    }

    func testOversizedWatchlistIsPreservedAndRejectedBeforeDecode() throws {
        let oversized = Data(repeating: 0x20, count: Int(WatchlistStorage.maximumBytes + 1))
        try oversized.write(to: storageURL)

        let watcher = makeWatcher(fakeFS: FakeFS())

        XCTAssertEqual(watcher.count, 0)
        XCTAssertTrue(watcher.lastPersistenceError?.contains("watchlist-too-large") == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, UInt64(oversized.count))
        XCTAssertThrowsError(try WatchlistInspectionService.loadEntries(storageURL: storageURL, scopePath: "/scope"))
    }

    func testPathsOutsideScopeAreRejectedOnAddAndLoad() throws {
        let fs = FakeFS()
        let entries = [
            WatchlistEntry(path: "/scope/inside.bin", addedAt: .distantPast, nextCheckAt: .distantFuture),
            WatchlistEntry(path: "/outside/escape.bin", addedAt: .distantPast, nextCheckAt: .distantFuture),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: storageURL)

        let watcher = makeWatcher(fakeFS: fs)
        watcher.add(paths: ["/scope/../outside/traversal.bin"])

        XCTAssertEqual(watcher.count, 1)
        let persisted = try JSONDecoder.withISO8601.decode([WatchlistEntry].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(persisted.map(\.path), ["/scope/inside.bin"])
    }

    func testUnreadableInitialStorageFailsClosedUntilWatcherIsRecreated() throws {
        let fs = FakeFS()
        let blockingParent = tempDir.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingParent)
        let failedStorage = blockingParent.appendingPathComponent("watchlist.json")
        let watcher = makeWatcher(fakeFS: fs, storage: failedStorage)

        let rejected = watcher.addPending(paths: ["/scope/a.bin"], now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(rejected.persisted)
        XCTAssertFalse(watcher.hasUnsavedChanges)
        XCTAssertEqual(watcher.count, 0)
        guard case .failed = watcher.loadHealth else {
            return XCTFail("unreadable initial storage must be an explicit load failure")
        }

        try FileManager.default.removeItem(at: blockingParent)
        try FileManager.default.createDirectory(at: blockingParent, withIntermediateDirectories: false)
        let retry = watcher.addPending(paths: ["/scope/a.bin"], now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(retry.persisted, "a failed load must not become success-shaped after the path changes")

        let recovered = makeWatcher(fakeFS: fs, storage: failedStorage)
        XCTAssertTrue(recovered.addPending(paths: ["/scope/a.bin"], now: Date(timeIntervalSince1970: 0)).persisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedStorage.path))
    }

    func testStopDuringBlockedPollPreventsReEvictionMutation() {
        let statStarted = DispatchSemaphore(value: 0)
        let releaseStat = DispatchSemaphore(value: 0)
        let evictionCount = OSAllocatedUnfairLock(initialState: 0)
        let identity = EvictionFileIdentity(device: 1, inode: 42, kind: .regular)
        let watcher = WatchlistWatcher(
            storageURL: storageURL,
            logger: TestLogger(),
            scopePath: "/scope",
            statResultProvider: { _ in
                statStarted.signal()
                releaseStat.wait()
                return .found(WatchlistStat(
                    isDataless: false,
                    allocatedBytes: 4_096,
                    identity: identity
                ))
            },
            evict: { _ in
                evictionCount.withLock { $0 += 1 }
                return true
            },
            mutationLockPath: tempDir.appendingPathComponent("run.lock").path
        )
        _ = watcher.add(
            paths: ["/scope/blocked.bin"],
            identities: ["/scope/blocked.bin": identity],
            now: .distantPast
        )
        watcher.start(intervalSeconds: 1)
        XCTAssertEqual(statStarted.wait(timeout: .now() + 3), .success)

        let stopStarted = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let releaseCompleted = DispatchSemaphore(value: 0)
        let returnedBeforeRelease = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .utility).async {
            stopStarted.wait()
            let returned = stopReturned.wait(timeout: .now() + 0.1) == .success
            returnedBeforeRelease.withLock { $0 = returned }
            releaseStat.signal()
            releaseCompleted.signal()
        }
        stopStarted.signal()
        watcher.stop()
        stopReturned.signal()
        XCTAssertEqual(releaseCompleted.wait(timeout: .now() + 3), .success)

        XCTAssertFalse(returnedBeforeRelease.withLock { $0 })
        XCTAssertEqual(evictionCount.withLock { $0 }, 0)
    }

    func testStopFencesBlockedFoundResultBeforeAnyMutation() throws {
        try assertStopFencesBlockedPoll(result: .found(WatchlistStat(
            isDataless: false,
            allocatedBytes: 4_096,
            identity: .init(device: 1, inode: 700, kind: .regular)
        )))
    }

    func testStopFencesBlockedVanishedResultBeforeRemovalOrPersistence() throws {
        try assertStopFencesBlockedPoll(result: .vanished)
    }

    func testStopFencesBlockedFailedResultBeforeRetryPersistence() throws {
        try assertStopFencesBlockedPoll(result: .failed("metadata unavailable"))
    }

    func testStopWinsBarrierImmediatelyBeforeEvictionAndPersistence() throws {
        try assertStopFencesBlockedPoll(
            result: .found(WatchlistStat(
                isDataless: false,
                allocatedBytes: 4_096,
                identity: .init(device: 1, inode: 701, kind: .regular)
            )),
            blockBeforeMutation: true
        )
    }

    func testStopWinsFoundCommitBarrierBeforeIdentityMismatchRemoval() throws {
        let original = EvictionFileIdentity(device: 1, inode: 800, kind: .regular)
        try assertStopFencesBlockedPoll(
            result: .found(WatchlistStat(
                isDataless: false,
                allocatedBytes: 4_096,
                identity: .init(device: 1, inode: 801, kind: .regular)
            )),
            blockBeforeMutation: true,
            initialEntry: stopFenceEntry(identity: original)
        )
    }

    func testStopWinsFoundCommitBarrierBeforeLegacyIdentityEstablishment() throws {
        try assertStopFencesBlockedPoll(
            result: .found(WatchlistStat(
                isDataless: false,
                allocatedBytes: 4_096,
                identity: .init(device: 1, inode: 802, kind: .regular)
            )),
            blockBeforeMutation: true,
            initialEntry: stopFenceEntry(identity: nil)
        )
    }

    func testStopWinsFoundCommitBarrierBeforeDatalessRemoval() throws {
        let identity = EvictionFileIdentity(device: 1, inode: 803, kind: .regular)
        try assertStopFencesBlockedPoll(
            result: .found(WatchlistStat(isDataless: true, allocatedBytes: 0, identity: identity)),
            blockBeforeMutation: true,
            initialEntry: stopFenceEntry(identity: identity, stableDatalessChecks: 11)
        )
    }

    func testStopWinsFoundCommitBarrierBeforePendingGraceUpdate() throws {
        let identity = EvictionFileIdentity(device: 1, inode: 804, kind: .regular)
        try assertStopFencesBlockedPoll(
            result: .found(WatchlistStat(isDataless: false, allocatedBytes: 4_096, identity: identity)),
            blockBeforeMutation: true,
            initialEntry: stopFenceEntry(
                identity: identity,
                pendingVerification: true,
                pendingSince: Date().addingTimeInterval(-5)
            )
        )
    }

    private func stopFenceEntry(
        identity: EvictionFileIdentity?,
        stableDatalessChecks: Int = 0,
        pendingVerification: Bool = false,
        pendingSince: Date? = nil
    ) -> WatchlistEntry {
        WatchlistEntry(
            path: "/scope/blocked.bin",
            addedAt: Date().addingTimeInterval(-10),
            stableDatalessChecks: stableDatalessChecks,
            nextCheckAt: .distantPast,
            pendingVerification: pendingVerification,
            pendingSince: pendingSince,
            identity: identity
        )
    }

    private func assertStopFencesBlockedPoll(
        result: WatchlistStatResult,
        blockBeforeMutation: Bool = false,
        initialEntry: WatchlistEntry? = nil
    ) throws {
        let caseStorage = tempDir.appendingPathComponent("stop-fence-\(UUID().uuidString).json")
        let providerEntered = DispatchSemaphore(value: 0)
        let releaseProvider = DispatchSemaphore(value: 0)
        let mutationEntered = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        let stopStarted = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let releaseCompleted = DispatchSemaphore(value: 0)
        let returnedBeforeRelease = OSAllocatedUnfairLock(initialState: false)
        let evictions = OSAllocatedUnfairLock(initialState: 0)
        let callbacks = OSAllocatedUnfairLock(initialState: 0)
        let identity: EvictionFileIdentity
        if case .found(let stat) = result, let foundIdentity = stat.identity {
            identity = foundIdentity
        } else {
            identity = EvictionFileIdentity(device: 1, inode: 700, kind: .regular)
        }
        let mutationBarrier: (@Sendable () -> Void)?
        if blockBeforeMutation {
            mutationBarrier = {
                mutationEntered.signal()
                releaseMutation.wait()
            }
        } else {
            mutationBarrier = nil
        }
        if let initialEntry {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([initialEntry]).write(to: caseStorage)
        }
        let watcher = WatchlistWatcher(
            storageURL: caseStorage,
            logger: TestLogger(),
            scopePath: "/scope",
            statResultProvider: { _ in
                if !blockBeforeMutation {
                    providerEntered.signal()
                    releaseProvider.wait()
                }
                return result
            },
            evict: { _ in
                evictions.withLock { $0 += 1 }
                return true
            },
            beforeMutation: mutationBarrier,
            mutationLockPath: tempDir.appendingPathComponent("run.lock").path
        )
        if initialEntry == nil {
            XCTAssertTrue(watcher.add(
                paths: ["/scope/blocked.bin"],
                identities: ["/scope/blocked.bin": identity],
                now: Date.distantPast
            ).persisted)
        }
        let persistedBefore = try Data(contentsOf: caseStorage)
        watcher.onRematerialization = { (_: [String]) in callbacks.withLock { $0 += 1 } }
        watcher.onFighting = { (_: [String]) in callbacks.withLock { $0 += 1 } }
        watcher.onCountChange = { (_: Int) in callbacks.withLock { $0 += 1 } }
        watcher.start(intervalSeconds: 1)
        XCTAssertEqual(
            (blockBeforeMutation ? mutationEntered : providerEntered).wait(timeout: .now() + 3),
            .success
        )

        DispatchQueue.global(qos: .utility).async {
            stopStarted.wait()
            let returned = stopReturned.wait(timeout: .now() + 0.1) == .success
            returnedBeforeRelease.withLock { $0 = returned }
            if blockBeforeMutation { releaseMutation.signal() } else { releaseProvider.signal() }
            releaseCompleted.signal()
        }
        stopStarted.signal()
        watcher.stop()
        stopReturned.signal()
        XCTAssertEqual(releaseCompleted.wait(timeout: .now() + 3), .success)

        XCTAssertFalse(returnedBeforeRelease.withLock { $0 })
        XCTAssertEqual(evictions.withLock { $0 }, 0)
        XCTAssertEqual(watcher.count, 1)
        XCTAssertFalse(watcher.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: caseStorage), persistedBefore)
        XCTAssertEqual(callbacks.withLock { $0 }, 0)
        watcher.start(intervalSeconds: 1)
        watcher.stop()
        XCTAssertFalse(watcher.hasUnsavedChanges, "resume must not inherit a cancelled poll's dirty commit")
    }
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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

        // Migration is non-destructive: the legacy key remains for older
        // versions while current defaults are added alongside it.
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("metadata_watcher_enabled = false"))
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

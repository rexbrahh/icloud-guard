import Foundation
import Darwin
import XCTest
@testable import ICloudGuardCore

final class GuardRunnerTests: XCTestCase {
    func testLockedStateUpdatePreservesNewerReceiptAndCooldown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(statePath: root.appendingPathComponent("state.json").path)
        let receipt = GuardRunSummary(
            timestamp: Date(timeIntervalSince1970: 10),
            action: .targeted,
            reason: "cli",
            dryRun: false,
            candidateCount: 1,
            evictedCount: 1,
            failedEvictionCount: 0,
            reclaimedBytes: 4_096,
            remainingLocalBytes: 0,
            remainingFreeBytes: 1,
            postScanComplete: true,
            freeSpaceAvailable: true,
            escalatedToPanic: false
        )
        try store.save(GuardState(
            lastRemediationAt: Date(timeIntervalSince1970: 10),
            lastSummary: receipt
        ))

        _ = try store.update { latest in
            latest.samples.append(GuardSample(
                timestamp: Date(timeIntervalSince1970: 20),
                localBytes: 2,
                freeBytes: 3
            ))
        }

        let result = try store.load()
        XCTAssertEqual(result.lastRemediationAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(result.lastSummary, receipt)
        XCTAssertEqual(result.samples.count, 1)
    }

    func testAdvisoryFileLockExcludesSecondOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = root.appendingPathComponent("instance.lock").path
        let first = try AdvisoryFileLock(path: path)
        try first.writeOwnerPID()

        XCTAssertThrowsError(try AdvisoryFileLock(path: path)) { error in
            XCTAssertEqual(error as? AdvisoryFileLock.LockError, .unavailable)
        }
        _ = first
    }

    func testAdvisoryFileLockExplicitUnlockAllowsNextOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = root.appendingPathComponent("instance.lock").path
        let first = try AdvisoryFileLock(path: path)
        first.unlock()

        let second = try AdvisoryFileLock(path: path)
        XCTAssertNoThrow(try second.writeOwnerPID())
    }

    func testAdvisoryFileLockRejectsSymlinkWithoutTouchingVictim() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("victim.txt")
        let lockPath = root.appendingPathComponent("run.lock")
        try Data("do-not-truncate".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: victim)

        XCTAssertThrowsError(try AdvisoryFileLock(path: lockPath.path)) { error in
            guard case AdvisoryFileLock.LockError.system = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "do-not-truncate")
    }

    func testAdvisoryFileLockRejectsFIFOWithoutBlockingOrWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-fifo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fifo = root.appendingPathComponent("run.lock")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()

        XCTAssertThrowsError(try AdvisoryFileLock(path: fifo.path)) { error in
            XCTAssertEqual(error as? AdvisoryFileLock.LockError, .system(EINVAL))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testStatusReturnsTemporaryFailureDuringMutationLockContention() throws {
        let sandbox = try makeSandbox()
        let activeLock = try AdvisoryFileLock(path: sandbox.lockURL.path)

        let exitCode = try GuardRunner().run(
            command: .status,
            configPath: sandbox.configURL.path,
            dryRun: false
        )

        XCTAssertEqual(exitCode, 75)
        _ = activeLock
    }

    func testRunIgnoresStaleLockContentsAndClearsActiveState() throws {
        let sandbox = try makeSandbox()
        let runner = GuardRunner()
        let deadPID: Int32 = 999_999

        try "\(deadPID)\n".write(to: sandbox.lockURL, atomically: true, encoding: .utf8)
        try saveState(
            GuardState(activeLock: ActiveLock(pid: deadPID, startedAt: Date(timeIntervalSince1970: 0))),
            to: sandbox.stateURL
        )

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: true)
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.lockURL.path))

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertNil(state.activeLock)
        XCTAssertEqual(state.lastSummary?.action, GuardDecisionKind.none)
        XCTAssertEqual(state.samples.count, 1)
    }

    func testRunReturnsNonzeroForAdvisoryLockContention() throws {
        let sandbox = try makeSandbox()
        let runner = GuardRunner()
        let currentPID = getpid()

        let activeFileLock = try AdvisoryFileLock(path: sandbox.lockURL.path)
        try activeFileLock.writeOwnerPID(currentPID)
        try saveState(
            GuardState(activeLock: ActiveLock(pid: currentPID, startedAt: Date())),
            to: sandbox.stateURL
        )

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: true)
        XCTAssertEqual(exitCode, 75)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.lockURL.path))

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertNotNil(state.activeLock)
        XCTAssertNil(state.lastLockContentionAt)
        XCTAssertNil(state.lastSummary)
        _ = activeFileLock
    }

    func testStatusScansAndReportsDecision() throws {
        let sandbox = try makeSandbox()
        let runner = GuardRunner()
        let residentFileURL = sandbox.rootURL
            .appendingPathComponent("CloudDocs", isDirectory: true)
            .appendingPathComponent("resident.bin")

        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)

        let exitCode = try runner.run(command: .status, configPath: sandbox.configURL.path, dryRun: false)
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.lockURL.path))

        let log = try String(contentsOf: sandbox.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("scan-start command=status"))
        XCTAssertTrue(log.contains("scan-complete local="))
    }

    func testDryRunCollectsCandidatesWithoutEvicting() throws {
        let sandbox = try makeSandbox()
        let runner = GuardRunner()
        let residentFileURL = sandbox.rootURL
            .appendingPathComponent("CloudDocs", isDirectory: true)
            .appendingPathComponent("resident.bin")

        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)

        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: true)
        XCTAssertEqual(exitCode, 0)

        let log = try String(contentsOf: sandbox.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("candidates count=1"))

        // Dry run: the file must still be there, untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: residentFileURL.path))
    }

    func testRunThrowsWhenScopeUnreachable() throws {
        let sandbox = try makeSandbox()
        var config = try loadConfig(from: sandbox.configURL)
        config.scope.path = sandbox.rootURL.appendingPathComponent("DoesNotExist").path
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        let runner = GuardRunner()
        XCTAssertThrowsError(try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false))

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertNil(state.activeLock)
        XCTAssertNil(state.lastSummary)
    }

    func testRunRecordsFailedEvictionCountWhenProviderRefusesEviction() throws {
        let sandbox = try makeSandbox()
        // A sandbox file is not iCloud-ubiquitous, so evictUbiquitousItem
        // refuses it — exercising real failure accounting end to end.
        let residentFileURL = sandbox.rootURL
            .appendingPathComponent("CloudDocs", isDirectory: true)
            .appendingPathComponent("resident.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)

        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        let runner = GuardRunner()
        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false)
        XCTAssertEqual(exitCode, 1)

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertEqual(state.lastSummary?.action, .targeted)
        XCTAssertEqual(state.lastSummary?.candidateCount, 1)
        XCTAssertEqual(state.lastSummary?.evictedCount, 0)
        XCTAssertEqual(state.lastSummary?.failedEvictionCount, 1)
        XCTAssertNil(state.lastRemediationAt)
        XCTAssertEqual(state.lastSummary?.postScanComplete, false)

        let log = try String(contentsOf: sandbox.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("failed=1"))
    }

    func testVerifiedRemediationPersistsPostRunStatsAndStartsCooldown() throws {
        let sandbox = try makeSandbox()
        let residentFileURL = sandbox.rootURL
            .appendingPathComponent("CloudDocs", isDirectory: true)
            .appendingPathComponent("resident.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)

        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        let runner = GuardRunner(engineFactory: { logger in
            EvictionEngine(
                logger: logger,
                evictItem: { try Data().write(to: $0) },
                footprint: EvictionFootprint.measure
            )
        })
        XCTAssertEqual(try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false), 0)

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertEqual(state.lastSummary?.evictedCount, 1)
        XCTAssertEqual(state.lastSummary?.remainingLocalBytes, 0)
        XCTAssertEqual(state.lastSummary?.postScanComplete, true)
        XCTAssertNotNil(state.lastRemediationAt)
    }

    func testPartialCancellationPersistsVerifiedEvictionWithoutStartingCooldown() throws {
        let sandbox = try makeSandbox()
        let scopeURL = sandbox.rootURL.appendingPathComponent("CloudDocs", isDirectory: true)
        try Data(repeating: 0x41, count: 4_096).write(to: scopeURL.appendingPathComponent("first.bin"))
        try Data(repeating: 0x42, count: 4_096).write(to: scopeURL.appendingPathComponent("second.bin"))
        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)
        let cancellation = EvictionCancellation()
        let runner = GuardRunner(
            engineFactory: { logger in
                EvictionEngine(
                    logger: logger,
                    evictItem: { url in
                        try Data().write(to: url)
                        cancellation.cancel()
                    },
                    footprint: EvictionFootprint.measure
                )
            },
            cancellation: cancellation
        )

        XCTAssertEqual(try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false), 130)

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertEqual(state.lastSummary?.evictedCount, 1)
        XCTAssertEqual(state.lastSummary?.reclaimedBytes, 4_096)
        XCTAssertNil(state.lastRemediationAt)
    }

    func testTargetedDryRunPersistsTruthfulReceipt() throws {
        let sandbox = try makeSandbox()
        let residentFileURL = sandbox.rootURL
            .appendingPathComponent("CloudDocs", isDirectory: true)
            .appendingPathComponent("resident.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)
        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        XCTAssertEqual(try GuardRunner().run(command: .run, configPath: sandbox.configURL.path, dryRun: true), 0)

        let summary = try loadState(from: sandbox.stateURL).lastSummary
        XCTAssertEqual(summary?.action, .targeted)
        XCTAssertEqual(summary?.dryRun, true)
        XCTAssertEqual(summary?.candidateCount, 1)
        XCTAssertEqual(summary?.evictedCount, 0)
        XCTAssertEqual(summary?.postScanComplete, true)
    }

    func testFullWatchlistMakesRunnerFailReceiptInsteadOfDroppingDurableEntry() throws {
        let sandbox = try makeSandbox()
        let scopeURL = sandbox.rootURL.appendingPathComponent("CloudDocs", isDirectory: true)
        let residentFileURL = scopeURL.appendingPathComponent("resident.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)
        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        let existing = (0..<WatchlistWatcher.defaultMaxEntries).map {
            WatchlistEntry(
                path: scopeURL.appendingPathComponent("existing-\($0).bin").path,
                addedAt: Date(timeIntervalSince1970: 0),
                nextCheckAt: .distantFuture
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(existing).write(to: sandbox.rootURL.appendingPathComponent("watchlist.json"))

        let runner = GuardRunner(engineFactory: { logger in
            EvictionEngine(
                logger: logger,
                evictItem: { try Data().write(to: $0) },
                footprint: EvictionFootprint.measure
            )
        })
        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false)

        XCTAssertEqual(exitCode, 74)
        let summary = try loadState(from: sandbox.stateURL).lastSummary
        XCTAssertEqual(summary?.action, .targeted)
        XCTAssertEqual(summary?.evictedCount, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            [WatchlistEntry].self,
            from: Data(contentsOf: sandbox.rootURL.appendingPathComponent("watchlist.json"))
        )
        XCTAssertEqual(persisted.count, WatchlistWatcher.defaultMaxEntries)
        XCTAssertFalse(persisted.contains { $0.path == residentFileURL.path })
    }

    func testPostMutationStateSaveFailureReturnsSoftwareErrorAndLogsTruthfulReceipt() throws {
        let sandbox = try makeSandbox()
        let residentFileURL = sandbox.rootURL
            .appendingPathComponent("CloudDocs", isDirectory: true)
            .appendingPathComponent("resident.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)

        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        let runner = GuardRunner(engineFactory: { logger in
            EvictionEngine(
                logger: logger,
                evictItem: { url in
                    try Data().write(to: url)
                    XCTAssertEqual(chmod(sandbox.rootURL.path, 0o500), 0)
                },
                footprint: EvictionFootprint.measure
            )
        })
        defer { _ = chmod(sandbox.rootURL.path, 0o700) }

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false)

        XCTAssertEqual(exitCode, 74)
        let log = try String(contentsOf: sandbox.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("receipt-save-failed action=targeted evicted=1"))
        XCTAssertTrue(log.contains("reclaimed=4096"))
    }

    func testPostScanFailurePersistsUnknownTruthFlagsAndReturnsNonzero() throws {
        let sandbox = try makeSandbox()
        let scopeURL = sandbox.rootURL.appendingPathComponent("CloudDocs", isDirectory: true)
        let movedScopeURL = sandbox.rootURL.appendingPathComponent("CloudDocs-moved", isDirectory: true)
        let residentFileURL = scopeURL.appendingPathComponent("resident.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: residentFileURL)

        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        var measurements = [
            EvictionFootprint(allocatedBytes: 4_096, isDataless: false),
            EvictionFootprint(allocatedBytes: 0, isDataless: false),
        ]
        let runner = GuardRunner(engineFactory: { logger in
            EvictionEngine(
                logger: logger,
                evictItem: { _ in try FileManager.default.moveItem(at: scopeURL, to: movedScopeURL) },
                footprint: { _ in measurements.removeFirst() }
            )
        })
        defer {
            if FileManager.default.fileExists(atPath: movedScopeURL.path) {
                try? FileManager.default.moveItem(at: movedScopeURL, to: scopeURL)
            }
        }

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false)

        XCTAssertEqual(exitCode, 65)
        let state = try loadState(from: sandbox.stateURL)
        XCTAssertEqual(state.lastSummary?.evictedCount, 1)
        XCTAssertEqual(state.lastSummary?.reclaimedBytes, 4_096)
        XCTAssertEqual(state.lastSummary?.postScanComplete, false)
        XCTAssertEqual(state.lastSummary?.freeSpaceAvailable, false)
        let log = try String(contentsOf: sandbox.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("post-run-scan-failed"))
    }

    func testLegacyStateSummaryMissingFailedEvictionCountStillRuns() throws {
        let sandbox = try makeSandbox()
        let runner = GuardRunner()
        let legacyState = """
        {
          "lastSummary": {
            "action": "none",
            "candidateCount": 0,
            "dryRun": false,
            "escalatedToPanic": false,
            "evictedCount": 0,
            "reason": "healthy",
            "reclaimedBytes": 0,
            "remainingFreeBytes": 183316472448,
            "remainingLocalBytes": 476770304,
            "timestamp": "2026-03-30T23:55:31Z"
          },
          "samples": []
        }
        """
        try legacyState.write(to: sandbox.stateURL, atomically: true, encoding: .utf8)

        let decodedState = try loadState(from: sandbox.stateURL)
        XCTAssertEqual(decodedState.lastSummary?.failedEvictionCount, 0)
        XCTAssertEqual(decodedState.lastSummary?.pendingEvictionCount, 0)
        XCTAssertEqual(decodedState.lastSummary?.postScanComplete, false)
        XCTAssertEqual(decodedState.lastSummary?.freeSpaceAvailable, false)

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: true)
        XCTAssertEqual(exitCode, 0)
    }

    func testRemediationMigratesPreRunLegacySummaryBeforeCurrentReceipt() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.rootURL) }
        let legacy = GuardRunSummary(
            timestamp: Date(timeIntervalSince1970: 10),
            action: .targeted,
            reason: "pre-run legacy",
            dryRun: false,
            candidateCount: 1,
            evictedCount: 1,
            failedEvictionCount: 0,
            reclaimedBytes: 4_096,
            remainingLocalBytes: 0,
            remainingFreeBytes: 1,
            postScanComplete: true,
            freeSpaceAvailable: true,
            escalatedToPanic: false
        )
        try saveState(GuardState(lastSummary: legacy), to: sandbox.stateURL)

        XCTAssertEqual(try GuardRunner().run(command: .run, configPath: sandbox.configURL.path, dryRun: true), 0)

        let receipts = try RunHistoryStore(url: sandbox.rootURL.appendingPathComponent("history.json")).load()
        XCTAssertEqual(receipts.filter { $0.trigger == .legacy && $0.reason == "pre-run legacy" }.count, 1)
        XCTAssertEqual(receipts.filter { $0.trigger == .cli && $0.command == GuardCommand.run.rawValue }.count, 1)
        XCTAssertEqual(receipts.count, 2)
    }

    func testRemediationUsesOneScanBundleForPolicyAndCandidates() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.rootURL) }
        var scanCalls = 0
        var stats = DriveStats()
        stats.materializedBytes = 4_096
        stats.freeBytes = 100 * bytesPerGiB
        stats.freeSpaceAvailable = true
        stats.scanComplete = true
        stats.completedAt = Date()
        let candidate = EvictionCandidate(
            path: sandbox.rootURL.appendingPathComponent("CloudDocs/item.bin").path,
            relativePath: "item.bin",
            allocatedBytes: 4_096,
            modificationDate: nil
        )
        let runner = GuardRunner(
            engineFactory: { EvictionEngine(logger: $0) },
            scanProvider: { _, _, _, _ in
                scanCalls += 1
                return ScanBundle(stats: stats, candidates: [candidate])
            }
        )

        let exitCode = try runner.run(
            command: .panicEvict,
            configPath: sandbox.configURL.path,
            dryRun: true
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(scanCalls, 1)
        XCTAssertEqual(try loadState(from: sandbox.stateURL).lastSummary?.candidateCount, 1)
    }

    func testInjectedScopedRunIgnoresConcurrentOnDiskClonePathChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("injected-scope-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldScope = root.appendingPathComponent("old-scope", isDirectory: true)
        let selectedScope = root.appendingPathComponent("selected-scope", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: oldScope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedScope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let paths = AppPaths.ScopePaths(root: storage)
        let staleConfigURL = storage.appendingPathComponent("config.toml")
        try ConfigStore(configURL: staleConfigURL).save(AppConfig(scope: .init(path: oldScope.path)))
        let selectedConfig = AppConfig(scope: .init(path: selectedScope.path))
        var observedScope: String?
        var stats = DriveStats()
        stats.freeBytes = 100 * bytesPerGiB
        stats.freeSpaceAvailable = true
        stats.scanComplete = true
        stats.completedAt = Date()
        let runner = GuardRunner(
            engineFactory: { EvictionEngine(logger: $0) },
            scanProvider: { _, scope, _, _ in
                observedScope = scope
                // Simulate another config writer changing the former shared
                // clone after this operation has acquired its run lock.
                try ConfigStore(configURL: staleConfigURL).save(AppConfig(scope: .init(path: oldScope.path)))
                return ScanBundle(stats: stats, candidates: [])
            }
        )

        let result = try runner.runResult(
            command: .run,
            config: selectedConfig,
            scopePaths: paths,
            dryRun: true,
            quiet: true,
            receiptCommand: "evict",
            requestedAction: "evict"
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(observedScope, selectedScope.path)
        XCTAssertEqual(result.receipt?.sourceScopeIdentifier, PrivacyIdentifier.scope(selectedScope.path))
        XCTAssertEqual(try ConfigStore(configURL: staleConfigURL).loadValidated().scope.path, oldScope.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.history.path))
    }

    func testDryRunReclaimGoalReportsExactAndPartialPlans() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.rootURL) }
        var stats = DriveStats()
        stats.materializedBytes = 4_096
        stats.freeBytes = 100 * bytesPerGiB
        stats.freeSpaceAvailable = true
        stats.scanComplete = true
        let candidate = EvictionCandidate(
            path: sandbox.rootURL.appendingPathComponent("CloudDocs/item.bin").path,
            relativePath: "item.bin",
            allocatedBytes: 4_096,
            modificationDate: nil
        )
        let runner = GuardRunner(
            engineFactory: { EvictionEngine(logger: $0) },
            scanProvider: { _, _, _, _ in ScanBundle(stats: stats, candidates: [candidate]) }
        )

        XCTAssertEqual(try runner.run(
            command: .run,
            configPath: sandbox.configURL.path,
            dryRun: true,
            reclaimGoalBytes: 4_096
        ), 0)
        XCTAssertEqual(try runner.run(
            command: .run,
            configPath: sandbox.configURL.path,
            dryRun: true,
            reclaimGoalBytes: 8_192
        ), 1)
        let receipt = try XCTUnwrap(RunHistoryStore(url: sandbox.rootURL.appendingPathComponent("history.json")).load().last)
        XCTAssertEqual(receipt.status, .partial)
        XCTAssertEqual(receipt.exitCode, 1)
        XCTAssertEqual(receipt.plannedBytes, 4_096)
        XCTAssertEqual(receipt.verifiedBytes, 0)
    }

    func testRunResultReturnsExactReclaimReceiptWithoutHistoryTimestampGuessing() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.rootURL) }
        var stats = DriveStats()
        stats.materializedBytes = 4_096
        stats.freeBytes = 100 * bytesPerGiB
        stats.freeSpaceAvailable = true
        stats.scanComplete = true
        let runner = GuardRunner(
            engineFactory: { EvictionEngine(logger: $0) },
            scanProvider: { _, _, _, _ in
                ScanBundle(stats: stats, candidates: [
                    EvictionCandidate(
                        path: sandbox.rootURL.appendingPathComponent("CloudDocs/private.bin").path,
                        relativePath: "private.bin",
                        allocatedBytes: 4_096,
                        modificationDate: nil
                    ),
                ])
            }
        )
        let olderSameSecond = GuardRunReceipt(
            id: "same-second-existing",
            startedAt: Date(timeIntervalSince1970: 2_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            trigger: .cli,
            command: "reclaim",
            requestedAction: "reclaim",
            action: .targeted,
            dryRun: true,
            reason: "manual reclaim goal",
            requestedGoalBytes: 1,
            sourceScopeIdentifier: "scope",
            plannedCount: 1,
            plannedBytes: 1,
            exitCode: 0,
            status: .succeeded,
            statePersisted: true,
            watchlistPersisted: true
        )
        try RunHistoryStore(url: sandbox.rootURL.appendingPathComponent("history.json")).append(olderSameSecond)

        let result = try runner.runResult(
            command: .run,
            configPath: sandbox.configURL.path,
            dryRun: true,
            reclaimGoalBytes: 4_096,
            receiptCommand: "reclaim",
            requestedAction: "reclaim"
        )

        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(receipt.command, "reclaim")
        XCTAssertEqual(receipt.requestedAction, "reclaim")
        XCTAssertEqual(receipt.requestedGoalBytes, 4_096)
        XCTAssertEqual(receipt.reason, "manual reclaim goal")
        XCTAssertEqual(receipt.reasonMetadata?["requested_goal_bytes"], "4096")
        XCTAssertNotEqual(receipt.id, olderSameSecond.id)
        XCTAssertTrue(try RunHistoryStore(url: sandbox.rootURL.appendingPathComponent("history.json")).load().contains { $0.id == receipt.id })
    }

    private func makeSandbox() throws -> (rootURL: URL, configURL: URL, lockURL: URL, stateURL: URL, logURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scopeURL = rootURL.appendingPathComponent("CloudDocs", isDirectory: true)
        let lockURL = rootURL.appendingPathComponent("run.lock")
        let stateURL = rootURL.appendingPathComponent("state.json")
        let logURL = rootURL.appendingPathComponent("icloud-guard.log")
        let configURL = rootURL.appendingPathComponent("config.toml")

        try FileManager.default.createDirectory(at: scopeURL, withIntermediateDirectories: true)

        let appConfig = AppConfig(
            suppression: .init(),
            eviction: .init(batchLimit: 500, panicLimit: 2000),
            watcher: .init(backoffMaxSeconds: 60, pollutionCheckIntervalSeconds: 300, watchlistPollSeconds: 10),
            scope: .init(path: scopeURL.path, protectedPaths: []),
            policy: .init(targetLocalGiB: 30, trimLocalGiB: 35, warnFreeGiB: 0, remediateFreeGiB: 0, panicFreeGiB: 0, cooldownMinutes: 30, growthTriggerGiB: 20, growthWindowMinutes: 10)
        )
        let store = ConfigStore(configURL: configURL)
        try store.save(appConfig)

        return (rootURL, configURL, lockURL, stateURL, logURL)
    }

    private func saveState(_ state: GuardState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url)
    }

    private func saveConfig(_ config: AppConfig, to url: URL) throws {
        let store = ConfigStore(configURL: url)
        try store.save(config)
    }

    private func loadState(from url: URL) throws -> GuardState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GuardState.self, from: Data(contentsOf: url))
    }

    private func loadConfig(from url: URL) throws -> AppConfig {
        let store = ConfigStore(configURL: url)
        return store.load()
    }
}

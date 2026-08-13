import CryptoKit
import Foundation
import os
import XCTest
@testable import ICloudGuardCore

final class Phase4OperationsTests: XCTestCase {
    func testHistoryMigratesLegacyCapsAndEscapesCSV() throws {
        let root = try temporaryDirectory()
        let historyURL = root.appendingPathComponent("history.json")
        let legacy = GuardRunSummary(
            timestamp: Date(timeIntervalSince1970: 100),
            action: .targeted,
            reason: "legacy",
            dryRun: false,
            candidateCount: 1,
            evictedCount: 1,
            pendingEvictionCount: 0,
            failedEvictionCount: 0,
            reclaimedBytes: 10,
            remainingLocalBytes: 20,
            remainingFreeBytes: 30,
            postScanComplete: true,
            freeSpaceAvailable: true,
            escalatedToPanic: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacy]).write(to: historyURL)
        let store = RunHistoryStore(url: historyURL, maximumReceipts: 2)
        XCTAssertEqual(try store.load().first?.trigger, .legacy)

        for index in 0..<3 {
            try store.append(receipt(id: "run-\(index)", endedAt: Date(timeIntervalSince1970: TimeInterval(200 + index)), reason: index == 2 ? "\t\r =SUM(A1:A2),\"quoted\"" : "ok"))
        }
        XCTAssertEqual(try store.load().map(\.id), ["run-1", "run-2"])

        let csv = root.appendingPathComponent("history.csv")
        try store.exportCSV(to: csv, privacyMode: false)
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.contains("\"'\t\r =SUM(A1:A2),\"\"quoted\"\"\""))
        XCTAssertTrue(text.contains("\r\n"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: csv.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHistoryRejectsCorruption() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("history.json")
        try Data("{broken".utf8).write(to: url)
        XCTAssertThrowsError(try RunHistoryStore(url: url).load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("corrupt"))
        }
    }

    func testHistoryRejectsOversizedFileBeforeDecode() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("history.json")
        try Data(count: Int(RunHistoryStore.maximumHistoryBytes) + 1).write(to: url)

        XCTAssertThrowsError(try RunHistoryStore(url: url).load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("history file exceeds"))
        }
    }

    func testHistoryRejectsSymlinkAndWatchlistRejectsFIFOWithoutBlocking() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("target.json")
        try Data("[]".utf8).write(to: target)
        let history = root.appendingPathComponent("history.json")
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: target)
        XCTAssertThrowsError(try RunHistoryStore(url: history).load())

        let fifo = root.appendingPathComponent("watchlist.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try WatchlistInspectionService.load(storageURL: fifo, scopePath: root.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testHistoryRejectsDuplicateReceiptIDs() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("history.json")
        try writeHistory([
            receipt(id: "duplicate", endedAt: Date(timeIntervalSince1970: 200), reason: "first"),
            receipt(id: "duplicate", endedAt: Date(timeIntervalSince1970: 201), reason: "second"),
        ], to: url)

        XCTAssertThrowsError(try RunHistoryStore(url: url).load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate receipt id"))
        }
    }

    func testHistoryRejectsContradictoryReceiptInvariants() throws {
        let cases: [(String, (inout GuardRunReceipt) -> Void, String)] = [
            ("succeeded-nonzero", { $0.exitCode = 74 }, "succeeded receipt has nonzero exit code"),
            ("succeeded-pending", {
                $0.plannedCount = 2; $0.plannedBytes = 20; $0.pendingCount = 1; $0.pendingBytes = 10
            }, "succeeded receipt has residual or incoherent work"),
            ("succeeded-failed", {
                $0.plannedCount = 2; $0.plannedBytes = 20; $0.failedCount = 1; $0.failedBytes = 10
            }, "succeeded receipt has residual or incoherent work"),
            ("failed-zero", { $0.status = .failed; $0.exitCode = 0 }, "failed receipt is not coherent"),
            ("cancelled-without-130", { $0.status = .cancelled; $0.cancelled = true; $0.exitCode = 1 }, "cancelled receipt must have exit code 130"),
            ("one-thirty-without-cancel", { $0.exitCode = 130 }, "cancelled receipt must have exit code 130"),
            ("contended-without-75", { $0.status = .contended; $0.exitCode = 1 }, "contended receipt must have exit code 75"),
            ("no-action-with-work", { $0.status = .noAction; $0.verifiedCount = 1; $0.verifiedBytes = 10 }, "no-action receipt is not coherent"),
            ("pending-without-pending", { $0.status = .pending; $0.exitCode = 1; $0.pendingCount = 0 }, "pending receipt is not coherent"),
            ("partial-without-work", { $0.status = .partial; $0.exitCode = 1; $0.verifiedCount = 0; $0.verifiedBytes = 0 }, "partial receipt is not coherent"),
            ("verified-over-planned", { $0.verifiedCount = 2 }, "receipt counts exceed planned count"),
            ("zero-count-with-bytes", { $0.verifiedCount = 0 }, "receipt has bytes without matching item count"),
            ("bytes-over-planned", { $0.verifiedBytes = 11 }, "receipt bytes exceed planned bytes"),
        ]

        for (name, mutate, message) in cases {
            let root = try temporaryDirectory()
            let url = root.appendingPathComponent("\(name).json")
            var bad = receipt(id: name, endedAt: Date(timeIntervalSince1970: 200), reason: name)
            mutate(&bad)
            try writeHistory([bad], to: url)

            XCTAssertThrowsError(try RunHistoryStore(url: url).load(), name) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), "\(name): \(error.localizedDescription)")
            }
        }
    }

    func testReceiptStatusDerivationCoversTerminalRelationships() {
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 0, pending: 0, failed: 0, dryRun: false), exitCode: 0, cancelled: false), .noAction)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 1, pending: 0, failed: 0, dryRun: false), exitCode: 0, cancelled: false), .succeeded)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 0, pending: 0, failed: 0, dryRun: false), exitCode: 69, cancelled: false), .failed)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 0, pending: 1, failed: 0, dryRun: false), exitCode: 1, cancelled: false), .pending)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 1, pending: 1, failed: 0, dryRun: false), exitCode: 1, cancelled: false), .partial)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 0, pending: 0, failed: 1, dryRun: false), exitCode: 1, cancelled: false), .partial)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 0, pending: 1, failed: 0, dryRun: false), exitCode: 0, cancelled: false), .pending)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 0, pending: 0, failed: 1, dryRun: false), exitCode: 0, cancelled: false), .partial)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 1, pending: 0, failed: 0, dryRun: false), exitCode: 130, cancelled: true), .cancelled)
        XCTAssertEqual(GuardRunReceipt.status(for: summary(evicted: 0, pending: 0, failed: 0, dryRun: false), exitCode: 75, cancelled: false), .contended)
    }

    func testLegacyStatusDerivationPreservesValidHistoryWithoutCallingResidualWorkSucceeded() {
        XCTAssertEqual(GuardRunReceipt.legacy(summary(evicted: 0, pending: 0, failed: 0, dryRun: false)).status, .noAction)
        XCTAssertEqual(GuardRunReceipt.legacy(summary(evicted: 1, pending: 0, failed: 0, dryRun: false)).status, .succeeded)
        XCTAssertEqual(GuardRunReceipt.legacy(summary(evicted: 0, pending: 1, failed: 0, dryRun: false)).status, .pending)
        XCTAssertEqual(GuardRunReceipt.legacy(summary(evicted: 0, pending: 0, failed: 1, dryRun: false)).status, .partial)
    }

    func testHistoryDoesNotDuplicateCurrentSummaryAsLegacy() throws {
        let root = try temporaryDirectory()
        let store = RunHistoryStore(url: root.appendingPathComponent("history.json"))
        let current = receipt(id: "current", endedAt: Date(timeIntervalSince1970: 200), reason: "same run")

        try store.append(current, legacySummary: current.summary)

        XCTAssertEqual(try store.load().map(\.id), ["current"])
    }

    func testHistoryMigratesDistinctPreexistingSummaryOnce() throws {
        let root = try temporaryDirectory()
        let store = RunHistoryStore(url: root.appendingPathComponent("history.json"))
        let legacy = receipt(id: "old", endedAt: Date(timeIntervalSince1970: 100), reason: "old run").summary
        let current = receipt(id: "current", endedAt: Date(timeIntervalSince1970: 200), reason: "current run")

        try store.append(current, legacySummary: legacy)
        try store.append(current, legacySummary: legacy)

        let receipts = try store.load()
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.filter { $0.trigger == .legacy }.count, 1)
        XCTAssertEqual(receipts.filter { $0.id == "current" }.count, 1)
    }

    func testHistoryMigratesIdenticalLegacyFieldsFromDifferentTime() throws {
        let root = try temporaryDirectory()
        let store = RunHistoryStore(url: root.appendingPathComponent("history.json"))
        let current = receipt(id: "current", endedAt: Date(timeIntervalSince1970: 200), reason: "same fields")
        var older = current.summary
        older.timestamp = Date(timeIntervalSince1970: 100)

        try store.append(current, legacySummary: older)

        let receipts = try store.load()
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.filter { $0.trigger == .legacy }.count, 1)
        XCTAssertEqual(receipts.filter { $0.id == "current" }.count, 1)
    }

    func testHistoryMigratesIdenticalLegacyFieldsWithinSameSecond() throws {
        let root = try temporaryDirectory()
        let store = RunHistoryStore(url: root.appendingPathComponent("history.json"))
        let current = receipt(id: "current", endedAt: Date(timeIntervalSince1970: 100.9), reason: "same fields")
        var older = current.summary
        older.timestamp = Date(timeIntervalSince1970: 100.1)

        try store.append(current, legacySummary: older)

        let receipts = try store.load()
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.filter { $0.trigger == .legacy }.count, 1)
        XCTAssertEqual(receipts.filter { $0.id == "current" }.count, 1)
    }

    func testStateSummarySurvivesHistoryAppendFailureAndLaterMigration() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("state.json")
        let store = StateStore(statePath: stateURL.path)
        let logged = receipt(id: "logged", endedAt: Date(timeIntervalSince1970: 10), reason: "old history")
        try RunHistoryStore(url: root.appendingPathComponent("history.json")).append(logged)

        let unlogged = receipt(id: "unlogged", endedAt: Date(timeIntervalSince1970: 20), reason: "new unlogged summary").summary
        try store.save(GuardState(lastSummary: unlogged))
        XCTAssertEqual(try store.load().lastSummary?.reason, "new unlogged summary")

        try RunHistoryStore(url: root.appendingPathComponent("history.json")).append(
            receipt(id: "current", endedAt: Date(timeIntervalSince1970: 30), reason: "current"),
            legacySummary: try store.load().lastSummary
        )
        XCTAssertTrue(try RunHistoryStore(url: root.appendingPathComponent("history.json")).load().contains {
            $0.trigger == .legacy && $0.reason == "new unlogged summary"
        })
    }

    func testStateRejectsSymlinkWithoutFollowingTarget() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("target.json")
        try JSONEncoder().encode(GuardState()).write(to: target)
        let stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: target)

        XCTAssertThrowsError(try StateStore(statePath: stateURL.path).load()) { error in
            XCTAssertEqual(error as? StateStore.StateError, .io("state file is not a readable regular file"))
        }
    }

    func testStateRejectsFIFOWithoutBlocking() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("state.json")
        XCTAssertEqual(mkfifo(stateURL.path, 0o600), 0)

        let started = Date()
        XCTAssertThrowsError(try StateStore(statePath: stateURL.path).load()) { error in
            XCTAssertEqual(error as? StateStore.StateError, .io("state file is not a readable regular file"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testStateRejectsOversizedFileBeforeDecode() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("state.json")
        try Data(count: Int(StateStore.maximumStateBytes) + 1).write(to: stateURL)

        XCTAssertThrowsError(try StateStore(statePath: stateURL.path).load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("state is corrupt: state file exceeds safety limit"))
        }
    }

    func testPersistenceTransactionAppendsOneFinalReceiptAfterState() throws {
        var terminal = receipt(id: "success", endedAt: Date(), reason: "ok")
        terminal.statePersisted = false
        var events: [String] = []
        var appended: [GuardRunReceipt] = []

        try RunPersistenceTransaction.perform(
            receipt: &terminal,
            saveState: { events.append("state") },
            appendReceipt: { receipt in events.append("history"); appended.append(receipt) }
        )

        XCTAssertEqual(events, ["state", "history"])
        XCTAssertEqual(appended.count, 1)
        XCTAssertTrue(appended[0].statePersisted)
    }

    func testPersistenceTransactionRecordsStateFailureOnce() throws {
        var terminal = receipt(id: "state-failure", endedAt: Date(), reason: "state failed")
        var appended: [GuardRunReceipt] = []

        XCTAssertThrowsError(try RunPersistenceTransaction.perform(
            receipt: &terminal,
            saveState: { throw CocoaError(.fileWriteNoPermission) },
            appendReceipt: { appended.append($0) }
        )) { error in
            guard case RunPersistenceTransaction.Failure.state(_, receiptPersisted: true) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(appended.count, 1)
        XCTAssertFalse(appended[0].statePersisted)
        XCTAssertEqual(appended[0].exitCode, 74)
        XCTAssertEqual(appended[0].status, .partial)
    }

    func testPersistenceTransactionReportsHistoryFailureAfterState() throws {
        var terminal = receipt(id: "history-failure", endedAt: Date(), reason: "history failed")
        var stateWrites = 0

        XCTAssertThrowsError(try RunPersistenceTransaction.perform(
            receipt: &terminal,
            saveState: { stateWrites += 1 },
            appendReceipt: { _ in throw CocoaError(.fileWriteNoPermission) }
        )) { error in
            guard case RunPersistenceTransaction.Failure.history(_, statePersisted: true) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(stateWrites, 1)
        XCTAssertTrue(terminal.statePersisted)
    }

    func testDoctorHasStableReadOnlyChecks() throws {
        let root = try temporaryDirectory()
        let configURL = root.appendingPathComponent("config.toml")
        var config = AppConfig()
        config.scope.path = root.appendingPathComponent("scope").path
        try ConfigStore(configURL: configURL).save(config)
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        let probe = DoctorProbe(
            fileExists: { _ in true },
            fileInfo: { _ in DoctorFileInfo(isDirectory: true, permissions: 0o700) },
            isWritable: { _ in true },
            canonicalPath: { $0 },
            freeBytes: { _ in 42 },
            processAlive: { _ in false },
            isSocket: { _ in true },
            executable: { _ in true }
        )
        let report = DoctorService.run(appHome: root, configURL: configURL, probe: probe)
        let ids = Set(report.checks.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["config.valid", "config.migration", "path.app-home", "scope.directory", "scope.file-provider", "volume.free-space", "lock.owner", "ipc.consistency", "suppression.tools", "product.version"]))
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)), before)
    }

    func testDoctorSnapshotsStatefulProvidersOncePerReport() throws {
        let root = try temporaryDirectory()
        let configURL = root.appendingPathComponent("config.toml")
        var config = AppConfig()
        config.scope.path = root.appendingPathComponent("scope").path
        try ConfigStore(configURL: configURL).save(config)
        let freeCalls = OSAllocatedUnfairLock(initialState: 0)
        let executableCalls = OSAllocatedUnfairLock(initialState: [String: Int]())
        let probe = DoctorProbe(
            fileExists: { _ in true },
            fileInfo: { _ in DoctorFileInfo(isDirectory: true, permissions: 0o700) },
            isWritable: { _ in true },
            canonicalPath: { $0 },
            freeBytes: { _ in
                let call = freeCalls.withLock { calls -> Int in
                    calls += 1
                    return calls
                }
                return call == 1 ? 42 : nil
            },
            processAlive: { _ in false },
            isSocket: { _ in true },
            executable: { path in
                let call = executableCalls.withLock { calls -> Int in
                    calls[path, default: 0] += 1
                    return calls[path] ?? 0
                }
                return call == 1
            }
        )

        let report = DoctorService.run(appHome: root, configURL: configURL, probe: probe)

        let freeSpace = try XCTUnwrap(report.checks.first { $0.id == "volume.free-space" })
        let tools = try XCTUnwrap(report.checks.first { $0.id == "suppression.tools" })
        XCTAssertEqual(freeSpace.status, .passed)
        XCTAssertTrue(freeSpace.message.contains("42"))
        XCTAssertEqual(tools.status, .passed)
        XCTAssertEqual(freeCalls.withLock { $0 }, 1)
        XCTAssertEqual(executableCalls.withLock { $0["/usr/bin/mdutil"] }, 1)
        XCTAssertEqual(executableCalls.withLock { $0["/usr/bin/qlmanage"] }, 1)
    }

    func testDoctorTreatsLivePIDInUnlockedRunLockAsStale() throws {
        let root = try temporaryDirectory()
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        var config = AppConfig()
        config.scope.path = scope.path
        try ConfigStore(configURL: configURL).save(config)
        let lockURL = root.appendingPathComponent("run.lock")
        try "\(getpid())\n".write(to: lockURL, atomically: true, encoding: .utf8)
        let probe = DoctorProbe(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            fileInfo: { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
                return DoctorFileInfo(
                    isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                    permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue
                )
            },
            isWritable: { _ in true },
            canonicalPath: { $0 },
            freeBytes: { _ in 42 },
            processAlive: { $0 == getpid() },
            isSocket: { _ in false },
            executable: { _ in true }
        )

        var report = DoctorService.run(appHome: root, configURL: configURL, probe: probe)
        var lockCheck = try XCTUnwrap(report.checks.first { $0.id == "lock.owner" })
        XCTAssertEqual(lockCheck.status, .passed)
        XCTAssertTrue(lockCheck.message.contains("no active advisory owner"))

        let heldLock = try AdvisoryFileLock(path: lockURL.path)
        try heldLock.writeOwnerPID()
        report = DoctorService.run(appHome: root, configURL: configURL, probe: probe)
        lockCheck = try XCTUnwrap(report.checks.first { $0.id == "lock.owner" })
        XCTAssertEqual(lockCheck.status, .warning)
        XCTAssertTrue(lockCheck.message.contains("advisory owner PID"))
        _ = heldLock
    }

    func testDoctorRejectsFIFORunLockWithoutBlocking() throws {
        let root = try temporaryDirectory()
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        var config = AppConfig()
        config.scope.path = scope.path
        try ConfigStore(configURL: configURL).save(config)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("run.lock").path, 0o600), 0)

        let started = Date()
        let report = DoctorService.run(appHome: root, configURL: configURL)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(report.checks.first { $0.id == "lock.owner" }?.status, .unavailable)
    }

    func testExplainUsesOneScanAndWritesDryRunReceipt() throws {
        let root = try temporaryDirectory()
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        var config = AppConfig()
        config.scope.path = scope.path
        config.policy.targetLocalGiB = 1
        config.policy.trimLocalGiB = 2
        try ConfigStore(configURL: configURL).save(config)
        var stats = DriveStats()
        stats.materializedBytes = 3 * 1024 * 1024 * 1024
        stats.freeBytes = 100 * 1024 * 1024 * 1024
        stats.freeSpaceAvailable = true
        stats.scanComplete = true
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let bundle = ScanBundle(stats: stats, candidates: [
            EvictionCandidate(path: scope.appendingPathComponent("file.bin").path, relativePath: "file.bin", allocatedBytes: 2 * 1024 * 1024 * 1024, modificationDate: nil),
        ], exclusions: [.protected: 2])
        let service = ExplainablePreviewService(scan: { _, _ in
            calls.withLock { $0 += 1 }
            return bundle
        })
        let preview = try service.run(configURL: configURL, appHome: root)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertTrue(preview.receiptPersisted)
        XCTAssertEqual(preview.exclusions[PreviewExclusionReason.protected.rawValue], 2)
        let receipt = try XCTUnwrap(RunHistoryStore(url: root.appendingPathComponent("history.json")).load().last)
        XCTAssertTrue(receipt.dryRun)
        XCTAssertEqual(receipt.verifiedBytes, 0)
        XCTAssertEqual(receipt.plannedBytes, preview.plannedBytes)
    }

    func testExplainIntersectsWatchlistAndStopsPlanningForIncompleteScan() throws {
        let root = try temporaryDirectory()
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        var config = AppConfig()
        config.scope.path = scope.path
        let configURL = root.appendingPathComponent("config.toml")
        try ConfigStore(configURL: configURL).save(config)
        let now = Date(timeIntervalSince1970: 1_000)
        let pendingPath = scope.appendingPathComponent("pending.bin").path
        let entries = [
            WatchlistEntry(path: pendingPath, addedAt: now, nextCheckAt: now, pendingVerification: true),
            WatchlistEntry(path: scope.appendingPathComponent("unrelated.bin").path, addedAt: now, nextCheckAt: now, pendingVerification: true),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: root.appendingPathComponent("watchlist.json"))
        var stats = DriveStats()
        stats.materializedBytes = 8_192
        stats.freeSpaceAvailable = true
        stats.scanComplete = false
        stats.scanReadErrors = 1
        let incompleteStats = stats
        let service = ExplainablePreviewService(scan: { _, _ in
            ScanBundle(stats: incompleteStats, candidates: [
                EvictionCandidate(path: pendingPath, relativePath: "pending.bin", allocatedBytes: 4_096, modificationDate: nil),
                EvictionCandidate(path: scope.appendingPathComponent("eligible.bin").path, relativePath: "eligible.bin", allocatedBytes: 4_096, modificationDate: nil),
            ])
        }, now: { now })

        let preview = try service.run(configURL: configURL, appHome: root)

        XCTAssertEqual(preview.exclusions[PreviewExclusionReason.pending.rawValue], 1)
        XCTAssertEqual(preview.plannedCount, 0)
        XCTAssertEqual(preview.plannedBytes, 0)
        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertFalse(preview.scan.scanComplete)
    }

    func testWatchlistInspectorRejectsMaliciousEntriesWithoutLeakingPath() throws {
        let root = try temporaryDirectory()
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("SECRET-outside.bin").path
        let now = Date()
        let entries = [
            WatchlistEntry(
                path: outside,
                addedAt: now,
                reEvictCount: 99,
                nextCheckAt: now,
                lastError: "failed at \(outside)"
            ),
        ]
        let url = root.appendingPathComponent("watchlist.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url)

        let inspected = try XCTUnwrap(WatchlistInspectionService.load(
            storageURL: url,
            scopePath: scope.path,
            revealPaths: true,
            maxFights: 10
        ).first)

        XCTAssertEqual(inspected.state, .rejected)
        XCTAssertEqual(inspected.rejectionReason, "outside-scope")
        XCTAssertTrue(inspected.displayPath.hasPrefix("path:"))
        XCTAssertFalse(inspected.displayPath.contains("SECRET"))
        XCTAssertNil(inspected.lastError)
        XCTAssertThrowsError(try WatchlistInspectionService.loadEntries(storageURL: url, scopePath: scope.path))
    }

    func testSupportBundleOmitsSeededSecretsAndVerifiesManifest() throws {
        let root = try temporaryDirectory()
        let appHome = root.appendingPathComponent("home")
        let scope = root.appendingPathComponent("Secret User/RawFileNames")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        var config = AppConfig()
        config.scope.path = scope.path
        config.scope.protectedPaths = ["SuperSecretFilename.pdf"]
        let configURL = appHome.appendingPathComponent("config.toml")
        try ConfigStore(configURL: configURL).save(config)
        try Data("token=TOP_SECRET_TOKEN path=SuperSecretFilename.pdf\n".utf8)
            .write(to: appHome.appendingPathComponent("icloud-guard.log"))
        try RunHistoryStore(url: appHome.appendingPathComponent("history.json")).append(
            receipt(id: "formula", endedAt: Date(), reason: "=TOP_SECRET_TOKEN")
        )
        let output = root.appendingPathComponent("bundle.zip")
        let result = try SupportBundleService().create(outputURL: output, appHome: appHome, configURL: configURL)
        XCTAssertNoThrow(try SupportBundleVerifier().verify(
            archiveURL: output,
            expectedManifestSHA256: result.manifestSHA256
        ))
        XCTAssertGreaterThan(result.fileCount, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let extracted = root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", output.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let bundleRoot = extracted.appendingPathComponent("icloud-guard-support")
        let names = try FileManager.default.contentsOfDirectory(atPath: bundleRoot.path)
        XCTAssertFalse(names.contains("logs.txt"))
        let bytes = try names.reduce(into: Data()) { data, name in
            data.append(try Data(contentsOf: bundleRoot.appendingPathComponent(name)))
        }
        let contents = String(decoding: bytes, as: UTF8.self)
        for secret in ["TOP_SECRET_TOKEN", "SuperSecretFilename.pdf", "Secret User", scope.path, NSHomeDirectory()] {
            XCTAssertFalse(contents.contains(secret), "bundle leaked \(secret)")
        }
        let manifestData = try Data(contentsOf: bundleRoot.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(SupportBundleManifest.self, from: manifestData)
        for entry in manifest.files {
            let data = try Data(contentsOf: bundleRoot.appendingPathComponent(entry.path))
            XCTAssertEqual(data.count, entry.bytes)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry.sha256)
        }
    }

    func testSupportBundleIsSeedDeterministicAndFreshSaltsAreUnlinkable() throws {
        let root = try temporaryDirectory()
        let appHome = root.appendingPathComponent("home")
        let scope = root.appendingPathComponent("Secret User/scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        var config = AppConfig()
        config.scope.path = scope.path
        let configURL = appHome.appendingPathComponent("config.toml")
        try ConfigStore(configURL: configURL).save(config)
        let salt = Data(repeating: 0x42, count: 32)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let deterministic = SupportBundleService(saltProvider: { salt }, now: { fixedDate })
        let first = root.appendingPathComponent("first.zip")
        let second = root.appendingPathComponent("second.zip")
        _ = try deterministic.create(outputURL: first, appHome: appHome, configURL: configURL)
        _ = try deterministic.create(outputURL: second, appHome: appHome, configURL: configURL)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))

        let third = root.appendingPathComponent("third.zip")
        let fourth = root.appendingPathComponent("fourth.zip")
        _ = try SupportBundleService(saltProvider: { Data(repeating: 1, count: 32) }, now: { fixedDate })
            .create(outputURL: third, appHome: appHome, configURL: configURL)
        _ = try SupportBundleService(saltProvider: { Data(repeating: 2, count: 32) }, now: { fixedDate })
            .create(outputURL: fourth, appHome: appHome, configURL: configURL)
        XCTAssertNotEqual(try Data(contentsOf: third), try Data(contentsOf: fourth))
    }

    func testSupportBundleFailsClosedForCorruptDurableInput() throws {
        let root = try temporaryDirectory()
        let appHome = root.appendingPathComponent("home")
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        var config = AppConfig()
        config.scope.path = scope.path
        let configURL = appHome.appendingPathComponent("config.toml")
        try ConfigStore(configURL: configURL).save(config)
        try Data("{broken".utf8).write(to: appHome.appendingPathComponent("history.json"))
        let output = root.appendingPathComponent("bundle.zip")

        XCTAssertThrowsError(try SupportBundleService().create(outputURL: output, appHome: appHome, configURL: configURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSupportBundleWatchlistAggregateUsesConfiguredFightLimit() throws {
        let root = try temporaryDirectory()
        let appHome = root.appendingPathComponent("home")
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        var config = AppConfig()
        config.scope.path = scope.path
        config.watcher.maxFights = 2
        let configURL = appHome.appendingPathComponent("config.toml")
        try ConfigStore(configURL: configURL).save(config)
        let now = Date(timeIntervalSince1970: 100)
        let entries = [1, 2, 3].map {
            WatchlistEntry(path: scope.appendingPathComponent("f\($0).bin").path, addedAt: now, reEvictCount: $0, nextCheckAt: now)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: appHome.appendingPathComponent("watchlist.json"))
        let output = root.appendingPathComponent("bundle.zip")

        _ = try SupportBundleService().create(outputURL: output, appHome: appHome, configURL: configURL)
        let bundleRoot = try extractSupportBundle(output, under: root)
        let data = try Data(contentsOf: bundleRoot.appendingPathComponent("watchlist.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["fighting"] as? Int, 1)
    }

    func testSupportBundleCreatesArchivePrivatelyBeforePublishing() throws {
        let root = try temporaryDirectory()
        let appHome = root.appendingPathComponent("home")
        let outputParent = root.appendingPathComponent("output")
        let output = outputParent.appendingPathComponent("bundle.zip")
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputParent, withIntermediateDirectories: true)
        let service = SupportBundleService(processRunner: { executable, arguments in
            let temporaryArchive = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
            let privateDirectory = temporaryArchive.deletingLastPathComponent()
            XCTAssertFalse(privateDirectory.path.hasPrefix(outputParent.path + "/"))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: privateDirectory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            return try SupportBundleService.runProcess(executable, arguments)
        })

        _ = try service.create(outputURL: output, appHome: appHome, configURL: appHome.appendingPathComponent("config.toml"))

        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputParent.path), ["bundle.zip"])
    }

    func testSupportBundleAcceptsPrivateTmpAliasAndRejectsTraversal() throws {
        let root = URL(fileURLWithPath: "/private/tmp/icloud-guard-support-alias-\(UUID().uuidString)", isDirectory: true)
        let appHome = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("support.zip")

        let result = try SupportBundleService().create(
            outputURL: output,
            appHome: appHome,
            configURL: appHome.appendingPathComponent("config.toml")
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        XCTAssertThrowsError(try SupportBundleService().create(
            outputURL: root.appendingPathComponent("nested/../traversal.zip"),
            appHome: appHome,
            configURL: appHome.appendingPathComponent("config.toml")
        ))
        let missingParent = root.appendingPathComponent("missing/support.zip")
        XCTAssertThrowsError(try SupportBundleService().create(
            outputURL: missingParent,
            appHome: appHome,
            configURL: appHome.appendingPathComponent("config.toml")
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.deletingLastPathComponent().path))
    }

    func testSupportBundleRejectsEarlyParentReplacementWithoutTouchingCanary() throws {
        let root = try temporaryDirectory()
        let appHome = root.appendingPathComponent("home")
        let parent = root.appendingPathComponent("output")
        let movedParent = root.appendingPathComponent("moved-output")
        let canary = root.appendingPathComponent("canary")
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        let service = SupportBundleService(processRunner: { executable, arguments in
            XCTAssertFalse(arguments.contains { $0.hasPrefix(parent.path + "/") })
            try FileManager.default.moveItem(at: parent, to: movedParent)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: canary)
            return try SupportBundleService.runProcess(executable, arguments)
        })

        XCTAssertThrowsError(try service.create(
            outputURL: parent.appendingPathComponent("support.zip"),
            appHome: appHome,
            configURL: appHome.appendingPathComponent("config.toml")
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: canary.path), [])
    }

    func testSupportBundleCreateTimesOutWithoutPublishingOutput() throws {
        let root = try temporaryDirectory()
        let appHome = root.appendingPathComponent("home")
        let outputParent = root.appendingPathComponent("output")
        let output = outputParent.appendingPathComponent("bundle.zip")
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputParent, withIntermediateDirectories: true)
        let service = SupportBundleService(processRunner: { _, _ in
            try SupportBundleService.runProcess(
                "/bin/sh", ["-c", "sleep 10"], timeoutSeconds: 0.05
            )
        })

        let started = Date()
        XCTAssertThrowsError(try service.create(
            outputURL: output,
            appHome: appHome,
            configURL: appHome.appendingPathComponent("config.toml")
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputParent.path), [])
    }

    func testSupportBundleVerifierRejectsOversizedEntryBeforeExtraction() throws {
        let root = try temporaryDirectory()
        let archive = try makeSupportArchive(under: root) { bundleRoot in
            try Data("{}".utf8).write(to: bundleRoot.appendingPathComponent("manifest.json"))
            try Data(repeating: 0x61, count: SupportBundleVerifier.maximumEntryBytes + 1)
                .write(to: bundleRoot.appendingPathComponent("product.json"))
        }

        XCTAssertThrowsError(try SupportBundleVerifier().verify(archiveURL: archive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("entry exceeds size limit"), error.localizedDescription)
        }
    }

    func testSupportBundleVerifierRejectsLargeListingWithoutDeadlock() throws {
        let root = try temporaryDirectory()
        let archive = try makeSupportArchive(under: root) { bundleRoot in
            for index in 0..<800 {
                let name = String(format: "listing-%04d-%070d.json", index, index)
                try Data().write(to: bundleRoot.appendingPathComponent(name))
            }
        }

        XCTAssertThrowsError(try SupportBundleVerifier().verify(archiveURL: archive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("listing exceeds size limit"), error.localizedDescription)
        }
    }

    func testSupportVerifierRejectsSymlinkAndFIFOArchiveWithoutBlocking() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("target.zip")
        try Data("not a zip".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        let link = root.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try SupportBundleVerifier().verify(archiveURL: link))

        let fifo = root.appendingPathComponent("fifo.zip")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try SupportBundleVerifier().verify(archiveURL: fifo))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSupportVerifierProcessDeadlineTerminatesChild() throws {
        let started = Date()
        XCTAssertThrowsError(try SupportBundleVerifier.capture(
            "/bin/sh", ["-c", "sleep 10"], timeoutSeconds: 0.05
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testDoctorUnavailableErrorIsNonzeroButWarningOnlyIsZero() {
        let unavailable = DoctorReport(checks: [
            DoctorCheck(id: "required", severity: .error, status: .unavailable, message: "unavailable", remediation: "repair"),
        ])
        let warning = DoctorReport(checks: [
            DoctorCheck(id: "optional", severity: .warning, status: .unavailable, message: "unavailable", remediation: "optional"),
        ])
        XCTAssertEqual(unavailable.exitCode, 78)
        XCTAssertEqual(warning.exitCode, 0)
    }

    func testFirstRunDoctorReviewPersistsSchemaAcknowledgement() throws {
        let suite = "doctor-review-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(FirstRunDoctorState.needsReview(defaults: defaults))
        FirstRunDoctorState.acknowledge(defaults: defaults)
        XCTAssertFalse(FirstRunDoctorState.needsReview(defaults: defaults))
    }

    func testHumanByteCountRejectsInvalidAndOverflow() {
        XCTAssertEqual(HumanByteCount.parse("5GiB"), 5 * 1024 * 1024 * 1024)
        XCTAssertEqual(HumanByteCount.parse("750MB"), 750_000_000)
        XCTAssertNil(HumanByteCount.parse("0"))
        XCTAssertNil(HumanByteCount.parse("-1GiB"))
        XCTAssertNil(HumanByteCount.parse("999999999999999999999GiB"))
    }

    func testReceiptPrivacyRedactsPathsAndStructuredReasonMetadata() throws {
        let root = try temporaryDirectory()
        let scope = root.appendingPathComponent("Secret User/Private Folder")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let receipt = GuardRunReceipt(
            startedAt: Date(),
            endedAt: Date(),
            trigger: .cli,
            command: "folder",
            requestedAction: "folder",
            action: .targeted,
            dryRun: false,
            reason: "evict folder Private Folder",
            sourceScopeIdentifier: PrivacyIdentifier.scope(scope.path),
            privacyScopePath: scope.path,
            plannedCount: 0,
            exitCode: 0,
            status: .noAction,
            statePersisted: true,
            watchlistPersisted: true
        )

        XCTAssertEqual(receipt.reason, "manual folder eviction")
        XCTAssertEqual(receipt.reasonCode, "manual-folder-eviction")
        XCTAssertNotNil(receipt.reasonMetadata?["folder_id"])
        XCTAssertFalse(String(describing: receipt).contains("Private Folder"))
        XCTAssertFalse(ReceiptPrivacy.redacted("failed at \(scope.appendingPathComponent("Tax.pdf").path)", scopePath: scope.path).contains("Secret User"))
    }

    func testTerminalSanitizerEscapesC0DELCSIAndBidi() {
        let hostile = "ok\u{001B}]0;owned\u{0007}\u{007F}\u{009B}2J\u{202E}txt"
        let safe = ReceiptPrivacy.terminalSafe(hostile)
        XCTAssertFalse(safe.unicodeScalars.contains { $0.value <= 0x1F || (0x80...0x9F).contains($0.value) || $0.value == 0x7F || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) })
        XCTAssertTrue(safe.contains("\\u{001B}]0;owned\\u{0007}"))
        XCTAssertTrue(safe.contains("\\u{009B}2J"))
    }

    private func receipt(id: String, endedAt: Date, reason: String) -> GuardRunReceipt {
        GuardRunReceipt(
            id: id,
            startedAt: endedAt.addingTimeInterval(-1),
            endedAt: endedAt,
            trigger: .cli,
            command: "evict",
            requestedAction: "run",
            action: .targeted,
            dryRun: false,
            reason: reason,
            sourceScopeIdentifier: "scope",
            plannedCount: 1,
            plannedBytes: 10,
            verifiedCount: 1,
            verifiedBytes: 10,
            exitCode: 0,
            status: .succeeded,
            statePersisted: true,
            watchlistPersisted: true
        )
    }

    private func summary(evicted: Int, pending: Int, failed: Int, dryRun: Bool) -> GuardRunSummary {
        GuardRunSummary(
            timestamp: Date(timeIntervalSince1970: 1),
            action: .targeted,
            reason: "status",
            dryRun: dryRun,
            candidateCount: max(evicted + pending + failed, dryRun ? 1 : 0),
            evictedCount: evicted,
            pendingEvictionCount: pending,
            failedEvictionCount: failed,
            reclaimedBytes: evicted > 0 ? 1 : 0,
            remainingLocalBytes: 0,
            remainingFreeBytes: 0,
            postScanComplete: false,
            freeSpaceAvailable: false,
            escalatedToPanic: false
        )
    }

    private func writeHistory(_ receipts: [GuardRunReceipt], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipts).write(to: url)
    }

    private func extractSupportBundle(_ archive: URL, under root: URL) throws -> URL {
        let extracted = root.appendingPathComponent("extracted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let status = try SupportBundleService.runProcess("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        XCTAssertEqual(status, 0)
        return extracted.appendingPathComponent("icloud-guard-support")
    }

    private func makeSupportArchive(
        under root: URL,
        populate: (URL) throws -> Void
    ) throws -> URL {
        let source = root.appendingPathComponent("archive-source-\(UUID().uuidString)")
        let bundleRoot = source.appendingPathComponent("icloud-guard-support")
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        try populate(bundleRoot)
        let archive = root.appendingPathComponent("archive-\(UUID().uuidString).zip")
        let status = try SupportBundleService.runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", bundleRoot.path, archive.path])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(chmod(archive.path, 0o600), 0)
        return archive
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phase4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

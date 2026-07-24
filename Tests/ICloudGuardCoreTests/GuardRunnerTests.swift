import Foundation
import XCTest
@testable import ICloudGuardCore

final class GuardRunnerTests: XCTestCase {
    func testRunReclaimsStaleLockAndClearsActiveState() throws {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.lockURL.path))

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertNil(state.activeLock)
        XCTAssertEqual(state.lastSummary?.action, GuardDecisionKind.none)
        XCTAssertEqual(state.samples.count, 1)
    }

    func testRunTreatsLiveLockContentionAsGracefulNoOp() throws {
        let sandbox = try makeSandbox()
        let runner = GuardRunner()
        let currentPID = getpid()

        try "\(currentPID)\n".write(to: sandbox.lockURL, atomically: true, encoding: .utf8)
        try saveState(
            GuardState(activeLock: ActiveLock(pid: currentPID, startedAt: Date())),
            to: sandbox.stateURL
        )

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: true)
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.lockURL.path))

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertNotNil(state.activeLock)
        XCTAssertNotNil(state.lastLockContentionAt)
        XCTAssertNil(state.lastSummary)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.lockURL.path))

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
        XCTAssertEqual(exitCode, 0)

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertEqual(state.lastSummary?.action, .targeted)
        XCTAssertEqual(state.lastSummary?.candidateCount, 1)
        XCTAssertEqual(state.lastSummary?.evictedCount, 0)
        XCTAssertEqual(state.lastSummary?.failedEvictionCount, 1)

        let log = try String(contentsOf: sandbox.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("failed=1"))
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

        let exitCode = try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: true)
        XCTAssertEqual(exitCode, 0)
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

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

    func testStatusUsesUsageScanOnly() throws {
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
        XCTAssertTrue(log.contains("scan-complete phase=usage"))
        XCTAssertFalse(log.contains("phase=candidates"))
    }

    func testTargetedRunUsesLazyCandidateSelectionPhase() throws {
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
        XCTAssertTrue(log.contains("phase=targeted-candidates"))
    }

    func testRunLogsProviderRestrictedTargetedSelectionFailure() throws {
        let sandbox = try makeSandbox()
        var config = try loadConfig(from: sandbox.configURL)
        config.policy.targetLocalGiB = 0
        config.policy.trimLocalGiB = 0
        try saveConfig(config, to: sandbox.configURL)

        let scanner = MockScanner(
            usageScans: [
                ScanResult(scopePath: sandbox.rootURL.appendingPathComponent("CloudDocs").path, freeBytes: 120 * bytesPerGiB, localBytes: 2 * bytesPerGiB, items: [])
            ],
            targetedSelections: [
                .failure(GuardError.runtime("provider access denied while enumerating managed File Provider items"))
            ]
        )
        let runner = GuardRunner(
            scannerFactory: { scanner },
            evictorFactory: { logger in MockEvictor(logger: logger, result: EvictionResult(evictedCount: 0, failedCount: 0)) }
        )

        XCTAssertThrowsError(try runner.run(command: .run, configPath: sandbox.configURL.path, dryRun: false)) { error in
            XCTAssertEqual(String(describing: error), "provider access denied while enumerating managed File Provider items")
        }

        let state = try loadState(from: sandbox.stateURL)
        XCTAssertNil(state.activeLock)
        XCTAssertNil(state.lastSummary)

        let log = try String(contentsOf: sandbox.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("scan-failure phase=targeted-candidates"))
        XCTAssertTrue(log.contains("provider access denied"))
    }

    func testRunRecordsFailedEvictionCountWhenProviderRefusesEviction() throws {
        let sandbox = try makeSandbox()
        let scopePath = sandbox.rootURL.appendingPathComponent("CloudDocs").path
        // Override remediateFreeGiB to trigger targeted eviction with mock data (40 GiB free < 50 GiB threshold)
        var config = try loadConfig(from: sandbox.configURL)
        config.policy.remediateFreeGiB = 50
        try saveConfig(config, to: sandbox.configURL)
        let candidate = snapshot(scopePath: scopePath, relativePath: "Resident.bin", localGiB: 2)
        let scanner = MockScanner(
            usageScans: [
                ScanResult(scopePath: scopePath, freeBytes: 40 * bytesPerGiB, localBytes: 2 * bytesPerGiB, items: []),
                ScanResult(scopePath: scopePath, freeBytes: 90 * bytesPerGiB, localBytes: 2 * bytesPerGiB, items: [])
            ],
            targetedSelections: [
                .success(TargetedSelectionResult(items: [candidate], inspectedCount: 1))
            ]
        )
        let runner = GuardRunner(
            scannerFactory: { scanner },
            evictorFactory: { logger in MockEvictor(logger: logger, result: EvictionResult(evictedCount: 0, failedCount: 1)) }
        )

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
            watcher: .init(backoffMaxSeconds: 60, pollutionCheckIntervalSeconds: 300),
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

    private func snapshot(scopePath: String, relativePath: String, localGiB: Int) -> ICloudItemSnapshot {
        ICloudItemSnapshot(
            relativePath: relativePath,
            absolutePath: "\(scopePath)/\(relativePath)",
            localBytes: Int64(localGiB) * bytesPerGiB,
            isRegularFile: true,
            isPackage: false,
            isUbiquitous: true,
            isUploaded: true,
            isUploading: false,
            isDownloading: false,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
            hasDownloadError: false,
            hasUploadError: false,
            contentModificationDate: Date(timeIntervalSince1970: 0)
        )
    }
}

private final class MockScanner: ICloudScanning {
    private var usageScans: [ScanResult]
    private var candidateScans: [Result<ScanResult, Error>]
    private var targetedSelections: [Result<TargetedSelectionResult, Error>]

    init(
        usageScans: [ScanResult] = [],
        candidateScans: [Result<ScanResult, Error>] = [],
        targetedSelections: [Result<TargetedSelectionResult, Error>] = []
    ) {
        self.usageScans = usageScans
        self.candidateScans = candidateScans
        self.targetedSelections = targetedSelections
    }

    func scan(scopePath: String, mode: ScanMode) throws -> ScanResult {
        switch mode {
        case .usageOnly:
            guard !usageScans.isEmpty else {
                throw GuardError.runtime("missing mocked usage scan")
            }
            return usageScans.removeFirst()
        case .candidateSelection:
            guard !candidateScans.isEmpty else {
                throw GuardError.runtime("missing mocked candidate scan")
            }
            return try candidateScans.removeFirst().get()
        }
    }

    func selectTargetedCandidates(
        scopePath: String,
        reclaimTargetBytes: Int64,
        protectedPaths: [String]
    ) throws -> TargetedSelectionResult {
        guard !targetedSelections.isEmpty else {
            throw GuardError.runtime("missing mocked targeted selection")
        }
        return try targetedSelections.removeFirst().get()
    }
}

private struct MockEvictor: ICloudEvicting {
    private let logger: GuardLogging
    private let result: EvictionResult

    init(logger: GuardLogging, result: EvictionResult) {
        self.logger = logger
        self.result = result
    }

    func evict(items: [ICloudItemSnapshot], dryRun: Bool) throws -> EvictionResult {
        if result.failedCount > 0 {
            logger.log("mock-eviction-refused count=\(result.failedCount)")
        }
        return result
    }
}

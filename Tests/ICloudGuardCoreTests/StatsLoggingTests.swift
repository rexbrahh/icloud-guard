import Foundation
import XCTest
@testable import ICloudGuardCore

/// Tests for StatsRecorder append/rotation and Logger rotation.
///
/// StatsRecorder has a hardcoded 10MB rotation threshold, so the rotation
/// tests pre-populate the file to >= 10MB before invoking the recorder. This
/// is the only way to exercise the real rotation path without modifying the
/// production code (the task forbids it).
final class StatsLoggingTests: XCTestCase {

    private var tempDir: URL!

    /// 10MB exact — matches StatsRecorder.maxFileSize so `size >= maxFileSize`
    /// fires and triggers rotation.
    private let rotationThreshold: Int = 10 * 1024 * 1024

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsLoggingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - StatsRecorder: append

    func testStatsRecorderAppend() throws {
        let statsURL = tempDir.appendingPathComponent("stats.jsonl")
        let recorder = StatsRecorder(statsURL: statsURL)

        let stat = StatsRecorder.EvictionStat(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            evictedCount: 5,
            failedCount: 1,
            reclaimedBytes: 1_024,
            dryRun: false
        )
        recorder.record(stat)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: statsURL.path),
            "stats.jsonl should exist after recording"
        )

        let contents = try String(contentsOf: statsURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "stats.jsonl should contain exactly one JSONL line")

        // Line must be valid JSON
        let jsonData = Data(lines[0].utf8)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            "Recorded line must be a valid JSON object"
        )
        XCTAssertEqual(parsed["evictedCount"] as? Int, 5)
        XCTAssertEqual(parsed["failedCount"] as? Int, 1)
        XCTAssertEqual(parsed["reclaimedBytes"] as? Int, 1_024)
        XCTAssertEqual(parsed["dryRun"] as? Bool, false)
        XCTAssertNotNil(parsed["timestamp"], "ISO 8601 timestamp must be present")
    }

    // MARK: - StatsRecorder: multiple records / valid JSONL re-read

    func testStatsRecorderMultipleRecords() throws {
        let statsURL = tempDir.appendingPathComponent("stats.jsonl")
        let recorder = StatsRecorder(statsURL: statsURL)

        let eviction = StatsRecorder.EvictionStat(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            evictedCount: 5,
            failedCount: 1,
            reclaimedBytes: 1_024,
            dryRun: false
        )
        let remat = StatsRecorder.RematerializationStat(
            timestamp: Date(timeIntervalSince1970: 1_000_001),
            itemPath: "Documents/file.txt"
        )
        let pollution = StatsRecorder.PollutionStat(
            timestamp: Date(timeIntervalSince1970: 1_000_002),
            materializedCount: 10,
            datalessCount: 2,
            pollutionRatio: 0.2
        )

        recorder.record(eviction)
        recorder.record(remat)
        recorder.record(pollution)

        let contents = try String(contentsOf: statsURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3, "stats.jsonl must contain one line per recorded stat")

        // Every line must be valid JSON with a timestamp.
        for (index, line) in lines.enumerated() {
            let jsonData = Data(line.utf8)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: jsonData),
                "Line \(index) must be valid JSON: \(line)"
            )
            let parsed = try XCTUnwrap(
                JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                "Line \(index) must be a JSON object"
            )
            XCTAssertNotNil(parsed["timestamp"], "Line \(index) must include a timestamp field")
        }

        // Round-trip each stat through the real decoders to prove the file is
        // not just "valid JSON" but also re-parseable into the original types.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let readEviction = try decoder.decode(
            StatsRecorder.EvictionStat.self,
            from: Data(lines[0].utf8)
        )
        XCTAssertEqual(readEviction, eviction)

        let readRemat = try decoder.decode(
            StatsRecorder.RematerializationStat.self,
            from: Data(lines[1].utf8)
        )
        XCTAssertEqual(readRemat, remat)

        let readPollution = try decoder.decode(
            StatsRecorder.PollutionStat.self,
            from: Data(lines[2].utf8)
        )
        XCTAssertEqual(readPollution, pollution)
        XCTAssertEqual(readPollution.pollutionRatio, 0.2, accuracy: 0.0001)
    }

    // MARK: - StatsRecorder: rotation

    func testStatsRecorderRotation() throws {
        let statsURL = tempDir.appendingPathComponent("stats.jsonl")
        let backupURL = tempDir.appendingPathComponent("stats.1.jsonl")

        // Pre-fill to exactly 10MB so `size >= maxFileSize` triggers rotation.
        try Data(count: rotationThreshold).write(to: statsURL)
        XCTAssertEqual(try fileSize(at: statsURL), Int64(rotationThreshold))

        let recorder = StatsRecorder(statsURL: statsURL)
        recorder.record(StatsRecorder.EvictionStat(
            timestamp: Date(),
            evictedCount: 1,
            failedCount: 0,
            reclaimedBytes: 100,
            dryRun: true
        ))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupURL.path),
            "stats.1.jsonl must be created when current file reaches 10MB"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: statsURL.path),
            "stats.jsonl must be re-created (empty) after rotation"
        )

        let backupSize = try fileSize(at: backupURL)
        XCTAssertEqual(
            backupSize,
            Int64(rotationThreshold),
            "stats.1.jsonl must contain the rotated 10MB content"
        )

        let newSize = try fileSize(at: statsURL)
        XCTAssertLessThan(
            newSize,
            Int64(rotationThreshold),
            "Fresh stats.jsonl must be much smaller than the rotated backup"
        )

        // The new file must contain the line we just recorded.
        let newContents = try String(contentsOf: statsURL, encoding: .utf8)
        let newLines = newContents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(newLines.count, 1, "New stats.jsonl must contain exactly the new line")
    }

    func testStatsRecorderRotationCleanup() throws {
        let statsURL = tempDir.appendingPathComponent("stats.jsonl")
        let backupURL = tempDir.appendingPathComponent("stats.1.jsonl")

        // Pre-create a stale .1.jsonl with sentinel content.
        let staleContent = "stale-pre-rotation-backup\n"
        try staleContent.write(to: backupURL, atomically: true, encoding: .utf8)

        // Pre-fill current file to 10MB to force rotation.
        try Data(count: rotationThreshold).write(to: statsURL)

        let recorder = StatsRecorder(statsURL: statsURL)
        recorder.record(StatsRecorder.EvictionStat(
            timestamp: Date(),
            evictedCount: 7,
            failedCount: 0,
            reclaimedBytes: 500,
            dryRun: true
        ))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupURL.path),
            "stats.1.jsonl must still exist after rotation"
        )

        let backupContents = try String(contentsOf: backupURL, encoding: .utf8)
        XCTAssertNotEqual(
            backupContents,
            staleContent,
            "Old stale .1.jsonl must be deleted and replaced with rotated content"
        )

        let backupSize = try fileSize(at: backupURL)
        XCTAssertEqual(
            backupSize,
            Int64(rotationThreshold),
            "Rotated backup must contain the 10MB pre-existing content"
        )

        // The newly-started file must NOT contain the stale sentinel.
        let newContents = try String(contentsOf: statsURL, encoding: .utf8)
        XCTAssertFalse(
            newContents.contains("stale-pre-rotation-backup"),
            "Fresh stats.jsonl must not inherit old backup content"
        )
    }

    // MARK: - Logger: rotation

    func testLoggerRotation() throws {
        let logURL = tempDir.appendingPathComponent("icloud-guard.log")
        // Logger uses `logURL.path + ".1"` for the backup, not URL extension.
        let backupURL = URL(fileURLWithPath: logURL.path + ".1")

        // Pre-fill the log to exactly 10MB so the rotation check fires.
        try Data(count: rotationThreshold).write(to: logURL)
        XCTAssertEqual(try fileSize(at: logURL), Int64(rotationThreshold))

        let logger = Logger(logPath: logURL.path)
        logger.log("post-rotation-marker")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupURL.path),
            "log.1 must be created when log reaches 10MB"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: logURL.path),
            "Log file must be re-created after rotation"
        )

        let backupSize = try fileSize(at: backupURL)
        XCTAssertEqual(
            backupSize,
            Int64(rotationThreshold),
            "Rotated log.1 must contain the 10MB pre-existing content"
        )

        let newSize = try fileSize(at: logURL)
        XCTAssertLessThan(
            newSize,
            Int64(rotationThreshold),
            "Fresh log file must be much smaller than the rotated backup"
        )

        let newContents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(
            newContents.contains("post-rotation-marker"),
            "Fresh log must contain the message written after rotation"
        )
    }

    // MARK: - Helpers

    private func fileSize(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}

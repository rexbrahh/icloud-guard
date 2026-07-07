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

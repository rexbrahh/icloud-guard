import Foundation
import XCTest
@testable import ICloudGuardCore

final class DownloadSuppressionTests: XCTestCase {
    func testSuppressionConfigDefaultsAreSafe() {
        let config = DownloadSuppressionConfig()
        XCTAssertTrue(config.spotlightSuppression)
        XCTAssertTrue(config.quickLookCacheClear)
        XCTAssertFalse(config.materializeDatalessFiles)
        XCTAssertTrue(config.scopePath.isEmpty)
    }

    func testSuppressionConfigCustomValuesRoundTripCodable() throws {
        let config = DownloadSuppressionConfig(
            spotlightSuppression: false,
            quickLookCacheClear: false,
            materializeDatalessFiles: true,
            scopePath: "/test/path"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DownloadSuppressionConfig.self, from: data)

        XCTAssertEqual(config, decoded)
    }

    func testSpotlightMarkerCreationSucceeds() throws {
        let sandbox = try makeSandbox()
        let config = DownloadSuppressionConfig(
            spotlightSuppression: true,
            quickLookCacheClear: false,
            materializeDatalessFiles: false,
            scopePath: sandbox.scopeURL.path
        )
        let logger = TestLogger()
        let suppression = DownloadSuppression(config: config, logger: logger)

        suppression.apply()

        let markerURL = sandbox.scopeURL.appendingPathComponent(".metadata_never_index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(logger.messages.contains(where: { $0.contains("spotlight marker-created") }))
    }

    func testSpotlightMarkerIsIdempotent() throws {
        let sandbox = try makeSandbox()
        let markerURL = sandbox.scopeURL.appendingPathComponent(".metadata_never_index")
        try Data().write(to: markerURL)

        let config = DownloadSuppressionConfig(
            spotlightSuppression: true,
            quickLookCacheClear: false,
            materializeDatalessFiles: false,
            scopePath: sandbox.scopeURL.path
        )
        let logger = TestLogger()
        let suppression = DownloadSuppression(config: config, logger: logger)

        suppression.apply()

        XCTAssertTrue(logger.messages.contains(where: { $0.contains("already-marked") }))
    }

    func testRemoveSpotlightSuppressionDeletesMarker() throws {
        let sandbox = try makeSandbox()
        let markerURL = sandbox.scopeURL.appendingPathComponent(".metadata_never_index")
        try Data().write(to: markerURL)

        let config = DownloadSuppressionConfig(
            spotlightSuppression: true,
            quickLookCacheClear: false,
            materializeDatalessFiles: false,
            scopePath: sandbox.scopeURL.path
        )
        let logger = TestLogger()
        let suppression = DownloadSuppression(config: config, logger: logger)

        suppression.removeSpotlightSuppression()

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    private func makeSandbox() throws -> (rootURL: URL, scopeURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scopeURL = rootURL.appendingPathComponent("CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: scopeURL, withIntermediateDirectories: true)
        return (rootURL, scopeURL)
    }
}

// MARK: - EvictionVerification Tests

final class EvictionVerificationTests: XCTestCase {
    func testVerifyDatalessReturnsCorrectFlagsForRegularFile() throws {
        let sandbox = try makeSandbox()
        let fileURL = sandbox.appendingPathComponent("test.bin")
        try Data(repeating: 0x41, count: 4096).write(to: fileURL)

        let verification = DatalessVerifier.verify(at: fileURL.path)

        XCTAssertEqual(verification.absolutePath, fileURL.path)
        XCTAssertFalse(verification.isDataless)
        XCTAssertGreaterThan(verification.fileAllocatedSize, 0)
        XCTAssertEqual(verification.fileSize, 4096)
        XCTAssertFalse(verification.isVerifiedDataless)
    }

    func testVerifyDatalessReturnsZeroForNonexistentFile() {
        let verification = DatalessVerifier.verify(at: "/nonexistent/path/file.bin")

        XCTAssertFalse(verification.isDataless)
        XCTAssertEqual(verification.fileAllocatedSize, 0)
        XCTAssertEqual(verification.fileSize, 0)
        XCTAssertFalse(verification.isVerifiedDataless)
    }

    func testIsVerifiedDatalessTrueWhenDatalessFlagSet() {
        let verification = EvictionVerification(
            absolutePath: "/test/path",
            isDataless: true,
            fileAllocatedSize: 0,
            fileSize: 1024
        )
        XCTAssertTrue(verification.isVerifiedDataless)
    }

    func testIsVerifiedDatalessFalseWhenAllocatedSizeNonZero() {
        let verification = EvictionVerification(
            absolutePath: "/test/path",
            isDataless: true,
            fileAllocatedSize: 512,
            fileSize: 1024
        )
        XCTAssertFalse(verification.isVerifiedDataless)
    }

    private func makeSandbox() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

// MARK: - Rematerialization Tests

final class RematerializationEventTests: XCTestCase {
    func testRematerializationEventCodableRoundTrip() throws {
        let event = RematerializationEvent(
            itemPath: "/test/path/file.pdf",
            detectedAt: Date(timeIntervalSince1970: 1700000000),
            previousStatus: "NSURLUbiquitousItemDownloadingStatusNotDownloaded",
            newStatus: "NSURLUbiquitousItemDownloadingStatusCurrent"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RematerializationEvent.self, from: data)

        XCTAssertEqual(event, decoded)
    }

    func testRematerializationEventEquality() {
        let date = Date()
        let event1 = RematerializationEvent(
            itemPath: "/test",
            detectedAt: date,
            previousStatus: "old",
            newStatus: "new"
        )
        let event2 = RematerializationEvent(
            itemPath: "/test",
            detectedAt: date,
            previousStatus: "old",
            newStatus: "new"
        )
        XCTAssertEqual(event1, event2)
    }
}

// MARK: - EvictionEngine Tests

final class EvictionEngineTests: XCTestCase {
    func testEvictNonUbiquitousFileCountsFailureWithReason() throws {
        let sandbox = try makeSandbox()
        let fileURL = sandbox.appendingPathComponent("regular.txt")
        try Data(repeating: 0x42, count: 256).write(to: fileURL)

        let logger = TestLogger()
        let engine = EvictionEngine(logger: logger)
        let candidate = EvictionCandidate(
            path: fileURL.path,
            relativePath: "regular.txt",
            allocatedBytes: 256,
            modificationDate: Date()
        )

        let outcome = engine.evict(candidates: [candidate])
        // Non-ubiquitous files can't be evicted — failure must be categorized, not silent
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertEqual(outcome.evictedCount, 0)
        XCTAssertEqual(outcome.reclaimedBytes, 0)
        XCTAssertEqual(outcome.failureReasons.values.reduce(0, +), 1)
        XCTAssertTrue(logger.messages.contains(where: { $0.contains("evict-failed path=regular.txt") }))
    }

    func testFileBudgetStopsEviction() throws {
        let sandbox = try makeSandbox()
        var candidates: [EvictionCandidate] = []
        for index in 0..<5 {
            let fileURL = sandbox.appendingPathComponent("file\(index).txt")
            try Data(repeating: 0x43, count: 128).write(to: fileURL)
            candidates.append(EvictionCandidate(
                path: fileURL.path,
                relativePath: "file\(index).txt",
                allocatedBytes: 128,
                modificationDate: Date()
            ))
        }

        let engine = EvictionEngine(logger: TestLogger())
        let outcome = engine.evict(candidates: candidates, fileBudget: 2)
        XCTAssertEqual(outcome.evictedCount + outcome.failedCount, 2)
    }

    func testCancellationStopsEviction() throws {
        let sandbox = try makeSandbox()
        var candidates: [EvictionCandidate] = []
        for index in 0..<5 {
            let fileURL = sandbox.appendingPathComponent("file\(index).txt")
            try Data(repeating: 0x44, count: 128).write(to: fileURL)
            candidates.append(EvictionCandidate(
                path: fileURL.path,
                relativePath: "file\(index).txt",
                allocatedBytes: 128,
                modificationDate: Date()
            ))
        }

        let cancellation = EvictionCancellation()
        cancellation.cancel()
        let engine = EvictionEngine(logger: TestLogger())
        let outcome = engine.evict(candidates: candidates, cancellation: cancellation)
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.evictedCount + outcome.failedCount, 0)
    }

    private func makeSandbox() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

// MARK: - Test Utilities

private final class TestLogger: GuardLogging {
    var messages: [String] = []

    func log(_ message: String) {
        messages.append(message)
    }
}

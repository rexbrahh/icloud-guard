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

        let verification = PackageAwareEvictor.verifyDataless(at: fileURL.path)

        XCTAssertEqual(verification.absolutePath, fileURL.path)
        XCTAssertFalse(verification.isDataless)
        XCTAssertGreaterThan(verification.fileAllocatedSize, 0)
        XCTAssertEqual(verification.fileSize, 4096)
        XCTAssertFalse(verification.isVerifiedDataless)
    }

    func testVerifyDatalessReturnsZeroForNonexistentFile() {
        let verification = PackageAwareEvictor.verifyDataless(at: "/nonexistent/path/file.bin")

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

// MARK: - PackageAwareEvictor Tests

final class PackageAwareEvictorTests: XCTestCase {
    func testDryRunDoesNotEvict() throws {
        let logger = TestLogger()
        let evictor = PackageAwareEvictor(logger: logger)

        let item = ICloudItemSnapshot(
            relativePath: "test.bin",
            absolutePath: "/tmp/test.bin",
            localBytes: 1024,
            isRegularFile: true,
            isPackage: false,
            isUbiquitous: true,
            isUploaded: true,
            isUploading: false,
            isDownloading: false,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
            hasDownloadError: false,
            hasUploadError: false,
            contentModificationDate: Date()
        )

        let result = try evictor.evict(items: [item], dryRun: true)
        XCTAssertEqual(result.evictedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(logger.messages.contains(where: { $0.contains("dry-run evict") }))
    }

    func testEvictRegularFileLogsSuccess() throws {
        let sandbox = try makeSandbox()
        let fileURL = sandbox.appendingPathComponent("regular.txt")
        try Data(repeating: 0x42, count: 256).write(to: fileURL)

        let logger = TestLogger()
        let evictor = PackageAwareEvictor(logger: logger)

        let item = ICloudItemSnapshot(
            relativePath: "regular.txt",
            absolutePath: fileURL.path,
            localBytes: 256,
            isRegularFile: true,
            isPackage: false,
            isUbiquitous: false,
            isUploaded: true,
            isUploading: false,
            isDownloading: false,
            downloadingStatus: nil,
            hasDownloadError: false,
            hasUploadError: false,
            contentModificationDate: Date()
        )

        // This will fail because the file is not ubiquitous, but it tests the path
        let result = try evictor.evict(items: [item], dryRun: false)
        // Non-ubiquitous files can't be evicted
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.evictedCount, 0)
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

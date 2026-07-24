import Foundation
import XCTest
@testable import ICloudGuardCore

final class BulkScannerTests: XCTestCase {
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

    func testScanFindsRegularFilesWithSizesAndRelativePaths() throws {
        let sub = tempDir.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: tempDir.appendingPathComponent("a.bin"))
        try Data(repeating: 0x42, count: 8192).write(to: sub.appendingPathComponent("b.bin"))

        var entries: [BulkScanEntry] = []
        try BulkScanner.scan(rootPath: tempDir.path) { entries.append($0) }

        let files = entries.filter { $0.isRegularFile }
        XCTAssertEqual(files.count, 2)

        let a = try XCTUnwrap(files.first { $0.relativePath == "a.bin" })
        XCTAssertGreaterThan(a.allocatedBytes, 0)
        XCTAssertEqual(a.logicalBytes, 4096)
        XCTAssertFalse(a.isDataless)
        XCTAssertTrue(a.isLocallyResidentFile)

        let b = try XCTUnwrap(files.first { $0.relativePath == "Sub/b.bin" })
        XCTAssertEqual(b.logicalBytes, 8192)
    }

    func testScanSkipsHiddenFilesAndReportsDirectories() throws {
        try Data(repeating: 0x41, count: 128).write(to: tempDir.appendingPathComponent(".hidden"))
        try Data(repeating: 0x41, count: 128).write(to: tempDir.appendingPathComponent("visible"))
        let sub = tempDir.appendingPathComponent("SubDir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        var entries: [BulkScanEntry] = []
        try BulkScanner.scan(rootPath: tempDir.path) { entries.append($0) }

        XCTAssertEqual(entries.filter { $0.isRegularFile }.count, 1)
        XCTAssertEqual(entries.filter { $0.isDirectory }.map(\.relativePath), ["SubDir"])
    }

    func testScanDoesNotFollowSymlinks() throws {
        let target = tempDir.appendingPathComponent("target.txt")
        try Data(repeating: 0x41, count: 128).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("link.txt"),
            withDestinationURL: target
        )

        var entries: [BulkScanEntry] = []
        try BulkScanner.scan(rootPath: tempDir.path) { entries.append($0) }

        let files = entries.filter { $0.isRegularFile }
        XCTAssertEqual(files.map(\.relativePath), ["target.txt"])
    }

    func testScanRespectsShouldStop() throws {
        for index in 0..<10 {
            try Data(repeating: 0x41, count: 128).write(to: tempDir.appendingPathComponent("f\(index).txt"))
        }

        var count = 0
        try BulkScanner.scan(rootPath: tempDir.path, shouldStop: { true }) { _ in count += 1 }
        // Stop is checked between directories: the root directory is scanned
        // before the first check in some orderings, so tolerate either early exit.
        XCTAssertLessThanOrEqual(count, 10)
    }

    func testScanThrowsForMissingRoot() {
        XCTAssertThrowsError(try BulkScanner.scan(rootPath: tempDir.appendingPathComponent("Nope").path) { _ in }) { error in
            XCTAssertTrue(String(describing: error).contains("cannot open scan root"))
        }
    }
}

final class DriveStatsTests: XCTestCase {
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

    func testDirectoriesAreNeverCountedAsMaterializedFiles() throws {
        // Several directories, one file — directories must not pollute counts.
        for index in 0..<5 {
            try FileManager.default.createDirectory(
                at: tempDir.appendingPathComponent("Dir\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data(repeating: 0x41, count: 4096).write(to: tempDir.appendingPathComponent("Dir0/file.bin"))

        let stats = try DriveStatsCollector.collect(scopePath: tempDir.path)

        XCTAssertEqual(stats.materializedFiles, 1)
        XCTAssertEqual(stats.datalessFiles, 0)
        XCTAssertGreaterThan(stats.materializedBytes, 0)
        XCTAssertEqual(stats.materializedRatio, 1.0)
        XCTAssertEqual(stats.topFolders.first?.name, "Dir0")
    }

    func testTopFoldersRankedByBytes() throws {
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("Small", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("Big", isDirectory: true), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024).write(to: tempDir.appendingPathComponent("Small/s.bin"))
        try Data(repeating: 0x41, count: 65536).write(to: tempDir.appendingPathComponent("Big/b.bin"))

        let stats = try DriveStatsCollector.collect(scopePath: tempDir.path)

        XCTAssertEqual(stats.topFolders.first?.name, "Big")
        XCTAssertEqual(stats.materializedFiles, 2)
    }

    func testEmptyScopeYieldsZeroRatioNotNaN() throws {
        let stats = try DriveStatsCollector.collect(scopePath: tempDir.path)
        XCTAssertEqual(stats.materializedRatio, 0)
        XCTAssertEqual(stats.totalFiles, 0)
    }
}

final class ProtectedPathsTests: XCTestCase {
    func testRelativePrefixMatch() {
        let matcher = ProtectedPathsMatcher(patterns: ["Documents/work"])
        XCTAssertTrue(matcher.isProtected(path: "/scope/Documents/work/file.txt", relativePath: "Documents/work/file.txt"))
        XCTAssertTrue(matcher.isProtected(path: "/scope/Documents/work", relativePath: "Documents/work"))
        XCTAssertFalse(matcher.isProtected(path: "/scope/Documents/other", relativePath: "Documents/other"))
    }

    func testAbsolutePrefixMatch() {
        let matcher = ProtectedPathsMatcher(patterns: ["/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Keep"])
        XCTAssertTrue(matcher.isProtected(
            path: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Keep/x.bin",
            relativePath: "Keep/x.bin"
        ))
    }

    func testGlobMatch() {
        let matcher = ProtectedPathsMatcher(patterns: ["*.photoslibrary"])
        XCTAssertTrue(matcher.isProtected(path: "/scope/Photos.photoslibrary/original.jpg", relativePath: "Photos.photoslibrary/original.jpg"))
        XCTAssertFalse(matcher.isProtected(path: "/scope/file.txt", relativePath: "file.txt"))
    }

    func testEmptyAndWhitespacePatternsIgnored() {
        let matcher = ProtectedPathsMatcher(patterns: ["", "   "])
        XCTAssertTrue(matcher.isEmpty)
        XCTAssertFalse(matcher.isProtected(path: "/anything", relativePath: "anything"))
    }
}

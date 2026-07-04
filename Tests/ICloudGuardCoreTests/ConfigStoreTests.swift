import Foundation
import XCTest
@testable import ICloudGuardCore

final class ConfigStoreTests: XCTestCase {
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

    func testDefaultConfigHasCorrectDefaults() {
        let config = AppConfig()
        XCTAssertTrue(config.suppression.spotlight)
        XCTAssertTrue(config.suppression.quicklook)
        XCTAssertFalse(config.suppression.materializeDataless)
        XCTAssertEqual(config.eviction.batchLimit, 500)
        XCTAssertEqual(config.eviction.panicLimit, 2000)
        XCTAssertEqual(config.watcher.backoffMaxSeconds, 60)
        XCTAssertEqual(config.watcher.pollutionCheckIntervalSeconds, 300)
        XCTAssertTrue(config.scope.path.contains("CloudDocs"))
        XCTAssertTrue(config.scope.protectedPaths.isEmpty)
    }

    func testTomlRoundTrip() throws {
        let original = AppConfig(
            suppression: .init(spotlight: false, quicklook: false, materializeDataless: true),
            eviction: .init(batchLimit: 100, panicLimit: 500),
            watcher: .init(backoffMaxSeconds: 30, pollutionCheckIntervalSeconds: 120),
            scope: .init(path: "/custom/path", protectedPaths: ["/keep/this", "/also/this"])
        )

        let store = ConfigStore(configURL: tempDir.appendingPathComponent("config.toml"))
        try store.save(original)
        let loaded = store.load()

        XCTAssertEqual(loaded.suppression.spotlight, false)
        XCTAssertEqual(loaded.suppression.quicklook, false)
        XCTAssertEqual(loaded.suppression.materializeDataless, true)
        XCTAssertEqual(loaded.eviction.batchLimit, 100)
        XCTAssertEqual(loaded.eviction.panicLimit, 500)
        XCTAssertEqual(loaded.watcher.backoffMaxSeconds, 30)
        XCTAssertEqual(loaded.watcher.pollutionCheckIntervalSeconds, 120)
        XCTAssertEqual(loaded.scope.path, "/custom/path")
        XCTAssertEqual(loaded.scope.protectedPaths, ["/keep/this", "/also/this"])
    }

    func testParseEmptyFile() {
        let store = ConfigStore(configURL: tempDir.appendingPathComponent("empty.toml"))
        let config = store.load()
        XCTAssertEqual(config, AppConfig())
    }

    func testParseProtectedPaths() {
        let toml = """
        [scope]
        path = "/test"
        protected_paths = ["/a/b", "/c/d"]
        """
        let url = tempDir.appendingPathComponent("paths.toml")
        try? toml.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        let config = store.load()
        XCTAssertEqual(config.scope.protectedPaths, ["/a/b", "/c/d"])
    }

    func testSerializeProducesValidToml() throws {
        let config = AppConfig()
        let store = ConfigStore(configURL: tempDir.appendingPathComponent("out.toml"))
        try store.save(config)
        let content = try String(contentsOf: store.configURLPath.url, encoding: .utf8)
        XCTAssertTrue(content.contains("[suppression]"))
        XCTAssertTrue(content.contains("[eviction]"))
        XCTAssertTrue(content.contains("[watcher]"))
        XCTAssertTrue(content.contains("[scope]"))
        XCTAssertTrue(content.contains("spotlight = true"))
        XCTAssertTrue(content.contains("batch_limit = 500"))
        XCTAssertTrue(content.contains("protected_paths = []"))
    }

    func testMissingSectionsFallBackToDefaults() {
        let toml = """
        [suppression]
        spotlight = false
        """
        let url = tempDir.appendingPathComponent("partial.toml")
        try? toml.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        let config = store.load()
        XCTAssertEqual(config.suppression.spotlight, false)
        XCTAssertEqual(config.eviction.batchLimit, 500)
        XCTAssertEqual(config.watcher.backoffMaxSeconds, 60)
    }

    func testParseComments() {
        let toml = """
        # this is a comment
        [suppression]
        # another comment
        spotlight = false
        """
        let url = tempDir.appendingPathComponent("comments.toml")
        try? toml.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        let config = store.load()
        XCTAssertFalse(config.suppression.spotlight)
    }

    func testEmptyProtectedPaths() {
        let toml = """
        [scope]
        protected_paths = []
        """
        let url = tempDir.appendingPathComponent("empty_paths.toml")
        try? toml.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        let config = store.load()
        XCTAssertTrue(config.scope.protectedPaths.isEmpty)
    }
}

extension String {
    var url: URL { URL(fileURLWithPath: self) }
}

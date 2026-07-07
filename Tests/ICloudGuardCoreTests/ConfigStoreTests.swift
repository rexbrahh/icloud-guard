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
        XCTAssertFalse(config.watcher.metadataWatcherEnabled)
        XCTAssertEqual(config.watcher.backoffMaxSeconds, 60)
        XCTAssertEqual(config.watcher.pollutionCheckIntervalSeconds, 300)
        XCTAssertTrue(config.scope.path.contains("CloudDocs"))
        XCTAssertTrue(config.scope.protectedPaths.isEmpty)
    }

    func testTomlRoundTrip() throws {
        let original = AppConfig(
            suppression: .init(spotlight: false, quicklook: false, materializeDataless: true),
            eviction: .init(batchLimit: 100, panicLimit: 500),
            watcher: .init(metadataWatcherEnabled: true, backoffMaxSeconds: 30, pollutionCheckIntervalSeconds: 120),
            scope: .init(path: "/custom/path", protectedPaths: ["/keep/this", "/also/this"]),
            policy: .init(targetLocalGiB: 20, trimLocalGiB: 25, warnFreeGiB: 70, remediateFreeGiB: 40, panicFreeGiB: 20, cooldownMinutes: 15, growthTriggerGiB: 10, growthWindowMinutes: 5)
        )

        let store = ConfigStore(configURL: tempDir.appendingPathComponent("config.toml"))
        try store.save(original)
        let loaded = store.load()

        XCTAssertEqual(loaded.suppression.spotlight, false)
        XCTAssertEqual(loaded.suppression.quicklook, false)
        XCTAssertEqual(loaded.suppression.materializeDataless, true)
        XCTAssertEqual(loaded.eviction.batchLimit, 100)
        XCTAssertEqual(loaded.eviction.panicLimit, 500)
        XCTAssertEqual(loaded.watcher.metadataWatcherEnabled, true)
        XCTAssertEqual(loaded.watcher.backoffMaxSeconds, 30)
        XCTAssertEqual(loaded.watcher.pollutionCheckIntervalSeconds, 120)
        XCTAssertEqual(loaded.scope.path, "/custom/path")
        XCTAssertEqual(loaded.scope.protectedPaths, ["/keep/this", "/also/this"])
        XCTAssertEqual(loaded.policy.targetLocalGiB, 20)
        XCTAssertEqual(loaded.policy.trimLocalGiB, 25)
        XCTAssertEqual(loaded.policy.warnFreeGiB, 70)
        XCTAssertEqual(loaded.policy.remediateFreeGiB, 40)
        XCTAssertEqual(loaded.policy.panicFreeGiB, 20)
        XCTAssertEqual(loaded.policy.cooldownMinutes, 15)
        XCTAssertEqual(loaded.policy.growthTriggerGiB, 10)
        XCTAssertEqual(loaded.policy.growthWindowMinutes, 5)
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
        XCTAssertTrue(content.contains("[policy]"))
        XCTAssertTrue(content.contains("spotlight = true"))
        XCTAssertTrue(content.contains("batch_limit = 500"))
        XCTAssertTrue(content.contains("metadata_watcher_enabled = false"))
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
        XCTAssertFalse(config.watcher.metadataWatcherEnabled)
        XCTAssertEqual(config.watcher.backoffMaxSeconds, 60)
        XCTAssertEqual(config.policy.targetLocalGiB, 30)
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

    func testLoadModifySaveReloadCycle() throws {
        let url = tempDir.appendingPathComponent("cycle.toml")
        let firstStore = ConfigStore(configURL: url)
        var config = firstStore.load()
        config.suppression.spotlight = false
        try firstStore.save(config)

        let secondStore = ConfigStore(configURL: url)
        let reloaded = secondStore.load()

        XCTAssertEqual(reloaded.suppression.spotlight, false)
        XCTAssertEqual(reloaded, AppConfig(
            suppression: .init(spotlight: false),
            eviction: .init(),
            watcher: .init(),
            scope: .init()
        ))
    }

    func testDefaultConfigIdempotency() throws {
        let url = tempDir.appendingPathComponent("idempotent.toml")
        let store = ConfigStore(configURL: url)
        let defaults = AppConfig()

        try store.save(defaults)
        try store.save(defaults)
        let loaded = store.load()

        XCTAssertEqual(loaded, AppConfig())
    }

    func testAppConfigModelWrap() throws {
        let url = tempDir.appendingPathComponent("modelwrap.toml")
        let firstStore = ConfigStore(configURL: url)

        var config = firstStore.load()
        config.suppression = .init(spotlight: false, quicklook: false, materializeDataless: true)
        config.eviction = .init(batchLimit: 100, panicLimit: 500)
        config.watcher = .init(metadataWatcherEnabled: true, backoffMaxSeconds: 30, pollutionCheckIntervalSeconds: 120)
        config.scope = .init(path: "/custom/path", protectedPaths: ["/keep/this", "/also/this"])
        try firstStore.save(config)

        let secondStore = ConfigStore(configURL: url)
        let reloaded = secondStore.load()

        XCTAssertEqual(reloaded.suppression, AppConfig.SuppressionConfig(spotlight: false, quicklook: false, materializeDataless: true))
        XCTAssertEqual(reloaded.eviction, AppConfig.EvictionConfig(batchLimit: 100, panicLimit: 500))
        XCTAssertEqual(reloaded.watcher, AppConfig.WatcherConfig(metadataWatcherEnabled: true, backoffMaxSeconds: 30, pollutionCheckIntervalSeconds: 120))
        XCTAssertEqual(reloaded.scope, AppConfig.ScopeConfig(path: "/custom/path", protectedPaths: ["/keep/this", "/also/this"]))
    }


    func testSettingsPersistenceSpotlightToggle() throws {
        let url = tempDir.appendingPathComponent("settings_spotlight.toml")
        let firstStore = ConfigStore(configURL: url)
        var config = firstStore.load()
        XCTAssertTrue(config.suppression.spotlight)

        config.suppression.spotlight = false
        try firstStore.save(config)

        let secondStore = ConfigStore(configURL: url)
        let reloaded = secondStore.load()

        XCTAssertEqual(reloaded.suppression.spotlight, false)
        XCTAssertEqual(reloaded.suppression.quicklook, true)
        XCTAssertEqual(reloaded.suppression.materializeDataless, false)
        XCTAssertEqual(reloaded.eviction, AppConfig.EvictionConfig())
        XCTAssertEqual(reloaded.watcher, AppConfig.WatcherConfig())
        XCTAssertEqual(reloaded.scope, AppConfig.ScopeConfig())
        XCTAssertEqual(reloaded.policy, AppConfig.PolicyConfig())
    }

    func testSettingsPersistenceProtectedPathsRoundTrip() throws {
        let url = tempDir.appendingPathComponent("settings_paths.toml")
        let firstStore = ConfigStore(configURL: url)
        var config = firstStore.load()
        XCTAssertTrue(config.scope.protectedPaths.isEmpty)

        config.scope.protectedPaths = ["/keep/this"]
        try firstStore.save(config)

        let secondStore = ConfigStore(configURL: url)
        var reloaded = secondStore.load()
        XCTAssertEqual(reloaded.scope.protectedPaths, ["/keep/this"])

        reloaded.scope.protectedPaths = ["/keep/this", "/also/this"]
        try secondStore.save(reloaded)

        let thirdStore = ConfigStore(configURL: url)
        var reloaded2 = thirdStore.load()
        XCTAssertEqual(reloaded2.scope.protectedPaths, ["/keep/this", "/also/this"])

        reloaded2.scope.protectedPaths = ["/keep/this"]
        try thirdStore.save(reloaded2)

        let fourthStore = ConfigStore(configURL: url)
        let reloaded3 = fourthStore.load()
        XCTAssertEqual(reloaded3.scope.protectedPaths, ["/keep/this"])
    }

    func testSettingsPersistencePolicyFields() throws {
        let url = tempDir.appendingPathComponent("settings_policy.toml")
        let firstStore = ConfigStore(configURL: url)
        var config = firstStore.load()

        config.policy.targetLocalGiB = 15
        config.policy.cooldownMinutes = 5
        try firstStore.save(config)

        let secondStore = ConfigStore(configURL: url)
        let reloaded = secondStore.load()

        XCTAssertEqual(reloaded.policy.targetLocalGiB, 15)
        XCTAssertEqual(reloaded.policy.cooldownMinutes, 5)
        XCTAssertEqual(reloaded.policy.trimLocalGiB, 35)
        XCTAssertEqual(reloaded.policy.warnFreeGiB, 80)
        XCTAssertEqual(reloaded.policy.remediateFreeGiB, 50)
        XCTAssertEqual(reloaded.policy.panicFreeGiB, 25)
        XCTAssertEqual(reloaded.policy.growthTriggerGiB, 20)
        XCTAssertEqual(reloaded.policy.growthWindowMinutes, 10)
    }

    func testInvalidPolicyThresholdsAreNormalized() throws {
        let url = tempDir.appendingPathComponent("settings_invalid_policy.toml")
        let store = ConfigStore(configURL: url)
        var config = store.load()

        config.policy.targetLocalGiB = 15
        config.policy.trimLocalGiB = 13
        config.policy.warnFreeGiB = 20
        config.policy.remediateFreeGiB = 30
        config.policy.panicFreeGiB = 40
        try store.save(config)

        let reloaded = ConfigStore(configURL: url).load()
        XCTAssertEqual(reloaded.policy.targetLocalGiB, 15)
        XCTAssertEqual(reloaded.policy.trimLocalGiB, 16)
        XCTAssertEqual(reloaded.policy.panicFreeGiB, 40)
        XCTAssertEqual(reloaded.policy.remediateFreeGiB, 40)
        XCTAssertEqual(reloaded.policy.warnFreeGiB, 40)
    }

}

extension String {
    var url: URL { URL(fileURLWithPath: self) }
}

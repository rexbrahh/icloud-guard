import CryptoKit
import Darwin
import Foundation
import os
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
        XCTAssertEqual(config.watcher.watchlistPollSeconds, 10)
        XCTAssertEqual(config.watcher.backoffMaxSeconds, 60)
        XCTAssertEqual(config.watcher.pollutionCheckIntervalSeconds, 300)
        XCTAssertTrue(config.scope.path.contains("CloudDocs"))
        XCTAssertTrue(config.scope.protectedPaths.isEmpty)
        XCTAssertEqual(config.energy, EnergySchedulingPolicy())
        XCTAssertFalse(config.updates.enabled)
        XCTAssertEqual(config.updates.channel, .stable)
        XCTAssertTrue(config.updates.feedURL.isEmpty)
        XCTAssertTrue(config.updates.keyID.isEmpty)
        XCTAssertTrue(config.updates.publicKeyX963Base64.isEmpty)
        XCTAssertTrue(config.updates.teamID.isEmpty)
        XCTAssertNil(try config.updates.verifiedUpdaterConfiguration())
    }

    func testTomlRoundTrip() throws {
        let original = AppConfig(
            suppression: .init(spotlight: false, quicklook: false, materializeDataless: true),
            eviction: .init(batchLimit: 100, panicLimit: 500),
            watcher: .init(backoffMaxSeconds: 30, pollutionCheckIntervalSeconds: 120, watchlistPollSeconds: 15),
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
        XCTAssertEqual(loaded.watcher.watchlistPollSeconds, 15)
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
        XCTAssertTrue(content.contains("watchlist_poll_seconds = 10"))
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
        XCTAssertEqual(config.watcher.watchlistPollSeconds, 10)
        XCTAssertEqual(config.watcher.backoffMaxSeconds, 60)
        XCTAssertEqual(config.policy.targetLocalGiB, 5)
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
        config.watcher = .init(backoffMaxSeconds: 30, pollutionCheckIntervalSeconds: 120, watchlistPollSeconds: 15)
        config.scope = .init(path: "/custom/path", protectedPaths: ["/keep/this", "/also/this"])
        try firstStore.save(config)

        let secondStore = ConfigStore(configURL: url)
        let reloaded = secondStore.load()

        XCTAssertEqual(reloaded.suppression, AppConfig.SuppressionConfig(spotlight: false, quicklook: false, materializeDataless: true))
        XCTAssertEqual(reloaded.eviction, AppConfig.EvictionConfig(batchLimit: 100, panicLimit: 500))
        XCTAssertEqual(reloaded.watcher, AppConfig.WatcherConfig(backoffMaxSeconds: 30, pollutionCheckIntervalSeconds: 120, watchlistPollSeconds: 15))
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
        XCTAssertEqual(reloaded.policy.trimLocalGiB, 16)
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

    func testValidatedLoadRejectsMalformedAndTruncatedValuesWithLineNumber() throws {
        let url = tempDir.appendingPathComponent("malformed.toml")
        try "[suppression]\nspotlight = maybe\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertEqual(
                error as? ConfigStore.ConfigError,
                .init(line: 2, message: "suppression.spotlight must be true or false")
            )
        }

        try "[scope]\nprotected_paths = [\"unfinished\"\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertTrue(error.localizedDescription.contains("line 2"))
            XCTAssertTrue(error.localizedDescription.contains("array of quoted strings"))
        }

        try Data().write(to: url)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertTrue(error.localizedDescription.contains("empty or truncated"))
        }

        try "[policy]\ntarget_local_gib = 5\n[policy]\ntrim_local_gib = 8\n"
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertEqual(
                error as? ConfigStore.ConfigError,
                .init(line: 3, message: "duplicate section [policy]")
            )
        }
    }

    func testMigrationPreservesCommentsUnknownKeysAndLegacyFieldsIdempotently() throws {
        let url = tempDir.appendingPathComponent("legacy.toml")
        let legacy = """
        # operator note
        [suppression]
        spotlight = false # keep this note
        vendor_mode = "future"

        [watcher]
        metadata_watcher_enabled = true
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)

        let first = try store.loadMigratingValidated()
        let afterFirst = try String(contentsOf: url, encoding: .utf8)
        let second = try store.loadMigratingValidated()
        let afterSecond = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(first.suppression.spotlight)
        XCTAssertEqual(second, first)
        XCTAssertEqual(afterSecond, afterFirst)
        XCTAssertTrue(afterFirst.contains("# operator note"))
        XCTAssertTrue(afterFirst.contains("# keep this note"))
        XCTAssertTrue(afterFirst.contains("vendor_mode = \"future\""))
        XCTAssertTrue(afterFirst.contains("metadata_watcher_enabled = true"))
        XCTAssertTrue(afterFirst.contains("growth_window_minutes = 10"))
    }

    func testValidatedLoadRejectsDuplicateUnknownKey() throws {
        let url = tempDir.appendingPathComponent("duplicate-unknown.toml")
        try "[vendor]\nmode = \"one\"\nmode = \"two\"\n"
            .write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertEqual(
                error as? ConfigStore.ConfigError,
                .init(line: 3, message: "duplicate key vendor.mode")
            )
        }
    }

    func testMigrationRejectsDuplicateLegacyKeyWithoutRewritingOriginal() throws {
        let url = tempDir.appendingPathComponent("duplicate-legacy.toml")
        let original = "[watcher]\nmetadata_watcher_enabled = true\nmetadata_watcher_enabled = false\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ConfigStore(configURL: url).loadMigratingValidated()) { error in
            XCTAssertEqual(
                error as? ConfigStore.ConfigError,
                .init(line: 3, message: "duplicate key watcher.metadata_watcher_enabled")
            )
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testSaveFailureIsThrownAndDoesNotReplaceOriginal() throws {
        enum InjectedFailure: Error { case flush }
        let url = tempDir.appendingPathComponent("write-failure.toml")
        let original = "[suppression]\nspotlight = true\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url) { _, _ in throw InjectedFailure.flush }

        XCTAssertThrowsError(try store.save(AppConfig(suppression: .init(spotlight: false)))) { error in
            XCTAssertTrue(error.localizedDescription.contains("cannot save"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testEnergyAndEnabledUpdaterRoundTripAndFactory() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let updates = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .beta,
            feedURL: "https://updates.example.test/beta/feed.json",
            keyID: "release-key_2026.08",
            publicKeyX963Base64: publicKey.base64EncodedString(),
            teamID: "A1B2C3D4E5"
        )
        let original = AppConfig(
            energy: .init(
                enabled: false,
                deferOnLowPowerMode: false,
                deferOnSeriousThermalState: true,
                deferOnBatteryPower: false
            ),
            updates: updates
        )
        let url = tempDir.appendingPathComponent("energy-updates.toml")

        try ConfigStore(configURL: url).save(original)
        let loaded = try ConfigStore(configURL: url).loadValidated()

        XCTAssertEqual(loaded, original)
        let updater = try XCTUnwrap(loaded.updates.verifiedUpdaterConfiguration(temporaryRoot: tempDir))
        XCTAssertEqual(updater.feedURL.absoluteString, updates.feedURL)
        XCTAssertEqual(updater.channel, .beta)
        XCTAssertEqual(updater.currentVersion.description, ICloudGuardProduct.version)
        XCTAssertEqual(updater.expectedKeyID, updates.keyID)
        XCTAssertEqual(updater.publicKeyX963, publicKey)
        XCTAssertEqual(updater.expectedTeamID, updates.teamID)
        XCTAssertEqual(updater.temporaryRoot, tempDir)
    }

    func testUpdaterParsingRejectsMalformedTypesChannelsAndBoundsWithoutWriting() throws {
        let url = tempDir.appendingPathComponent("malformed-updates.toml")
        let malformed = "[energy]\nenabled = yes\n"
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertEqual(
                error as? ConfigStore.ConfigError,
                .init(line: 2, message: "energy.enabled must be true or false")
            )
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), malformed)

        let invalidChannel = "[updates]\nchannel = \"nightly\"\n"
        try invalidChannel.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertEqual(
                error as? ConfigStore.ConfigError,
                .init(line: 2, message: "updates.channel must be stable, beta, or tip")
            )
        }

        let oversizedKeyID = String(repeating: "a", count: 129)
        let oversized = "[updates]\nkey_id = \"\(oversizedKeyID)\"\n"
        try oversized.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertEqual(
                error as? ConfigStore.ConfigError,
                .init(line: 2, message: "updates.key_id exceeds 128 UTF-8 bytes")
            )
        }
    }

    func testEnabledUpdaterRejectsUnsafeTrustInputsAndTip() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let valid = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .stable,
            feedURL: "https://updates.example.test/stable/feed.json",
            keyID: "release-key",
            publicKeyX963Base64: publicKey,
            teamID: "A1B2C3D4E5"
        )
        let invalid: [AppConfig.UpdatesConfig] = [
            replacing(valid, feedURL: "http://updates.example.test/feed.json"),
            replacing(valid, feedURL: "https://user:pass@updates.example.test/feed.json"),
            replacing(valid, feedURL: "https://updates.example.test/feed.json?candidate=1"),
            replacing(valid, feedURL: "https://updates.example.test/feed.json#candidate"),
            replacing(valid, keyID: "release key"),
            replacing(valid, publicKeyX963Base64: Data(repeating: 0, count: 65).base64EncodedString()),
            replacing(valid, teamID: "a1B2C3D4E5"),
            replacing(valid, channel: .tip),
        ]

        for config in invalid {
            XCTAssertThrowsError(try config.verifiedUpdaterConfiguration(temporaryRoot: tempDir))
        }
    }

    func testNewSectionMigrationPreservesExistingBytesAndBecomesIdempotent() throws {
        let url = tempDir.appendingPathComponent("new-section-migration.toml")
        let legacy = """
        # keep operator preface
        [suppression]
        spotlight = false # keep inline note
        vendor_key = "untouched"

        [vendor]
        mode = "future"
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)

        _ = try store.loadValidated()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), legacy)

        _ = try store.loadMigratingValidated()
        let migrated = try String(contentsOf: url, encoding: .utf8)
        _ = try store.loadMigratingValidated()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), migrated)
        XCTAssertTrue(migrated.contains("# keep operator preface"))
        XCTAssertTrue(migrated.contains("spotlight = false"))
        XCTAssertTrue(migrated.contains("# keep inline note"))
        XCTAssertTrue(migrated.contains("vendor_key = \"untouched\""))
        XCTAssertTrue(migrated.contains("[vendor]\nmode = \"future\""))
        XCTAssertTrue(migrated.contains("[energy]"))
        XCTAssertTrue(migrated.contains("[updates]"))
        XCTAssertTrue(migrated.contains("enabled = false"))
        XCTAssertTrue(migrated.contains("public_key_x963_base64 = \"\""))
    }

    func testFullyCurrentLegacyConfigNeedsNoMigrationAndIsNeverRewritten() throws {
        let url = tempDir.appendingPathComponent("current-legacy.toml")
        try ConfigStore(configURL: url).save(AppConfig())
        let beforeData = try Data(contentsOf: url)
        let beforeIdentity = try fileIdentity(url)
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let store = ConfigStore(configURL: url) { _, _ in
            writes.withLock { $0 += 1 }
        }

        let inspection = store.inspect()
        XCTAssertTrue(inspection.valid)
        XCTAssertFalse(inspection.migrationNeeded)
        XCTAssertNil(inspection.config?.scopes)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("[scopes]"))

        _ = try store.loadMigratingValidated()

        XCTAssertEqual(writes.withLock { $0 }, 0)
        XCTAssertEqual(try Data(contentsOf: url), beforeData)
        XCTAssertEqual(try fileIdentity(url), beforeIdentity)
    }

    func testExplicitScopesRequireDefinitionsAndCurrentV2NeedsNoMigration() throws {
        let invalidURL = tempDir.appendingPathComponent("invalid-explicit-scopes.toml")
        try "[scopes]\nvendor = true\n".write(to: invalidURL, atomically: true, encoding: .utf8)
        let invalidInspection = ConfigStore(configURL: invalidURL).inspect()
        XCTAssertFalse(invalidInspection.valid)
        XCTAssertTrue(invalidInspection.error?.contains("scopes.definitions is required") == true)

        let scopeURL = tempDir.appendingPathComponent("managed-scope", isDirectory: true)
        try FileManager.default.createDirectory(at: scopeURL, withIntermediateDirectories: true)
        let currentURL = tempDir.appendingPathComponent("current-v2.toml")
        let store = ConfigStore(configURL: currentURL)
        try store.save(AppConfig(scopes: [
            ManagedScopeConfig(
                id: "current",
                name: "Current",
                scope: .init(path: canonicalTemporaryPath(scopeURL))
            ),
        ]))

        let inspection = store.inspect()
        XCTAssertTrue(inspection.valid)
        XCTAssertFalse(inspection.migrationNeeded)
        XCTAssertEqual(inspection.config?.scopes?.first?.id, "current")
        XCTAssertTrue(try String(contentsOf: currentURL, encoding: .utf8).contains(#"\"version\":2"#))
    }

    func testAllConfigReadsRejectSymlinkFIFOAndSparseOversizeWithoutBlocking() throws {
        let valid = tempDir.appendingPathComponent("valid.toml")
        try ConfigStore(configURL: valid).save(AppConfig())

        let symlink = tempDir.appendingPathComponent("symlink.toml")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)
        let fifo = tempDir.appendingPathComponent("fifo.toml")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let oversized = tempDir.appendingPathComponent("oversized.toml")
        let descriptor = Darwin.open(oversized.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, off_t(ConfigStore.maximumConfigBytes + 1)), 0)
        Darwin.close(descriptor)

        let started = Date()
        for url in [symlink, fifo, oversized] {
            let store = ConfigStore(configURL: url)
            XCTAssertThrowsError(try store.loadValidated())
            XCTAssertThrowsError(try store.loadMigratingValidated())
            XCTAssertThrowsError(try store.save(AppConfig()))
            let inspection = store.inspect()
            XCTAssertTrue(inspection.exists)
            XCTAssertFalse(inspection.valid)
            XCTAssertNil(inspection.source)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(try ConfigStore(configURL: valid).loadValidated(), AppConfig())
    }

    private func fileIdentity(_ url: URL) throws -> EvictionFileIdentity {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return EvictionFileIdentity.from(info)
    }

    private func canonicalTemporaryPath(_ url: URL) -> String {
        url.path.hasPrefix("/var/") ? "/private" + url.path : url.path
    }

    private func replacing(
        _ value: AppConfig.UpdatesConfig,
        enabled: Bool? = nil,
        channel: UpdateChannel? = nil,
        feedURL: String? = nil,
        keyID: String? = nil,
        publicKeyX963Base64: String? = nil,
        teamID: String? = nil
    ) -> AppConfig.UpdatesConfig {
        AppConfig.UpdatesConfig(
            enabled: enabled ?? value.enabled,
            channel: channel ?? value.channel,
            feedURL: feedURL ?? value.feedURL,
            keyID: keyID ?? value.keyID,
            publicKeyX963Base64: publicKeyX963Base64 ?? value.publicKeyX963Base64,
            teamID: teamID ?? value.teamID
        )
    }

}

extension String {
    var url: URL { URL(fileURLWithPath: self) }
}

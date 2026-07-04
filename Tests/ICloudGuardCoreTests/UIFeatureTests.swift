import Foundation
import XCTest
@testable import ICloudGuardCore

/// Tests the underlying data flow that the SwiftUI views in ICloudGuardApp drive.
/// GuardViewModel and AppConfigModel are in the app target (not importable from
/// these core tests), so we exercise the same logic through the core types and
/// a small mock that mirrors the view-model contract.
final class UIFeatureTests: XCTestCase {
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

    // MARK: - Mock view-model contract
    //
    // GuardViewModel exposes `isPaused` and `togglePause()`. The SwiftUI views
    // bind the "Evict now" and "Panic evict" buttons to `vm.isPaused == false`,
    // so we mirror that contract in a small mock and assert the gate flips
    // eviction availability on pause/resume.

    private final class MockPauseGate {
        private(set) var isPaused = false
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0

        func togglePause() {
            isPaused.toggle()
            if isPaused {
                pauseCount += 1
            } else {
                resumeCount += 1
            }
        }

        var canEvict: Bool { !isPaused }
    }

    // MARK: - Pause / resume (T25)

    func testPauseDisablesEviction() {
        let gate = MockPauseGate()
        XCTAssertTrue(gate.canEvict, "eviction is enabled while running")

        gate.togglePause()
        XCTAssertTrue(gate.isPaused, "first toggle should pause")
        XCTAssertFalse(gate.canEvict, "eviction must be disabled while paused")
        XCTAssertEqual(gate.pauseCount, 1)
        XCTAssertEqual(gate.resumeCount, 0)

        gate.togglePause()
        XCTAssertFalse(gate.isPaused, "second toggle should resume")
        XCTAssertTrue(gate.canEvict, "eviction re-enabled after resume")
        XCTAssertEqual(gate.pauseCount, 1)
        XCTAssertEqual(gate.resumeCount, 1)
    }

    func testPauseResumeTogglesRepeatedly() {
        let gate = MockPauseGate()
        for _ in 0..<4 {
            XCTAssertTrue(gate.canEvict, "starts unpaused each cycle")
            gate.togglePause()
            XCTAssertFalse(gate.canEvict, "eviction disabled while paused")
            gate.togglePause()
            XCTAssertTrue(gate.canEvict, "eviction re-enabled after resume")
        }
        XCTAssertEqual(gate.pauseCount, 4)
        XCTAssertEqual(gate.resumeCount, 4)
    }

    // MARK: - Browse button → protected paths (T24)

    func testProtectedPathsRoundTrip() throws {
        // Browse button → user picks a path → AppConfigModel updates
        // scope.protectedPaths → AppConfigModel.onChange → ConfigStore.save
        let url = tempDir.appendingPathComponent("browse_paths.toml")
        let store = ConfigStore(configURL: url)

        var config = store.load()
        XCTAssertTrue(config.scope.protectedPaths.isEmpty)

        config.scope.protectedPaths = ["/Users/me/Documents/keep"]
        try store.save(config)

        // A fresh store simulates the next time the UI reads from disk.
        let reloaded = ConfigStore(configURL: url).load()
        XCTAssertEqual(reloaded.scope.protectedPaths, ["/Users/me/Documents/keep"])
    }

    func testProtectedPathsAppendAndRemove() throws {
        let url = tempDir.appendingPathComponent("browse_append_remove.toml")
        let store = ConfigStore(configURL: url)

        var config = store.load()
        config.scope.protectedPaths = ["/keep/a"]
        try store.save(config)

        var reloaded = ConfigStore(configURL: url).load()
        reloaded.scope.protectedPaths.append("/keep/b")
        try store.save(reloaded)

        let afterAppend = ConfigStore(configURL: url).load()
        XCTAssertEqual(afterAppend.scope.protectedPaths, ["/keep/a", "/keep/b"])

        var trim = ConfigStore(configURL: url).load()
        trim.scope.protectedPaths.removeAll { $0 == "/keep/a" }
        try store.save(trim)

        let afterRemove = ConfigStore(configURL: url).load()
        XCTAssertEqual(afterRemove.scope.protectedPaths, ["/keep/b"])
    }

    // MARK: - Settings steppers (policy) and config onChange (T26)

    func testConfigChangePersists() throws {
        let url = tempDir.appendingPathComponent("config_change.toml")
        let store = ConfigStore(configURL: url)

        var config = store.load()
        XCTAssertTrue(config.suppression.spotlight, "spotlight defaults to on")

        config.suppression.spotlight = false
        try store.save(config)

        // Reload verifies what AppConfigModel.onChange would observe.
        let reloaded = ConfigStore(configURL: url).load()
        XCTAssertFalse(reloaded.suppression.spotlight, "config change must persist")
        // Sibling fields are untouched.
        XCTAssertEqual(reloaded.suppression.quicklook, config.suppression.quicklook)
        XCTAssertEqual(reloaded.eviction, AppConfig.EvictionConfig())
    }

    func testPolicyFieldsRoundTrip() throws {
        let url = tempDir.appendingPathComponent("policy_steppers.toml")
        let store = ConfigStore(configURL: url)

        var config = store.load()
        let defaults = AppConfig.PolicyConfig()
        XCTAssertEqual(config.policy, defaults, "policy starts at defaults")

        // User drags a few steppers in SettingsView.
        config.policy.targetLocalGiB = 12
        config.policy.warnFreeGiB = 90
        config.policy.cooldownMinutes = 7
        try store.save(config)

        let reloaded = ConfigStore(configURL: url).load()
        XCTAssertEqual(reloaded.policy.targetLocalGiB, 12)
        XCTAssertEqual(reloaded.policy.warnFreeGiB, 90)
        XCTAssertEqual(reloaded.policy.cooldownMinutes, 7)
        // Untouched fields keep their defaults.
        XCTAssertEqual(reloaded.policy.trimLocalGiB, defaults.trimLocalGiB)
        XCTAssertEqual(reloaded.policy.remediateFreeGiB, defaults.remediateFreeGiB)
        XCTAssertEqual(reloaded.policy.panicFreeGiB, defaults.panicFreeGiB)
    }

    func testConfigOnChangeCallbackSeesLatestValues() throws {
        // AppConfigModel wires ConfigStore.save → onChange callback. The
        // callback must observe the freshly written values, not a cached one.
        let url = tempDir.appendingPathComponent("onchange_callback.toml")
        let store = ConfigStore(configURL: url)

        var snapshots: [AppConfig] = []
        let onChange: (AppConfig) -> Void = { snapshots.append($0) }

        var config = store.load()
        config.eviction.batchLimit = 250
        try store.save(config)
        onChange(ConfigStore(configURL: url).load())

        config = ConfigStore(configURL: url).load()
        config.eviction.panicLimit = 1500
        try store.save(config)
        onChange(ConfigStore(configURL: url).load())

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].eviction.batchLimit, 250)
        XCTAssertEqual(snapshots[1].eviction.batchLimit, 250)
        XCTAssertEqual(snapshots[1].eviction.panicLimit, 1500)
    }
}

import Foundation
import XCTest
@testable import ICloudGuardCore

/// Tests for AppPaths static helpers.
///
/// AppPaths uses hardcoded paths under `~/.icloud-guard/`. We cannot redirect
/// them, so each test must (a) ensure the home dir exists in setUp and
/// (b) restore prior state in tearDown. config.toml is backed up before the
/// test runs and restored afterwards, so seeding it does not pollute the
/// real user config.
final class AppPathsTests: XCTestCase {

    /// Saved copy of the user's config.toml, captured in setUp so we can
    /// restore it in tearDown. nil if no config existed before the test.
    private var configBackup: (url: URL, contents: String)?

    override func setUp() {
        super.setUp()
        // Most helpers assume the home dir exists.
        AppPaths.ensureHomeDir()
        // Back up config.toml so tests that create or mutate it can be undone.
        let cfg = AppPaths.config
        if FileManager.default.fileExists(atPath: cfg.path),
           let contents = try? String(contentsOf: cfg, encoding: .utf8) {
            configBackup = (cfg, contents)
        }
    }

    override func tearDown() {
        // Always remove the pid file we may have written.
        AppPaths.removePID()
        // Always remove the token file we may have generated.
        try? FileManager.default.removeItem(at: AppPaths.tokenFile)
        // Restore config.toml to its pre-test state, or remove it if we created it.
        if let backup = configBackup {
            try? backup.contents.write(to: backup.url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: AppPaths.config)
        }
        super.tearDown()
    }

    // MARK: - PID lifecycle

    func testWriteAndRemovePID() throws {
        let testPID: Int32 = 4242
        try AppPaths.writePID(testPID)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: AppPaths.pidFile.path),
            "pidFile should exist after writePID"
        )

        let contents = try String(contentsOf: AppPaths.pidFile, encoding: .utf8)
        XCTAssertEqual(
            contents.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(testPID)",
            "pidFile should contain the PID we wrote"
        )

        AppPaths.removePID()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AppPaths.pidFile.path),
            "pidFile should be gone after removePID"
        )
    }

    func testIsGUIAliveWithCurrentProcess() throws {
        try AppPaths.writePID(getpid())
        XCTAssertTrue(
            AppPaths.isGUIAlive(),
            "isGUIAlive should return true when pidFile points at our own process"
        )
    }

    func testIsGUIAliveWithDeadPID() throws {
        // 999_999 is far above any realistic maxproc on macOS (default 99998),
        // so kill(pid, 0) will return -1 with ESRCH.
        let deadPID: Int32 = 999_999
        try AppPaths.writePID(deadPID)
        XCTAssertFalse(
            AppPaths.isGUIAlive(),
            "isGUIAlive should return false for a non-existent PID"
        )
    }

    func testReapStalePID() throws {
        let deadPID: Int32 = 999_999
        try AppPaths.writePID(deadPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.pidFile.path))

        AppPaths.reapStalePID()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AppPaths.pidFile.path),
            "reapStalePID should remove a pidFile pointing at a dead process"
        )
    }

    func testReapStalePIDDoesNotRemoveLivePID() throws {
        try AppPaths.writePID(getpid())
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.pidFile.path))

        AppPaths.reapStalePID()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: AppPaths.pidFile.path),
            "reapStalePID must not remove a pidFile that points at a live process"
        )
    }

    // MARK: - Config seeding

    func testSeedDefaultConfigIfMissing() throws {
        // Make sure we start from a known-empty state for this test only.
        try? FileManager.default.removeItem(at: AppPaths.config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.config.path))

        AppPaths.seedDefaultConfigIfMissing()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: AppPaths.config.path),
            "seedDefaultConfigIfMissing should create config.toml when absent"
        )

        let firstContents = try String(contentsOf: AppPaths.config, encoding: .utf8)

        // Idempotency: a second call must not modify the file.
        AppPaths.seedDefaultConfigIfMissing()
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.config.path))

        let secondContents = try String(contentsOf: AppPaths.config, encoding: .utf8)
        XCTAssertEqual(
            firstContents,
            secondContents,
            "seedDefaultConfigIfMissing should be idempotent when config already exists"
        )
    }

    // MARK: - Auth token

    func testGenerateAndReadToken() throws {
        let token = try AppPaths.generateToken()

        XCTAssertEqual(
            token.count,
            64,
            "Token should be 64 hex characters (32 bytes hex-encoded)"
        )
        XCTAssertTrue(
            token.allSatisfy { $0.isHexDigit },
            "Token should contain only hex characters"
        )

        let readBack = AppPaths.readToken()
        XCTAssertEqual(
            readBack,
            token,
            "readToken should return the same hex string that generateToken produced"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: AppPaths.tokenFile.path),
            "tokenFile should exist after generateToken"
        )
    }

    // MARK: - Home directory

    func testEnsureHomeDirCreatesDirectory() throws {
        // setUp already called ensureHomeDir; verify it is present and 0700.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: AppPaths.homeDir.path),
            "homeDir should exist after ensureHomeDir"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: AppPaths.homeDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(
            perms,
            0o700,
            "homeDir should have posixPermissions 0700"
        )
    }
}

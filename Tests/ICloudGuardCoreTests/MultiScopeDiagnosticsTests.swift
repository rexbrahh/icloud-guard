import Foundation
import XCTest
@testable import ICloudGuardCore

final class MultiScopeDiagnosticsTests: XCTestCase {
    func testDoctorInjectedScopeUsesSelectedConfigAndStorageOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedScope = root.appendingPathComponent("selected-scope", isDirectory: true)
        let selectedStorage = root.appendingPathComponent("selected-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedScope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: selectedStorage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = AppPaths.ScopePaths(root: selectedStorage)
        let config = AppConfig(scope: .init(path: selectedScope.path))
        let probe = DoctorProbe(
            fileExists: { path in path == selectedScope.path || path == selectedStorage.path },
            fileInfo: { path in
                guard path == selectedScope.path || path == selectedStorage.path else { return nil }
                return DoctorFileInfo(isDirectory: true, permissions: 0o700)
            },
            isWritable: { $0 == selectedStorage.path },
            canonicalPath: { $0 },
            freeBytes: { $0 == selectedScope.path ? 42 : nil },
            processAlive: { _ in false },
            isSocket: { _ in false },
            executable: { _ in true }
        )

        let report = DoctorService.run(config: config, scopePaths: paths, probe: probe)

        XCTAssertEqual(report.checks.first { $0.id == "config.valid" }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.id == "path.app-home" }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.id == "scope.directory" }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.id == "volume.free-space" }?.status, .passed)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains(selectedScope.path))
        XCTAssertFalse(encoded.contains(selectedStorage.path))
    }

    func testSupportBundleInjectedScopeIgnoresLegacyStorageAndRedactsSelectedPath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedScope = root.appendingPathComponent("Private Selected Scope", isDirectory: true)
        let selectedStorage = root.appendingPathComponent("selected-storage", isDirectory: true)
        let legacyStorage = root.appendingPathComponent("legacy-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedScope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyStorage, withIntermediateDirectories: true)
        try Data("{malformed-legacy-history".utf8).write(to: legacyStorage.appendingPathComponent("history.json"))
        try Data("{malformed-legacy-watchlist".utf8).write(to: legacyStorage.appendingPathComponent("watchlist.json"))

        let salt = Data(repeating: 0x42, count: 32)
        let config = AppConfig(scope: .init(path: selectedScope.path))
        let paths = AppPaths.ScopePaths(root: selectedStorage)
        let output = root.appendingPathComponent("selected.zip")
        _ = try SupportBundleService(
            saltProvider: { salt },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        ).create(outputURL: output, config: config, scopePaths: paths)

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        XCTAssertEqual(
            try SupportBundleService.runProcess("/usr/bin/ditto", ["-x", "-k", output.path, extracted.path]),
            0
        )
        let bundleRoot = extracted.appendingPathComponent("icloud-guard-support", isDirectory: true)
        let configData = try Data(contentsOf: bundleRoot.appendingPathComponent("config.json"))
        let configJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let expectedIdentifier = "hash:" + String(PrivacyIdentifier.hash(selectedScope.path, salt: salt).prefix(24))
        XCTAssertEqual(configJSON["scopeIdentifier"] as? String, expectedIdentifier)

        let names = try FileManager.default.contentsOfDirectory(atPath: bundleRoot.path)
        let combined = try names.reduce(into: Data()) { data, name in
            data.append(try Data(contentsOf: bundleRoot.appendingPathComponent(name)))
        }
        let contents = String(decoding: combined, as: UTF8.self)
        XCTAssertFalse(contents.contains(selectedScope.path))
        XCTAssertFalse(contents.contains(selectedStorage.path))
        XCTAssertFalse(contents.contains(legacyStorage.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

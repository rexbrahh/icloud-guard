import CryptoKit
import Foundation
import XCTest
@testable import ICloudGuardCore

final class UpdateFeedProducerCompatibilityTests: XCTestCase {
    func testProducerEnvelopeAuthenticatesWithInstalledUpdaterCodec() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-feed-compatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repository.appendingPathComponent("scripts/update-feed.swift")
        let tool = root.appendingPathComponent("update-feed")
        try run("/usr/bin/xcrun", ["swiftc", "-warnings-as-errors", source.path, "-o", tool.path])

        let privateKey = root.appendingPathComponent("private.pem")
        let publicKey = root.appendingPathComponent("public.txt")
        try run(tool.path, ["keygen", "--private-key", privateKey.path, "--public-key", publicKey.path])
        let publicKeyBase64 = try String(contentsOf: publicKey, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKeyData = try XCTUnwrap(Data(base64Encoded: publicKeyBase64))

        let version = "9.8.7"
        let artifactFilename = "ICloudGuard-\(version).zip"
        let artifact = root.appendingPathComponent(artifactFilename)
        let artifactData = Data("verified release archive fixture".utf8)
        try artifactData.write(to: artifact)
        let artifactSHA = SHA256.hash(data: artifactData).map { String(format: "%02x", $0) }.joined()
        let manifest = root.appendingPathComponent("\(artifactFilename).json")
        let manifestObject: [String: Any] = [
            "schema_version": 2,
            "channel": "stable",
            "version": version,
            "tag": "v\(version)",
            "commit": "0123456789abcdef0123456789abcdef01234567",
            "source_tree_clean": true,
            "artifact_filename": artifactFilename,
            "artifact_sha256": artifactSHA,
            "artifact_size": artifactData.count,
            "executable_sha256": String(repeating: "b", count: 64),
            "executable_uuid": "12345678-1234-ABCD-9876-123456789ABC",
            "signing_identity": "Developer ID Application: Feed Fixture",
            "signing_type": "developer-id",
            "notarized": true,
            "stapled": true,
            "build_toolchain": "Apple Swift fixture",
            "minimum_macos": "14.0",
            "source_epoch": 1_700_000_000,
        ]
        try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys]).write(to: manifest)

        let generated = Int64(Date().timeIntervalSince1970)
        let feed = root.appendingPathComponent("feed.json")
        let updateOrigin = "https://updates.example.invalid/icloud-guard"
        try run(tool.path, [
            "create",
            "--manifest", manifest.path,
            "--artifact", artifact.path,
            "--update-origin", updateOrigin,
            "--channel", "stable",
            "--team-id", "ABCDE12345",
            "--key-id", "release-2026-a",
            "--private-key", privateKey.path,
            "--generated-at", String(generated),
            "--expires-at", String(generated + 3_600),
            "--output", feed.path,
        ])

        let payload = try UpdateFeedCodec.authenticatedPayload(
            from: Data(contentsOf: feed),
            expectedKeyID: "release-2026-a",
            publicKeyX963: publicKeyData
        )
        XCTAssertEqual(payload.schema, UpdateFeedPayload.schemaVersion)
        XCTAssertEqual(payload.releases.count, 1)
        XCTAssertEqual(payload.releases[0].version, SemanticVersion(version))
        XCTAssertEqual(payload.releases[0].artifactFilename, artifactFilename)
        XCTAssertEqual(payload.releases[0].artifactURL.absoluteString, "\(updateOrigin)/stable/\(artifactFilename)")
        XCTAssertEqual(payload.releases[0].teamID, "ABCDE12345")
        XCTAssertEqual(payload.releases[0].provenance, .trustedCI)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = try stderr.fileHandleForReading.readToEnd() ?? Data()
            throw NSError(
                domain: "UpdateFeedProducerCompatibilityTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
    }
}

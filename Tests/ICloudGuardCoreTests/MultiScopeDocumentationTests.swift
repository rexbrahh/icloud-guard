import Foundation
import XCTest
@testable import ICloudGuardCore

final class MultiScopeDocumentationTests: XCTestCase {
    func testReadmeContainsCanonicalLoadableMultiScopeExample() throws {
        let readme = try readme()
        let marker = "This one-scope example includes every required canonical field:\n\n```toml\n"
        let start = try XCTUnwrap(readme.range(of: marker)).upperBound
        let end = try XCTUnwrap(readme.range(of: "\n```", range: start..<readme.endIndex)).lowerBound
        let example = String(readme[start..<end]) + "\n"

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-readme-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.toml")
        try example.write(to: configURL, atomically: true, encoding: .utf8)

        let scopes = try XCTUnwrap(ConfigStore(configURL: configURL).loadValidated().scopes)
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes[0].id, "personal")
        XCTAssertEqual(scopes[0].name, "Personal")
        XCTAssertTrue(scopes[0].automaticEnabled)
    }

    func testReadmeDocumentsFinalUpdaterAndScopedDiagnosticsBoundaries() throws {
        let readme = try readme()
        for requiredContract in [
            "The app and CLI never install or replace an app.",
            "Cache and backoff timers use monotonic system uptime.",
            "These checks persist across process restarts.",
            "On cancellation, it sends `TERM` and escalates to `KILL` after 500 ms.",
            "The app shows a **Discard verified download** button.",
            "Multiple scopes without a selector fail with `scope-required`.",
            "icloud-guard doctor --scope <id-or-name>",
            "icloud-guard support-bundle <output.zip> --scope <id-or-name>"
        ] {
            XCTAssertTrue(readme.contains(requiredContract), "README is missing contract: \(requiredContract)")
        }
    }

    private func readme() throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent("README.md"), encoding: .utf8)
    }
}

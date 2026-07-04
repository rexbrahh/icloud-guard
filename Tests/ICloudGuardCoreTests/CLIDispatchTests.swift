import Foundation
import XCTest
@testable import ICloudGuardCore

final class CLIDispatchTests: XCTestCase {
    private var binaryPath: URL {
        // The binary is built at .build/debug/icloud-guard relative to package root
        // Package root is the parent of the Tests directory
        let packageRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot.appendingPathComponent(".build/debug/icloud-guard")
    }

    private func runCLI(args: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = binaryPath
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, "Failed to run: \(error)")
        }
    }

    func testCLIHelp() throws {
        // Skip if binary doesn't exist (e.g., running in CI without build)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: binaryPath.path), "CLI binary not found at \(binaryPath.path)")

        let (code, output) = runCLI(args: ["--help"])
        XCTAssertEqual(code, 0, "icloud-guard --help should exit 0")
        XCTAssertTrue(output.contains("icloud-guard"), "Help should mention command name")
        XCTAssertTrue(output.contains("status"), "Help should list status subcommand")
        XCTAssertTrue(output.contains("evict"), "Help should list evict subcommand")
    }

    func testCLIStatus() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: binaryPath.path), "CLI binary not found")

        let (code, output) = runCLI(args: ["status"])
        // Exit code 0 = success, 1 = GuardRunner fallback error (expected in test env without iCloud access)
        XCTAssertTrue(code == 0 || code == 1, "icloud-guard status should exit 0 or 1, got \(code)")
        XCTAssertFalse(output.isEmpty, "Status command should produce some output")
    }

    func testCLIVersion() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: binaryPath.path), "CLI binary not found")

        let (code, output) = runCLI(args: ["--version"])
        XCTAssertEqual(code, 0, "icloud-guard --version should exit 0")
        XCTAssertTrue(output.contains("0.3.0"), "Version should be 0.3.0")
    }
}

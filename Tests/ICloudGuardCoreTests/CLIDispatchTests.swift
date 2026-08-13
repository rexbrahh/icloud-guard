import Darwin
import os
import XCTest
@testable import ICloudGuardCLIKit
@testable import ICloudGuardCore

/// Directly exercises the importable command tree compiled in this test run.
/// Product-process smoke coverage is run only after an explicit product build.
final class CLIDispatchTests: XCTestCase {
    func testCurrentCommandSurfaceAndVersion() {
        XCTAssertEqual(CLIEntrypoint.configuration.commandName, "icloud-guard")
        XCTAssertEqual(CLIEntrypoint.configuration.version, ICloudGuardProduct.version)
        XCTAssertEqual(
            CLIEntrypoint.configuration.subcommands.compactMap { $0.configuration.commandName },
            ["status", "evict", "panic-evict", "reclaim", "explain", "doctor", "history", "watchlist", "scope", "restore-last", "keep-downloaded", "support-bundle", "config", "update"]
        )
    }

    func testPhase5CommandsParseThroughCurrentDispatch() throws {
        let browse = try CLIEntrypoint.parseAsRoot(["scope", "browse", "--limit", "25", "--reveal-paths"])
        XCTAssertEqual((browse as? ScopeBrowse)?.limit, 25)
        XCTAssertTrue((browse as? ScopeBrowse)?.revealPaths == true)
        XCTAssertNotNil(try CLIEntrypoint.parseAsRoot(["restore-last"]) as? RestoreLast)
        XCTAssertNotNil(try CLIEntrypoint.parseAsRoot(["keep-downloaded"]) as? KeepDownloaded)
    }

    func testMultiScopeOptionsParseAcrossLocalCommands() throws {
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["status", "--scope", "work"]) as? Status)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["evict", "--scope", "work"]) as? Evict)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["panic-evict", "--scope", "work"]) as? PanicEvict)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["reclaim", "1GiB", "--scope", "work"]) as? Reclaim)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["explain", "--scope", "work"]) as? Explain)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["doctor", "--scope", "work"]) as? Doctor)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["history", "list", "--scope", "work"]) as? HistoryList)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["watchlist", "--scope", "work"]) as? Watchlist)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["scope", "browse", "--scope", "work"]) as? ScopeBrowse)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["restore-last", "--scope", "work"]) as? RestoreLast)?.scope, "work")
        XCTAssertEqual((try CLIEntrypoint.parseAsRoot(["keep-downloaded", "--scope", "work"]) as? KeepDownloaded)?.scope, "work")
        XCTAssertEqual(
            (try CLIEntrypoint.parseAsRoot(["support-bundle", "/tmp/support.zip", "--scope", "work"]) as? SupportBundle)?.scope,
            "work"
        )
        XCTAssertTrue(try CLIEntrypoint.parseAsRoot(["scope", "list"]) is ScopeList)
    }

    func testStatusAndEvictionFlagsParseThroughCurrentDispatch() throws {
        let status = try CLIEntrypoint.parseAsRoot(["status", "--dry-run"])
        XCTAssertTrue((status as? Status)?.dryRun == true)

        let eviction = try CLIEntrypoint.parseAsRoot(["evict", "--dry-run"])
        XCTAssertTrue((eviction as? Evict)?.dryRun == true)

        let panic = try CLIEntrypoint.parseAsRoot(["panic-evict", "--dry-run"])
        XCTAssertTrue((panic as? PanicEvict)?.dryRun == true)
    }

    func testNestedConfigShowParsesThroughCurrentDispatch() throws {
        let command = try CLIEntrypoint.parseAsRoot(["config", "show"])
        XCTAssertTrue(command is ConfigShow)
    }

    func testUpdateCommandsParseThroughCurrentDispatch() throws {
        XCTAssertTrue(try CLIEntrypoint.parseAsRoot(["update", "check"]) is UpdateCheck)
        XCTAssertTrue(try CLIEntrypoint.parseAsRoot(["update", "download"]) is UpdateDownload)
    }


    func testProductProcessJSONEnvelopeMatrixAndExitCodes() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/icloud-guard")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("build the icloud-guard product before running process integration tests")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-process-\(UUID().uuidString)")
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x41, count: 4_096).write(to: scope.appendingPathComponent("resident.bin"))
        var config = AppConfig()
        config.scope.path = scope.path
        config.scope.protectedPaths = []
        try ConfigStore(configURL: root.appendingPathComponent("config.toml")).save(config)

        let successCommands: [[String]] = [
            ["--json", "config", "show"],
            ["doctor", "--json"],
            ["--json", "status"],
            ["evict", "--dry-run", "--json"],
            ["--json", "panic-evict", "--dry-run"],
            ["reclaim", "1B", "--dry-run", "--json"],
            ["explain", "--json"],
            ["--json", "history", "list"],
            ["watchlist", "--json"],
        ]
        for arguments in successCommands {
            let result = try runProduct(binary: binary, arguments: arguments, home: root)
            XCTAssertTrue([0, 1].contains(result.status), "\(arguments): \(result.stderr)")
            let envelope = try decodeSingleEnvelope(result.stdout)
            XCTAssertEqual(envelope["schema"] as? Int, 1)
            XCTAssertNotNil(envelope["request_id"] as? String)
            XCTAssertEqual(envelope["exit_code"] as? Int, Int(result.status))
            XCTAssertNotNil(envelope["payload"])
            XCTAssertTrue(result.stderr.isEmpty, "\(arguments): \(result.stderr)")
        }

        let history = try RunHistoryStore(url: root.appendingPathComponent("history.json")).load()
        let runID = try XCTUnwrap(history.last?.id)
        for arguments in [
            ["history", "show", runID, "--json"],
            ["--json", "history", "export", root.appendingPathComponent("history.csv").path],
            ["support-bundle", root.appendingPathComponent("support.zip").path, "--json"],
        ] {
            let result = try runProduct(binary: binary, arguments: arguments, home: root)
            XCTAssertEqual(result.status, 0, "\(arguments): \(result.stderr)")
            _ = try decodeSingleEnvelope(result.stdout)
            XCTAssertTrue(result.stderr.isEmpty)
        }

        let usage = try runProduct(binary: binary, arguments: ["--json", "reclaim", "invalid"], home: root)
        XCTAssertEqual(usage.status, 64)
        let usageEnvelope = try decodeSingleEnvelope(usage.stdout)
        XCTAssertEqual(usageEnvelope["exit_code"] as? Int, 64)
        XCTAssertNil(usageEnvelope["payload"])
        XCTAssertNotNil(usageEnvelope["error"])
        XCTAssertTrue(usage.stderr.isEmpty)

        let notFound = try runProduct(binary: binary, arguments: ["history", "show", "missing", "--json"], home: root)
        XCTAssertEqual(notFound.status, 65)
        XCTAssertEqual(try decodeSingleEnvelope(notFound.stdout)["exit_code"] as? Int, 65)
    }

    func testProductSupportBundleAcceptsPrivateTmpAliasForNonexistentOutput() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let outputPath = "/private/tmp/\(root.lastPathComponent)/output/support.zip"

        let result = try runProduct(
            binary: binary,
            arguments: ["--json", "support-bundle", outputPath],
            home: root
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try decodeSingleEnvelope(result.stdout)["exit_code"] as? Int, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
    }

    func testProductHumanStatusReturnsDataExitForIncompleteScan() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        let blocked = root.appendingPathComponent("scope/blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("resident".utf8).write(to: blocked.appendingPathComponent("resident.bin"))
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer {
            _ = chmod(blocked.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        let result = try runProduct(binary: binary, arguments: ["status"], home: root)

        XCTAssertEqual(result.status, 65, String(decoding: result.stdout, as: UTF8.self) + result.stderr)
        XCTAssertFalse(result.stdout.isEmpty)
    }

    func testProductHistoryRejectsMaliciousFixture() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture("malicious-history.json"), to: root.appendingPathComponent("history.json"))

        let result = try runProduct(binary: binary, arguments: ["--json", "history", "list"], home: root)
        XCTAssertEqual(result.status, 65)
        let envelope = try decodeSingleEnvelope(result.stdout)
        XCTAssertEqual(envelope["exit_code"] as? Int, 65)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "malformed-data")
        XCTAssertTrue((error["message"] as? String)?.contains("run history is corrupt") == true)
    }

    func testProductHistoryRejectsOversizedHistory() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: Int(RunHistoryStore.maximumHistoryBytes) + 1).write(to: root.appendingPathComponent("history.json"))

        let result = try runProduct(binary: binary, arguments: ["--json", "history", "list"], home: root)
        XCTAssertEqual(result.status, 65)
        let envelope = try decodeSingleEnvelope(result.stdout)
        XCTAssertEqual(envelope["exit_code"] as? Int, 65)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "malformed-data")
        XCTAssertTrue((error["message"] as? String)?.contains("history file exceeds") == true)
    }

    func testProductScopeListIsPrivateAndAmbiguousSelectionFailsClosed() throws {
        let binary = try requireProductBinary()
        let root = try makeMultiScopeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let list = try runProduct(binary: binary, arguments: ["--json", "scope", "list"], home: root)
        XCTAssertEqual(list.status, 0, list.stderr)
        let listText = String(decoding: list.stdout, as: UTF8.self)
        XCTAssertFalse(listText.contains(root.path), listText)
        let envelope = try decodeSingleEnvelope(list.stdout)
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        let values = try XCTUnwrap(payload["value"] as? [[String: Any]])
        XCTAssertEqual(values.compactMap { $0["id"] as? String }, ["personal", "work"])
        XCTAssertEqual(values.compactMap { $0["name"] as? String }, ["Personal", "Work Files"])
        XCTAssertTrue(values.allSatisfy {
            guard let identifier = $0["scopeIdentifier"] as? String else { return false }
            return identifier.count == 24 && identifier.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        })

        let ambiguous = try runProduct(binary: binary, arguments: ["--json", "status"], home: root)
        XCTAssertEqual(ambiguous.status, CLIExitCode.usage)
        let error = try XCTUnwrap(try decodeSingleEnvelope(ambiguous.stdout)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "scope-required")
        XCTAssertFalse((error["message"] as? String)?.contains(root.path) == true)
    }

    func testProductUpdateCommandsFailClosedWithoutTrustConfiguration() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }

        for command in [["--json", "update", "check"], ["update", "download", "--json"]] {
            let result = try runProduct(binary: binary, arguments: command, home: root)
            XCTAssertEqual(result.status, CLIExitCode.configuration, "\(command): \(result.stderr)")
            let envelope = try decodeSingleEnvelope(result.stdout)
            XCTAssertEqual(envelope["exit_code"] as? Int, Int(CLIExitCode.configuration))
            let error = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "updates-disabled")
            XCTAssertNil(envelope["payload"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
            XCTAssertTrue(result.stderr.isEmpty)
        }
    }

    func testProductScopedDryRunUsesIsolatedHistoryAndNeverLegacyHistory() throws {
        let binary = try requireProductBinary()
        let root = try makeMultiScopeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runProduct(
            binary: binary,
            arguments: ["--json", "evict", "--dry-run", "--scope", "Work Files"],
            home: root
        )
        XCTAssertTrue([CLIExitCode.success, CLIExitCode.partial].contains(result.status), result.stderr)
        let envelope = try decodeSingleEnvelope(result.stdout)
        XCTAssertEqual(envelope["command"] as? String, "evict")
        XCTAssertNotNil(envelope["payload"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
        let scopedHistory = root.appendingPathComponent("scopes/work/history.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedHistory.path))
        let receipts = try RunHistoryStore(url: scopedHistory).load()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].sourceScopeIdentifier, PrivacyIdentifier.scope(root.appendingPathComponent("work-scope").path))
    }

    func testProductRestartWithSameIDChangedPathRejectsOldStorageWithoutReadingOrWritingIt() throws {
        let binary = try requireProductBinary()
        let root = try makeMultiScopeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try runProduct(
            binary: binary,
            arguments: ["--json", "evict", "--dry-run", "--scope", "work"],
            home: root
        )
        XCTAssertTrue([CLIExitCode.success, CLIExitCode.partial].contains(first.status), first.stderr)
        let historyURL = root.appendingPathComponent("scopes/work/history.json")
        let before = try Data(contentsOf: historyURL)
        let replacementScope = root.appendingPathComponent("replacement-work-scope", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementScope, withIntermediateDirectories: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.toml"))
        var changed = try store.loadValidated()
        let workIndex = try XCTUnwrap(changed.scopes?.firstIndex { $0.id == "work" })
        changed.scopes?[workIndex].scope.path = replacementScope.path
        try store.save(changed)

        let restarted = try runProduct(
            binary: binary,
            arguments: ["--json", "history", "list", "--scope", "work"],
            home: root
        )

        XCTAssertEqual(restarted.status, CLIExitCode.configuration, restarted.stderr)
        let envelope = try decodeSingleEnvelope(restarted.stdout)
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "configuration")
        XCTAssertNil(envelope["payload"])
        XCTAssertEqual(try Data(contentsOf: historyURL), before)
        XCTAssertFalse(String(decoding: restarted.stdout, as: UTF8.self).contains(replacementScope.path))
    }

    func testProductCaseVariantMutationSelectorFailsClosedWithoutChoosingEitherScope() throws {
        let binary = try requireProductBinary()
        let root = try makeMultiScopeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.toml")
        let original = try String(contentsOf: configURL, encoding: .utf8)
        let ambiguous = original.replacingOccurrences(of: "Work Files", with: "PERSONAL")
        XCTAssertNotEqual(ambiguous, original)
        try ambiguous.write(to: configURL, atomically: true, encoding: .utf8)
        chmod(configURL.path, 0o600)

        let result = try runProduct(
            binary: binary,
            arguments: ["--json", "evict", "--dry-run", "--scope", "PERSONAL"],
            home: root
        )

        XCTAssertEqual(result.status, CLIExitCode.configuration, result.stderr)
        let envelope = try decodeSingleEnvelope(result.stdout)
        XCTAssertEqual(envelope["exit_code"] as? Int, Int(CLIExitCode.configuration))
        XCTAssertNil(envelope["payload"])
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains(root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scopes/personal/history.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scopes/work/history.json").path))
    }

    func testProductScopedDoctorAndSupportIgnoreMalformedLegacyStorage() throws {
        let binary = try requireProductBinary()
        let root = try makeMultiScopeProcessHome()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-scoped-support-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: output)
        }
        try Data("{malformed-legacy-history".utf8).write(to: root.appendingPathComponent("history.json"))
        try Data("{malformed-legacy-watchlist".utf8).write(to: root.appendingPathComponent("watchlist.json"))

        let doctor = try runProduct(
            binary: binary,
            arguments: ["--json", "doctor", "--scope", "Work Files"],
            home: root
        )
        XCTAssertEqual(doctor.status, 0, doctor.stderr)
        let doctorEnvelope = try decodeSingleEnvelope(doctor.stdout)
        XCTAssertEqual(doctorEnvelope["command"] as? String, "doctor")
        XCTAssertFalse(String(decoding: doctor.stdout, as: UTF8.self).contains(root.path))

        let support = try runProduct(
            binary: binary,
            arguments: ["--json", "support-bundle", output.path, "--scope", "Work Files"],
            home: root
        )
        XCTAssertEqual(support.status, 0, support.stderr)
        XCTAssertEqual(try decodeSingleEnvelope(support.stdout)["command"] as? String, "support-bundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(String(decoding: support.stdout, as: UTF8.self).contains(root.path))
    }

    func testEvictJSONOldPeerUnavailableKeepsExactExitAndSingleEnvelope() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeIPCToken("test-token", home: root)
        let server = try CLIIPCStub(
            socketPath: root.appendingPathComponent("guard.sock").path,
            token: "test-token",
            exitCode: Int(CLIExitCode.unavailable),
            output: "running app did not return a structured run receipt"
        )
        server.start()
        defer { server.stop() }

        let result = try runProduct(binary: binary, arguments: ["--json", "evict"], home: root)

        XCTAssertEqual(result.status, CLIExitCode.unavailable)
        let envelope = try decodeSingleEnvelope(result.stdout)
        XCTAssertEqual(envelope["exit_code"] as? Int, Int(CLIExitCode.unavailable))
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "structured-ipc-unavailable")
        XCTAssertNil(envelope["payload"])
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    func testPanicJSONStructuredMissingReceiptKeepsIOExitAndSingleEnvelope() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeIPCToken("test-token", home: root)
        let server = try CLIIPCStub(
            socketPath: root.appendingPathComponent("guard.sock").path,
            token: "test-token",
            exitCode: Int(CLIExitCode.io),
            output: "current run receipt was not persisted",
            result: ["output": "current run receipt was not persisted", "exitCode": Int(CLIExitCode.io)]
        )
        server.start()
        defer { server.stop() }

        let result = try runProduct(binary: binary, arguments: ["panic-evict", "--json"], home: root)

        XCTAssertEqual(result.status, CLIExitCode.io)
        let envelope = try decodeSingleEnvelope(result.stdout)
        XCTAssertEqual(envelope["exit_code"] as? Int, Int(CLIExitCode.io))
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "io")
        XCTAssertNil(envelope["payload"])
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    func testWatchlistRevealPathsEscapesTerminalControlsOnlyForHumanOutput() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = root.appendingPathComponent("scope")
        let hostileName = "safe\nspoof\r\u{202E}txt"
        try Data().write(to: scope.appendingPathComponent(hostileName))
        let entry = WatchlistEntry(
            path: scope.appendingPathComponent(hostileName).path,
            addedAt: Date(),
            nextCheckAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(to: root.appendingPathComponent("watchlist.json"))

        let human = try runProduct(binary: binary, arguments: ["watchlist", "--reveal-paths"], home: root)
        XCTAssertEqual(human.status, 0, human.stderr)
        let humanText = String(decoding: human.stdout, as: UTF8.self)
        XCTAssertEqual(humanText.split(whereSeparator: \.isNewline).count, 1, humanText)
        XCTAssertTrue(humanText.contains("safe\\u{000A}spoof\\u{000D}\\u{202E}txt"), humanText)
        XCTAssertFalse(humanText.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) })

        let json = try runProduct(binary: binary, arguments: ["--json", "watchlist", "--reveal-paths"], home: root)
        XCTAssertEqual(json.status, 0, json.stderr)
        let envelope = try decodeSingleEnvelope(json.stdout)
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        let value = try XCTUnwrap(payload["value"] as? [[String: Any]])
        XCTAssertEqual(value.first?["displayPath"] as? String, hostileName)
    }

    func testHistoryHumanOutputEscapesReceiptTerminalControls() throws {
        let binary = try requireProductBinary()
        let root = try makeProcessHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = GuardRunReceipt(
            id: "run\u{001B}]0;owned\u{0007}",
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            trigger: .cli,
            command: "reclaim\u{009B}2J",
            requestedAction: "reclaim\u{202E}",
            action: .targeted,
            dryRun: true,
            reason: "operator note\u{001B}]0;owned\u{0007}",
            requestedGoalBytes: 1,
            sourceScopeIdentifier: "scope",
            plannedCount: 1,
            plannedBytes: 1,
            exitCode: 0,
            status: .succeeded,
            statePersisted: true,
            watchlistPersisted: true
        )
        try RunHistoryStore(url: root.appendingPathComponent("history.json")).append(receipt)

        let list = try runProduct(binary: binary, arguments: ["history", "list"], home: root)
        XCTAssertEqual(list.status, 0, list.stderr)
        let listText = String(decoding: list.stdout, as: UTF8.self)
        XCTAssertTrue(listText.contains("run\\u{001B}]0;owned\\u{0007}"), listText)
        XCTAssertTrue(listText.contains("reclaim\\u{009B}2J"), listText)
        assertNoTerminalControls(listText)

        let show = try runProduct(binary: binary, arguments: ["history", "show", receipt.id], home: root)
        XCTAssertEqual(show.status, 0, show.stderr)
        let showText = String(decoding: show.stdout, as: UTF8.self)
        XCTAssertTrue(showText.contains("operator note\\u{001B}]0;owned\\u{0007}"), showText)
        XCTAssertTrue(showText.contains("Requested: reclaim\\u{202E}"), showText)
        assertNoTerminalControls(showText)
    }

    private func requireProductBinary() throws -> URL {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/icloud-guard")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("build the icloud-guard product before running process integration tests")
        }
        return binary
    }

    private func makeProcessHome() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/ig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scope = root.appendingPathComponent("scope", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var config = AppConfig()
        config.scope.path = scope.path
        config.scope.protectedPaths = []
        try ConfigStore(configURL: root.appendingPathComponent("config.toml")).save(config)
        return root
    }

    private func makeMultiScopeProcessHome() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/ig-multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let personal = root.appendingPathComponent("personal-scope", isDirectory: true)
        let work = root.appendingPathComponent("work-scope", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 256).write(to: work.appendingPathComponent("resident.bin"))
        let scopes = [
            ManagedScopeConfig(id: "personal", name: "Personal", scope: .init(path: personal.path)),
            ManagedScopeConfig(id: "work", name: "Work Files", scope: .init(path: work.path)),
        ]
        try ConfigStore(configURL: root.appendingPathComponent("config.toml")).save(AppConfig(scopes: scopes))
        return root
    }

    private func writeIPCToken(_ token: String, home: URL) throws {
        let tokenURL = home.appendingPathComponent("guard.token")
        try "\(token)\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        chmod(tokenURL.path, 0o600)
    }

    private func runProduct(binary: URL, arguments: [String], home: URL) throws -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[AppPaths.homeOverrideEnvironmentKey] = home.path
        environment["ICLOUD_GUARD_DISABLE_SYSTEM_INTEGRATIONS"] = "1"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + .seconds(5)) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(1))
            XCTFail("icloud-guard timed out: \(arguments)")
        }
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func decodeSingleEnvelope(_ data: Data) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text.split(whereSeparator: \.isNewline).count, 1, text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertNoTerminalControls(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.unicodeScalars.contains {
            ($0.value <= 0x1F && $0.value != 0x0A)
                || (0x80...0x9F).contains($0.value)
                || $0.value == 0x7F
                || (0x202A...0x202E).contains($0.value)
                || (0x2066...0x2069).contains($0.value)
        }, text, file: file, line: line)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }
}

private final class CLIIPCStub: @unchecked Sendable {
    private struct State {
        var listenFD: Int32
        var workerStarted = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let worker = DispatchGroup()
    private let socketPath: String
    private let token: String
    private let exitCode: Int
    private let output: String
    private let result: [String: Any]?

    init(socketPath: String, token: String, exitCode: Int, output: String, result: [String: Any]? = nil) throws {
        self.socketPath = socketPath
        self.token = token
        self.exitCode = exitCode
        self.output = output
        self.result = result
        Darwin.unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "CLIIPCStub", code: 1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < sunPathSize else {
            Darwin.close(fd)
            throw NSError(domain: "CLIIPCStub", code: 4)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cPath in
                _ = strncpy(UnsafeMutableRawPointer(ptr), cPath, sunPathSize - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "CLIIPCStub", code: 2)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "CLIIPCStub", code: 3)
        }
        state = OSAllocatedUnfairLock(initialState: State(listenFD: fd))
    }

    deinit { stop() }

    func start() {
        let descriptor = state.withLock { state -> Int32 in
            guard !state.workerStarted, state.listenFD >= 0 else { return -1 }
            state.workerStarted = true
            return state.listenFD
        }
        guard descriptor >= 0 else { return }
        worker.enter()
        Thread { [self] in
            defer { worker.leave() }
            serveOnce(descriptor)
        }.start()
    }

    func stop() {
        let stopped = state.withLock { state -> (Int32, Bool) in
            let descriptor = state.listenFD
            state.listenFD = -1
            return (descriptor, state.workerStarted)
        }
        guard stopped.0 >= 0 else { return }
        _ = Darwin.shutdown(stopped.0, SHUT_RDWR)
        if stopped.1 { worker.wait() }
        Darwin.close(stopped.0)
        Darwin.unlink(socketPath)
    }

    private func serveOnce(_ listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        let authFrame = readJSONLine(fd)
        guard let auth = authFrame["auth"] as? String,
              auth == token,
              let requestID = authFrame["request_id"] as? String else {
            return
        }
        writeJSONLine(["auth": "ok", "request_id": requestID], fd: fd)
        let command = readJSONLine(fd)
        guard command["request_id"] as? String == requestID else {
            return
        }

        var response: [String: Any] = [
            "done": true,
            "exit_code": exitCode,
            "output": output,
            "request_id": requestID,
        ]
        if let result { response["result"] = result }
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(UInt8(ascii: "\n"))
        try? IPCSocketIO.writeAll(fd: fd, data: data)
    }

    private func writeJSONLine(_ json: [String: Any], fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: json) else { return }
        data.append(UInt8(ascii: "\n"))
        try? IPCSocketIO.writeAll(fd: fd, data: data)
    }

    private func readJSONLine(_ fd: Int32) -> [String: Any] {
        guard let line = try? IPCSocketIO.readLine(fd: fd, maxBytes: 4_096),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}

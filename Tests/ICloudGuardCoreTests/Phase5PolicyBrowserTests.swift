import os
import XCTest
@testable import ICloudGuardCore

final class Phase5PolicyBrowserTests: XCTestCase {
    func testFolderPolicyParsesMatchesAndPrioritizesStably() throws {
        let first = try FolderPolicyRule(serialized: "evict-first:Projects/builds")
        let last = try FolderPolicyRule(serialized: "evict-last:Archive")
        let protected = try FolderPolicyRule(serialized: "protect:Taxes")
        XCTAssertTrue(first.matches(relativePath: "Projects/builds/a.bin"))
        XCTAssertFalse(first.matches(relativePath: "Projects/other.bin"))
        XCTAssertThrowsError(try FolderPolicyRule(serialized: "protect:../escape"))

        let candidates = [
            candidate("Archive/a"), candidate("Regular/a"), candidate("Projects/builds/a"), candidate("Regular/b"),
        ]
        XCTAssertEqual(
            FolderPolicySet([first, last, protected]).prioritized(candidates).map(\.relativePath),
            ["Projects/builds/a", "Regular/a", "Regular/b", "Archive/a"]
        )
        XCTAssertEqual(FolderPolicySet([protected]).effectiveMode(relativePath: "Taxes/2026"), .protect)
    }

    func testMostSpecificFolderPolicyIsSharedByScannerEngineAndBrowser() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Projects/Old/file.bin")
        let active = root.appendingPathComponent("Projects/Active/file.bin")
        let archive = root.appendingPathComponent("Projects/Active/Archive/file.bin")
        for file in [old, active, archive] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data".utf8).write(to: file)
        }
        let rules = [
            try FolderPolicyRule(path: "Projects", mode: .protect),
            try FolderPolicyRule(path: "Projects/Active", mode: .evictFirst),
            try FolderPolicyRule(path: "Projects/Active/Archive", mode: .evictLast),
        ]
        let matcher = ProtectedPathsMatcher(
            protectedPaths: [], keepDownloadedPatterns: [], folderPolicies: rules
        )
        let entries = [
            entry(root, "Projects/Old/file.bin", dataless: false, bytes: 10),
            entry(root, "Projects/Active/file.bin", dataless: false, bytes: 20),
            entry(root, "Projects/Active/Archive/file.bin", dataless: false, bytes: 30),
        ]
        let scan = try ScanOrchestrator.scan(
            scopePath: root.path,
            protectedPaths: matcher,
            bulkScan: { _, _, onEntry in
                entries.forEach(onEntry)
                var summary = BulkScanSummary(); summary.scannedEntries = entries.count
                return summary
            },
            isFilePackage: { _ in false },
            freeDiskBytes: { _ in 1 }
        )
        XCTAssertEqual(
            matcher.folderPolicies.prioritized(scan.candidates).map(\.relativePath),
            ["Projects/Active/file.bin", "Projects/Active/Archive/file.bin"]
        )

        let activeCandidate = EvictionCandidate(
            path: active.path,
            relativePath: "Projects/Active/file.bin",
            allocatedBytes: 20,
            modificationDate: nil,
            identity: try XCTUnwrap(EvictionFileIdentity.capture(path: active.path))
        )
        let oldCandidate = EvictionCandidate(
            path: old.path,
            relativePath: "Projects/Old/file.bin",
            allocatedBytes: 10,
            modificationDate: nil,
            identity: try XCTUnwrap(EvictionFileIdentity.capture(path: old.path))
        )
        XCTAssertNil(EvictionEngine.validateCandidateForMutation(
            activeCandidate, scopePath: root.path, protectedPaths: matcher
        ))
        XCTAssertEqual(EvictionEngine.validateCandidateForMutation(
            oldCandidate, scopePath: root.path, protectedPaths: matcher
        ), "protected-path")

        let configURL = root.appendingPathComponent("config.toml")
        try ConfigStore(configURL: configURL).save(AppConfig(scope: .init(path: root.path, folderPolicies: rules)))
        let browser = ScopeBrowserService(scan: { _, _, onEntry in
            entries.forEach(onEntry)
            var summary = BulkScanSummary(); summary.scannedEntries = entries.count
            return summary
        }, isFilePackage: { _ in false })
        let policies = Dictionary(uniqueKeysWithValues: try browser.browse(
            configURL: configURL, revealPaths: true
        ).rows.map { ($0.displayPath, $0.policy) })
        XCTAssertEqual(policies["Projects/Old/file.bin"], .protected)
        XCTAssertEqual(policies["Projects/Active/file.bin"], .evictFirst)
        XCTAssertEqual(policies["Projects/Active/Archive/file.bin"], .evictLast)
    }

    func testConfigRejectsDuplicateNormalizedFolderPolicyPathsRegardlessOfMode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try """
        [scope]
        path = "\(root.path)"
        protected_paths = []
        keep_downloaded_paths = []
        folder_policies = ["protect:Projects", "evict-first:Projects/"]
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate normalized path Projects"))
        }
    }

    func testConfigMigratesAndRoundTripsPhase5KeysWhilePreservingUnknownText() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try """
        # preserve me
        [scope]
        path = "(root.path)"
        protected_paths = ["Never"]

        [custom]
        future = "kept"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        var config = try store.loadMigratingValidated()
        XCTAssertEqual(config.scope.keepDownloadedPaths, [])
        XCTAssertTrue(config.eviction.protectBusyPackages)
        config.scope.keepDownloadedPaths = ["Pinned"]
        config.scope.folderPolicies = [try FolderPolicyRule(serialized: "evict-first:Builds")]
        config.notifications.partialFailure = false
        try store.save(config)
        let loaded = try store.loadValidated()
        XCTAssertEqual(loaded.scope.keepDownloadedPaths, ["Pinned"])
        XCTAssertEqual(loaded.scope.folderPolicies.map(\.serialized), ["evict-first:Builds"])
        XCTAssertFalse(loaded.notifications.partialFailure)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# preserve me"))
        XCTAssertTrue(text.contains("future = \"kept\""))
    }

    func testConfigRejectsMalformedFolderPolicy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try """
        [scope]
        path = "(root.path)"
        protected_paths = []
        keep_downloaded_paths = []
        folder_policies = ["protect:../escape"]
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated())
    }

    func testConfigRejectsUnsafeKeepDownloadedPattern() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try """
        [scope]
        path = "\(root.path)"
        protected_paths = []
        keep_downloaded_paths = ["../escape"]
        folder_policies = []
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertTrue(error.localizedDescription.contains("safe scope-relative"))
        }
    }

    func testNoActionRecoveryAndKeepDownloadedOperationsPersistTruthfulReceipts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let scope = root.appendingPathComponent("scope", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)

        let restoration = try RestorationOperations.restoreLastRun(
            appHomeURL: home,
            scopePath: scope.path,
            trigger: .cli
        )
        XCTAssertEqual(restoration.receipt.status, .noAction)
        XCTAssertEqual(restoration.receipt.exitCode, 0)
        XCTAssertTrue(restoration.result.items.isEmpty)

        let keep = try KeepDownloadedOperations.enforce(
            appHomeURL: home,
            scopePath: scope.path,
            patterns: [],
            trigger: .cli
        )
        XCTAssertEqual(keep.receipt.status, .noAction)
        XCTAssertEqual(keep.receipt.exitCode, 0)
        XCTAssertEqual(try RunHistoryStore(url: home.appendingPathComponent("history.json")).load().count, 2)
    }

    func testScopeBrowserIsBoundedReadOnlyAndExplainsEffectivePolicy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.toml")
        try ConfigStore(configURL: configURL).save(AppConfig(
            scope: .init(
                path: root.path,
                protectedPaths: ["Never"],
                keepDownloadedPaths: ["Pinned"],
                folderPolicies: [try FolderPolicyRule(serialized: "evict-first:Builds")]
            )
        ))
        let summary: BulkScanSummary = {
            var value = BulkScanSummary()
            value.scannedEntries = 4
            return value
        }()
        let entries = [
            entry(root, "Never/a", dataless: false, bytes: 10),
            entry(root, "Pinned/a", dataless: true, bytes: 0),
            entry(root, "Builds/a", dataless: false, bytes: 20),
            entry(root, "Regular/a", dataless: false, bytes: 30),
        ]
        let service = ScopeBrowserService(scan: { _, stop, onEntry in
            for entry in entries where !stop() { onEntry(entry) }
            return summary
        }, isFilePackage: { _ in false })
        let report = try service.browse(configURL: configURL, revealPaths: true, limit: 3)
        XCTAssertEqual(report.rows.count, 3)
        XCTAssertTrue(report.truncated)
        XCTAssertEqual(report.rows.first(where: { $0.displayPath == "Never/a" })?.policy, .protected)
        XCTAssertEqual(report.rows.first(where: { $0.displayPath == "Pinned/a" })?.policy, .keepDownloaded)
        XCTAssertEqual(report.rows.first(where: { $0.displayPath == "Builds/a" })?.policy, .evictFirst)
    }

    func testInjectedPreviewUsesProvidedScopePolicyAndAppHomeWithoutCreatingConfig() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = root.appendingPathComponent("selected-scope", isDirectory: true)
        let appHome = root.appendingPathComponent("selected-home", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        let absentConfig = root.appendingPathComponent("config.toml")
        let now = Date(timeIntervalSince1970: 1_000)
        try StateStore(statePath: appHome.appendingPathComponent("state.json").path).save(
            GuardState(lastRemediationAt: now)
        )
        let pendingPath = scope.appendingPathComponent("Pending/file.bin").path
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([
            WatchlistEntry(
                path: pendingPath,
                addedAt: now,
                nextCheckAt: now,
                pendingVerification: true
            ),
        ]).write(to: appHome.appendingPathComponent("watchlist.json"))
        let folderRule = try FolderPolicyRule(serialized: "evict-first:Builds")
        let config = AppConfig(
            eviction: .init(batchLimit: 7, panicLimit: 11),
            scope: .init(
                path: scope.path,
                protectedPaths: ["Protected"],
                folderPolicies: [folderRule]
            ),
            policy: .init(targetLocalGiB: 1, trimLocalGiB: 2)
        )
        let observation = OSAllocatedUnfairLock(initialState: (path: "", protected: false, first: false))
        var stats = DriveStats()
        stats.materializedBytes = 3 * 1024 * 1024 * 1024
        stats.freeBytes = 100 * 1024 * 1024 * 1024
        stats.freeSpaceAvailable = true
        stats.scanComplete = true
        let scanStats = stats
        let service = ExplainablePreviewService(scan: { path, matcher in
            observation.withLock {
                $0.path = path
                $0.protected = matcher.patternsMatch(
                    path: scope.appendingPathComponent("Protected/a").path,
                    relativePath: "Protected/a"
                )
                $0.first = matcher.folderMode(relativePath: "Builds/a") == .evictFirst
            }
            return ScanBundle(stats: scanStats, candidates: [
                EvictionCandidate(
                    path: pendingPath,
                    relativePath: "Pending/file.bin",
                    allocatedBytes: 2 * 1024 * 1024 * 1024,
                    modificationDate: nil
                ),
            ])
        }, now: { now })

        let preview = try service.run(config: config, appHome: appHome)

        XCTAssertEqual(observation.withLock { $0.path }, scope.path)
        XCTAssertTrue(observation.withLock { $0.protected })
        XCTAssertTrue(observation.withLock { $0.first })
        XCTAssertEqual(preview.action, .cooldown)
        XCTAssertEqual(preview.thresholds.targetLocalBytes, 1 * 1024 * 1024 * 1024)
        XCTAssertEqual(preview.thresholds.trimLocalBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(preview.exclusions[PreviewExclusionReason.pending.rawValue], 1)
        XCTAssertTrue(preview.receiptPersisted)
        XCTAssertEqual(try RunHistoryStore(url: appHome.appendingPathComponent("history.json")).load().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentConfig.path))
    }

    func testInjectedScopeBrowserUsesProvidedPolicyWithoutCreatingConfig() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = root.appendingPathComponent("selected-scope", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let absentConfig = root.appendingPathComponent("config.toml")
        let config = AppConfig(scope: .init(
            path: scope.path,
            protectedPaths: ["Protected"],
            keepDownloadedPaths: ["Pinned"],
            folderPolicies: [try FolderPolicyRule(serialized: "evict-first:Builds")]
        ))
        let entries = [
            entry(scope, "Protected/a", dataless: false, bytes: 10),
            entry(scope, "Pinned/a", dataless: true, bytes: 0),
            entry(scope, "Builds/a", dataless: false, bytes: 20),
        ]
        let observedScope = OSAllocatedUnfairLock(initialState: "")
        let service = ScopeBrowserService(scan: { path, stop, onEntry in
            observedScope.withLock { $0 = path }
            for entry in entries where !stop() { onEntry(entry) }
            var summary = BulkScanSummary()
            summary.scannedEntries = entries.count
            return summary
        }, isFilePackage: { _ in false })

        let report = try service.browse(config: config, revealPaths: true)
        let policies = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.displayPath, $0.policy) })

        XCTAssertEqual(observedScope.withLock { $0 }, scope.path)
        XCTAssertEqual(report.scopeIdentifier, PrivacyIdentifier.scope(scope.path))
        XCTAssertEqual(policies["Protected/a"], .protected)
        XCTAssertEqual(policies["Pinned/a"], .keepDownloaded)
        XCTAssertEqual(policies["Builds/a"], .evictFirst)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentConfig.path))
    }

    private func candidate(_ relative: String) -> EvictionCandidate {
        EvictionCandidate(path: "/scope/\(relative)", relativePath: relative, allocatedBytes: 1, modificationDate: nil)
    }

    private func entry(_ root: URL, _ relative: String, dataless: Bool, bytes: Int64) -> BulkScanEntry {
        BulkScanEntry(
            path: root.appendingPathComponent(relative).path,
            relativePath: relative,
            isDirectory: false,
            isRegularFile: true,
            isDataless: dataless,
            allocatedBytes: bytes,
            logicalBytes: bytes,
            modificationDate: nil,
            identity: nil
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phase5-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

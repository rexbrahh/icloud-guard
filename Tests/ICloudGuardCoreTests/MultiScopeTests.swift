import Darwin
import Foundation
import os
import XCTest
@testable import ICloudGuardCore

final class MultiScopeTests: XCTestCase {
    private var root: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousHome = ProcessInfo.processInfo.environment[AppPaths.homeOverrideEnvironmentKey]
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-multi-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        root = URL(
            fileURLWithPath: candidate.path.hasPrefix("/var/")
                ? "/private" + candidate.path
                : candidate.path,
            isDirectory: true
        )
        setenv(AppPaths.homeOverrideEnvironmentKey, root.appendingPathComponent("app-home").path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        if let previousHome {
            setenv(AppPaths.homeOverrideEnvironmentKey, previousHome, 1)
        } else {
            unsetenv(AppPaths.homeOverrideEnvironmentKey)
        }
        try super.tearDownWithError()
    }

    func testLegacyConfigDoesNotGainOptionalScopesOrMoveStorage() throws {
        let url = root.appendingPathComponent("legacy.toml")
        let store = ConfigStore(configURL: url)
        let legacyWatcher = AppConfig.WatcherConfig(
            backoffMaxSeconds: 91,
            pollutionCheckIntervalSeconds: 401,
            watchlistPollSeconds: 17,
            watchlistMaxEntries: 701,
            verifiedRetentionHours: 49,
            pendingVerificationGraceSeconds: 41,
            pendingRetryLimit: 8,
            maxFights: 6
        )
        try store.save(AppConfig(
            watcher: legacyWatcher,
            scope: .init(path: root.appendingPathComponent("legacy-scope").path)
        ))
        let before = try String(contentsOf: url, encoding: .utf8)

        let config = try store.loadMigratingValidated()
        let catalog = try MultiScopeCatalog(config: config)

        XCTAssertNil(config.scopes)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
        XCTAssertFalse(before.contains("[scopes]"))
        XCTAssertEqual(catalog.contexts.count, 1)
        XCTAssertTrue(catalog.contexts[0].usesLegacyStorage)
        XCTAssertEqual(catalog.contexts[0].config.watcher, legacyWatcher)
        XCTAssertEqual(catalog.contexts[0].paths.state, AppPaths.state)
        XCTAssertEqual(catalog.contexts[0].paths.watchlist, AppPaths.watchlist)
        XCTAssertEqual(catalog.contexts[0].paths.history, AppPaths.history)
        XCTAssertEqual(catalog.contexts[0].paths.recovery, AppPaths.recovery)
        XCTAssertEqual(catalog.contexts[0].paths.log, AppPaths.log)
        XCTAssertEqual(catalog.contexts[0].paths.lock, AppPaths.lock)
        XCTAssertEqual(catalog.contexts[0].paths.browser, AppPaths.browser)
    }

    func testIndependentScopesRoundTripAndPreserveUnknownToml() throws {
        let firstRoot = try makeDirectory("first")
        let secondRoot = try makeDirectory("second")
        let first = ManagedScopeConfig(
            id: "personal",
            name: "Personal",
            scope: .init(
                path: firstRoot.path,
                protectedPaths: ["Private"],
                keepDownloadedPaths: ["Pinned/**"],
                folderPolicies: [try FolderPolicyRule(serialized: "evict-last:Archives")]
            ),
            watcher: .init(
                backoffMaxSeconds: 30,
                pollutionCheckIntervalSeconds: 120,
                watchlistPollSeconds: 5,
                watchlistMaxEntries: 800,
                verifiedRetentionHours: 24,
                pendingVerificationGraceSeconds: 12,
                pendingRetryLimit: 3,
                maxFights: 4
            ),
            policy: .init(targetLocalGiB: 7, trimLocalGiB: 11, panicFreeGiB: 20),
            eviction: .init(batchLimit: 101, panicLimit: 303)
        )
        let second = ManagedScopeConfig(
            id: "work",
            name: "Work",
            automaticEnabled: false,
            scope: .init(path: secondRoot.path, protectedPaths: ["Clients"]),
            watcher: .init(
                backoffMaxSeconds: 300,
                pollutionCheckIntervalSeconds: 600,
                watchlistPollSeconds: 45,
                watchlistMaxEntries: 9_000,
                verifiedRetentionHours: 720,
                pendingVerificationGraceSeconds: 120,
                pendingRetryLimit: 12,
                maxFights: 15
            ),
            policy: .init(targetLocalGiB: 19, trimLocalGiB: 23, panicFreeGiB: 30),
            eviction: .init(batchLimit: 202, panicLimit: 404)
        )
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigStore(configURL: url)
        try store.save(AppConfig(scopes: [first, second]))
        let generated = try String(contentsOf: url, encoding: .utf8)
        try ("# operator scope note\n" + generated + "\n[vendor]\nmode = \"future\"\n")
            .write(to: url, atomically: true, encoding: .utf8)

        var loaded = try store.loadValidated()
        XCTAssertEqual(loaded.scopes, [first, second])
        XCTAssertFalse(store.inspect().migrationNeeded)
        loaded.scopes?[0].policy.targetLocalGiB = 8
        try store.save(loaded)

        let afterSave = try String(contentsOf: url, encoding: .utf8)
        let reloaded = try store.loadValidated()
        XCTAssertTrue(afterSave.contains("# operator scope note"))
        XCTAssertTrue(afterSave.contains("[vendor]\nmode = \"future\""))
        XCTAssertEqual(reloaded.scopes?[0].policy.targetLocalGiB, 8)
        XCTAssertEqual(reloaded.scopes?[0].watcher.verifiedRetentionHours, 24)
        XCTAssertEqual(reloaded.scopes?[1].watcher.verifiedRetentionHours, 720)
        XCTAssertEqual(reloaded.scopes?[0].watcher.pendingRetryLimit, 3)
        XCTAssertEqual(reloaded.scopes?[1].watcher.pendingRetryLimit, 12)
        XCTAssertEqual(reloaded.scopes?[1], second)
        XCTAssertEqual(try MultiScopeCatalog(config: reloaded).contexts.map(\.paths.root), [
            try AppPaths.paths(forManagedScope: first).root,
            try AppPaths.paths(forManagedScope: second).root,
        ])
    }

    func testRejectsDuplicateIdentifiersAndFoldedNamesWithoutReplacingConfig() throws {
        let firstRoot = try makeDirectory("one")
        let secondRoot = try makeDirectory("two")
        let url = root.appendingPathComponent("config.toml")
        try "[scope]\npath = \"/preserve\"\n".write(to: url, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: url)
        let store = ConfigStore(configURL: url)

        let duplicateID = [
            ManagedScopeConfig(id: "same", name: "One", scope: .init(path: firstRoot.path)),
            ManagedScopeConfig(id: "same", name: "Two", scope: .init(path: secondRoot.path)),
        ]
        XCTAssertThrowsError(try store.save(AppConfig(scopes: duplicateID))) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate scope identifier same"))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)

        let selectorCollision = [
            ManagedScopeConfig(id: "work", name: "Primary", scope: .init(path: firstRoot.path)),
            ManagedScopeConfig(id: "other", name: "WORK", scope: .init(path: secondRoot.path)),
        ]
        XCTAssertThrowsError(try MultiScopeValidator.validate(selectorCollision)) { error in
            XCTAssertEqual(error as? MultiScopeError, .ambiguousSelector("work", "WORK"))
        }
        XCTAssertThrowsError(try store.save(AppConfig(scopes: selectorCollision))) { error in
            XCTAssertTrue(error.localizedDescription.contains("scope identifier work conflicts with scope name WORK"))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)

        XCTAssertThrowsError(try MultiScopeValidator.validate([
            ManagedScopeConfig(id: "resume", name: "Primary", scope: .init(path: firstRoot.path)),
            ManagedScopeConfig(id: "other", name: "Résumé", scope: .init(path: secondRoot.path)),
        ])) { error in
            XCTAssertEqual(error as? MultiScopeError, .ambiguousSelector("resume", "Résumé"))
        }

        let duplicateName = [
            ManagedScopeConfig(id: "one", name: "Résumé", scope: .init(path: firstRoot.path)),
            ManagedScopeConfig(id: "two", name: "resume", scope: .init(path: secondRoot.path)),
        ]
        XCTAssertThrowsError(try store.save(AppConfig(scopes: duplicateName))) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate scope name"))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRejectsOverlapsCanonicalAliasesAndSymlinkAmbiguity() throws {
        let parent = try makeDirectory("parent")
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        XCTAssertThrowsError(try MultiScopeValidator.validate([
            ManagedScopeConfig(id: "parent", name: "Parent", scope: .init(path: parent.path)),
            ManagedScopeConfig(id: "child", name: "Child", scope: .init(path: child.path)),
        ])) { error in
            XCTAssertEqual(error as? MultiScopeError, .overlappingPaths("parent", "child"))
        }

        let alias = root.appendingPathComponent("missing/../parent").path
        XCTAssertThrowsError(try MultiScopeValidator.validate([
            ManagedScopeConfig(id: "direct", name: "Direct", scope: .init(path: parent.path)),
            ManagedScopeConfig(id: "alias", name: "Alias", scope: .init(path: alias)),
        ])) { error in
            XCTAssertEqual(error as? MultiScopeError, .overlappingPaths("direct", "alias"))
        }

        let destination = try makeDirectory("destination")
        let link = root.appendingPathComponent("linked-scope")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try MultiScopeValidator.validate([
            ManagedScopeConfig(id: "linked", name: "Linked", scope: .init(path: link.path)),
        ])) { error in
            XCTAssertEqual(error as? MultiScopeError, .symlinkAmbiguity("linked"))
        }
    }

    func testDerivedPathsAndSelectorsDoNotCrossScopesOrExposePaths() throws {
        let firstRoot = try makeDirectory("personal-data")
        let secondRoot = try makeDirectory("work-data")
        let config = AppConfig(scopes: [
            ManagedScopeConfig(id: "personal", name: "Personal", scope: .init(path: firstRoot.path)),
            ManagedScopeConfig(id: "work", name: "Work", scope: .init(path: secondRoot.path)),
        ])
        let catalog = try MultiScopeCatalog(config: config)
        let personal = try catalog.context(for: ScopeSelector("personal"))
        let work = try catalog.context(for: ScopeSelector("work"))
        let byName = try catalog.context(for: ScopeSelector("PERSONAL"))

        XCTAssertEqual(personal.config, byName.config)
        XCTAssertNotEqual(personal.paths.root, work.paths.root)
        for keyPath in [
            \AppPaths.ScopePaths.state, \.watchlist, \.history, \.recovery,
            \.log, \.evictionLog, \.lock, \.browser,
        ] {
            XCTAssertNotEqual(personal.paths[keyPath: keyPath], work.paths[keyPath: keyPath])
        }
        let encoded = try JSONEncoder().encode(catalog.selections)
        let publicOutput = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(publicOutput.contains(firstRoot.path))
        XCTAssertFalse(publicOutput.contains(secondRoot.path))
        XCTAssertTrue(publicOutput.contains(PrivacyIdentifier.scope(firstRoot.path)))
        XCTAssertThrowsError(try ScopeSelector(firstRoot.path))
    }

    func testScopeStorageAndAtomicConfigRejectSymlinkRedirection() throws {
        try AppPaths.ensureHomeDir()
        let external = try makeDirectory("external-storage")
        let scopesLink = AppPaths.homeDir.appendingPathComponent("scopes")
        try FileManager.default.createSymbolicLink(at: scopesLink, withDestinationURL: external)
        let paths = try AppPaths.paths(forManagedScope: ManagedScopeConfig(
            id: "work",
            name: "Work",
            scope: .init(path: try makeDirectory("work-link-scope").path)
        ))

        XCTAssertThrowsError(try AppPaths.ensureScopeDir(paths)) { error in
            XCTAssertEqual(error as? AppPaths.ScopeDirectoryError, .unsafeComponent("scopes"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("work").path))

        try FileManager.default.removeItem(at: scopesLink)
        try FileManager.default.createDirectory(at: scopesLink, withIntermediateDirectories: false)
        let scopeLink = scopesLink.appendingPathComponent("work")
        try FileManager.default.createSymbolicLink(at: scopeLink, withDestinationURL: external)
        XCTAssertThrowsError(try AppPaths.ensureScopeDir(paths)) { error in
            XCTAssertEqual(error as? AppPaths.ScopeDirectoryError, .unsafeComponent("work"))
        }

        let redirectedConfig = scopeLink.appendingPathComponent("config.toml")
        XCTAssertThrowsError(try ConfigStore(configURL: redirectedConfig).save(AppConfig()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("config.toml").path))
    }

    func testScopeStorageRemainsIsolatedForAutomaticContexts() throws {
        let catalog = try MultiScopeCatalog(config: AppConfig(scopes: [
            ManagedScopeConfig(id: "work", name: "Work", scope: .init(path: try makeDirectory("work").path)),
            ManagedScopeConfig(id: "personal", name: "Personal", scope: .init(path: try makeDirectory("personal").path)),
            ManagedScopeConfig(id: "archive", name: "Archive", scope: .init(path: try makeDirectory("archive").path)),
        ]))
        XCTAssertEqual(Set(catalog.contexts.map(\.paths.lock)).count, catalog.contexts.count)
        try AppPaths.ensureScopeDir(catalog.contexts[0].paths)
        let permissions = try FileManager.default.attributesOfItem(atPath: catalog.contexts[0].paths.root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o700)
    }

    func testEmptyStorageBindsThenRestartAcceptsWithoutExposingRawPath() throws {
        let scopeRoot = try makeDirectory("bound-scope")
        let managed = ManagedScopeConfig(id: "bound", name: "Bound", scope: .init(path: scopeRoot.path))
        let first = try MultiScopeCatalog(config: AppConfig(scopes: [managed])).contexts[0]

        try AppPaths.ensureScopeDir(first.paths)
        let markerData = try Data(contentsOf: first.paths.binding)
        let marker = try XCTUnwrap(String(data: markerData, encoding: .utf8))
        XCTAssertFalse(marker.contains(scopeRoot.path))
        XCTAssertTrue(marker.contains(PrivacyIdentifier.hash(try MultiScopeValidator.canonicalPath(for: managed))))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: first.paths.binding.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        let restarted = try MultiScopeCatalog(config: AppConfig(scopes: [managed])).contexts[0]
        XCTAssertNoThrow(try AppPaths.ensureScopeDir(restarted.paths))
        XCTAssertEqual(try Data(contentsOf: restarted.paths.binding), markerData)
    }

    func testSameIDPathChangeAfterRestartFailsClosedAndPreservesOldState() throws {
        let oldScope = try makeDirectory("old-bound-scope")
        let newScope = try makeDirectory("new-bound-scope")
        let old = ManagedScopeConfig(id: "stable", name: "Stable", scope: .init(path: oldScope.path))
        let oldContext = try MultiScopeCatalog(config: AppConfig(scopes: [old])).contexts[0]
        try AppPaths.ensureScopeDir(oldContext.paths)
        let oldState = Data("old-state-must-survive".utf8)
        try oldState.write(to: oldContext.paths.state)
        let oldMarker = try Data(contentsOf: oldContext.paths.binding)

        let changed = ManagedScopeConfig(id: "stable", name: "Stable", scope: .init(path: newScope.path))
        let restarted = try MultiScopeCatalog(config: AppConfig(scopes: [changed])).contexts[0]
        XCTAssertEqual(
            restarted.paths.root.resolvingSymlinksInPath().path,
            oldContext.paths.root.resolvingSymlinksInPath().path
        )
        XCTAssertThrowsError(try AppPaths.ensureScopeDir(restarted.paths)) { error in
            XCTAssertEqual(error as? AppPaths.ScopeDirectoryError, .bindingMismatch("stable"))
        }
        XCTAssertEqual(try Data(contentsOf: oldContext.paths.state), oldState)
        XCTAssertEqual(try Data(contentsOf: oldContext.paths.binding), oldMarker)
    }

    func testUnboundNonemptyManagedStorageFailsClosedWithoutAdopting() throws {
        let managed = ManagedScopeConfig(
            id: "unbound",
            name: "Unbound",
            scope: .init(path: try makeDirectory("unbound-scope").path)
        )
        let paths = try AppPaths.paths(forManagedScope: managed)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let state = Data("pre-marker-state".utf8)
        try state.write(to: paths.state)

        XCTAssertThrowsError(try AppPaths.ensureScopeDir(paths)) { error in
            XCTAssertEqual(error as? AppPaths.ScopeDirectoryError, .unboundNonemptyStorage("unbound"))
        }
        XCTAssertEqual(try Data(contentsOf: paths.state), state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binding.path))
    }

    func testBindingMarkerRejectsSymlinkFIFOOversizeAndNoncanonicalContent() throws {
        enum MarkerVariant: CaseIterable {
            case symlink, fifo, oversized, noncanonical
        }
        for (index, variant) in MarkerVariant.allCases.enumerated() {
            let identifier = "marker-\(index)"
            let managed = ManagedScopeConfig(
                id: identifier,
                name: "Marker \(index)",
                scope: .init(path: try makeDirectory("marker-scope-\(index)").path)
            )
            let paths = try AppPaths.paths(forManagedScope: managed)
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            switch variant {
            case .symlink:
                let victim = root.appendingPathComponent("binding-victim")
                try Data("victim".utf8).write(to: victim)
                try FileManager.default.createSymbolicLink(at: paths.binding, withDestinationURL: victim)
            case .fifo:
                XCTAssertEqual(mkfifo(paths.binding.path, 0o600), 0)
            case .oversized:
                try Data(repeating: 0x41, count: 4_097).write(to: paths.binding)
                chmod(paths.binding.path, 0o600)
            case .noncanonical:
                let canonicalPath = try MultiScopeValidator.canonicalPath(for: managed)
                let content = "{ \"schema\": 1, \"scopeID\": \"\(identifier)\", \"scopeIdentifier\": \"\(PrivacyIdentifier.hash(canonicalPath))\" }"
                try Data(content.utf8).write(to: paths.binding)
                chmod(paths.binding.path, 0o600)
            }
            XCTAssertThrowsError(try AppPaths.ensureScopeDir(paths), "variant \(variant)")
        }
    }

    func testConcurrentFirstBindingPublishesOneCanonicalMarker() throws {
        let managed = ManagedScopeConfig(
            id: "concurrent",
            name: "Concurrent",
            scope: .init(path: try makeDirectory("concurrent-scope").path)
        )
        let paths = try AppPaths.paths(forManagedScope: managed)
        let failures = OSAllocatedUnfairLock(initialState: [String]())

        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { try AppPaths.ensureScopeDir(paths) }
            catch { failures.withLock { $0.append(error.localizedDescription) } }
        }

        XCTAssertEqual(failures.withLock { $0 }, [])
        XCTAssertNoThrow(try AppPaths.ensureScopeDir(paths))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.root.path).sorted(),
            [".scope-binding.json"]
        )
    }

    func testBindingLockContentionFailsWithinBoundedDeadline() throws {
        let managed = ManagedScopeConfig(
            id: "busy-binding",
            name: "Busy Binding",
            scope: .init(path: try makeDirectory("busy-binding-scope").path)
        )
        let paths = try AppPaths.paths(forManagedScope: managed)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let descriptor = Darwin.open(paths.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        let started = Date()

        XCTAssertThrowsError(try AppPaths.ensureScopeDir(paths)) { error in
            XCTAssertEqual(error as? AppPaths.ScopeDirectoryError, .bindingBusy("busy-binding"))
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.9)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binding.path))
    }

    func testRejectsInvalidIdentifiersNamesAndEmptyExplicitSet() {
        XCTAssertThrowsError(try MultiScopeValidator.validateIdentifier("../escape"))
        XCTAssertThrowsError(try MultiScopeValidator.validateIdentifier("Upper"))
        XCTAssertThrowsError(try MultiScopeValidator.validateName(" Work"))
        XCTAssertThrowsError(try MultiScopeValidator.validateName("Work/Private"))
        XCTAssertThrowsError(try MultiScopeValidator.validate([]))
        XCTAssertThrowsError(try MultiScopeValidator.validate((0..<65).map {
            ManagedScopeConfig(id: "scope-\($0)", name: "Scope \($0)", scope: .init(path: "/missing/\($0)"))
        }))
        XCTAssertThrowsError(try AppPaths.paths(forManagedScope: ManagedScopeConfig(
            id: "../escape",
            name: "Escape",
            scope: .init(path: "/tmp/escape")
        )))
    }

    func testRejectsIncompleteAndNoncanonicalDefinitions() throws {
        let url = root.appendingPathComponent("invalid.toml")
        try "[scopes]\nvendor = true\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(configURL: url).loadValidated()) { error in
            XCTAssertTrue(error.localizedDescription.contains("scopes.definitions is required"))
        }

        let definition = try ManagedScopeConfig(
            id: "one",
            name: "One",
            scope: .init(path: try makeDirectory("one-definition").path)
        ).encodedDefinition()
        let noncanonical = definition.replacingOccurrences(of: "{", with: "{\"unknown\":true,", options: [], range: definition.startIndex..<definition.index(after: definition.startIndex))
        XCTAssertThrowsError(try ManagedScopeConfig.decodeDefinition(noncanonical)) { error in
            XCTAssertEqual(error as? MultiScopeError, .invalidDefinition("definition is not canonical"))
        }
    }

    func testCanonicalV1DefinitionLoadsWithDefaultWatcherAndUpgradesOnSave() throws {
        let old = LegacyManagedScopeV1(
            version: 1,
            id: "legacy-v1",
            name: "Legacy V1",
            automaticEnabled: true,
            scope: .init(path: try makeDirectory("legacy-v1").path),
            policy: .init(),
            eviction: .init()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let oldData = try encoder.encode(old)
        let oldDefinition = try XCTUnwrap(String(data: oldData, encoding: .utf8))
        let quotedData = try JSONSerialization.data(withJSONObject: oldDefinition, options: [.fragmentsAllowed])
        let quotedDefinition = try XCTUnwrap(String(data: quotedData, encoding: .utf8))
        let url = root.appendingPathComponent("v1.toml")
        try "[scopes]\ndefinitions = [\(quotedDefinition)]\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let loaded = try ConfigStore(configURL: url).loadValidated()
        let scope = try XCTUnwrap(loaded.scopes?.first)
        XCTAssertEqual(scope.id, "legacy-v1")
        XCTAssertEqual(scope.watcher, AppConfig.WatcherConfig())
        XCTAssertTrue(try scope.encodedDefinition().contains("\"version\":2"))
        XCTAssertTrue(try scope.encodedDefinition().contains("\"watcher\":"))

        try ConfigStore(configURL: url).save(loaded)
        let upgraded = try ConfigStore(configURL: url).loadValidated()
        XCTAssertEqual(upgraded.scopes?.first?.watcher, AppConfig.WatcherConfig())
        XCTAssertNotEqual(try String(contentsOf: url, encoding: .utf8), "[scopes]\ndefinitions = [\(quotedDefinition)]\n")
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct LegacyManagedScopeV1: Codable {
    var version: Int
    var id: String
    var name: String
    var automaticEnabled: Bool
    var scope: AppConfig.ScopeConfig
    var policy: AppConfig.PolicyConfig
    var eviction: AppConfig.EvictionConfig

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case name
        case automaticEnabled = "automatic_enabled"
        case scope
        case policy
        case eviction
    }
}

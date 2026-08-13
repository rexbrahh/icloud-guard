import Foundation
import os
import XCTest
@testable import ICloudGuardCore

final class DownloadSuppressionTests: XCTestCase {
    func testSuppressionConfigDefaultsAreSafe() {
        let config = DownloadSuppressionConfig()
        XCTAssertTrue(config.spotlightSuppression)
        XCTAssertTrue(config.quickLookCacheClear)
        XCTAssertFalse(config.materializeDatalessFiles)
        XCTAssertTrue(config.scopePath.isEmpty)
    }

    func testSuppressionConfigCustomValuesRoundTripCodable() throws {
        let config = DownloadSuppressionConfig(
            spotlightSuppression: false,
            quickLookCacheClear: false,
            materializeDatalessFiles: true,
            scopePath: "/test/path"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DownloadSuppressionConfig.self, from: data)

        XCTAssertEqual(config, decoded)
    }

    func testSpotlightMarkerCreationSucceeds() async throws {
        let sandbox = try makeSandbox()
        let config = DownloadSuppressionConfig(
            spotlightSuppression: true,
            quickLookCacheClear: false,
            materializeDatalessFiles: false,
            scopePath: sandbox.scopeURL.path
        )
        let logger = TestLogger()
        let suppression = DownloadSuppression(config: config, logger: logger)

        let result = await suppression.apply()

        let markerURL = sandbox.scopeURL.appendingPathComponent(".metadata_never_index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(result.spotlight, .succeeded)
    }

    func testSpotlightMarkerIsIdempotent() async throws {
        let sandbox = try makeSandbox()
        let markerURL = sandbox.scopeURL.appendingPathComponent(".metadata_never_index")
        try Data().write(to: markerURL)

        let config = DownloadSuppressionConfig(
            spotlightSuppression: true,
            quickLookCacheClear: false,
            materializeDatalessFiles: false,
            scopePath: sandbox.scopeURL.path
        )
        let logger = TestLogger()
        let suppression = DownloadSuppression(config: config, logger: logger)

        let result = await suppression.apply()

        XCTAssertEqual(result.spotlight, .succeeded)
    }

    func testRemoveSpotlightSuppressionDeletesMarker() throws {
        let sandbox = try makeSandbox()
        let markerURL = sandbox.scopeURL.appendingPathComponent(".metadata_never_index")
        try Data().write(to: markerURL)

        let config = DownloadSuppressionConfig(
            spotlightSuppression: true,
            quickLookCacheClear: false,
            materializeDatalessFiles: false,
            scopePath: sandbox.scopeURL.path
        )
        let logger = TestLogger()
        let suppression = DownloadSuppression(config: config, logger: logger)

        XCTAssertEqual(suppression.removeSpotlightSuppression(), .succeeded)

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testApplyReportsPartialFailurePerMechanism() async throws {
        let sandbox = try makeSandbox()
        let blockedScope = sandbox.rootURL.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedScope)
        let suppression = DownloadSuppression(
            config: DownloadSuppressionConfig(
                spotlightSuppression: true,
                quickLookCacheClear: true,
                materializeDatalessFiles: true,
                scopePath: blockedScope.path
            ),
            logger: TestLogger(),
            quickLookRunner: { _, _ in .succeeded },
            ioPolicyProvider: { _ in .succeeded }
        )

        let result = await suppression.apply()

        XCTAssertEqual(result.ioPolicy, .succeeded)
        guard case .failed = result.spotlight else { return XCTFail("Spotlight failure must remain visible") }
        XCTAssertEqual(result.quickLook, .succeeded)
        XCTAssertFalse(result.allConfiguredSucceeded)
    }

    func testQuickLookWorkIsCancellable() async throws {
        let sandbox = try makeSandbox()
        let started = DispatchSemaphore(value: 0)
        let cancellation = EvictionCancellation()
        let suppression = DownloadSuppression(
            config: DownloadSuppressionConfig(
                spotlightSuppression: false,
                quickLookCacheClear: true,
                materializeDatalessFiles: true,
                scopePath: sandbox.scopeURL.path
            ),
            logger: TestLogger(),
            quickLookRunner: { _, cancellation in
                started.signal()
                while !cancellation.isCancelled { usleep(1_000) }
                return .cancelled
            }
        )

        let task = Task { await suppression.apply(cancellation: cancellation) }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        cancellation.cancel()
        let result = await task.value

        XCTAssertEqual(result.quickLook, .cancelled)
        XCTAssertFalse(result.allConfiguredSucceeded)
    }

    func testConcurrentApplyCallsKeepIndependentMechanismResults() async throws {
        struct CallState {
            var active = 0
            var maximumActive = 0
            var calls = 0
        }
        let sandbox = try makeSandbox()
        let calls = OSAllocatedUnfairLock(initialState: CallState())
        let config = DownloadSuppressionConfig(
            spotlightSuppression: false,
            quickLookCacheClear: true,
            materializeDatalessFiles: true,
            scopePath: sandbox.scopeURL.path
        )
        let runner: QuickLookRunner = { _, _ in
            calls.withLock { state in
                state.active += 1
                state.calls += 1
                state.maximumActive = max(state.maximumActive, state.active)
            }
            usleep(20_000)
            calls.withLock { $0.active -= 1 }
            return .succeeded
        }

        async let first = DownloadSuppression(
            config: config,
            logger: TestLogger(),
            quickLookRunner: runner
        ).apply()
        async let second = DownloadSuppression(
            config: config,
            logger: TestLogger(),
            quickLookRunner: runner
        ).apply()
        let results = await [first, second]

        XCTAssertEqual(results.map(\.quickLook), [.succeeded, .succeeded])
        XCTAssertEqual(calls.withLock { $0.calls }, 2)
        XCTAssertEqual(calls.withLock { $0.maximumActive }, 2)
    }

    func testQuickLookTimeoutRemainsVisible() async throws {
        let sandbox = try makeSandbox()
        let suppression = DownloadSuppression(
            config: DownloadSuppressionConfig(
                spotlightSuppression: false,
                quickLookCacheClear: true,
                materializeDatalessFiles: true,
                scopePath: sandbox.scopeURL.path
            ),
            logger: TestLogger(),
            quickLookRunner: { timeout, _ in timeout == 0.1 ? .timedOut : .failed("unbounded timeout") }
        )

        let result = await suppression.apply(quickLookTimeout: 0)

        XCTAssertEqual(result.quickLook, .timedOut)
        XCTAssertFalse(result.allConfiguredSucceeded)
    }

    func testQuickLookReportsFailureWhenProcessSurvivesTerminateAndKill() async throws {
        struct ProcessState {
            var terminated = 0
            var killed = 0
            var now: UInt64 = 0
        }
        let sandbox = try makeSandbox()
        let state = OSAllocatedUnfairLock(initialState: ProcessState())
        let operations = QuickLookProcessOperations(
            run: {},
            isRunning: { true },
            terminationStatus: { 0 },
            terminate: { state.withLock { $0.terminated += 1 } },
            kill: { state.withLock { $0.killed += 1 } }
        )
        let suppression = DownloadSuppression(
            config: DownloadSuppressionConfig(
                spotlightSuppression: false,
                quickLookCacheClear: true,
                materializeDatalessFiles: true,
                scopePath: sandbox.scopeURL.path
            ),
            logger: TestLogger(),
            quickLookProcessFactory: { operations },
            monotonicNow: {
                state.withLock { value in
                    value.now += 200_000_000
                    return value.now
                }
            },
            sleep: { _ in }
        )

        let result = await suppression.apply(quickLookTimeout: 0.1)

        XCTAssertEqual(result.quickLook, .failed("QuickLook process did not exit after SIGKILL"))
        XCTAssertEqual(state.withLock { $0.terminated }, 1)
        XCTAssertEqual(state.withLock { $0.killed }, 1)
    }

    func testMaterializationTransitionAppliesOffThenExplicitDefaultPolicy() async {
        let policies = OSAllocatedUnfairLock(initialState: [Int32]())
        let provider: IOPolicyProvider = { policy in
            policies.withLock { $0.append(policy) }
            return .succeeded
        }
        let enabled = DownloadSuppression(
            config: DownloadSuppressionConfig(
                spotlightSuppression: false,
                quickLookCacheClear: false,
                materializeDatalessFiles: false
            ),
            logger: TestLogger(),
            quickLookRunner: { _, _ in .disabled },
            ioPolicyProvider: provider
        )
        let disabled = DownloadSuppression(
            config: DownloadSuppressionConfig(
                spotlightSuppression: false,
                quickLookCacheClear: false,
                materializeDatalessFiles: true
            ),
            logger: TestLogger(),
            quickLookRunner: { _, _ in .disabled },
            ioPolicyProvider: provider
        )

        let enabledResult = await enabled.apply()
        let disabledResult = await disabled.apply()
        XCTAssertEqual(enabledResult.ioPolicy, .succeeded)
        XCTAssertEqual(disabledResult.ioPolicy, .succeeded)
        XCTAssertEqual(
            policies.withLock { $0 },
            [ioPolicyMaterializeDatalessFilesOff, ioPolicyMaterializeDatalessFilesDefault]
        )
    }

    func testMaterializationRestoreFailureIsReportedTruthfully() async {
        let suppression = DownloadSuppression(
            config: DownloadSuppressionConfig(
                spotlightSuppression: false,
                quickLookCacheClear: false,
                materializeDatalessFiles: true
            ),
            logger: TestLogger(),
            quickLookRunner: { _, _ in .disabled },
            ioPolicyProvider: { policy in
                policy == ioPolicyMaterializeDatalessFilesDefault
                    ? .failed("restore refused")
                    : .succeeded
            }
        )

        let result = await suppression.apply()
        XCTAssertEqual(result.ioPolicy, .failed("restore refused"))
    }

    private func makeSandbox() throws -> (rootURL: URL, scopeURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scopeURL = rootURL.appendingPathComponent("CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: scopeURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return (rootURL, scopeURL)
    }
}

// MARK: - EvictionVerification Tests

final class EvictionVerificationTests: XCTestCase {
    func testVerifyDatalessReturnsCorrectFlagsForRegularFile() throws {
        let sandbox = try makeSandbox()
        let fileURL = sandbox.appendingPathComponent("test.bin")
        try Data(repeating: 0x41, count: 4096).write(to: fileURL)

        let verification = DatalessVerifier.verify(at: fileURL.path)

        XCTAssertEqual(verification.absolutePath, fileURL.path)
        XCTAssertFalse(verification.isDataless)
        XCTAssertGreaterThan(verification.fileAllocatedSize, 0)
        XCTAssertEqual(verification.fileSize, 4096)
        XCTAssertFalse(verification.isVerifiedDataless)
    }

    func testVerifyDatalessReturnsZeroForNonexistentFile() {
        let verification = DatalessVerifier.verify(at: "/nonexistent/path/file.bin")

        XCTAssertFalse(verification.isDataless)
        XCTAssertEqual(verification.fileAllocatedSize, 0)
        XCTAssertEqual(verification.fileSize, 0)
        XCTAssertFalse(verification.isVerifiedDataless)
    }

    func testIsVerifiedDatalessTrueWhenDatalessFlagSet() {
        let verification = EvictionVerification(
            absolutePath: "/test/path",
            isDataless: true,
            fileAllocatedSize: 0,
            fileSize: 1024
        )
        XCTAssertTrue(verification.isVerifiedDataless)
    }

    func testIsVerifiedDatalessFalseWhenAllocatedSizeNonZero() {
        let verification = EvictionVerification(
            absolutePath: "/test/path",
            isDataless: true,
            fileAllocatedSize: 512,
            fileSize: 1024
        )
        XCTAssertFalse(verification.isVerifiedDataless)
    }

    private func makeSandbox() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

// MARK: - Rematerialization Tests

final class RematerializationEventTests: XCTestCase {
    func testRematerializationEventCodableRoundTrip() throws {
        let event = RematerializationEvent(
            itemPath: "/test/path/file.pdf",
            detectedAt: Date(timeIntervalSince1970: 1700000000),
            previousStatus: "NSURLUbiquitousItemDownloadingStatusNotDownloaded",
            newStatus: "NSURLUbiquitousItemDownloadingStatusCurrent"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RematerializationEvent.self, from: data)

        XCTAssertEqual(event, decoded)
    }

    func testRematerializationEventEquality() {
        let date = Date()
        let event1 = RematerializationEvent(
            itemPath: "/test",
            detectedAt: date,
            previousStatus: "old",
            newStatus: "new"
        )
        let event2 = RematerializationEvent(
            itemPath: "/test",
            detectedAt: date,
            previousStatus: "old",
            newStatus: "new"
        )
        XCTAssertEqual(event1, event2)
    }
}

// MARK: - EvictionEngine Tests

final class EvictionEngineTests: XCTestCase {
    func testEvictNonUbiquitousFileCountsFailureWithReason() throws {
        let sandbox = try makeSandbox()
        let fileURL = sandbox.appendingPathComponent("regular.txt")
        try Data(repeating: 0x42, count: 256).write(to: fileURL)

        let logger = TestLogger()
        let engine = EvictionEngine(logger: logger)
        let candidate = EvictionCandidate(
            path: fileURL.path,
            relativePath: "regular.txt",
            allocatedBytes: 256,
            modificationDate: Date()
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )
        // Non-ubiquitous files can't be evicted — failure must be categorized, not silent
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertEqual(outcome.evictedCount, 0)
        XCTAssertEqual(outcome.reclaimedBytes, 0)
        XCTAssertEqual(outcome.failureReasons.values.reduce(0, +), 1)
        XCTAssertTrue(logger.messages.contains(where: { $0.contains("evict-failed path=regular.txt") }))
    }

    func testFileBudgetStopsEviction() throws {
        let sandbox = try makeSandbox()
        var candidates: [EvictionCandidate] = []
        for index in 0..<5 {
            let fileURL = sandbox.appendingPathComponent("file\(index).txt")
            try Data(repeating: 0x43, count: 128).write(to: fileURL)
            candidates.append(EvictionCandidate(
                path: fileURL.path,
                relativePath: "file\(index).txt",
                allocatedBytes: 128,
                modificationDate: Date()
            ))
        }

        let engine = EvictionEngine(logger: TestLogger())
        let outcome = engine.evict(
            candidates: candidates,
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: []),
            fileBudget: 2
        )
        XCTAssertEqual(outcome.evictedCount + outcome.failedCount, 2)
    }

    func testCancellationStopsEviction() throws {
        let sandbox = try makeSandbox()
        var candidates: [EvictionCandidate] = []
        for index in 0..<5 {
            let fileURL = sandbox.appendingPathComponent("file\(index).txt")
            try Data(repeating: 0x44, count: 128).write(to: fileURL)
            candidates.append(EvictionCandidate(
                path: fileURL.path,
                relativePath: "file\(index).txt",
                allocatedBytes: 128,
                modificationDate: Date()
            ))
        }

        let cancellation = EvictionCancellation()
        cancellation.cancel()
        let engine = EvictionEngine(logger: TestLogger())
        let outcome = engine.evict(
            candidates: candidates,
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: []),
            cancellation: cancellation
        )
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.evictedCount + outcome.failedCount, 0)
    }

    func testVerifiedReclaimedBytesUseMeasuredPackageContents() {
        var measurements = [
            EvictionFootprint(allocatedBytes: 12_288, isDataless: true, isDirectory: true),
            EvictionFootprint(allocatedBytes: 0, isDataless: true, isDirectory: true),
        ]
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in },
            footprint: { _ in measurements.removeFirst() },
            mutationValidator: { _, _, _ in nil }
        )
        let candidate = EvictionCandidate(
            path: "/scope/Movie.fcpbundle",
            relativePath: "Movie.fcpbundle",
            allocatedBytes: 999_999,
            modificationDate: nil,
            isPackageRoot: true
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(outcome.evictedCount, 1)
        XCTAssertEqual(outcome.reclaimedBytes, 12_288)
        XCTAssertEqual(outcome.evictedPaths, [candidate.path])
    }

    func testAPISuccessWithoutPostconditionIsPending() {
        var evictionCalls = 0
        let identity = EvictionFileIdentity(device: 2, inode: 3, kind: .regular)
        let resident = EvictionFootprint(allocatedBytes: 4_096, isDataless: false, identity: identity)
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in evictionCalls += 1 },
            footprint: { _ in resident },
            mutationValidator: { _, _, _ in nil }
        )
        let candidate = EvictionCandidate(
            path: "/scope/file.bin",
            relativePath: "file.bin",
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: identity
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(evictionCalls, 1)
        XCTAssertEqual(outcome.evictedCount, 0)
        XCTAssertEqual(outcome.failedCount, 0)
        XCTAssertEqual(outcome.pendingCount, 1)
        XCTAssertEqual(outcome.reclaimedBytes, 0)
        XCTAssertEqual(outcome.pendingReasons["unverified-postcondition"], 1)
        XCTAssertTrue(outcome.evictedPaths.isEmpty)
        XCTAssertEqual(outcome.pendingPaths, [candidate.path])
        XCTAssertEqual(outcome.pendingIdentities[candidate.path], identity)
    }

    func testOutcomePreservesCandidateIdentityAndValidatesExactlyOnceAfterFootprint() {
        let identity = EvictionFileIdentity(device: 7, inode: 9, kind: .regular)
        var measurements = [
            EvictionFootprint(allocatedBytes: 4_096, isDataless: false, identity: identity),
            EvictionFootprint(allocatedBytes: 0, isDataless: true, identity: identity),
        ]
        var validationCalls = 0
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in },
            footprint: { _ in measurements.removeFirst() },
            mutationValidator: { _, _, _ in validationCalls += 1; return nil }
        )
        let candidate = EvictionCandidate(
            path: "/scope/file.bin",
            relativePath: "file.bin",
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: identity
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(validationCalls, 2) // initial precondition + one final pre-API validation
        XCTAssertEqual(outcome.evictedIdentities[candidate.path], identity)
    }

    func testDatalessPackageRootDoesNotHideResidentChildren() {
        var measurements = [
            EvictionFootprint(allocatedBytes: 8_192, isDataless: true, isDirectory: true),
            EvictionFootprint(allocatedBytes: 4_096, isDataless: true, isDirectory: true),
            EvictionFootprint(allocatedBytes: 4_096, isDataless: true, isDirectory: true),
            EvictionFootprint(allocatedBytes: 4_096, isDataless: true, isDirectory: true),
            EvictionFootprint(allocatedBytes: 4_096, isDataless: true, isDirectory: true),
            EvictionFootprint(allocatedBytes: 4_096, isDataless: true, isDirectory: true),
        ]
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in },
            footprint: { _ in measurements.removeFirst() },
            mutationValidator: { _, _, _ in nil }
        )
        let candidate = EvictionCandidate(
            path: "/scope/App.app",
            relativePath: "App.app",
            allocatedBytes: 8_192,
            modificationDate: nil,
            isPackageRoot: true
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(outcome.evictedCount, 0)
        XCTAssertEqual(outcome.pendingCount, 1)
        XCTAssertEqual(outcome.reclaimedBytes, 0)
    }

    func testAlreadyDatalessCandidateDoesNotInvokeEvictionAPI() throws {
        let sandbox = try makeSandbox()
        let fileURL = sandbox.appendingPathComponent("already-evicted.bin")
        try Data(repeating: 0x41, count: 128).write(to: fileURL)
        var evictionCalls = 0
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in evictionCalls += 1 },
            footprint: { _ in EvictionFootprint(allocatedBytes: 0, isDataless: true) }
        )
        let candidate = EvictionCandidate(
            path: fileURL.path,
            relativePath: fileURL.lastPathComponent,
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: EvictionFileIdentity.capture(path: fileURL.path)
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.evictedCount, 0)
        XCTAssertEqual(outcome.reclaimedBytes, 0)
        XCTAssertEqual(outcome.failureReasons["already-evicted"], 1)
    }

    func testCandidateReplacedBySymlinkIsRejectedBeforeEvictionAPI() throws {
        let sandbox = try makeSandbox()
        let outside = try makeSandbox().appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: outside)
        let fileURL = sandbox.appendingPathComponent("candidate.bin")
        try Data("inside".utf8).write(to: fileURL)
        let candidate = EvictionCandidate(
            path: fileURL.path,
            relativePath: "candidate.bin",
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: EvictionFileIdentity.capture(path: fileURL.path)
        )
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: outside)
        var evictionCalls = 0
        let engine = EvictionEngine(logger: TestLogger(), evictItem: { _ in evictionCalls += 1 }, footprint: EvictionFootprint.measure)

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.failureReasons["symlink"], 1)
        XCTAssertEqual(EvictionFootprint.measure(path: fileURL.path)?.isSymbolicLink, true)
    }

    func testCandidateAncestorReplacedBySymlinkIsRejectedBeforeEvictionAPI() throws {
        let sandbox = try makeSandbox()
        let directory = sandbox.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("candidate.bin")
        try Data("inside".utf8).write(to: fileURL)
        let candidate = EvictionCandidate(
            path: fileURL.path,
            relativePath: "Folder/candidate.bin",
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: EvictionFileIdentity.capture(path: fileURL.path)
        )
        let outside = try makeSandbox()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("candidate.bin"))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        var evictionCalls = 0
        let engine = EvictionEngine(logger: TestLogger(), evictItem: { _ in evictionCalls += 1 }, footprint: EvictionFootprint.measure)

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.failureReasons["unsafe-ancestor"], 1)
    }

    func testPackageProtectedDescendantIsRecheckedBeforeEvictionAPI() throws {
        let sandbox = try makeSandbox()
        let package = sandbox.appendingPathComponent("Mixed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: package.appendingPathComponent("Protected.bin"))
        try Data(repeating: 0x41, count: 4_096).write(to: package.appendingPathComponent("resident.bin"))
        let measured = try XCTUnwrap(EvictionFootprint.measure(path: package.path))
        let candidate = EvictionCandidate(
            path: package.path,
            relativePath: "Mixed.app",
            allocatedBytes: measured.allocatedBytes,
            modificationDate: nil,
            isPackageRoot: true,
            identity: measured.identity
        )
        var evictionCalls = 0
        let engine = EvictionEngine(logger: TestLogger(), evictItem: { _ in evictionCalls += 1 }, footprint: EvictionFootprint.measure)

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: ["Mixed.app/Protected.bin"])
        )

        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.failureReasons["protected-path"], 1)
    }

    func testSameTypeFileReplacementDuringFootprintIsRejectedBeforeAPI() throws {
        let sandbox = try makeSandbox()
        let fileURL = sandbox.appendingPathComponent("candidate.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: fileURL)
        let before = try XCTUnwrap(EvictionFootprint.measure(path: fileURL.path))
        let candidate = EvictionCandidate(
            path: fileURL.path,
            relativePath: "candidate.bin",
            allocatedBytes: before.allocatedBytes,
            modificationDate: nil,
            identity: before.identity
        )
        var evictionCalls = 0
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in evictionCalls += 1 },
            footprintResult: { path in
                try? FileManager.default.removeItem(atPath: path)
                try? Data(repeating: 0x42, count: 4_096).write(to: URL(fileURLWithPath: path))
                return .found(before)
            }
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.failureReasons["stale-identity"], 1)
    }

    func testPackageRootReplacementDuringFootprintIsRejectedBeforeAPI() throws {
        let sandbox = try makeSandbox()
        let package = sandbox.appendingPathComponent("Project.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4_096).write(to: package.appendingPathComponent("resident.bin"))
        let before = try XCTUnwrap(EvictionFootprint.measure(path: package.path))
        let candidate = EvictionCandidate(
            path: package.path,
            relativePath: "Project.app",
            allocatedBytes: before.allocatedBytes,
            modificationDate: nil,
            isPackageRoot: true,
            identity: before.identity
        )
        var evictionCalls = 0
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in evictionCalls += 1 },
            footprintResult: { _ in
                try? FileManager.default.removeItem(at: package)
                try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                try? Data(repeating: 0x42, count: 4_096).write(to: package.appendingPathComponent("replacement.bin"))
                return .found(before)
            }
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: sandbox.path,
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.failureReasons["stale-identity"], 1)
    }

    func testBusyPackageInspectionBlocksBeforeEvictionAndReturnsBoundedAssistance() {
        var evictionCalls = 0
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in evictionCalls += 1 },
            footprint: { _ in EvictionFootprint(allocatedBytes: 4_096, isDataless: false, isDirectory: true) },
            mutationValidator: { _, _, _ in nil },
            inspectBusyPackage: { _ in
                .busy(BusyPackageAssistance(processDisplayNames: ["Editor"]))
            }
        )
        let candidate = EvictionCandidate(
            path: "/scope/Project.package",
            relativePath: "Project.package",
            allocatedBytes: 4_096,
            modificationDate: nil,
            isPackageRoot: true
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.failureReasons["busy-package"], 1)
        XCTAssertEqual(outcome.busyProcessDisplayNames, ["Editor"])
    }

    func testPackageReplacementDuringBusyInspectionIsRejectedByFinalValidator() {
        var evictionCalls = 0
        var replaced = false
        var validationCalls = 0
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in evictionCalls += 1 },
            footprint: { _ in EvictionFootprint(
                allocatedBytes: 4_096, isDataless: false, isDirectory: true
            ) },
            mutationValidator: { _, _, _ in
                validationCalls += 1
                return replaced ? "stale-identity" : nil
            },
            inspectBusyPackage: { _ in
                replaced = true
                return .clear
            }
        )
        let candidate = EvictionCandidate(
            path: "/scope/Project.package",
            relativePath: "Project.package",
            allocatedBytes: 4_096,
            modificationDate: nil,
            isPackageRoot: true
        )

        let outcome = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )

        XCTAssertEqual(validationCalls, 3)
        XCTAssertEqual(evictionCalls, 0)
        XCTAssertEqual(outcome.failureReasons["stale-identity"], 1)
    }

    func testUnavailableBusyInspectionFailsClosedButConfiguredOptOutProceeds() {
        var evictionCalls = 0
        var measurements = [
            EvictionFootprint(allocatedBytes: 4_096, isDataless: false, isDirectory: true),
            EvictionFootprint(allocatedBytes: 4_096, isDataless: false, isDirectory: true),
            EvictionFootprint(allocatedBytes: 0, isDataless: true, isDirectory: true),
        ]
        let engine = EvictionEngine(
            logger: TestLogger(),
            evictItem: { _ in evictionCalls += 1 },
            footprint: { _ in measurements.removeFirst() },
            mutationValidator: { _, _, _ in nil },
            inspectBusyPackage: { _ in .unavailable(.permissionDenied) }
        )
        let candidate = EvictionCandidate(
            path: "/scope/Project.package",
            relativePath: "Project.package",
            allocatedBytes: 4_096,
            modificationDate: nil,
            isPackageRoot: true
        )
        let blocked = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: [])
        )
        XCTAssertEqual(blocked.failureReasons["busy-inspection-permission-denied"], 1)
        XCTAssertEqual(evictionCalls, 0)

        let allowed = engine.evict(
            candidates: [candidate],
            scopePath: "/scope",
            protectedPaths: ProtectedPathsMatcher(patterns: []),
            protectBusyPackages: false
        )
        XCTAssertEqual(allowed.evictedCount, 1)
        XCTAssertEqual(evictionCalls, 1)
    }

    private func makeSandbox() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

// MARK: - Test Utilities

private final class TestLogger: GuardLogging {
    var messages: [String] = []

    func log(_ message: String) {
        messages.append(message)
    }
}

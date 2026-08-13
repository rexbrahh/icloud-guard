import Darwin
import Foundation
import XCTest
@testable import ICloudGuardCore

final class RecoveryTests: XCTestCase {
    func testVerifiedMutationRestoresAndPersistsVerifiedStatus() throws {
        let sandbox = try RecoverySandbox()
        let recorded = try sandbox.recordVerifiedRun()
        var requested: [URL] = []
        var downloaded = false
        let service = sandbox.service(
            requestDownload: { requested.append($0); downloaded = true },
            metadata: { _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: downloaded)) }
        )

        let result = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.runID, sandbox.runID)
        XCTAssertEqual(result.verifiedCount, 1)
        XCTAssertEqual(requested.map(\.path), [sandbox.file.path])
        XCTAssertEqual(try sandbox.journal.load().first?.status, .verified)
        XCTAssertEqual(try sandbox.journal.load().first?.retries, 0)
        XCTAssertEqual(recorded.first?.relativePath, "folder/file.txt")
        XCTAssertEqual(try permissions(of: sandbox.journalURL), 0o600)
    }

    func testUnverifiedDownloadStaysPendingAndIsDurable() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let service = sandbox.service(
            metadata: { _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: false, isDownloading: true)) },
            attempts: 2
        )

        let result = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.pendingCount, 1)
        XCTAssertEqual(result.items.first?.reason, "download-in-progress")
        XCTAssertEqual(try sandbox.journal.load().first?.status, .pending)
    }

    func testProviderFailureIsTruthfulAndDurable() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let service = sandbox.service(
            requestDownload: { _ in throw CocoaError(.fileReadNoPermission) },
            metadata: { _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: false)) }
        )

        let result = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.items.first?.reason, "request-failed")
        XCTAssertEqual(try sandbox.journal.load().first?.status, .failed)
    }

    func testReplacementIdentityIsRejectedBeforeDownloadRequest() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let original = sandbox.scope.appendingPathComponent("original.txt")
        try FileManager.default.moveItem(at: sandbox.file, to: original)
        try Data("replacement".utf8).write(to: sandbox.file)
        var requested = false
        let service = sandbox.service(requestDownload: { _ in requested = true })

        let result = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.items.first?.reason, "stale-identity")
        XCTAssertFalse(requested)
    }

    func testOutsideScopeCandidateCannotEnterJournal() throws {
        let sandbox = try RecoverySandbox()
        let identity = try XCTUnwrap(EvictionFileIdentity.capture(path: sandbox.file.path))
        let outside = sandbox.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let candidate = EvictionCandidate(
            path: outside.path,
            relativePath: "../outside.txt",
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: identity
        )
        let outcome = EvictionOutcome(
            evictedCount: 1,
            failedCount: 0,
            reclaimedBytes: 4_096,
            failureReasons: [:],
            cancelled: false,
            evictedPaths: [outside.path],
            evictedIdentities: [outside.path: identity]
        )

        XCTAssertThrowsError(try sandbox.journal.recordVerifiedMutations(
            runID: sandbox.runID,
            scopePath: sandbox.scope.path,
            candidates: [candidate],
            outcome: outcome
        )) { error in
            XCTAssertEqual(error as? RecoveryJournalStore.JournalError, .invalidMutation("invalid relative path"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.journalURL.path))
    }

    func testSymlinkAncestorIsRejectedBeforeDownloadRequest() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let originalFolder = sandbox.scope.appendingPathComponent("original-folder")
        try FileManager.default.moveItem(at: sandbox.file.deletingLastPathComponent(), to: originalFolder)
        try FileManager.default.createSymbolicLink(
            at: sandbox.file.deletingLastPathComponent(),
            withDestinationURL: originalFolder
        )
        var requested = false
        let service = sandbox.service(
            requestDownload: { _ in requested = true },
            identity: { _ in sandbox.identity }
        )

        let result = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.items.first?.reason, "unsafe-ancestor")
        XCTAssertFalse(requested)
    }

    func testJournalRejectsCorruptionAndByteCap() throws {
        let sandbox = try RecoverySandbox()
        try FileManager.default.createDirectory(at: sandbox.journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: sandbox.journalURL)
        XCTAssertEqual(chmod(sandbox.journalURL.path, 0o600), 0)
        XCTAssertThrowsError(try sandbox.journal.load()) { error in
            XCTAssertEqual(error as? RecoveryJournalStore.JournalError, .corrupt("invalid JSON document"))
        }

        try Data(repeating: 0x61, count: 65).write(to: sandbox.journalURL, options: .atomic)
        XCTAssertEqual(chmod(sandbox.journalURL.path, 0o600), 0)
        let capped = RecoveryJournalStore(url: sandbox.journalURL, maximumEntries: 2, maximumBytes: 64)
        XCTAssertThrowsError(try capped.load()) { error in
            XCTAssertEqual(error as? RecoveryJournalStore.JournalError, .corrupt("file exceeds safety limit (65 bytes)"))
        }
    }

    func testJournalRejectsSymlinkAndEntryCap() throws {
        let sandbox = try RecoverySandbox()
        let target = sandbox.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: sandbox.journalURL, withDestinationURL: target)
        XCTAssertThrowsError(try sandbox.journal.load()) { error in
            XCTAssertEqual(error as? RecoveryJournalStore.JournalError, .io("file is not a readable regular file"))
        }

        try FileManager.default.removeItem(at: sandbox.journalURL)
        let capped = RecoveryJournalStore(url: sandbox.journalURL, maximumEntries: 1)
        let identity = try XCTUnwrap(EvictionFileIdentity.capture(path: sandbox.file.path))
        let entries = ["one.txt", "two.txt"].map {
            RecoveryJournalEntry(
                runID: sandbox.runID,
                scopeIdentifier: PrivacyIdentifier.scope(sandbox.scope.path),
                relativePath: $0,
                isPackageRoot: false,
                identity: identity
            )
        }
        let document = try JSONEncoder().encode(RecoveryTestDocument(entries: entries))
        try document.write(to: sandbox.journalURL)
        XCTAssertEqual(chmod(sandbox.journalURL.path, 0o600), 0)
        XCTAssertThrowsError(try capped.load()) { error in
            XCTAssertEqual(error as? RecoveryJournalStore.JournalError, .corrupt("too many entries"))
        }
    }

    func testCancellationBeforeFirstItemMakesNoRequestOrJournalMutation() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let cancellation = EvictionCancellation()
        cancellation.cancel()
        var requested = false
        let service = sandbox.service(requestDownload: { _ in requested = true })

        let result = try service.restoreLastVerifiedRun(
            scopePath: sandbox.scope.path,
            cancellation: cancellation
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(requested)
        XCTAssertEqual(try sandbox.journal.load().first?.status, .eligible)
        XCTAssertEqual(try sandbox.journal.load().first?.retries, 0)
    }

    func testCancellationDuringVerificationPersistsPendingResult() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let cancellation = EvictionCancellation()
        let service = sandbox.service(
            metadata: { _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: false, isDownloading: true)) },
            attempts: 3,
            delay: { cancellation.cancel() }
        )

        let result = try service.restoreLastVerifiedRun(
            scopePath: sandbox.scope.path,
            cancellation: cancellation
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.pendingCount, 1)
        XCTAssertEqual(result.items.first?.reason, "cancelled")
        XCTAssertEqual(try sandbox.journal.load().first?.status, .pending)
    }

    func testMutationLockContentionAndHeldSeam() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let lockPath = sandbox.root.appendingPathComponent("run.lock").path
        let heldLock = try AdvisoryFileLock(path: lockPath)
        var requests = 0
        var downloaded = false
        let service = sandbox.service(
            requestDownload: { _ in requests += 1; downloaded = true },
            metadata: { _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: downloaded)) }
        )

        XCTAssertThrowsError(try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)) { error in
            XCTAssertEqual(error as? RestorationService.RestorationError, .contention)
        }
        XCTAssertEqual(requests, 0)

        let result = try service.restoreLastVerifiedRun(
            scopePath: sandbox.scope.path,
            mutationLockHeld: true
        )
        XCTAssertEqual(result.verifiedCount, 1)
        XCTAssertEqual(requests, 1)
        withExtendedLifetime(heldLock) {}
    }

    func testRetriesStopAtBound() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        var requests = 0
        let service = sandbox.service(
            requestDownload: { _ in
                requests += 1
                throw CocoaError(.fileReadUnknown)
            },
            metadata: { _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: false)) }
        )

        var lastResult: RestorationResult?
        for _ in 0..<RecoveryJournalStore.maximumRetries + 1 {
            lastResult = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)
        }

        XCTAssertEqual(requests, RecoveryJournalStore.maximumRetries)
        XCTAssertEqual(lastResult?.failedCount, 1)
        XCTAssertEqual(try sandbox.journal.load().first?.retries, RecoveryJournalStore.maximumRetries)
    }

    func testVerifiedJournalStateIsRevalidatedAndReEvictedItemRequestsAgain() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        var downloaded = true
        var requests = 0
        let service = sandbox.service(
            requestDownload: { _ in requests += 1; downloaded = true },
            metadata: { _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: downloaded)) }
        )

        let first = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)
        XCTAssertEqual(first.items.first?.reason, "already-downloaded")
        XCTAssertEqual(requests, 0)

        downloaded = false
        let second = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)
        XCTAssertEqual(second.verifiedCount, 1)
        XCTAssertEqual(second.items.first?.reason, "downloaded")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try sandbox.journal.load().first?.status, .verified)
    }

    func testReplacementIsRejectedEvenAfterPriorVerifiedInvocation() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        _ = try sandbox.service().restoreLastVerifiedRun(scopePath: sandbox.scope.path)
        let displaced = sandbox.root.appendingPathComponent("displaced.txt")
        try FileManager.default.moveItem(at: sandbox.file, to: displaced)
        try Data("replacement".utf8).write(to: sandbox.file)
        var requests = 0

        let result = try sandbox.service(requestDownload: { _ in requests += 1 })
            .restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.items.first?.reason, "stale-identity")
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try sandbox.journal.load().first?.status, .failed)
    }

    func testAlreadyDownloadingDoesNotDuplicateRequestAndLaterInvocationObservesCompletion() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        var downloaded = false
        var requests = 0
        let service = sandbox.service(
            requestDownload: { _ in requests += 1 },
            metadata: { _ in .found(RestorationMetadata(
                isUbiquitous: true, isDownloaded: downloaded, isDownloading: !downloaded
            )) },
            attempts: 1
        )

        let pending = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)
        XCTAssertEqual(pending.pendingCount, 1)
        XCTAssertEqual(pending.items.first?.reason, "download-in-progress")
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try sandbox.journal.load().first?.retries, 0)

        downloaded = true
        let completed = try service.restoreLastVerifiedRun(scopePath: sandbox.scope.path)
        XCTAssertEqual(completed.verifiedCount, 1)
        XCTAssertEqual(completed.items.first?.reason, "already-downloaded")
        XCTAssertEqual(requests, 0)
    }

    func testUnavailablePreflightFailsClosedWithoutDuplicateRequest() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        var requests = 0
        let result = try sandbox.service(
            requestDownload: { _ in requests += 1 },
            metadata: { _ in .unavailable }
        ).restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.pendingCount, 1)
        XCTAssertEqual(result.items.first?.reason, "metadata-unavailable")
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try sandbox.journal.load().first?.retries, 0)
    }

    func testRepeatedCancellationAfterAcceptedRequestNeverConsumesRetryBudget() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        var downloading = false
        var requests = 0
        for _ in 0..<RecoveryJournalStore.maximumRetries + 2 {
            let cancellation = EvictionCancellation()
            let service = sandbox.service(
                requestDownload: { _ in requests += 1; downloading = true; cancellation.cancel() },
                metadata: { _ in .found(RestorationMetadata(
                    isUbiquitous: true, isDownloaded: false, isDownloading: downloading
                )) },
                attempts: 1
            )
            let result = try service.restoreLastVerifiedRun(
                scopePath: sandbox.scope.path, cancellation: cancellation
            )
            XCTAssertEqual(result.pendingCount, 1)
            downloading = false
        }
        XCTAssertEqual(requests, RecoveryJournalStore.maximumRetries + 2)
        XCTAssertEqual(try sandbox.journal.load().first?.retries, 0)
        XCTAssertEqual(try sandbox.journal.load().first?.status, .pending)
    }

    func testLatestReceiptMustMatchScopeRunAndVerifiedMutationCount() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        let unrelated = RecoverySandbox.makeReceipt(
            id: "newer-unrelated",
            scopePath: sandbox.root.appendingPathComponent("other").path,
            verifiedCount: 1
        )
        _ = try sandbox.history.append(unrelated)

        let result = try sandbox.service().restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertEqual(result.runID, sandbox.runID)
        XCTAssertEqual(result.verifiedCount, 1)
    }

    func testIncompleteJournalCannotMasqueradeAsWholeVerifiedRun() throws {
        let sandbox = try RecoverySandbox()
        try sandbox.recordVerifiedRun()
        _ = try sandbox.history.append(RecoverySandbox.makeReceipt(
            id: sandbox.runID,
            scopePath: sandbox.scope.path,
            verifiedCount: 2
        ))
        var requested = false

        let result = try sandbox.service(requestDownload: { _ in requested = true })
            .restoreLastVerifiedRun(scopePath: sandbox.scope.path)

        XCTAssertNil(result.runID)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(requested)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private struct RecoveryTestDocument: Codable {
    var schema = 1
    var entries: [RecoveryJournalEntry]
}

private final class RecoverySandbox {
    let root: URL
    let scope: URL
    let file: URL
    let journalURL: URL
    let historyURL: URL
    let journal: RecoveryJournalStore
    let history: RunHistoryStore
    let runID = "verified-run"
    let identity: EvictionFileIdentity

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        scope = root.appendingPathComponent("scope", isDirectory: true)
        file = scope.appendingPathComponent("folder/file.txt")
        journalURL = root.appendingPathComponent("recovery.json")
        historyURL = root.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: file)
        identity = try XCTUnwrap(EvictionFileIdentity.capture(path: file.path))
        journal = RecoveryJournalStore(url: journalURL)
        history = RunHistoryStore(url: historyURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func recordVerifiedRun() throws -> [RecoveryJournalEntry] {
        let receipt = Self.makeReceipt(id: runID, scopePath: scope.path, verifiedCount: 1)
        _ = try history.append(receipt)
        let candidate = EvictionCandidate(
            path: file.path,
            relativePath: "folder/file.txt",
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: identity
        )
        let outcome = EvictionOutcome(
            evictedCount: 1,
            failedCount: 0,
            reclaimedBytes: 4_096,
            failureReasons: [:],
            cancelled: false,
            evictedPaths: [file.path],
            evictedIdentities: [file.path: identity]
        )
        return try journal.recordVerifiedMutations(
            runID: runID,
            scopePath: scope.path,
            candidates: [candidate],
            outcome: outcome
        )
    }

    func service(
        requestDownload: @escaping (URL) throws -> Void = { _ in },
        metadata: @escaping (URL) -> RestorationMetadataReadResult = {
            _ in .found(RestorationMetadata(isUbiquitous: true, isDownloaded: true))
        },
        identity identityProvider: ((String) -> EvictionFileIdentity?)? = nil,
        attempts: Int = 1,
        delay: @escaping () -> Void = {}
    ) -> RestorationService {
        RestorationService(
            journalStore: journal,
            historyStore: history,
            mutationLockPath: root.appendingPathComponent("run.lock").path,
            verificationAttempts: attempts,
            requestDownload: requestDownload,
            metadata: metadata,
            identity: identityProvider ?? EvictionFileIdentity.capture,
            delay: delay
        )
    }

    static func makeReceipt(id: String, scopePath: String, verifiedCount: Int) -> GuardRunReceipt {
        GuardRunReceipt(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_001),
            trigger: .cli,
            command: "trim",
            requestedAction: "trim",
            action: .targeted,
            dryRun: false,
            reason: "test",
            sourceScopeIdentifier: PrivacyIdentifier.scope(scopePath),
            plannedCount: verifiedCount,
            plannedBytes: Int64(verifiedCount) * 4_096,
            verifiedCount: verifiedCount,
            verifiedBytes: Int64(verifiedCount) * 4_096,
            exitCode: 0,
            status: .succeeded,
            statePersisted: true,
            watchlistPersisted: true
        )
    }
}

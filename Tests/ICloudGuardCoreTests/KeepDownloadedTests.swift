import Foundation
@testable import ICloudGuardCore
import os
import XCTest

final class KeepDownloadedTests: XCTestCase {
    func testMatcherSupportsRelativePrefixesAndGlobsButRejectsUnsafePatterns() {
        let matcher = KeepDownloadedMatcher(patterns: [
            "Projects/Active",
            "Documents/*.pdf",
            "*.photoslibrary",
            "/absolute/path",
            "../escape",
            "Projects/Active/",
        ])

        XCTAssertEqual(matcher.invalidPatternCount, 2)
        XCTAssertEqual(matcher.rules.count, 3)
        XCTAssertTrue(matcher.matches(relativePath: "Projects/Active/file.bin"))
        XCTAssertTrue(matcher.matches(relativePath: "Documents/brief.pdf"))
        XCTAssertTrue(matcher.matches(relativePath: "Photos/Library.photoslibrary/original.bin"))
        XCTAssertFalse(matcher.matches(relativePath: "Projects/Inactive/file.bin"))
    }

    func testEvictionExclusionUsesExactKeepMatcherIncludingBracketsAndDeepAncestors() {
        let patterns = ["Projects/[AB]*/Reports/*.pdf", "*.photoslibrary"]
        let keep = KeepDownloadedMatcher(patterns: patterns)
        let eviction = ProtectedPathsMatcher(
            protectedPaths: [], keepDownloadedPatterns: patterns, folderPolicies: []
        )
        let paths = [
            "Projects/Alpha/Reports/Q1.pdf",
            "Projects/Beta/Reports/Q2.pdf/previews/thumb.bin",
            "Media/Family.photoslibrary/originals/image.heic",
            "Projects/Charlie/Reports/Q3.pdf",
            "Projects/Alpha/Notes/Q1.pdf",
        ]
        for path in paths {
            XCTAssertEqual(
                keep.matches(relativePath: path),
                eviction.isProtected(path: "/scope/\(path)", relativePath: path),
                path
            )
        }
        XCTAssertTrue(keep.matches(relativePath: paths[0]))
        XCTAssertTrue(keep.matches(relativePath: paths[1]))
        XCTAssertFalse(keep.matches(relativePath: paths[3]))
    }

    func testPendingAndEveryResidualReasonProduceCoherentPartialReceipt() throws {
        let residualItemReasons: [KeepDownloadedReasonCode] = [
            .requestFailed, .requestVanished, .requestPermission, .requestBusy,
            .requestNotUbiquitous, .requestCapReached, .outsideScope, .unsafeScope,
            .unsafeAncestor, .symlink, .staleType, .missingIdentity, .staleIdentity,
            .metadataUnavailable, .vanished,
        ]
        let reasonOnly: [KeepDownloadedReasonCode] = [
            .invalidPattern, .ruleCapReached, .scanCapReached, .scanFailed, .scanIncomplete,
        ]
        var items = residualItemReasons.enumerated().map { index, reason in
            KeepDownloadedItemResult(
                path: "/scope/item-\(index)",
                relativePath: "item-\(index)",
                status: reason.rawValue.hasPrefix("request-") && reason != .requestCapReached ? .failed : .skipped,
                reason: reason,
                requestAttempts: 0
            )
        }
        items.append(KeepDownloadedItemResult(
            path: "/scope/pending", relativePath: "pending", status: .pending,
            reason: .verificationPending, requestAttempts: 1
        ))
        var counts = Dictionary(grouping: items, by: \.reason).mapValues(\.count)
        for reason in reasonOnly { counts[reason] = 1 }
        let outcome = KeepDownloadedOutcome(
            items: items,
            scannedEntries: items.count,
            requestsAttempted: 1,
            cancelled: false,
            reasonCounts: counts
        )

        let receipt = KeepDownloadedOperations.makeReceipt(
            outcome: outcome, scopePath: "/scope", trigger: .cli,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(receipt.status, .partial)
        XCTAssertEqual(receipt.exitCode, 1)
        XCTAssertEqual(receipt.pendingCount, 1)
        XCTAssertEqual(receipt.failedCount, residualItemReasons.count + reasonOnly.count)
        XCTAssertEqual(receipt.plannedCount, receipt.pendingCount + receipt.failedCount)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RunHistoryStore(url: root.appendingPathComponent("history.json"))
        _ = try store.append(receipt)
        let loaded = try XCTUnwrap(store.load().last)
        XCTAssertEqual(loaded.id, receipt.id)
        XCTAssertEqual(loaded.status, .partial)
        XCTAssertEqual(loaded.pendingCount, 1)
        XCTAssertEqual(loaded.failedCount, residualItemReasons.count + reasonOnly.count)
    }

    func testVerifiedDownloadUsesNarrowPrefixScanAndOneRequest() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("Projects/Active/item.bin")
        let state = MetadataState(dataless: [file.path])
        let scanRoots = OSAllocatedUnfairLock(initialState: [String]())
        let materializer = KeepDownloadedMaterializer(
            providers: providers(state: state, scan: { root, shouldStop, onEntry in
                scanRoots.withLock { $0.append(root) }
                return try BulkScanner.scan(rootPath: root, shouldStop: shouldStop, onEntry: onEntry)
            }, request: { url in
                state.setDataless(false, path: url.path)
            })
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Projects/Active"])

        XCTAssertEqual(scanRoots.withLock { $0 }, [sandbox.root.appendingPathComponent("Projects/Active").path])
        XCTAssertEqual(outcome.verifiedCount, 1)
        XCTAssertEqual(outcome.requestsAttempted, 1)
        XCTAssertEqual(outcome.items.first?.reason, .downloadVerified)
    }

    func testAcceptedRequestWithoutPostconditionIsPending() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("Documents/item.bin")
        let state = MetadataState(dataless: [file.path])
        let materializer = KeepDownloadedMaterializer(
            limits: KeepDownloadedLimits(verificationAttempts: 2),
            providers: providers(state: state)
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Documents"])

        XCTAssertEqual(outcome.pendingCount, 1)
        XCTAssertEqual(outcome.failedCount, 0)
        XCTAssertEqual(outcome.items.first?.reason, .verificationPending)
    }

    func testRequestFailureIsRetriedAndCategorized() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("Documents/item.bin")
        let state = MetadataState(dataless: [file.path])
        let materializer = KeepDownloadedMaterializer(
            limits: KeepDownloadedLimits(requestAttempts: 2),
            providers: providers(state: state, request: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            })
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Documents"])

        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertEqual(outcome.requestsAttempted, 2)
        XCTAssertEqual(outcome.items.first?.reason, .requestPermission)
    }

    func testSameTypeReplacementAfterScanIsRejectedBeforeRequest() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("Documents/item.bin")
        let replacement = try sandbox.file("replacement.bin")
        let state = MetadataState(dataless: [file.path])
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let materializer = KeepDownloadedMaterializer(
            providers: providers(state: state, scan: { root, shouldStop, onEntry in
                let summary = try BulkScanner.scan(rootPath: root, shouldStop: shouldStop, onEntry: onEntry)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: replacement, to: file)
                return summary
            }, request: { _ in requests.withLock { $0 += 1 } })
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Documents"])

        XCTAssertEqual(requests.withLock { $0 }, 0)
        XCTAssertEqual(outcome.skippedCount, 1)
        XCTAssertEqual(outcome.items.first?.reason, .staleIdentity)
    }

    func testAncestorSymlinkReplacementIsRejectedBeforeRequest() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.file("Documents/item.bin")
        let outside = try Sandbox()
        _ = try outside.file("item.bin")
        let state = MetadataState(dataless: [])
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let documents = sandbox.root.appendingPathComponent("Documents")
        let outsideRoot = outside.root
        let materializer = KeepDownloadedMaterializer(
            providers: providers(state: state, scan: { root, shouldStop, onEntry in
                let summary = try BulkScanner.scan(rootPath: root, shouldStop: shouldStop, onEntry: onEntry)
                try FileManager.default.removeItem(at: documents)
                try FileManager.default.createSymbolicLink(at: documents, withDestinationURL: outsideRoot)
                return summary
            }, request: { _ in requests.withLock { $0 += 1 } })
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Documents"])

        XCTAssertEqual(requests.withLock { $0 }, 0)
        XCTAssertEqual(outcome.items.first?.reason, .unsafeAncestor)
    }

    func testScannerCannotInjectOutsideCandidate() throws {
        let sandbox = try Sandbox()
        try sandbox.directory("Documents")
        let outside = try Sandbox()
        let outsideFile = try outside.file("outside.bin")
        let state = MetadataState(dataless: [outsideFile.path])
        let identity = try XCTUnwrap(EvictionFileIdentity.capture(path: outsideFile.path))
        let materializer = KeepDownloadedMaterializer(
            providers: providers(state: state, scan: { _, _, onEntry in
                onEntry(BulkScanEntry(
                    path: outsideFile.path,
                    relativePath: "outside.bin",
                    isDirectory: false,
                    isRegularFile: true,
                    isDataless: true,
                    allocatedBytes: 0,
                    logicalBytes: 1,
                    modificationDate: nil,
                    identity: identity
                ))
                var summary = BulkScanSummary()
                summary.scannedEntries = 1
                return summary
            })
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Documents"])

        XCTAssertEqual(outcome.requestsAttempted, 0)
        XCTAssertEqual(outcome.skippedCount, 1)
        XCTAssertEqual(outcome.items.first?.reason, .outsideScope)
        XCTAssertEqual(outcome.reasonCounts[.outsideScope], 1)
    }

    func testPreCancelledRunMakesNoRequest() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("Documents/item.bin")
        let state = MetadataState(dataless: [file.path])
        let cancellation = EvictionCancellation()
        cancellation.cancel()

        let outcome = KeepDownloadedMaterializer(providers: providers(state: state)).materialize(
            scopePath: sandbox.root.path,
            patterns: ["Documents"],
            cancellation: cancellation
        )

        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.requestsAttempted, 0)
        XCTAssertEqual(outcome.reasonCounts[.cancelled], 1)
    }

    func testRequestCapSkipsRemainingMatchedFiles() throws {
        let sandbox = try Sandbox()
        let first = try sandbox.file("Documents/a.bin")
        let second = try sandbox.file("Documents/b.bin")
        let state = MetadataState(dataless: [first.path, second.path])
        let materializer = KeepDownloadedMaterializer(
            limits: KeepDownloadedLimits(maxRequests: 1, requestAttempts: 2, verificationAttempts: 1),
            providers: providers(state: state)
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Documents"])

        XCTAssertEqual(outcome.requestsAttempted, 1)
        XCTAssertEqual(outcome.pendingCount, 1)
        XCTAssertEqual(outcome.skippedCount, 1)
        XCTAssertEqual(outcome.reasonCounts[.requestCapReached], 1)
    }

    func testScanCapBoundsCandidateCollection() throws {
        let sandbox = try Sandbox()
        let first = try sandbox.file("Documents/a.bin")
        let second = try sandbox.file("Documents/b.bin")
        let state = MetadataState(dataless: [first.path, second.path])
        let materializer = KeepDownloadedMaterializer(
            limits: KeepDownloadedLimits(maxScanEntries: 1, verificationAttempts: 1),
            providers: providers(state: state)
        )

        let outcome = materializer.materialize(scopePath: sandbox.root.path, patterns: ["Documents"])

        XCTAssertEqual(outcome.scannedEntries, 1)
        XCTAssertEqual(outcome.items.count, 1)
        XCTAssertEqual(outcome.reasonCounts[.scanCapReached], 1)
    }

    private func providers(
        state: MetadataState,
        scan: @escaping KeepDownloadedScanProvider = { root, shouldStop, onEntry in
            try BulkScanner.scan(rootPath: root, shouldStop: shouldStop, onEntry: onEntry)
        },
        request: @escaping KeepDownloadedRequestProvider = { _ in }
    ) -> KeepDownloadedProviders {
        KeepDownloadedProviders(
            scan: scan,
            metadata: { state.metadata(path: $0) },
            requestDownload: request,
            delay: {}
        )
    }
}

private final class MetadataState: Sendable {
    private let dataless: OSAllocatedUnfairLock<Set<String>>

    init(dataless: Set<String>) {
        self.dataless = OSAllocatedUnfairLock(initialState: dataless)
    }

    func setDataless(_ value: Bool, path: String) {
        dataless.withLock {
            if value { $0.insert(path) } else { $0.remove(path) }
        }
    }

    func metadata(path: String) -> KeepDownloadedMetadataResult {
        guard let identity = EvictionFileIdentity.capture(path: path) else { return .vanished }
        return .found(KeepDownloadedMetadata(
            identity: identity,
            isDataless: dataless.withLock { $0.contains(path) }
        ))
    }
}

private final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-keep-downloaded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: url)
        return url
    }
}

import Foundation
import XCTest
@testable import ICloudGuardCore

final class PolicyTests: XCTestCase {
    private let config = GuardConfig(
        label: "org.nix-community.home.icloud-guard",
        logPath: "/tmp/icloud-guard.log",
        lockPath: "/tmp/icloud-guard.lock",
        scopePath: "/tmp/CloudDocs",
        statePath: "/tmp/icloud-guard-state.json",
        notifications: NotificationConfig(enable: false),
        policy: PolicyConfig(
            sampleIntervalSeconds: 300,
            targetLocalGiB: 30,
            trimLocalGiB: 35,
            warnFreeGiB: 80,
            remediateFreeGiB: 50,
            panicFreeGiB: 25,
            growthTriggerGiB: 20,
            growthWindowMinutes: 10,
            cooldownMinutes: 30,
            protectedPaths: ["KeepLocal"]
        )
    )

    func testHealthyScanProducesNoAction() {
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 120 * bytesPerGiB, localBytes: 28 * bytesPerGiB, items: [])
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.kind, .none)
    }

    func testExceedingTrimThresholdTriggersTargetedTrim() {
        let items = [
            snapshot(relativePath: "A.mov", localGiB: 4),
            snapshot(relativePath: "B.mov", localGiB: 3),
            snapshot(relativePath: "C.mov", localGiB: 2),
        ]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 120 * bytesPerGiB, localBytes: 39 * bytesPerGiB, items: items)
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.kind, .targeted)
        XCTAssertEqual(decision.candidates.map(\.relativePath), ["A.mov", "B.mov", "C.mov"])
        XCTAssertEqual(decision.reclaimTargetBytes, 9 * bytesPerGiB)
    }

    func testLowFreeSpaceTriggersTargetedTrim() {
        let items = [snapshot(relativePath: "A.mov", localGiB: 20)]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 40 * bytesPerGiB, localBytes: 20 * bytesPerGiB, items: items)
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.kind, .targeted)
        XCTAssertTrue(decision.reason.contains("free space"))
    }

    func testPanicThresholdTriggersPanicEviction() {
        let items = [snapshot(relativePath: "A.mov", localGiB: 8)]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 20 * bytesPerGiB, localBytes: 8 * bytesPerGiB, items: items)
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.kind, .panic)
        XCTAssertEqual(decision.candidates.count, 1)
    }

    func testCooldownSuppressesTargetedTrim() {
        let items = [snapshot(relativePath: "A.mov", localGiB: 8)]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 40 * bytesPerGiB, localBytes: 36 * bytesPerGiB, items: items)
        let state = GuardState(lastRemediationAt: Date().addingTimeInterval(-5 * 60))
        let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config, now: Date())

        XCTAssertEqual(decision.kind, .cooldown)
        XCTAssertNotNil(decision.cooldownRemainingSeconds)
    }

    func testProtectedPathsAreSkipped() {
        let items = [
            snapshot(relativePath: "KeepLocal/taxes.pdf", localGiB: 6),
            snapshot(relativePath: "Elsewhere/archive.zip", localGiB: 6),
        ]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 120 * bytesPerGiB, localBytes: 42 * bytesPerGiB, items: items)
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.candidates.map(\.relativePath), ["Elsewhere/archive.zip"])
    }

    func testUploadedFlagDoesNotBlockEviction() {
        let items = [
            snapshot(relativePath: "LocalOnly.psd", localGiB: 8, isUploaded: false),
            snapshot(relativePath: "Uploaded.mov", localGiB: 8),
            snapshot(relativePath: "Archive.zip", localGiB: 4),
        ]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 120 * bytesPerGiB, localBytes: 42 * bytesPerGiB, items: items)
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.candidates.map(\.relativePath), ["LocalOnly.psd", "Uploaded.mov"])
    }

    func testUploadingAndDownloadingItemsAreSkipped() {
        let items = [
            snapshot(relativePath: "Uploading.mov", localGiB: 8, isUploading: true),
            snapshot(relativePath: "Downloading.mov", localGiB: 8, isDownloading: true),
            snapshot(relativePath: "Ready.mov", localGiB: 8),
            snapshot(relativePath: "Archive.zip", localGiB: 6),
            snapshot(relativePath: "Photos.tar", localGiB: 6),
        ]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 120 * bytesPerGiB, localBytes: 44 * bytesPerGiB, items: items)
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.candidates.map(\.relativePath), ["Ready.mov", "Archive.zip"])
    }

    func testUploadStateMismatchDoesNotBlockEviction() {
        let mismatch = snapshot(relativePath: "Draft.pages", localGiB: 2, isUploaded: false)
        XCTAssertEqual(mismatch.evictionEligibilityBlockers(protectedPaths: []), [])
        XCTAssertTrue(mismatch.isEligibleForEviction(protectedPaths: []))
    }

    func testPackageDirectoriesCanBeEvicted() {
        let items = [
            snapshot(relativePath: "Movie.fcpbundle", localGiB: 14, isRegularFile: false, isPackage: true),
            snapshot(relativePath: "Archive.zip", localGiB: 4),
        ]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 120 * bytesPerGiB, localBytes: 48 * bytesPerGiB, items: items)
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.candidates.map(\.relativePath), ["Movie.fcpbundle", "Archive.zip"])
    }

    func testProviderErrorsAreReportedAsEvictionBlockers() {
        let errored = ICloudItemSnapshot(
            relativePath: "Partial/provider.bin",
            absolutePath: "/tmp/Partial/provider.bin",
            localBytes: 2 * bytesPerGiB,
            isRegularFile: true,
            isPackage: false,
            isUbiquitous: true,
            isUploaded: true,
            isUploading: false,
            isDownloading: false,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
            hasDownloadError: true,
            hasUploadError: true,
            contentModificationDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            errored.evictionEligibilityBlockers(protectedPaths: []),
            [.downloadError, .uploadError]
        )
        XCTAssertFalse(errored.isEligibleForEviction(protectedPaths: []))
    }

    func testGrowthTriggerCanForceTargetedTrim() {
        let now = Date()
        let state = GuardState(samples: [
            GuardSample(timestamp: now.addingTimeInterval(-9 * 60), localBytes: 5 * bytesPerGiB, freeBytes: 120 * bytesPerGiB),
            GuardSample(timestamp: now.addingTimeInterval(-1 * 60), localBytes: 31 * bytesPerGiB, freeBytes: 118 * bytesPerGiB),
        ])
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 118 * bytesPerGiB, localBytes: 31 * bytesPerGiB, items: [snapshot(relativePath: "Ready.mov", localGiB: 8)])
        let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config, now: now)

        XCTAssertEqual(decision.kind, .targeted)
        XCTAssertTrue(decision.reason.contains("grew too quickly"))
    }

    func testInvalidTrimBelowTargetIsNormalizedBeforeEvaluation() {
        var badConfig = config
        badConfig.policy.targetLocalGiB = 15
        badConfig.policy.trimLocalGiB = 13
        let items = [snapshot(relativePath: "Ready.mov", localGiB: 4)]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 120 * bytesPerGiB, localBytes: 17 * bytesPerGiB, items: items)

        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: badConfig, now: Date())

        XCTAssertEqual(decision.kind, .targeted)
        XCTAssertEqual(decision.reclaimTargetBytes, 2 * bytesPerGiB)
        XCTAssertEqual(decision.candidates.map(\.relativePath), ["Ready.mov"])
    }

    private func snapshot(
        relativePath: String,
        localGiB: Int,
        isRegularFile: Bool = true,
        isPackage: Bool = false,
        isUploaded: Bool = true,
        isUploading: Bool = false,
        isDownloading: Bool = false
    ) -> ICloudItemSnapshot {
        ICloudItemSnapshot(
            relativePath: relativePath,
            absolutePath: "/tmp/\(relativePath)",
            localBytes: Int64(localGiB) * bytesPerGiB,
            isRegularFile: isRegularFile,
            isPackage: isPackage,
            isUbiquitous: true,
            isUploaded: isUploaded,
            isUploading: isUploading,
            isDownloading: isDownloading,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
            hasDownloadError: false,
            hasUploadError: false,
            contentModificationDate: Date(timeIntervalSince1970: 0)
        )
    }
}

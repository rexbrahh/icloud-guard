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

    func testUnavailableFreeSpaceDoesNotTriggerPanicOrTargetedEviction() {
        let scan = ScanResult(
            scopePath: "/tmp",
            freeBytes: 0,
            localBytes: 28 * bytesPerGiB,
            items: [],
            freeSpaceAvailable: false
        )
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.kind, .none)
        XCTAssertEqual(PolicyEngine.targetedReclaimTargetBytes(scan: scan, config: config.policy), 0)
    }

    func testUnavailableFreeSpaceFailsClosedForAutomaticLocalAndGrowthTriggers() {
        let now = Date()
        let scan = ScanResult(
            scopePath: "/tmp",
            freeBytes: 0,
            localBytes: 100 * bytesPerGiB,
            items: [snapshot(relativePath: "A.mov", localGiB: 8)],
            freeSpaceAvailable: false
        )
        let state = GuardState(samples: [
            GuardSample(timestamp: now.addingTimeInterval(-60), localBytes: 1, freeBytes: 0),
            GuardSample(timestamp: now, localBytes: 100 * bytesPerGiB, freeBytes: 0),
        ])

        let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config, now: now)

        XCTAssertEqual(decision.kind, .none)
        XCTAssertTrue(decision.reason.contains("free space unavailable"))
    }

    func testManualRequestRetainsLocalTargetSemanticsWithoutFreeTelemetry() {
        let scan = ScanResult(
            scopePath: "/tmp",
            freeBytes: 0,
            localBytes: 100 * bytesPerGiB,
            items: [snapshot(relativePath: "A.mov", localGiB: 8)],
            freeSpaceAvailable: false
        )

        let decision = PolicyEngine.evaluate(
            scan: scan,
            state: GuardState(),
            config: config,
            now: Date(),
            manualRequest: true
        )

        XCTAssertEqual(decision.kind, .targeted)
    }

    func testManualPanicStillRejectsIncompleteScan() {
        let scan = ScanResult(
            scopePath: "/tmp",
            freeBytes: 100 * bytesPerGiB,
            localBytes: 100 * bytesPerGiB,
            items: [snapshot(relativePath: "A.mov", localGiB: 8)],
            scanComplete: false
        )

        let decision = PolicyEngine.evaluate(
            scan: scan,
            state: GuardState(),
            config: config,
            now: Date(),
            forcePanic: true,
            manualRequest: true
        )

        XCTAssertEqual(decision.kind, .none)
        XCTAssertTrue(decision.reason.contains("incomplete"))
    }

    func testIncompleteScanDisablesAutomaticEviction() {
        let scan = ScanResult(
            scopePath: "/tmp",
            freeBytes: 20 * bytesPerGiB,
            localBytes: 100 * bytesPerGiB,
            items: [snapshot(relativePath: "A.mov", localGiB: 8)],
            scanComplete: false
        )
        let decision = PolicyEngine.evaluate(scan: scan, state: GuardState(), config: config, now: Date())

        XCTAssertEqual(decision.kind, .none)
        XCTAssertTrue(decision.reason.contains("incomplete"))
    }

    func testCooldownSuppressesTargetedTrim() {
        let items = [snapshot(relativePath: "A.mov", localGiB: 8)]
        let scan = ScanResult(scopePath: "/tmp", freeBytes: 40 * bytesPerGiB, localBytes: 36 * bytesPerGiB, items: items)
        let state = GuardState(lastRemediationAt: Date().addingTimeInterval(-5 * 60))
        let decision = PolicyEngine.evaluate(scan: scan, state: state, config: config, now: Date())

        XCTAssertEqual(decision.kind, .cooldown)
        XCTAssertNotNil(decision.cooldownRemainingSeconds)
    }

    func testAutomaticGateUsesFreshCooldownAndExcludesPendingPaths() {
        let now = Date()
        let scan = ScanResult(
            scopePath: "/tmp",
            freeBytes: 40 * bytesPerGiB,
            localBytes: 36 * bytesPerGiB,
            items: []
        )
        let pending = EvictionCandidate(
            path: "/tmp/pending.bin",
            relativePath: "pending.bin",
            allocatedBytes: 1,
            modificationDate: nil
        )
        let ready = EvictionCandidate(
            path: "/tmp/ready.bin",
            relativePath: "ready.bin",
            allocatedBytes: 1,
            modificationDate: nil
        )

        let result = AutomaticRemediationGate.evaluate(
            scan: scan,
            state: GuardState(lastRemediationAt: now),
            config: config,
            candidates: [pending, ready],
            pendingPaths: [pending.path],
            now: now
        )

        XCTAssertEqual(result.decision.kind, .cooldown)
        XCTAssertEqual(result.candidates, [ready])
    }

    func testDryRunPlannerHasCommandSpecificBudgetParity() {
        let candidates = [6, 5, 4].enumerated().map { index, bytes in
            EvictionCandidate(
                path: "/tmp/\(index)",
                relativePath: "\(index)",
                allocatedBytes: Int64(bytes),
                modificationDate: nil
            )
        }
        let targeted = GuardDecision(
            kind: .targeted,
            reason: "targeted reason",
            candidates: [],
            reclaimTargetBytes: 7,
            predictedLocalBytes: 0,
            predictedFreeBytes: 0,
            cooldownRemainingSeconds: nil,
            growthBytes: 0
        )
        var panic = targeted
        panic.kind = .panic
        panic.reason = "panic reason"

        let evictPlan = EvictionDryRunPlanner.plan(
            command: .run,
            decision: targeted,
            candidates: candidates,
            batchLimit: 2,
            panicLimit: 3
        )
        let panicPlan = EvictionDryRunPlanner.plan(
            command: .panicEvict,
            decision: panic,
            candidates: candidates,
            batchLimit: 2,
            panicLimit: 3
        )

        XCTAssertEqual(evictPlan.action, .targeted)
        XCTAssertEqual(evictPlan.reason, "targeted reason")
        XCTAssertEqual(evictPlan.plannedCount, 2)
        XCTAssertEqual(evictPlan.plannedBytes, 11)
        XCTAssertEqual(panicPlan.action, .panic)
        XCTAssertEqual(panicPlan.reason, "panic reason")
        XCTAssertEqual(panicPlan.plannedCount, 3)
        XCTAssertEqual(panicPlan.plannedBytes, 15)
        XCTAssertEqual(
            EvictionDryRunPlanner.plan(
                command: .run,
                decision: panic,
                candidates: candidates,
                batchLimit: 2,
                panicLimit: 3
            ),
            panicPlan
        )
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

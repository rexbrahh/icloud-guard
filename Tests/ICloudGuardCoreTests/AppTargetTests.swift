import Foundation
import Darwin
import CryptoKit
import os
import XCTest
import SwiftUI
@testable import ICloudGuardApp
@testable import ICloudGuardCore

final class Phase5NotificationTests: XCTestCase {
    func testActionRouterValidatesCategoryEventAndCurrentPolicy() {
        let restore = GuardNotificationActionContext(
            actionIdentifier: GuardNotificationCategory.restoreLast,
            categoryIdentifier: GuardNotificationCategory.eviction,
            eventRawValue: GuardNotificationEvent.evictionCompleted.rawValue,
            scopeID: "default",
            scopeGeneration: 1
        )
        XCTAssertEqual(GuardNotificationActionRouter.action(
            for: restore,
            policy: .init(notificationsEnabled: true, notifications: .init())
        ), .restoreLast(scopeID: "default", scopeGeneration: 1))

        let forgedCategory = GuardNotificationActionContext(
            actionIdentifier: GuardNotificationCategory.restoreLast,
            categoryIdentifier: GuardNotificationCategory.attention,
            eventRawValue: GuardNotificationEvent.evictionCompleted.rawValue,
            scopeID: "default",
            scopeGeneration: 1
        )
        XCTAssertNil(GuardNotificationActionRouter.action(
            for: forgedCategory,
            policy: .init(notificationsEnabled: true, notifications: .init())
        ))
        XCTAssertNil(GuardNotificationActionRouter.action(
            for: GuardNotificationActionContext(
                actionIdentifier: GuardNotificationCategory.pause,
                categoryIdentifier: GuardNotificationCategory.attention,
                eventRawValue: nil
            ),
            policy: .init(notificationsEnabled: true, notifications: .init())
        ))

        var disabledActions = AppConfig.NotificationsConfig()
        disabledActions.actionsEnabled = false
        XCTAssertNil(GuardNotificationActionRouter.action(
            for: restore,
            policy: .init(notificationsEnabled: true, notifications: disabledActions)
        ))
        var disabledEvent = AppConfig.NotificationsConfig()
        disabledEvent.evictionCompleted = false
        XCTAssertNil(GuardNotificationActionRouter.action(
            for: restore,
            policy: .init(notificationsEnabled: true, notifications: disabledEvent)
        ))
        XCTAssertNil(GuardNotificationActionRouter.action(
            for: restore,
            policy: .init(notificationsEnabled: false, notifications: .init())
        ))
        XCTAssertNil(GuardNotificationActionRouter.action(for: restore, policy: nil))
        XCTAssertEqual(GuardNotificationAction.restoreLast(scopeID: "default", scopeGeneration: 1).notificationName, .icloudGuardRestoreLast)
        XCTAssertEqual(GuardNotificationAction.pause(scopeID: "default", scopeGeneration: 1).notificationName, .icloudGuardPause)
    }

    func testDeliveredActionIsRevokedAndRejectedAfterStrictPolicyReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        let store = ConfigStore(configURL: configURL)
        var config = AppConfig()
        try store.save(config)
        let context = GuardNotificationActionContext(
            actionIdentifier: GuardNotificationCategory.restoreLast,
            categoryIdentifier: GuardNotificationCategory.eviction,
            eventRawValue: GuardNotificationEvent.evictionCompleted.rawValue,
            scopeID: "default",
            scopeGeneration: 1
        )
        XCTAssertEqual(
            GuardNotificationActionRouter.action(
                for: context,
                policy: .init(
                    notificationsEnabled: true,
                    notifications: try store.loadValidated().notifications
                )
            ),
            .restoreLast(scopeID: "default", scopeGeneration: 1)
        )

        config.notifications.actionsEnabled = false
        try store.save(config)
        let current = try store.loadValidated().notifications
        XCTAssertNil(GuardNotificationActionRouter.action(
            for: context,
            policy: .init(notificationsEnabled: true, notifications: current)
        ))
        XCTAssertTrue(GuardNotificationRevocation.shouldRevoke(
            categoryIdentifier: context.categoryIdentifier,
            eventRawValue: context.eventRawValue,
            notificationsEnabled: true,
            policy: current
        ))
        XCTAssertTrue(GuardNotificationRevocation.shouldRevoke(
            categoryIdentifier: context.categoryIdentifier,
            eventRawValue: nil,
            notificationsEnabled: true,
            policy: AppConfig.NotificationsConfig()
        ))
        XCTAssertTrue(GuardNotificationRevocation.shouldRevoke(
            categoryIdentifier: context.categoryIdentifier,
            eventRawValue: context.eventRawValue,
            notificationsEnabled: false,
            policy: .init()
        ))
    }

    func testDelayedActionDispatchPostsBeforeCompletionAndRejectedBranchCompletesOnce() async {
        let acceptedGate = AsyncTestGate()
        let accepted = NotificationDispatchTestState()
        let context = GuardNotificationActionContext(
            actionIdentifier: GuardNotificationCategory.restoreLast,
            categoryIdentifier: GuardNotificationCategory.eviction,
            eventRawValue: GuardNotificationEvent.evictionCompleted.rawValue,
            scopeID: "default",
            scopeGeneration: 1
        )
        GuardNotificationActionDispatcher.dispatch(
            context: context,
            policyLoader: {
                accepted.markLoaderEntered()
                await acceptedGate.wait()
                return GuardNotificationConsumptionPolicy(
                    notificationsEnabled: true,
                    notifications: .init()
                )
            },
            post: { _ in accepted.record("post") },
            completionHandler: { accepted.recordCompletion() }
        )

        for _ in 0..<1_000 where !accepted.loaderEntered {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(accepted.loaderEntered)
        XCTAssertEqual(accepted.completionCount, 0, "completion must wait for current-policy validation")
        XCTAssertTrue(accepted.events.isEmpty)

        await acceptedGate.open()
        for _ in 0..<1_000 where accepted.completionCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(accepted.events, ["post", "completion"])
        XCTAssertEqual(accepted.completionCount, 1)

        let rejected = NotificationDispatchTestState()
        GuardNotificationActionDispatcher.dispatch(
            context: context,
            policyLoader: {
                return GuardNotificationConsumptionPolicy(
                    notificationsEnabled: false,
                    notifications: .init()
                )
            },
            post: { _ in rejected.record("post") },
            completionHandler: { rejected.recordCompletion() }
        )
        for _ in 0..<1_000 where rejected.completionCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(rejected.events, ["completion"])
        XCTAssertEqual(rejected.completionCount, 1)
    }

    func testNotifierConfigureIsHermeticUntilAppLifecycleActivation() async {
        let notifier = Notifier()
        await notifier.configure(.init(), notificationsEnabled: true)
        await notifier.configure(.init(), notificationsEnabled: false)
    }

    func testNotificationThrottleDoesNotSuppressAfterClockRollback() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(GuardNotificationThrottle.shouldSuppress(
            now: last.addingTimeInterval(10), last: last, interval: 60
        ))
        XCTAssertFalse(GuardNotificationThrottle.shouldSuppress(
            now: last.addingTimeInterval(-10), last: last, interval: 60
        ))
    }

    func testPartialFailureSummaryReportsActualShortfallsAndPersistenceReasons() {
        let report = GuardRunReport(
            kind: .trim,
            reason: "postcondition unavailable",
            candidateCount: 2,
            evictedCount: 1,
            reclaimedBytes: 1,
            failureReasons: ["provider-refused": 1],
            postScanComplete: false,
            statePersisted: false,
            watchlistPersisted: false,
            recoveryJournalPersisted: false,
            exitCode: 74,
            requestedGoalBytes: 1_000_000
        )

        let message = GuardPartialFailureSummary.message(for: report)

        XCTAssertTrue(message.contains("reclaim goal short"))
        XCTAssertTrue(message.contains("post-run scan incomplete"))
        XCTAssertTrue(message.contains("receipt was not persisted"))
        XCTAssertTrue(message.contains("watchlist was not persisted"))
        XCTAssertTrue(message.contains("recovery journal was not persisted"))
        XCTAssertTrue(message.contains("provider-refused 1"))
        XCTAssertFalse(message.contains("0 pending"))
    }
}

private final class NotificationDispatchTestState: Sendable {
    private struct State {
        var loaderEntered = false
        var events: [String] = []
        var completionCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var loaderEntered: Bool { state.withLock(\.loaderEntered) }
    var events: [String] { state.withLock(\.events) }
    var completionCount: Int { state.withLock(\.completionCount) }

    func markLoaderEntered() { state.withLock { $0.loaderEntered = true } }
    func record(_ event: String) { state.withLock { $0.events.append(event) } }
    func recordCompletion() {
        state.withLock {
            $0.events.append("completion")
            $0.completionCount += 1
        }
    }
}

private final class EventHintSourceHarness: Sendable {
    private struct State {
        var handlers: [UUID: FileSystemEventSource.Handler] = [:]
        var starts = 0
        var cancellations = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var source: FileSystemEventSource {
        FileSystemEventSource { [state] handler in
            let id = UUID()
            state.withLock {
                $0.handlers[id] = handler
                $0.starts += 1
            }
            return FileSystemEventSubscription {
                state.withLock {
                    $0.handlers.removeValue(forKey: id)
                    $0.cancellations += 1
                }
            }
        }
    }

    var starts: Int { state.withLock(\.starts) }
    var cancellations: Int { state.withLock(\.cancellations) }

    func emit(_ events: [FileSystemEventHint]) {
        let handlers = state.withLock { Array($0.handlers.values) }
        for handler in handlers { handler(events) }
    }
}

final class GuardServiceTests: XCTestCase {
    func testManualMutationRejectsCorruptOversizedAndUnreadableWatchlistBeforeEviction() async throws {
        enum Fixture { case corrupt, oversized, unreadable }
        for fixture in [Fixture.corrupt, .oversized, .unreadable] {
            let sandbox = try makeSandbox()
            let watchlist = sandbox.home.appendingPathComponent("watchlist.json")
            switch fixture {
            case .corrupt:
                try Data("{broken".utf8).write(to: watchlist)
            case .oversized:
                let descriptor = Darwin.open(watchlist.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                XCTAssertEqual(ftruncate(descriptor, off_t(WatchlistStorage.maximumBytes + 1)), 0)
                Darwin.close(descriptor)
            case .unreadable:
                XCTAssertEqual(mkfifo(watchlist.path, 0o600), 0)
            }
            let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
            let config: AppConfig = {
                var value = AppConfig(scope: .init(path: sandbox.scope.path))
                value.policy.targetLocalGiB = 0
                value.policy.trimLocalGiB = 1
                return value
            }()
            let service = try GuardService(
                scopePath: sandbox.scope.path,
                appHomeURL: sandbox.home,
                scanProvider: { _, _, _, _ in
                    var stats = DriveStats()
                    stats.materializedBytes = bytesPerGiB
                    stats.freeBytes = 100 * bytesPerGiB
                    stats.scanComplete = true
                    stats.freeSpaceAvailable = true
                    return ScanBundle(stats: stats, candidates: [
                        EvictionCandidate(
                            path: sandbox.scope.appendingPathComponent("candidate").path,
                            relativePath: "candidate",
                            allocatedBytes: 1,
                            modificationDate: nil
                        ),
                    ])
                },
                evictProvider: { _, _, _, _, _, _, _, _ in
                    evictionCalls.withLock { $0 += 1 }
                    return EvictionOutcome(
                        evictedCount: 0,
                        failedCount: 0,
                        reclaimedBytes: 0,
                        failureReasons: [:],
                        cancelled: false,
                        evictedPaths: []
                    )
                },
                evictionNotification: { _, _ in },
                runtimeConfigProvider: { config },
                eventHandler: { _ in }
            )

            let report = await service.trimNow()
            await service.stop()

            XCTAssertEqual(report.exitCode, 74)
            XCTAssertTrue(report.reason.contains("watchlist unavailable"))
            XCTAssertEqual(evictionCalls.withLock { $0 }, 0)
        }
    }

    func testConcurrentStatusRequestsShareOneScan() async throws {
        let sandbox = try makeSandbox()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let scan: GuardScanProvider = { _, _, _, _ in
            calls.withLock { $0 += 1 }
            started.signal()
            release.wait()
            return Self.completeBundle()
        }
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictionNotification: { _, _ in },
            eventHandler: { _ in }
        )

        async let first = service.statusText()
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        async let second = service.statusText()
        try await Task.sleep(nanoseconds: 50_000_000)
        release.signal()

        _ = await (first, second)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testCreatorCancellationDoesNotPoisonJoiningStatusWaiter() async throws {
        let sandbox = try makeSandbox()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let scan: GuardScanProvider = { _, _, _, _ in
            calls.withLock { $0 += 1 }
            started.signal()
            release.wait()
            return Self.completeBundle()
        }
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictionNotification: { _, _ in },
            eventHandler: { _ in }
        )
        let creatorCancellation = EvictionCancellation()
        let creator = Task { await service.preview(cancellation: creatorCancellation) }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let joiner = Task { await service.statusText() }
        try await Task.sleep(nanoseconds: 30_000_000)
        creatorCancellation.cancel()
        let creatorReport = await creator.value
        XCTAssertTrue(creatorReport.cancelled)

        release.signal()
        let joinerText = await joiner.value
        XCTAssertTrue(joinerText.contains("Scope:"))
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testJoinerCancellationDoesNotPoisonCreatorStatusWaiter() async throws {
        let sandbox = try makeSandbox()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let scan: GuardScanProvider = { _, _, _, _ in
            calls.withLock { $0 += 1 }
            started.signal()
            release.wait()
            return Self.completeBundle()
        }
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictionNotification: { _, _ in },
            eventHandler: { _ in }
        )
        let creator = Task { await service.statusText() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let joinerCancellation = EvictionCancellation()
        let joiner = Task { await service.preview(cancellation: joinerCancellation) }
        try await Task.sleep(nanoseconds: 30_000_000)
        joinerCancellation.cancel()
        let joinerReport = await joiner.value
        XCTAssertTrue(joinerReport.cancelled)

        release.signal()
        let creatorText = await creator.value
        XCTAssertTrue(creatorText.contains("Scope:"))
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testPauseCancelsScanAndReloadDoesNotResumeIt() async throws {
        let sandbox = try makeSandbox()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let started = DispatchSemaphore(value: 0)
        let scan: GuardScanProvider = { _, _, shouldStop, _ in
            let call = calls.withLock { count in
                count += 1
                return count
            }
            started.signal()
            if call > 1 { return Self.completeBundle() }
            while !shouldStop() { usleep(1_000) }
            var stats = DriveStats()
            stats.scanComplete = false
            stats.completedAt = Date()
            return ScanBundle(stats: stats, candidates: [])
        }
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(
                scopePath: sandbox.scope.path,
                harness: EventHintSourceHarness()
            ),
            eventHandler: { _ in }
        )

        await service.start()
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        await service.pause()

        await service.reloadConfig()
        await service.scanIfStale(maxAgeSeconds: 0)
        XCTAssertEqual(calls.withLock { $0 }, 1)

        await service.resume()
        for _ in 0..<200 where calls.withLock({ $0 }) < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        await service.pause()
    }

    func testRapidPauseResumeStartsFreshScanWhileCancelledProviderIsStillBlocked() async throws {
        let sandbox = try makeSandbox()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let scan: GuardScanProvider = { _, _, _, _ in
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if call == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
            return Self.completeBundle()
        }
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(
                scopePath: sandbox.scope.path,
                harness: EventHintSourceHarness()
            ),
            eventHandler: { _ in }
        )
        await service.start()
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)

        await service.pause()
        await service.resume()
        for _ in 0..<200 where calls.withLock({ $0 }) < 2 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(calls.withLock { $0 }, 2)

        releaseFirst.signal()
        await service.pause()
    }

    func testPauseCancelsActiveEviction() async throws {
        let sandbox = try makeSandbox()
        let evictionStarted = DispatchSemaphore(value: 0)
        let scan: GuardScanProvider = { _, _, _, _ in
            var stats = DriveStats()
            stats.materializedBytes = 2 * bytesPerGiB
            stats.scanComplete = true
            stats.freeSpaceAvailable = true
            stats.completedAt = Date()
            return ScanBundle(stats: stats, candidates: [
                EvictionCandidate(
                    path: sandbox.scope.appendingPathComponent("item.bin").path,
                    relativePath: "item.bin",
                    allocatedBytes: 2 * bytesPerGiB,
                    modificationDate: nil
                ),
            ])
        }
        let evict: GuardEvictProvider = { _, _, _, _, _, _, cancellation, _ in
            evictionStarted.signal()
            while !cancellation.isCancelled { usleep(1_000) }
            return EvictionOutcome(
                evictedCount: 0,
                failedCount: 0,
                reclaimedBytes: 0,
                failureReasons: [:],
                cancelled: true,
                evictedPaths: []
            )
        }
        var config = AppConfig()
        config.policy.targetLocalGiB = 1
        config.policy.trimLocalGiB = 2
        try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).save(config)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictProvider: evict,
            evictionNotification: { _, _ in },
            eventHandler: { _ in }
        )

        let run = Task { await service.trimNow() }
        XCTAssertEqual(evictionStarted.wait(timeout: .now() + 2), .success)
        await service.pause()
        let report = await run.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.exitCode, 130)
    }

    func testPostRunStatsUseSharedScanProviderSeam() async throws {
        let sandbox = try makeSandbox()
        let scanCalls = OSAllocatedUnfairLock(initialState: 0)
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let candidatePath = sandbox.scope.appendingPathComponent("item.bin").path
        try Data(repeating: 0x41, count: 4_096).write(to: URL(fileURLWithPath: candidatePath))
        let identity = try XCTUnwrap(EvictionFileIdentity.capture(path: candidatePath))
        let scan: GuardScanProvider = { _, _, _, _ in
            let call = scanCalls.withLock { value in
                value += 1
                return value
            }
            var stats = DriveStats()
            stats.materializedBytes = call == 1 ? 2 * bytesPerGiB : bytesPerGiB
            stats.scanComplete = true
            stats.freeSpaceAvailable = true
            stats.completedAt = Date()
            return ScanBundle(stats: stats, candidates: call == 1 ? [
                EvictionCandidate(
                    path: candidatePath,
                    relativePath: "item.bin",
                    allocatedBytes: bytesPerGiB,
                    modificationDate: nil,
                    identity: identity
                ),
            ] : [])
        }
        let evict: GuardEvictProvider = { _, _, _, _, _, _, _, _ in
            EvictionOutcome(
                evictedCount: 1,
                failedCount: 0,
                reclaimedBytes: bytesPerGiB,
                failureReasons: [:],
                cancelled: false,
                evictedPaths: [candidatePath],
                evictedIdentities: [candidatePath: identity]
            )
        }
        var config = try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).loadValidated()
        config.policy.targetLocalGiB = 1
        try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).save(config)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictProvider: evict,
            evictionNotification: { _, _ in notifications.withLock { $0 += 1 } },
            eventHandler: { _ in }
        )

        let report = await service.trimNow()

        XCTAssertEqual(scanCalls.withLock { $0 }, 2)
        XCTAssertEqual(notifications.withLock { $0 }, 1)
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertTrue(report.watchlistPersisted)
        XCTAssertTrue(report.postScanComplete)
    }

    func testDisablingSuppressionEmitsSpotlightRemovalFailure() async throws {
        let sandbox = try makeSandbox()
        let results = OSAllocatedUnfairLock(initialState: [DownloadSuppressionResult]())
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            spotlightRemoval: { _ in .failed("marker is read-only") },
            evictionNotification: { _, _ in },
            eventHandler: { event in
                if case .suppressionApplied(let result) = event {
                    results.withLock { $0.append(result) }
                }
            }
        )
        var updated = try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).loadValidated()
        updated.suppression.spotlight = false
        try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).save(updated)

        await service.reloadConfig()

        XCTAssertEqual(results.withLock { $0.last?.spotlight }, .failed("marker is read-only"))
    }

    func testLatestSuppressionGenerationQuiescesStaleMarkerSideEffectBeforeDisable() async throws {
        let sandbox = try makeSandbox()
        let marker = sandbox.scope.appendingPathComponent(".metadata_never_index")
        let enabledStarted = DispatchSemaphore(value: 0)
        let releaseEnabled = AsyncTestGate()
        let results = OSAllocatedUnfairLock(initialState: [DownloadSuppressionResult]())
        let appliedPolicies = OSAllocatedUnfairLock(initialState: [Int32]())
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            suppressionProvider: { config, _ in
                appliedPolicies.withLock {
                    $0.append(config.materializeDatalessFiles
                        ? ioPolicyMaterializeDatalessFilesDefault
                        : ioPolicyMaterializeDatalessFilesOff)
                }
                if config.spotlightSuppression {
                    enabledStarted.signal()
                    await releaseEnabled.wait()
                    try? Data().write(to: marker, options: .atomic)
                    return DownloadSuppressionResult(ioPolicy: .succeeded, spotlight: .succeeded, quickLook: .succeeded)
                }
                return DownloadSuppressionResult(ioPolicy: .succeeded, spotlight: .disabled, quickLook: .disabled)
            },
            spotlightRemoval: { _ in
                do {
                    if FileManager.default.fileExists(atPath: marker.path) {
                        try FileManager.default.removeItem(at: marker)
                    }
                    return .succeeded
                } catch {
                    return .failed(error.localizedDescription)
                }
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(
                scopePath: sandbox.scope.path,
                harness: EventHintSourceHarness()
            ),
            eventHandler: { event in
                if case .suppressionApplied(let result) = event {
                    results.withLock { $0.append(result) }
                }
            }
        )
        let start = Task { await service.start() }
        XCTAssertEqual(enabledStarted.wait(timeout: .now() + 2), .success)
        var updated = try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).loadValidated()
        updated.suppression.spotlight = false
        updated.suppression.materializeDataless = true
        try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).save(updated)

        let reload = Task { await service.reloadConfig() }
        try await Task.sleep(nanoseconds: 30_000_000)
        await releaseEnabled.open()
        await reload.value
        await start.value

        XCTAssertEqual(results.withLock { $0.map(\.spotlight) }, [.succeeded])
        XCTAssertEqual(
            appliedPolicies.withLock { $0 },
            [ioPolicyMaterializeDatalessFilesOff, ioPolicyMaterializeDatalessFilesDefault]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await service.stop()
    }

    func testStopAwaitsSuppressionProviderQuiescenceBeforeReturning() async throws {
        let sandbox = try makeSandbox()
        let marker = sandbox.scope.appendingPathComponent("stop-side-effect")
        let providerStarted = DispatchSemaphore(value: 0)
        let releaseProvider = AsyncTestGate()
        let sideEffects = OSAllocatedUnfairLock(initialState: 0)
        let watchlistEvents = OSAllocatedUnfairLock(initialState: 0)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            suppressionProvider: { _, _ in
                providerStarted.signal()
                await releaseProvider.wait()
                try? Data().write(to: marker, options: .atomic)
                sideEffects.withLock { $0 += 1 }
                return DownloadSuppressionResult(ioPolicy: .succeeded, spotlight: .succeeded, quickLook: .succeeded)
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(
                scopePath: sandbox.scope.path,
                harness: EventHintSourceHarness()
            ),
            eventHandler: { event in
                if case .watchlistUpdated = event { watchlistEvents.withLock { $0 += 1 } }
            }
        )
        let start = Task { await service.start() }
        XCTAssertEqual(providerStarted.wait(timeout: .now() + 2), .success)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let stop = Task {
            await service.stop()
            stopped.withLock { $0 = true }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(stopped.withLock { $0 })

        await releaseProvider.open()
        await stop.value
        await start.value
        XCTAssertTrue(stopped.withLock { $0 })
        XCTAssertEqual(sideEffects.withLock { $0 }, 1)
        XCTAssertEqual(watchlistEvents.withLock { $0 }, 0)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(sideEffects.withLock { $0 }, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStopInvalidatesReloadWaitingOnPriorSuppressionProvider() async throws {
        let sandbox = try makeSandbox()
        let providerStarted = DispatchSemaphore(value: 0)
        let releaseProvider = AsyncTestGate()
        let providerCalls = OSAllocatedUnfairLock(initialState: 0)
        let removalCalls = OSAllocatedUnfairLock(initialState: 0)
        let watchlistEvents = OSAllocatedUnfairLock(initialState: 0)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            suppressionProvider: { _, _ in
                providerCalls.withLock { $0 += 1 }
                providerStarted.signal()
                await releaseProvider.wait()
                return DownloadSuppressionResult(ioPolicy: .succeeded, spotlight: .succeeded, quickLook: .succeeded)
            },
            spotlightRemoval: { _ in
                removalCalls.withLock { $0 += 1 }
                return .succeeded
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(
                scopePath: sandbox.scope.path,
                harness: EventHintSourceHarness()
            ),
            eventHandler: { event in
                if case .watchlistUpdated = event { watchlistEvents.withLock { $0 += 1 } }
            }
        )
        let start = Task { await service.start() }
        XCTAssertEqual(providerStarted.wait(timeout: .now() + 2), .success)
        var updated = try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).loadValidated()
        updated.suppression.spotlight = false
        try ConfigStore(configURL: sandbox.home.appendingPathComponent("config.toml")).save(updated)

        let reload = Task { await service.reloadConfig() }
        try await Task.sleep(nanoseconds: 30_000_000)
        let stop = Task { await service.stop() }
        await releaseProvider.open()
        await stop.value
        await reload.value
        await start.value

        XCTAssertEqual(providerCalls.withLock { $0 }, 1)
        XCTAssertEqual(removalCalls.withLock { $0 }, 0)
        XCTAssertEqual(watchlistEvents.withLock { $0 }, 0)
    }

    func testOneShotReclaimUsesExactBudgetAndDryRunDoesNotMutate() async throws {
        let sandbox = try makeSandbox()
        let budgets = OSAllocatedUnfairLock(initialState: [Int64?]())
        let goalURL = sandbox.scope.appendingPathComponent("goal.bin")
        try Data(repeating: 0x41, count: 8_192).write(to: goalURL)
        let goalIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: goalURL.path))
        let candidate = EvictionCandidate(
            path: goalURL.path,
            relativePath: "goal.bin",
            allocatedBytes: 8_192,
            modificationDate: nil,
            identity: goalIdentity
        )
        let scan: GuardScanProvider = { _, _, _, _ in
            var stats = DriveStats()
            stats.materializedBytes = 8_192
            stats.freeBytes = 1_000_000
            stats.scanComplete = true
            stats.freeSpaceAvailable = true
            stats.completedAt = Date()
            return ScanBundle(stats: stats, candidates: [candidate])
        }
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: scan,
            evictProvider: { _, _, _, byteBudget, _, _, _, _ in
                budgets.withLock { $0.append(byteBudget) }
                return EvictionOutcome(
                    evictedCount: 1,
                    failedCount: 0,
                    processedBytes: 4_096,
                    reclaimedBytes: 4_096,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: [candidate.path],
                    evictedIdentities: [candidate.path: goalIdentity]
                )
            },
            evictionNotification: { _, _ in },
            eventHandler: { _ in }
        )

        let preview = await service.reclaim(bytes: 4_096, dryRun: true)
        XCTAssertTrue(preview.dryRun)
        XCTAssertEqual(preview.plannedBytes, 8_192)
        XCTAssertTrue(budgets.withLock { $0 }.isEmpty)

        let run = await service.reclaim(bytes: 4_096, dryRun: false)
        XCTAssertEqual(budgets.withLock { $0 }, [4_096])
        XCTAssertEqual(run.plannedBytes, 4_096)
        XCTAssertEqual(run.reclaimedBytes, 4_096)
    }

    func testAutomaticTerminalReceiptUsesScheduledTrigger() async throws {
        let sandbox = try makeSandbox()
        let configURL = sandbox.home.appendingPathComponent("config.toml")
        var config = try ConfigStore(configURL: configURL).loadValidated()
        config.policy.targetLocalGiB = 1
        config.policy.trimLocalGiB = 2
        try ConfigStore(configURL: configURL).save(config)
        let candidate = EvictionCandidate(
            path: sandbox.scope.appendingPathComponent("item.bin").path,
            relativePath: "item.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil
        )
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [candidate])
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            eventHandler: { _ in }
        )

        await service.start()
        for _ in 0..<1_000 where (try? RunHistoryStore(
            url: sandbox.home.appendingPathComponent("history.json")
        ).load().isEmpty) != false {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await service.stop()

        let receipt = try XCTUnwrap(RunHistoryStore(url: sandbox.home.appendingPathComponent("history.json")).load().last)
        XCTAssertEqual(receipt.trigger, .scheduled)
        XCTAssertEqual(receipt.status, .noAction)
    }

    func testPersistedFailureReasonRedactsScopePath() async throws {
        let sandbox = try makeSandbox()
        let secretPath = sandbox.scope.appendingPathComponent("Secret.bin").path
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                throw NSError(
                    domain: "GuardServiceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "failed reading \(secretPath)"]
                )
            },
            evictionNotification: { _, _ in },
            eventHandler: { _ in }
        )

        let report = await service.preview()

        XCTAssertEqual(report.exitCode, 1)
        let receipt = try XCTUnwrap(RunHistoryStore(url: sandbox.home.appendingPathComponent("history.json")).load().last)
        XCTAssertFalse(receipt.reason.contains(sandbox.scope.path))
        XCTAssertEqual(receipt.reason, "run failed")
        XCTAssertEqual(receipt.reasonCode, "run-failed")
        XCTAssertFalse(receipt.reason.contains("Secret.bin"))
        let state = try StateStore(statePath: sandbox.home.appendingPathComponent("state.json").path).load()
        XCTAssertFalse(try XCTUnwrap(state.lastSummary?.reason).contains(sandbox.scope.path))
    }

    func testScheduledEnergyDeferralPersistsNoActionAfterAuthoritativeScan() async throws {
        let sandbox = try makeSandbox()
        let configURL = sandbox.home.appendingPathComponent("config.toml")
        var config = try ConfigStore(configURL: configURL).loadValidated()
        config.policy.targetLocalGiB = 1
        config.policy.trimLocalGiB = 2
        try ConfigStore(configURL: configURL).save(config)
        let scanCalls = OSAllocatedUnfairLock(initialState: 0)
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let reports = OSAllocatedUnfairLock(initialState: [GuardRunReport]())
        let candidate = EvictionCandidate(
            path: sandbox.scope.appendingPathComponent("candidate.bin").path,
            relativePath: "candidate.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil
        )
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                scanCalls.withLock { $0 += 1 }
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [candidate])
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            evictionNotification: { _, _ in },
            energySignalProvider: {
                EnergySchedulingSignals(
                    lowPowerModeEnabled: true,
                    thermalState: .nominal,
                    powerSource: .ac
                )
            },
            eventHandler: { event in
                if case .runFinished(let report) = event { reports.withLock { $0.append(report) } }
            }
        )

        await service.start()
        for _ in 0..<1_000 where reports.withLock({ $0.isEmpty }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await service.stop()

        XCTAssertEqual(scanCalls.withLock { $0 }, 1, "energy policy must not suppress safety reconciliation")
        XCTAssertEqual(evictionCalls.withLock { $0 }, 0)
        let report = try XCTUnwrap(reports.withLock { $0.last })
        XCTAssertEqual(report.trigger, .scheduled)
        XCTAssertEqual(report.action, .targeted)
        XCTAssertEqual(report.reason, "automatic eviction deferred: low-power-mode")
        XCTAssertTrue(report.statePersisted)
        let receipt = try XCTUnwrap(
            RunHistoryStore(url: sandbox.home.appendingPathComponent("history.json")).load().last
        )
        XCTAssertEqual(receipt.status, .noAction)
        XCTAssertEqual(receipt.trigger, .scheduled)
        XCTAssertEqual(receipt.reason, "automatic eviction deferred: low-power-mode")
        XCTAssertEqual(receipt.reasonCode, "automatic-eviction-deferred-low-power-mode")
        XCTAssertEqual(receipt.verifiedCount, 0)
    }

    func testScheduledKeepDownloadedDefersOnLowEnergyAndManualKeepBypassesDeferral() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let config: AppConfig = {
            var value = AppConfig(scope: .init(
                path: sandbox.scope.path,
                keepDownloadedPaths: ["Pinned"]
            ))
            value.policy.targetLocalGiB = 1
            value.policy.trimLocalGiB = 2
            return value
        }()
        let providerCalls = OSAllocatedUnfairLock(initialState: 0)
        let providerTriggers = OSAllocatedUnfairLock(initialState: [GuardRunTrigger]())
        let providerPatterns = OSAllocatedUnfairLock(initialState: [[String]]())
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let energyReads = OSAllocatedUnfairLock(initialState: 0)
        let keepReceipts = OSAllocatedUnfairLock(initialState: [GuardRunReceipt]())
        let scheduledDeferral = DispatchSemaphore(value: 0)
        let hints = EventHintSourceHarness()
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [])
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            energySignalProvider: {
                energyReads.withLock { $0 += 1 }
                return EnergySchedulingSignals(
                    lowPowerModeEnabled: true,
                    thermalState: .nominal,
                    powerSource: .ac
                )
            },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            runtimeConfigProvider: { config },
            keepDownloadedProvider: { _, scope, patterns, trigger, _ in
                providerCalls.withLock { $0 += 1 }
                providerTriggers.withLock { $0.append(trigger) }
                providerPatterns.withLock { $0.append(patterns) }
                return KeepDownloadedExecution(
                    outcome: KeepDownloadedOutcome(
                        items: [],
                        scannedEntries: 0,
                        requestsAttempted: 0,
                        cancelled: false,
                        reasonCounts: [:]
                    ),
                    receipt: GuardRunReceipt(
                        startedAt: Date(),
                        trigger: trigger,
                        command: "keep-downloaded",
                        requestedAction: "keep-downloaded",
                        action: .none,
                        dryRun: false,
                        reason: "keep-downloaded items already local or no rules matched",
                        sourceScopeIdentifier: PrivacyIdentifier.scope(scope),
                        privacyScopePath: scope,
                        exitCode: 0,
                        status: .noAction,
                        statePersisted: true,
                        watchlistPersisted: true
                    )
                )
            },
            eventHandler: { event in
                if case .keepDownloadedFinished(let receipt) = event {
                    keepReceipts.withLock { $0.append(receipt) }
                    if receipt.trigger == .scheduled { scheduledDeferral.signal() }
                }
            }
        )

        await service.start()
        XCTAssertEqual(scheduledDeferral.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(providerCalls.withLock { $0 }, 0, "scheduled keep mutation must not call its provider under low power")
        XCTAssertEqual(evictionCalls.withLock { $0 }, 0, "the same low-power decision must also defer scheduled trim")
        XCTAssertEqual(energyReads.withLock { $0 }, 1, "scheduled trim and keep must share one energy signal snapshot")
        let deferred = try XCTUnwrap(keepReceipts.withLock { $0.first })
        XCTAssertEqual(deferred.command, "keep-downloaded")
        XCTAssertEqual(deferred.requestedAction, "keep-downloaded")
        XCTAssertEqual(deferred.trigger, .scheduled)
        XCTAssertEqual(deferred.status, .noAction)
        XCTAssertEqual(deferred.reason, "keep-downloaded deferred: low-power-mode")
        XCTAssertEqual(deferred.reasonMetadata?["energy_reason"], "low-power-mode")
        XCTAssertTrue(deferred.statePersisted)
        let persisted = try XCTUnwrap(
            RunHistoryStore(url: sandbox.home.appendingPathComponent("history.json")).load().last
        )
        XCTAssertEqual(persisted.id, deferred.id)
        XCTAssertEqual(persisted.reason, deferred.reason)

        let manual = try await service.enforceKeepDownloaded()
        await service.stop()

        XCTAssertEqual(providerCalls.withLock { $0 }, 1, "manual keep must bypass scheduled energy deferral")
        XCTAssertEqual(providerTriggers.withLock { $0 }, [.appManual])
        XCTAssertEqual(providerPatterns.withLock { $0 }, [["Pinned"]])
        XCTAssertEqual(manual.receipt.trigger, .appManual)
        XCTAssertEqual(energyReads.withLock { $0 }, 1, "manual keep must not read scheduled energy signals")
    }

    func testScheduledPanicBypassesEnergyDeferral() async throws {
        let sandbox = try makeSandbox()
        let candidateURL = sandbox.scope.appendingPathComponent("panic.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: candidateURL)
        let identity = try XCTUnwrap(EvictionFileIdentity.capture(path: candidateURL.path))
        let candidate = EvictionCandidate(
            path: candidateURL.path,
            relativePath: candidateURL.lastPathComponent,
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: identity
        )
        let energyReads = OSAllocatedUnfairLock(initialState: 0)
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let finished = DispatchSemaphore(value: 0)
        let hints = EventHintSourceHarness()
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 0
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [candidate])
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 1,
                    failedCount: 0,
                    processedBytes: 4_096,
                    reclaimedBytes: 4_096,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: [candidate.path],
                    evictedIdentities: [candidate.path: identity]
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            energySignalProvider: {
                energyReads.withLock { $0 += 1 }
                return EnergySchedulingSignals(
                    lowPowerModeEnabled: true,
                    thermalState: .critical,
                    powerSource: .battery
                )
            },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            eventHandler: { event in
                if case .runFinished = event { finished.signal() }
            }
        )

        await service.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        await service.stop()

        XCTAssertEqual(evictionCalls.withLock { $0 }, 1)
        XCTAssertEqual(energyReads.withLock { $0 }, 0, "panic must bypass even reading deferral signals")
    }

    func testUnavailableEnergySignalsRunTargetedRemediation() async throws {
        let sandbox = try makeSandbox()
        let configURL = sandbox.home.appendingPathComponent("config.toml")
        var config = try ConfigStore(configURL: configURL).loadValidated()
        config.policy.targetLocalGiB = 1
        config.policy.trimLocalGiB = 2
        try ConfigStore(configURL: configURL).save(config)
        let candidateURL = sandbox.scope.appendingPathComponent("target.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: candidateURL)
        let identity = try XCTUnwrap(EvictionFileIdentity.capture(path: candidateURL.path))
        let candidate = EvictionCandidate(
            path: candidateURL.path,
            relativePath: candidateURL.lastPathComponent,
            allocatedBytes: 4_096,
            modificationDate: nil,
            identity: identity
        )
        let energyReads = OSAllocatedUnfairLock(initialState: 0)
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let finished = DispatchSemaphore(value: 0)
        let hints = EventHintSourceHarness()
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [candidate])
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 1,
                    failedCount: 0,
                    processedBytes: 4_096,
                    reclaimedBytes: 4_096,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: [candidate.path],
                    evictedIdentities: [candidate.path: identity]
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            energySignalProvider: {
                energyReads.withLock { $0 += 1 }
                return EnergySchedulingSignals(
                    lowPowerModeEnabled: nil,
                    thermalState: nil,
                    powerSource: nil
                )
            },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            eventHandler: { event in
                if case .runFinished = event { finished.signal() }
            }
        )

        await service.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        await service.stop()

        XCTAssertEqual(energyReads.withLock { $0 }, 1)
        XCTAssertEqual(evictionCalls.withLock { $0 }, 1)
    }

    func testEventHintsRunBoundedTargetThenAuthoritativeFullReconciliation() async throws {
        let sandbox = try makeSandbox()
        let folder = sandbox.scope.appendingPathComponent("Changed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hints = EventHintSourceHarness()
        let scannedScopes = OSAllocatedUnfairLock(initialState: [String]())
        let statsEvents = OSAllocatedUnfairLock(initialState: [DriveStats]())
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let targetCandidate = EvictionCandidate(
            path: folder.appendingPathComponent("pressure.bin").path,
            relativePath: "pressure.bin",
            allocatedBytes: 99 * bytesPerGiB,
            modificationDate: nil
        )
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { scope, _, _, _ in
                scannedScopes.withLock { $0.append(scope) }
                if scope == folder.path {
                    var targetedStats = DriveStats()
                    targetedStats.materializedBytes = 99 * bytesPerGiB
                    targetedStats.freeBytes = 0
                    targetedStats.scanComplete = true
                    targetedStats.freeSpaceAvailable = true
                    targetedStats.completedAt = Date()
                    return ScanBundle(stats: targetedStats, candidates: [targetCandidate])
                }
                return Self.completeBundle()
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            energySignalProvider: {
                EnergySchedulingSignals(lowPowerModeEnabled: true, thermalState: .critical, powerSource: .battery)
            },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            eventHandler: { event in
                if case .statsUpdated(let stats) = event { statsEvents.withLock { $0.append(stats) } }
            }
        )
        await service.start()
        for _ in 0..<1_000 where statsEvents.withLock({ $0.count }) < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(statsEvents.withLock { $0.count }, 1)

        hints.emit([FileSystemEventHint(path: folder.appendingPathComponent("file.txt").path)])
        for _ in 0..<2_000 where scannedScopes.withLock({ $0.count }) < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<1_000 where statsEvents.withLock({ $0.count }) < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(Array(scannedScopes.withLock { $0 }.suffix(2)), [folder.path, sandbox.scope.path])
        XCTAssertEqual(statsEvents.withLock { $0.count }, 2, "targeted statistics must not be published as full-drive state")
        XCTAssertEqual(statsEvents.withLock { $0.last?.materializedBytes }, 0)
        XCTAssertEqual(statsEvents.withLock { $0.last?.freeBytes }, 100 * bytesPerGiB)
        XCTAssertEqual(evictionCalls.withLock { $0 }, 0, "target hints never authorize eviction")

        let beforeFullHint = scannedScopes.withLock { $0.count }
        hints.emit([FileSystemEventHint(path: folder.path, flags: .userDropped)])
        for _ in 0..<2_000 where scannedScopes.withLock({ $0.count }) <= beforeFullHint {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(
            Array(scannedScopes.withLock { $0 }.dropFirst(beforeFullHint)),
            [sandbox.scope.path],
            "drop flags must skip targeted work and force exactly one authoritative root scan"
        )
        XCTAssertEqual(evictionCalls.withLock { $0 }, 0)
        await service.stop()
    }

    func testTargetHintOnlyReordersMatchingAuthoritativeCandidates() async throws {
        let sandbox = try makeSandbox()
        let changed = sandbox.scope.appendingPathComponent("Changed", isDirectory: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        let hintedURL = changed.appendingPathComponent("hinted.bin")
        let unhintedURL = sandbox.scope.appendingPathComponent("unhinted.bin")
        let urgentDirectory = sandbox.scope.appendingPathComponent("Urgent", isDirectory: true)
        try FileManager.default.createDirectory(at: urgentDirectory, withIntermediateDirectories: true)
        let urgentURL = urgentDirectory.appendingPathComponent("first.bin")
        let targetOnlyURL = changed.appendingPathComponent("target-only.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: hintedURL)
        try Data(repeating: 0x42, count: 4_096).write(to: unhintedURL)
        try Data(repeating: 0x44, count: 4_096).write(to: urgentURL)
        try Data(repeating: 0x43, count: 4_096).write(to: targetOnlyURL)
        let hintedIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: hintedURL.path))
        let unhintedIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: unhintedURL.path))
        let targetOnlyIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: targetOnlyURL.path))
        let urgentIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: urgentURL.path))
        let hinted = EvictionCandidate(
            path: hintedURL.path,
            relativePath: "Changed/hinted.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil,
            identity: hintedIdentity
        )
        let unhinted = EvictionCandidate(
            path: unhintedURL.path,
            relativePath: "unhinted.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil,
            identity: unhintedIdentity
        )
        let targetOnly = EvictionCandidate(
            path: targetOnlyURL.path,
            relativePath: "target-only.bin",
            allocatedBytes: 99 * bytesPerGiB,
            modificationDate: nil,
            identity: targetOnlyIdentity
        )
        let urgent = EvictionCandidate(
            path: urgentURL.path,
            relativePath: "Urgent/first.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil,
            identity: urgentIdentity
        )
        let rootScans = OSAllocatedUnfairLock(initialState: 0)
        let scannedScopes = OSAllocatedUnfairLock(initialState: [String]())
        let evictedCandidatePaths = OSAllocatedUnfairLock(initialState: [String]())
        let publishedStats = OSAllocatedUnfairLock(initialState: [DriveStats]())
        let mutationCalled = DispatchSemaphore(value: 0)
        let hints = EventHintSourceHarness()
        let urgentRule = try FolderPolicyRule(path: "Urgent", mode: .evictFirst)
        let config: AppConfig = {
            var value = AppConfig(scope: .init(path: sandbox.scope.path))
            value.scope.folderPolicies = [urgentRule]
            value.policy.targetLocalGiB = 1
            value.policy.trimLocalGiB = 2
            return value
        }()
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { scope, _, _, _ in
                scannedScopes.withLock { $0.append(scope) }
                if scope == changed.path {
                    var targetStats = DriveStats()
                    targetStats.materializedBytes = 99 * bytesPerGiB
                    targetStats.freeBytes = 0
                    targetStats.scanComplete = true
                    targetStats.freeSpaceAvailable = true
                    targetStats.completedAt = Date()
                    return ScanBundle(stats: targetStats, candidates: [hinted, targetOnly])
                }
                let call = rootScans.withLock { count -> Int in
                    count += 1
                    return count
                }
                if call == 1 { return Self.completeBundle() }
                var fullStats = DriveStats()
                fullStats.materializedBytes = 3 * bytesPerGiB
                fullStats.freeBytes = 100 * bytesPerGiB
                fullStats.scanComplete = true
                fullStats.freeSpaceAvailable = true
                fullStats.completedAt = Date()
                return ScanBundle(stats: fullStats, candidates: [unhinted, hinted, urgent])
            },
            evictProvider: { candidates, _, _, _, _, _, _, _ in
                evictedCandidatePaths.withLock { $0 = candidates.map(\.path) }
                mutationCalled.signal()
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            energySignalProvider: {
                EnergySchedulingSignals(lowPowerModeEnabled: false, thermalState: .nominal, powerSource: .ac)
            },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            runtimeConfigProvider: { config },
            eventHandler: { event in
                if case .statsUpdated(let stats) = event { publishedStats.withLock { $0.append(stats) } }
            }
        )
        await service.start()
        for _ in 0..<1_000 where publishedStats.withLock({ $0.count }) < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        hints.emit([FileSystemEventHint(path: hintedURL.path)])
        XCTAssertEqual(mutationCalled.wait(timeout: .now() + 2), .success)
        await service.stop()

        XCTAssertEqual(Array(scannedScopes.withLock { $0 }.suffix(2)), [changed.path, sandbox.scope.path])
        XCTAssertEqual(
            evictedCandidatePaths.withLock { $0 },
            [urgentURL.path, hintedURL.path, unhintedURL.path],
            "folder policy stays authoritative while target metadata prioritizes matches within an equal policy rank"
        )
        XCTAssertFalse(evictedCandidatePaths.withLock { $0.contains(targetOnlyURL.path) })
        XCTAssertEqual(publishedStats.withLock { $0.count }, 2)
        XCTAssertEqual(publishedStats.withLock { $0.last?.materializedBytes }, 3 * bytesPerGiB)
        XCTAssertFalse(publishedStats.withLock { $0.contains(where: { $0.materializedBytes == 99 * bytesPerGiB }) })
    }

    func testEventHintLifecycleReloadsAndPauseCancelsTargetScan() async throws {
        let sandbox = try makeSandbox()
        let folder = sandbox.scope.appendingPathComponent("Changed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hints = EventHintSourceHarness()
        let fullScans = OSAllocatedUnfairLock(initialState: 0)
        let targetStarted = DispatchSemaphore(value: 0)
        let targetCancelled = DispatchSemaphore(value: 0)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { scope, _, shouldStop, _ in
                if scope == sandbox.scope.path {
                    fullScans.withLock { $0 += 1 }
                    return Self.completeBundle()
                }
                targetStarted.signal()
                while !shouldStop() { usleep(1_000) }
                targetCancelled.signal()
                throw CancellationError()
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            eventHandler: { _ in }
        )
        await service.start()
        for _ in 0..<1_000 where fullScans.withLock({ $0 }) < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(hints.starts, 1)

        await service.reloadConfig()
        XCTAssertEqual(hints.starts, 2)
        XCTAssertEqual(hints.cancellations, 1)
        hints.emit([FileSystemEventHint(path: folder.appendingPathComponent("file.txt").path)])
        XCTAssertEqual(targetStarted.wait(timeout: .now() + 2), .success)
        await service.pause()
        XCTAssertEqual(targetCancelled.wait(timeout: .now() + 2), .success)
        let pausedCount = fullScans.withLock { $0 }
        hints.emit([FileSystemEventHint(path: folder.path)])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fullScans.withLock { $0 }, pausedCount)
        XCTAssertEqual(hints.cancellations, 2)

        await service.resume()
        for _ in 0..<1_000 where fullScans.withLock({ $0 }) <= pausedCount {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(hints.starts, 3)
        await service.stop()
        let stoppedCount = fullScans.withLock { $0 }
        hints.emit([FileSystemEventHint(path: folder.path)])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fullScans.withLock { $0 }, stoppedCount)
        XCTAssertEqual(hints.cancellations, 3)
    }

    func testManualPreparationLoadsWatchlistWithoutStartingAutomaticWorkAndReloadsSafely() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let watchedURL = sandbox.scope.appendingPathComponent("watched.bin")
        let freshURL = sandbox.scope.appendingPathComponent("fresh.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: watchedURL)
        try Data(repeating: 0x42, count: 4_096).write(to: freshURL)
        let watchedIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: watchedURL.path))
        let freshIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: freshURL.path))
        let now = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([WatchlistEntry(
            path: watchedURL.path,
            addedAt: now,
            nextCheckAt: now.addingTimeInterval(60),
            pendingVerification: true,
            identity: watchedIdentity
        )]).write(to: sandbox.home.appendingPathComponent("watchlist.json"), options: .atomic)

        let config: AppConfig = {
            var value = AppConfig(scope: .init(path: sandbox.scope.path))
            value.scope.keepDownloadedPaths = ["Pinned"]
            value.policy.targetLocalGiB = 1
            value.policy.trimLocalGiB = 2
            value.eviction.batchLimit = 7
            return value
        }()
        let runtimeConfig = OSAllocatedUnfairLock(initialState: config)
        let scanCalls = OSAllocatedUnfairLock(initialState: 0)
        let suppressionCalls = OSAllocatedUnfairLock(initialState: 0)
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let keepCalls = OSAllocatedUnfairLock(initialState: 0)
        let evictedPaths = OSAllocatedUnfairLock(initialState: [String]())
        let budgets = OSAllocatedUnfairLock(initialState: [Int]())
        let watchlistCounts = OSAllocatedUnfairLock(initialState: [Int]())
        let hints = EventHintSourceHarness()
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                scanCalls.withLock { $0 += 1 }
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [
                    EvictionCandidate(
                        path: watchedURL.path,
                        relativePath: watchedURL.lastPathComponent,
                        allocatedBytes: bytesPerGiB,
                        modificationDate: nil,
                        identity: watchedIdentity
                    ),
                    EvictionCandidate(
                        path: freshURL.path,
                        relativePath: freshURL.lastPathComponent,
                        allocatedBytes: bytesPerGiB,
                        modificationDate: nil,
                        identity: freshIdentity
                    ),
                ])
            },
            evictProvider: { candidates, _, _, _, fileBudget, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                evictedPaths.withLock { $0 = candidates.map(\.path) }
                budgets.withLock { $0.append(fileBudget) }
                return EvictionOutcome(
                    evictedCount: 1,
                    failedCount: 0,
                    processedCount: 1,
                    processedBytes: bytesPerGiB,
                    reclaimedBytes: bytesPerGiB,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: [freshURL.path],
                    evictedIdentities: [freshURL.path: freshIdentity]
                )
            },
            suppressionProvider: { _, _ in
                suppressionCalls.withLock { $0 += 1 }
                return DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            runtimeConfigProvider: { runtimeConfig.withLock { $0 } },
            keepDownloadedProvider: { _, scope, _, trigger, _ in
                keepCalls.withLock { $0 += 1 }
                return KeepDownloadedExecution(
                    outcome: KeepDownloadedOutcome(
                        items: [],
                        scannedEntries: 0,
                        requestsAttempted: 0,
                        cancelled: false,
                        reasonCounts: [:]
                    ),
                    receipt: GuardRunReceipt(
                        startedAt: Date(),
                        trigger: trigger,
                        command: "keep-downloaded",
                        requestedAction: "keep-downloaded",
                        action: .none,
                        dryRun: false,
                        reason: "no action",
                        sourceScopeIdentifier: PrivacyIdentifier.scope(scope),
                        privacyScopePath: scope,
                        exitCode: 0,
                        status: .noAction,
                        statePersisted: true,
                        watchlistPersisted: true
                    )
                )
            },
            eventHandler: { event in
                if case .watchlistUpdated(let count) = event { watchlistCounts.withLock { $0.append(count) } }
            }
        )

        try await service.prepareForManualOperations()
        runtimeConfig.withLock { $0.eviction.batchLimit = 9 }
        await service.reloadConfig()
        await service.pause()
        await service.resume()
        await service.scanIfStale(maxAgeSeconds: 0)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(watchlistCounts.withLock { $0.last }, 1, "manual readiness must load the persisted watchlist")
        XCTAssertEqual(scanCalls.withLock { $0 }, 1, "menu refresh may scan authoritatively but must not run policy")
        XCTAssertEqual(evictionCalls.withLock { $0 }, 0)
        XCTAssertEqual(keepCalls.withLock { $0 }, 0)
        XCTAssertEqual(suppressionCalls.withLock { $0 }, 0)
        XCTAssertEqual(hints.starts, 0)

        let report = await service.trimNow()
        await service.stop()

        XCTAssertEqual(report.trigger, .appManual)
        XCTAssertEqual(scanCalls.withLock { $0 }, 3)
        XCTAssertEqual(evictionCalls.withLock { $0 }, 1)
        XCTAssertEqual(budgets.withLock { $0 }, [9], "manual-ready reload must apply current runtime limits")
        XCTAssertEqual(
            evictedPaths.withLock { $0 },
            [watchedURL.path, freshURL.path]
        )
        XCTAssertTrue(report.watchlistPersisted, "manual mutation must have a ready watcher for durable tracking")
        XCTAssertEqual(watchlistCounts.withLock { $0.last }, 2, "manual mutation must extend the loaded watchlist")
        XCTAssertEqual(suppressionCalls.withLock { $0 }, 0)
        XCTAssertEqual(keepCalls.withLock { $0 }, 0)
        XCTAssertEqual(hints.starts, 0)
    }

    func testStopAwaitsActiveManualMutationQuiescence() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let candidateURL = sandbox.scope.appendingPathComponent("active.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: candidateURL)
        let identity = try XCTUnwrap(EvictionFileIdentity.capture(path: candidateURL.path))
        let config: AppConfig = {
            var value = AppConfig(scope: .init(path: sandbox.scope.path))
            value.policy.targetLocalGiB = 1
            value.policy.trimLocalGiB = 2
            return value
        }()
        let mutationStarted = DispatchSemaphore(value: 0)
        let cancellationSeen = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        let stopReturned = OSAllocatedUnfairLock(initialState: false)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [EvictionCandidate(
                    path: candidateURL.path,
                    relativePath: candidateURL.lastPathComponent,
                    allocatedBytes: bytesPerGiB,
                    modificationDate: nil,
                    identity: identity
                )])
            },
            evictProvider: { _, _, _, _, _, _, cancellation, _ in
                mutationStarted.signal()
                while !cancellation.isCancelled { usleep(1_000) }
                cancellationSeen.signal()
                _ = releaseMutation.wait(timeout: .now() + 2)
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: true,
                    evictedPaths: []
                )
            },
            runtimeConfigProvider: { config },
            eventHandler: { _ in }
        )
        try await service.prepareForManualOperations()
        let run = Task { await service.trimNow() }
        XCTAssertEqual(mutationStarted.wait(timeout: .now() + 2), .success)
        let stop = Task {
            await service.stop()
            stopReturned.withLock { $0 = true }
        }
        XCTAssertEqual(cancellationSeen.wait(timeout: .now() + 2), .success)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(stopReturned.withLock { $0 }, "stop must not return while the mutation provider is still active")

        releaseMutation.signal()
        let report = await run.value
        await stop.value

        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(stopReturned.withLock { $0 })
    }

    func testManualReadinessProviderFailurePreventsMutation() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let initialConfig = AppConfig(scope: .init(path: sandbox.scope.path))
        let providerCalls = OSAllocatedUnfairLock(initialState: 0)
        let scanCalls = OSAllocatedUnfairLock(initialState: 0)
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                scanCalls.withLock { $0 += 1 }
                return Self.completeBundle()
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            runtimeConfigProvider: {
                let call = providerCalls.withLock { value -> Int in
                    value += 1
                    return value
                }
                guard call == 1 else { throw CocoaError(.fileReadCorruptFile) }
                return initialConfig
            },
            eventHandler: { _ in }
        )

        do {
            try await service.prepareForManualOperations()
            XCTFail("manual readiness must surface runtime provider failure")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile)
        }
        let report = await service.panicEvict()
        await service.stop()

        XCTAssertEqual(providerCalls.withLock { $0 }, 3)
        XCTAssertEqual(scanCalls.withLock { $0 }, 0)
        XCTAssertEqual(evictionCalls.withLock { $0 }, 0)
        XCTAssertEqual(report.exitCode, 74)
        XCTAssertTrue(report.reason.contains("manual readiness failed"))
    }

    func testRuntimeConfigProviderDrivesScopedPolicyWatcherAndReloadWithoutConfigFile() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let firstURL = sandbox.scope.appendingPathComponent("first.bin")
        let secondURL = sandbox.scope.appendingPathComponent("second.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: firstURL)
        try Data(repeating: 0x42, count: 4_096).write(to: secondURL)
        let firstIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: firstURL.path))
        let secondIdentity = try XCTUnwrap(EvictionFileIdentity.capture(path: secondURL.path))
        let candidates = [
            EvictionCandidate(
                path: firstURL.path,
                relativePath: firstURL.lastPathComponent,
                allocatedBytes: bytesPerGiB,
                modificationDate: nil,
                identity: firstIdentity
            ),
            EvictionCandidate(
                path: secondURL.path,
                relativePath: secondURL.lastPathComponent,
                allocatedBytes: bytesPerGiB,
                modificationDate: nil,
                identity: secondIdentity
            ),
        ]
        var initialConfig = AppConfig(scope: .init(path: sandbox.scope.path, protectedPaths: ["Protected"]))
        initialConfig.policy.targetLocalGiB = 1
        initialConfig.policy.trimLocalGiB = 2
        initialConfig.eviction.batchLimit = 7
        initialConfig.watcher.watchlistMaxEntries = 1
        let runtimeConfig = OSAllocatedUnfairLock(initialState: initialConfig)
        let runtimeLoads = OSAllocatedUnfairLock(initialState: 0)
        let matcherSnapshots = OSAllocatedUnfairLock(initialState: [String]())
        let budgets = OSAllocatedUnfairLock(initialState: [Int]())
        let finished = DispatchSemaphore(value: 0)
        let hints = EventHintSourceHarness()
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, protected, _, _ in
                let label: String
                if protected.isProtected(
                    path: sandbox.scope.appendingPathComponent("Reloaded/file.bin").path,
                    relativePath: "Reloaded/file.bin"
                ) {
                    label = "reloaded"
                } else if protected.isProtected(
                    path: sandbox.scope.appendingPathComponent("Protected/file.bin").path,
                    relativePath: "Protected/file.bin"
                ) {
                    label = "initial"
                } else {
                    label = "missing"
                }
                matcherSnapshots.withLock { $0.append(label) }
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: candidates)
            },
            evictProvider: { _, _, _, _, fileBudget, _, _, _ in
                let call = budgets.withLock { values -> Int in
                    values.append(fileBudget)
                    return values.count
                }
                guard call == 1 else {
                    return EvictionOutcome(
                        evictedCount: 0,
                        failedCount: 0,
                        reclaimedBytes: 0,
                        failureReasons: [:],
                        cancelled: false,
                        evictedPaths: []
                    )
                }
                return EvictionOutcome(
                    evictedCount: 2,
                    failedCount: 0,
                    processedCount: 2,
                    processedBytes: 2 * bytesPerGiB,
                    reclaimedBytes: 2 * bytesPerGiB,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: [firstURL.path, secondURL.path],
                    evictedIdentities: [firstURL.path: firstIdentity, secondURL.path: secondIdentity]
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            energySignalProvider: {
                EnergySchedulingSignals(lowPowerModeEnabled: nil, thermalState: nil, powerSource: nil)
            },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            runtimeConfigProvider: {
                runtimeLoads.withLock { $0 += 1 }
                return runtimeConfig.withLock { $0 }
            },
            eventHandler: { event in
                if case .runFinished = event { finished.signal() }
            }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent("config.toml").path))
        await service.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(budgets.withLock { $0 }, [7], "runtime policy must trigger and use the scoped batch limit")
        XCTAssertEqual(matcherSnapshots.withLock { $0.first }, "initial")
        XCTAssertEqual(
            try WatchlistInspectionService.loadEntries(
                storageURL: sandbox.home.appendingPathComponent("watchlist.json"),
                scopePath: sandbox.scope.path
            ).count,
            1,
            "scoped watcher retention must use its runtime maximum"
        )

        runtimeConfig.withLock {
            $0.eviction.batchLimit = 9
            $0.scope.protectedPaths = ["Reloaded"]
        }
        await service.reloadConfig()
        _ = await service.trimNow()
        await service.stop()

        XCTAssertEqual(runtimeLoads.withLock { $0 }, 2)
        XCTAssertEqual(budgets.withLock { $0 }, [7, 9])
        XCTAssertEqual(matcherSnapshots.withLock { $0.last }, "reloaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent("config.toml").path))
    }

    func testRuntimeConfigProviderScopeMismatchFailsClosedAtInitializationAndReload() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let otherScope = sandbox.home.deletingLastPathComponent().appendingPathComponent("OtherCloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: otherScope, withIntermediateDirectories: true)
        let canonicalOtherScope = try canonicalExistingDirectory(otherScope)
        let mismatchedConfig = AppConfig(scope: .init(path: canonicalOtherScope.path, protectedPaths: ["WrongScope"]))

        XCTAssertThrowsError(
            try GuardService(
                scopePath: sandbox.scope.path,
                appHomeURL: sandbox.home,
                runtimeConfigProvider: { mismatchedConfig },
                eventHandler: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? GuardRuntimeConfigurationError,
                .scopeMismatch(expected: sandbox.scope.path, configured: canonicalOtherScope.path)
            )
        }

        var initialConfig = AppConfig(scope: .init(path: sandbox.scope.path, protectedPaths: ["Protected"]))
        initialConfig.policy.targetLocalGiB = 1
        initialConfig.policy.trimLocalGiB = 2
        initialConfig.eviction.batchLimit = 7
        let runtimeConfig = OSAllocatedUnfairLock(initialState: initialConfig)
        let observedBudgets = OSAllocatedUnfairLock(initialState: [Int]())
        let observedProtection = OSAllocatedUnfairLock(initialState: [Bool]())
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, protected, _, _ in
                observedProtection.withLock {
                    $0.append(protected.isProtected(
                        path: sandbox.scope.appendingPathComponent("Protected/file.bin").path,
                        relativePath: "Protected/file.bin"
                    ))
                }
                var stats = DriveStats()
                stats.materializedBytes = 2 * bytesPerGiB
                stats.freeBytes = 100 * bytesPerGiB
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(
                    stats: stats,
                    candidates: [EvictionCandidate(
                        path: sandbox.scope.appendingPathComponent("candidate.bin").path,
                        relativePath: "candidate.bin",
                        allocatedBytes: bytesPerGiB,
                        modificationDate: nil
                    )]
                )
            },
            evictProvider: { _, _, _, _, fileBudget, _, _, _ in
                observedBudgets.withLock { $0.append(fileBudget) }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            runtimeConfigProvider: { runtimeConfig.withLock { $0 } },
            eventHandler: { event in
                if case .error(let message) = event { errors.withLock { $0.append(message) } }
            }
        )

        try await service.prepareForManualOperations()
        runtimeConfig.withLock {
            $0.scope.path = canonicalOtherScope.path
            $0.scope.protectedPaths = ["WrongScope"]
            $0.eviction.batchLimit = 99
        }
        await service.reloadConfig()
        _ = await service.trimNow()

        XCTAssertEqual(observedBudgets.withLock { $0 }, [7], "a mismatched reload must retain the last valid limits")
        XCTAssertEqual(observedProtection.withLock { $0 }, [true], "a mismatched reload must retain the last valid protections")
        XCTAssertEqual(errors.withLock { $0.count }, 1)
        XCTAssertTrue(errors.withLock { $0[0].contains("does not match service scope") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent("config.toml").path))
    }

    func testSharedAutomaticPanicLockAllowsOneOwnerAndPersistsOtherScopeDeferral() async throws {
        let first = try makeSandbox(createConfig: false)
        let second = try makeSandbox(createConfig: false)
        let sharedLockPath = first.home.deletingLastPathComponent().appendingPathComponent("automatic-panic.lock").path
        let firstCandidate = EvictionCandidate(
            path: first.scope.appendingPathComponent("panic.bin").path,
            relativePath: "panic.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil
        )
        let secondCandidate = EvictionCandidate(
            path: second.scope.appendingPathComponent("panic.bin").path,
            relativePath: "panic.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil
        )
        let firstConfig: AppConfig = {
            var config = AppConfig(scope: .init(path: first.scope.path))
            config.eviction.panicLimit = 3
            return config
        }()
        let secondConfig: AppConfig = {
            var config = AppConfig(scope: .init(path: second.scope.path))
            config.eviction.panicLimit = 4
            return config
        }()
        let firstEvictionStarted = DispatchSemaphore(value: 0)
        let releaseFirstEviction = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondDeferred = DispatchSemaphore(value: 0)
        let firstEvictions = OSAllocatedUnfairLock(initialState: 0)
        let secondEvictions = OSAllocatedUnfairLock(initialState: 0)
        let firstHints = EventHintSourceHarness()
        let secondHints = EventHintSourceHarness()
        let panicBundle: @Sendable (EvictionCandidate) -> ScanBundle = { candidate in
            var stats = DriveStats()
            stats.materializedBytes = 3 * bytesPerGiB
            stats.freeBytes = 0
            stats.scanComplete = true
            stats.freeSpaceAvailable = true
            stats.completedAt = Date()
            return ScanBundle(stats: stats, candidates: [candidate])
        }
        let firstService = try GuardService(
            scopePath: first.scope.path,
            appHomeURL: first.home,
            scanProvider: { _, _, _, _ in panicBundle(firstCandidate) },
            evictProvider: { _, _, _, _, _, _, _, _ in
                firstEvictions.withLock { $0 += 1 }
                firstEvictionStarted.signal()
                _ = releaseFirstEviction.wait(timeout: .now() + 2)
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: first.scope.path, harness: firstHints),
            runtimeConfigProvider: { firstConfig },
            automaticPanicLockPath: sharedLockPath,
            eventHandler: { event in
                if case .runFinished = event { firstFinished.signal() }
            }
        )
        let secondService = try GuardService(
            scopePath: second.scope.path,
            appHomeURL: second.home,
            scanProvider: { _, _, _, _ in panicBundle(secondCandidate) },
            evictProvider: { _, _, _, _, _, _, _, _ in
                secondEvictions.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: second.scope.path, harness: secondHints),
            runtimeConfigProvider: { secondConfig },
            automaticPanicLockPath: sharedLockPath,
            eventHandler: { event in
                if case .runFinished(let report) = event,
                   report.reason == "automatic panic deferred: another scope owns automatic panic remediation" {
                    secondDeferred.signal()
                }
            }
        )

        await firstService.start()
        XCTAssertEqual(firstEvictionStarted.wait(timeout: .now() + 2), .success)
        await secondService.start()
        XCTAssertEqual(secondDeferred.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(firstEvictions.withLock { $0 }, 1)
        XCTAssertEqual(secondEvictions.withLock { $0 }, 0, "a contending scope must never overlap the panic owner")
        let deferredReceipt = try XCTUnwrap(
            RunHistoryStore(url: second.home.appendingPathComponent("history.json")).load().last
        )
        XCTAssertEqual(deferredReceipt.trigger, .scheduled)
        XCTAssertEqual(deferredReceipt.status, .noAction)
        XCTAssertEqual(deferredReceipt.reason, "automatic panic deferred: another scope owns automatic panic remediation")

        releaseFirstEviction.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        await firstService.stop()
        await secondService.stop()
    }

    func testAutomaticPanicLockErrorFailsClosedAndPersistsFailure() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let invalidLock = sandbox.home.appendingPathComponent("lock-is-a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidLock, withIntermediateDirectories: true)
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let failed = DispatchSemaphore(value: 0)
        let hints = EventHintSourceHarness()
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                var stats = DriveStats()
                stats.materializedBytes = 3 * bytesPerGiB
                stats.freeBytes = 0
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(
                    stats: stats,
                    candidates: [EvictionCandidate(
                        path: sandbox.scope.appendingPathComponent("panic.bin").path,
                        relativePath: "panic.bin",
                        allocatedBytes: bytesPerGiB,
                        modificationDate: nil
                    )]
                )
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            suppressionProvider: { _, _ in
                DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
            },
            evictionNotification: { _, _ in },
            eventHintMonitorFactory: Self.eventMonitorFactory(scopePath: sandbox.scope.path, harness: hints),
            runtimeConfigProvider: { AppConfig(scope: .init(path: sandbox.scope.path)) },
            automaticPanicLockPath: invalidLock.path,
            eventHandler: { event in
                if case .runFinished(let report) = event,
                   report.reason == "automatic panic disabled: shared lock unavailable" {
                    failed.signal()
                }
            }
        )

        await service.start()
        XCTAssertEqual(failed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(evictionCalls.withLock { $0 }, 0)
        let receipt = try XCTUnwrap(
            RunHistoryStore(url: sandbox.home.appendingPathComponent("history.json")).load().last
        )
        XCTAssertEqual(receipt.trigger, .scheduled)
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.exitCode, 74)
        XCTAssertEqual(receipt.reason, "automatic panic disabled: shared lock unavailable")
        await service.stop()
    }

    func testManualPanicBypassesSharedAutomaticPanicLock() async throws {
        let sandbox = try makeSandbox(createConfig: false)
        let sharedLockPath = sandbox.home.deletingLastPathComponent().appendingPathComponent("automatic-panic.lock").path
        let heldLock = try AdvisoryFileLock(path: sharedLockPath)
        let candidate = EvictionCandidate(
            path: sandbox.scope.appendingPathComponent("manual.bin").path,
            relativePath: "manual.bin",
            allocatedBytes: bytesPerGiB,
            modificationDate: nil
        )
        let evictionCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = try GuardService(
            scopePath: sandbox.scope.path,
            appHomeURL: sandbox.home,
            scanProvider: { _, _, _, _ in
                var stats = DriveStats()
                stats.materializedBytes = bytesPerGiB
                stats.freeBytes = 0
                stats.scanComplete = true
                stats.freeSpaceAvailable = true
                stats.completedAt = Date()
                return ScanBundle(stats: stats, candidates: [candidate])
            },
            evictProvider: { _, _, _, _, _, _, _, _ in
                evictionCalls.withLock { $0 += 1 }
                return EvictionOutcome(
                    evictedCount: 0,
                    failedCount: 0,
                    reclaimedBytes: 0,
                    failureReasons: [:],
                    cancelled: false,
                    evictedPaths: []
                )
            },
            evictionNotification: { _, _ in },
            runtimeConfigProvider: { AppConfig(scope: .init(path: sandbox.scope.path)) },
            automaticPanicLockPath: sharedLockPath,
            eventHandler: { _ in }
        )

        let report = await service.panicEvict()
        heldLock.unlock()

        XCTAssertEqual(evictionCalls.withLock { $0 }, 1)
        XCTAssertEqual(report.trigger, .appManual)
        XCTAssertEqual(report.reason, "panic eviction")
        XCTAssertFalse(report.reason.contains("deferred"))
    }

    nonisolated private static func completeBundle() -> ScanBundle {
        var stats = DriveStats()
        stats.freeBytes = 100 * bytesPerGiB
        stats.scanComplete = true
        stats.freeSpaceAvailable = true
        stats.completedAt = Date()
        return ScanBundle(stats: stats, candidates: [])
    }

    nonisolated private static func eventMonitorFactory(
        scopePath: String,
        harness: EventHintSourceHarness
    ) -> GuardEventHintMonitorFactory {
        { handler in
            try EventScanHintMonitor(
                scopePath: scopePath,
                maxPendingTargets: 8,
                debounceSeconds: 0.01,
                source: harness.source,
                handler: handler
            )
        }
    }

    private func makeSandbox(createConfig: Bool = true) throws -> (home: URL, scope: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-service-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let scope = root.appendingPathComponent("CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let canonicalHome = try canonicalExistingDirectory(home)
        let canonicalScope = try canonicalExistingDirectory(scope)
        if createConfig {
            try ConfigStore(configURL: canonicalHome.appendingPathComponent("config.toml")).save(
                AppConfig(scope: .init(path: canonicalScope.path))
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (canonicalHome, canonicalScope)
    }

    private func canonicalExistingDirectory(_ url: URL) throws -> URL {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard url.path.withCString({ realpath($0, &resolved) }) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

final class StatusBarPresentationTests: XCTestCase {
    @MainActor
    func testStatusPopoverHasUsableIntrinsicHeight() {
        let view = StatusBarView(viewModel: GuardViewModel())
            .environment(AppConfigModel())
        let host = NSHostingView(rootView: view)

        XCTAssertGreaterThanOrEqual(host.fittingSize.width, 320)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 280)
    }

    func testStatusAccessibilityNamesIncompleteScanAndUnavailableFreeSpace() {
        var status = GuardStatus()
        status.hasStats = true
        status.scanComplete = false

        XCTAssertEqual(
            StatusBarAccessibility.statusValue(
                status: status,
                title: "Scan incomplete",
                freeSpace: "Free space unavailable"
            ),
            "Scan incomplete, Free space unavailable"
        )
    }

    func testStatusAccessibilityIncludesErrorWithoutDependingOnColor() {
        var status = GuardStatus()
        status.lastError = "Configuration is invalid"

        XCTAssertEqual(
            StatusBarAccessibility.statusValue(status: status, title: "Error", freeSpace: ""),
            "Error, Error: Configuration is invalid"
        )
    }

    func testProgressAccessibilityReportsAllTerminalBuckets() {
        let progress = EvictionProgress(
            phase: .evicting,
            candidateCount: 10,
            evictedCount: 4,
            failedCount: 2,
            pendingCount: 1,
            reclaimedBytes: 4096
        )

        XCTAssertEqual(
            StatusBarAccessibility.progressValue(progress, formatBytes: { "\($0) bytes" }),
            "7 of 10 files processed, 4096 bytes reclaimed, 1 awaiting verification, 2 failed"
        )
    }

    func testBusyPackageAssistanceExposesBoundedProcessNamesAndRetryInstruction() {
        XCTAssertEqual(
            StatusBarAccessibility.busyPackageAssistance(
                processDisplayNames: ["Preview", "Finder", "Pages", "Numbers", "Keynote", "Ignored"]
            ),
            "Close Preview, Finder, Pages, Numbers, Keynote and retry the package"
        )
    }

    func testAccessibilitySizesUseWiderVerticalLayout() {
        XCTAssertFalse(StatusBarLayout.usesVerticalActions(for: .large))
        XCTAssertEqual(StatusBarLayout.minimumWidth(for: .large), 320)
        XCTAssertTrue(StatusBarLayout.usesVerticalActions(for: .accessibility1))
        XCTAssertFalse(StatusBarLayout.usesVerticalRows(for: .large))
        XCTAssertTrue(StatusBarLayout.usesVerticalRows(for: .accessibility1))
        XCTAssertEqual(StatusBarLayout.minimumWidth(for: .accessibility1), 400)
        XCTAssertEqual(StatusBarLayout.minimumHeight(for: .large), 280)
        XCTAssertEqual(StatusBarLayout.minimumHeight(for: .accessibility1), 420)
        XCTAssertGreaterThan(
            StatusBarLayout.idealWidth(for: .accessibility1),
            StatusBarLayout.idealWidth(for: .large)
        )
    }

    func testCriticalFreeSpaceIsExplicitTextAndAccessibilityState() {
        XCTAssertEqual(
            StatusBarAccessibility.criticalFreeSpaceValue(
                hasStats: true,
                freeSpaceAvailable: true,
                freeBytes: 10,
                panicFreeBytes: 25,
                formatBytes: { "\($0) GiB" }
            ),
            "Critical: 10 GiB free, below the 25 GiB panic threshold"
        )
        XCTAssertNil(
            StatusBarAccessibility.criticalFreeSpaceValue(
                hasStats: true,
                freeSpaceAvailable: true,
                freeBytes: 25,
                panicFreeBytes: 25,
                formatBytes: { "\($0) GiB" }
            )
        )
    }

    func testSuppressionToggleNamesTheEnabledAction() {
        XCTAssertEqual(SettingsPresentation.spotlightSuppressionLabel, "Suppress Spotlight indexing")
    }

    func testSettingsRowsStackAtAccessibilitySizes() {
        XCTAssertFalse(SettingsLayout.usesVerticalRows(for: .large))
        XCTAssertTrue(SettingsLayout.usesVerticalRows(for: .accessibility1))
    }

    func testDiagnosticModeDisablesSystemIntegrationsOnlyForExactOptOut() {
        XCTAssertFalse(SystemIntegrationPolicy.isEnabled(environment: [SystemIntegrationPolicy.disableEnvironmentKey: "1"]))
        XCTAssertTrue(SystemIntegrationPolicy.isEnabled(environment: [SystemIntegrationPolicy.disableEnvironmentKey: "true"]))
        XCTAssertTrue(SystemIntegrationPolicy.isEnabled(environment: [:]))
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor
final class AppConfigModelTests: XCTestCase {
    func testScopeSelectorPreservesAllSixtyFourManagedScopes() throws {
        let temporary = FileManager.default.temporaryDirectory
        let physical = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true)
            : temporary
        let root = physical.appendingPathComponent("icloud-guard-64-scopes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scopes = try (0..<64).map { index -> ManagedScopeConfig in
            let path = root.appendingPathComponent("Scope-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return ManagedScopeConfig(id: "scope-\(index)", name: "Scope \(index)", scope: .init(path: path.path))
        }
        let store = ConfigStore(configURL: root.appendingPathComponent("config.toml"))
        try store.save(AppConfig(scopes: scopes))
        let model = AppConfigModel(store: store)

        XCTAssertEqual(model.scopeSelections.count, 64)
        XCTAssertEqual(model.scopeSelections.first?.id, "scope-0")
        XCTAssertEqual(model.scopeSelections.last?.id, "scope-63")
        XCTAssertTrue(model.selectScope(id: "scope-63"))
        XCTAssertEqual(model.selectedScopeID, "scope-63")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testManagedScopeEditsDisplayAndPersistOnlySelectedScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-config-scopes-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.toml"))
        let physicalRoot = root.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + root.path, isDirectory: true)
            : root
        try FileManager.default.createDirectory(at: physicalRoot.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: physicalRoot.appendingPathComponent("Home"), withIntermediateDirectories: true)
        let first = ManagedScopeConfig(id: "work", name: "Work", scope: .init(path: physicalRoot.appendingPathComponent("Work").path))
        let second = ManagedScopeConfig(id: "home", name: "Home", scope: .init(path: physicalRoot.appendingPathComponent("Home").path))
        try store.save(AppConfig(scopes: [first, second]))
        let model = AppConfigModel(store: store)

        XCTAssertTrue(model.selectScope(id: "home"))
        XCTAssertEqual(model.selectedScopeName, "Home")
        model.updatePolicy(.init(targetLocalGiB: 19, trimLocalGiB: 25))
        model.updateWatcher(.init(backoffMaxSeconds: 77))
        XCTAssertTrue(model.flushPending())

        let loaded = try store.loadValidated()
        XCTAssertEqual(loaded.scopes?[0].policy, first.policy)
        XCTAssertEqual(loaded.scopes?[1].policy.targetLocalGiB, 19)
        XCTAssertEqual(loaded.scopes?[1].watcher.backoffMaxSeconds, 77)
        XCTAssertEqual(loaded.policy, AppConfig.PolicyConfig(), "legacy top-level policy must remain untouched")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testMalformedConfigurationFailsClosedUntilExplicitValidReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-config-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        let malformed = "[suppression]\nspotlight = maybe\n"
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let store = ConfigStore(configURL: url) { data, destination in
            writes.withLock { $0 += 1 }
            try data.write(to: destination, options: .atomic)
        }
        let model = AppConfigModel(store: store)

        XCTAssertFalse(model.isConfigurationValid)
        XCTAssertNotNil(model.lastError)
        let presented = model.config
        model.updateSuppression(.init(spotlight: false))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.config, presented)
        XCTAssertEqual(writes.withLock { $0 }, 0)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), malformed)

        let recoveryURL = root.appendingPathComponent("valid-recovery.toml")
        try ConfigStore(configURL: recoveryURL).save(AppConfig())
        try Data(contentsOf: recoveryURL).write(to: url, options: .atomic)
        model.reload()
        XCTAssertTrue(model.isConfigurationValid)
        XCTAssertNil(model.lastError)
        model.updateSuppression(.init(spotlight: false))
        XCTAssertTrue(model.flushPending())
        XCTAssertEqual(writes.withLock { $0 }, 1)
        XCTAssertFalse(try store.loadValidated().suppression.spotlight)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testRapidChangesFlushOnlyLatestSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-config-model-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigStore(configURL: url)
        let model = AppConfigModel(store: store)
        var persisted = 0
        model.onChange = { persisted += 1 }

        model.updateEviction(.init(batchLimit: 100, panicLimit: 500))
        model.updateEviction(.init(batchLimit: 200, panicLimit: 600))
        model.updateEviction(.init(batchLimit: 300, panicLimit: 700))
        XCTAssertTrue(model.flushPending())

        let loaded = try store.loadValidated()
        XCTAssertEqual(loaded.eviction, .init(batchLimit: 300, panicLimit: 700))
        XCTAssertEqual(persisted, 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testWriteFailureIsVisibleAndDoesNotFireChange() {
        enum InjectedFailure: Error { case flush }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-config-failure-\(UUID().uuidString)/config.toml")
        let store = ConfigStore(configURL: url) { _, _ in throw InjectedFailure.flush }
        let model = AppConfigModel(store: store)
        var persisted = 0
        model.onChange = { persisted += 1 }

        model.updateSuppression(.init(spotlight: false))

        XCTAssertFalse(model.flushPending())
        XCTAssertEqual(persisted, 0)
        XCTAssertNotNil(model.lastError)
    }

    func testFailedAutomaticSaveRemainsDirtyAndFlushRetriesLatestSnapshot() async throws {
        enum InjectedFailure: Error { case firstWrite }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-config-retry-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("config.toml")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let store = ConfigStore(configURL: url) { data, destination in
            let attempt = attempts.withLock { value in
                value += 1
                return value
            }
            if attempt == 1 { throw InjectedFailure.firstWrite }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }
        let model = AppConfigModel(store: store)
        model.updateEviction(.init(batchLimit: 321, panicLimit: 654))

        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        XCTAssertNotNil(model.lastError)

        XCTAssertTrue(model.flushPending())
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try store.loadValidated().eviction, .init(batchLimit: 321, panicLimit: 654))
        XCTAssertTrue(model.flushPending(), "termination-style second flush has no dirty work")
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testReloadFlushesPendingEditBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-config-reload-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.toml"))
        let model = AppConfigModel(store: store)
        model.updateWatcher(.init(backoffMaxSeconds: 42, pollutionCheckIntervalSeconds: 120, watchlistPollSeconds: 11))

        model.reload()

        XCTAssertEqual(model.config.watcher.backoffMaxSeconds, 42)
        XCTAssertEqual(try store.loadValidated().watcher.watchlistPollSeconds, 11)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }
}

@MainActor
final class GuardViewModelLifecycleTests: XCTestCase {
    func testEveryEnabledManagedScopeStartsAutomatically() async throws {
        let sandbox = try makeLifecycleSandbox()
        let scopes = [
            ManagedScopeConfig(id: "first", name: "First", scope: .init(path: sandbox.root.appendingPathComponent("First").path)),
            ManagedScopeConfig(id: "second", name: "Second", scope: .init(path: sandbox.root.appendingPathComponent("Second").path)),
        ]
        for scope in scopes { try FileManager.default.createDirectory(atPath: scope.scope.path, withIntermediateDirectories: true) }
        let config = AppConfig(watcher: .init(pollutionCheckIntervalSeconds: 3600), scopes: scopes)
        let store = ConfigStore(configURL: sandbox.configURL); try store.save(config)
        let scans = OSAllocatedUnfairLock(initialState: [String: Int]())
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: { context, provider, panicLock, eventHandler in
                try GuardService(
                    scopePath: context.config.scope.path,
                    appHomeURL: context.paths.root,
                    scanProvider: { _, _, _, _ in
                        scans.withLock { $0[context.config.id, default: 0] += 1 }
                        return Self.completeBundle()
                    },
                    suppressionProvider: { _, _ in DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled) },
                    eventHintMonitorFactory: Self.eventMonitorFactory(
                        scopePath: context.config.scope.path,
                        harness: EventHintSourceHarness()
                    ),
                    runtimeConfigProvider: provider,
                    automaticPanicLockPath: panicLock,
                    eventHandler: eventHandler
                )
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )

        viewModel.startGuardServices(config: config, selectedScopeID: "first")
        await viewModel.waitForServiceReconciliation()
        for _ in 0..<2_000 where scans.withLock({ $0.count }) < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(Set(scans.withLock { $0.keys }), ["first", "second"])
        await viewModel.stopGuardServiceAndWait()
    }

    func testDisabledUpdaterNeverCreatesNetworkActions() async throws {
        let sandbox = try makeLifecycleSandbox()
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(AppConfig(scope: .init(path: sandbox.scope.path)))
        let factories = OSAllocatedUnfairLock(initialState: 0)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw NSError(domain: "unused", code: 1) },
            updaterFactory: { _ in
                factories.withLock { $0 += 1 }
                throw NSError(domain: "unexpected", code: 1)
            }
        )

        viewModel.checkForUpdates()
        await waitForUpdates(viewModel)
        XCTAssertEqual(factories.withLock { $0 }, 0)
        XCTAssertEqual(viewModel.operations.updateStatus, "Update checks are disabled in configuration.")
    }

    func testUpdaterReusesAuthenticatedCandidateForExplicitVerifiedDownload() async throws {
        let sandbox = try makeLifecycleSandbox()
        let privateKey = P256.Signing.PrivateKey()
        let updates = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .stable,
            feedURL: "https://updates.example.test/feed.json",
            keyID: "release",
            publicKeyX963Base64: privateKey.publicKey.x963Representation.base64EncodedString(),
            teamID: "ABCDEFGHIJ"
        )
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(AppConfig(scope: .init(path: sandbox.scope.path), updates: updates))
        let release = Self.updateRelease()
        let archive = sandbox.root.appendingPathComponent("verified.zip")
        let factories = OSAllocatedUnfairLock(initialState: 0)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let downloads = OSAllocatedUnfairLock(initialState: 0)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw NSError(domain: "unused", code: 1) },
            updaterFactory: { _ in
                factories.withLock { $0 += 1 }
                return GuardUpdaterActions(
                    check: {
                        checks.withLock { $0 += 1 }
                        return GuardUpdateCheck(availability: .available(release.version), source: .network)
                    },
                    download: {
                        downloads.withLock { $0 += 1 }
                        return ManualUpdateHandoff(release: release, verifiedArchiveURL: archive, instructions: "Replace the app manually.")
                    }
                )
            }
        )

        viewModel.checkForUpdates()
        await waitForUpdates(viewModel)
        XCTAssertEqual(viewModel.operations.updateCandidateVersion, release.version)
        viewModel.checkForUpdates()
        await waitForUpdates(viewModel)
        XCTAssertEqual(factories.withLock { $0 }, 1, "checks must retain the updater cache and backoff actor")
        XCTAssertEqual(checks.withLock { $0 }, 2)
        viewModel.downloadAvailableUpdate()
        await waitForUpdates(viewModel)
        XCTAssertEqual(downloads.withLock { $0 }, 1)
        XCTAssertEqual(viewModel.operations.updateHandoff?.verifiedArchiveURL, archive)
        XCTAssertEqual(viewModel.operations.updateHandoff?.instructions, "Replace the app manually.")
    }

    func testVerifiedDownloadDiscardFailurePreservesHandoffAndRetryRemovesIt() async throws {
        enum DiscardFailure: LocalizedError {
            case refused
            var errorDescription: String? { "discard refused" }
        }
        let sandbox = try makeLifecycleSandbox()
        let privateKey = P256.Signing.PrivateKey()
        let updates = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .stable,
            feedURL: "https://updates.example.test/feed.json",
            keyID: "release",
            publicKeyX963Base64: privateKey.publicKey.x963Representation.base64EncodedString(),
            teamID: "ABCDEFGHIJ"
        )
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(AppConfig(scope: .init(path: sandbox.scope.path), updates: updates))
        let release = Self.updateRelease()
        let archive = sandbox.root.appendingPathComponent("verified.zip")
        let discardAttempts = OSAllocatedUnfairLock(initialState: 0)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw NSError(domain: "unused", code: 1) },
            updaterFactory: { _ in
                GuardUpdaterActions(
                    check: { GuardUpdateCheck(availability: .available(release.version), source: .network) },
                    download: {
                        ManualUpdateHandoff(
                            release: release,
                            verifiedArchiveURL: archive,
                            instructions: "Replace the app manually."
                        )
                    },
                    discard: { _ in
                        let attempt = discardAttempts.withLock { value -> Int in
                            value += 1
                            return value
                        }
                        if attempt == 1 { throw DiscardFailure.refused }
                    }
                )
            }
        )

        viewModel.checkForUpdates()
        await waitForUpdates(viewModel)
        viewModel.downloadAvailableUpdate()
        await waitForUpdates(viewModel)
        XCTAssertEqual(viewModel.operations.updateHandoff?.verifiedArchiveURL, archive)

        viewModel.discardDownloadedUpdate()
        await waitForUpdates(viewModel)
        XCTAssertEqual(viewModel.operations.updateHandoff?.verifiedArchiveURL, archive)
        XCTAssertEqual(viewModel.operations.error, "discard refused")
        XCTAssertEqual(viewModel.operations.updateStatus, "Discard failed. The verified archive was preserved for retry.")

        viewModel.discardDownloadedUpdate()
        await waitForUpdates(viewModel)
        XCTAssertNil(viewModel.operations.updateHandoff)
        XCTAssertEqual(discardAttempts.withLock { $0 }, 2)
        XCTAssertEqual(viewModel.operations.updateStatus, "Verified download discarded.")
    }

    func testNewCheckDiscardsExistingHandoffExactlyOnceBeforeChecking() async throws {
        let sandbox = try makeLifecycleSandbox()
        let privateKey = P256.Signing.PrivateKey()
        let updates = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .stable,
            feedURL: "https://updates.example.test/feed.json",
            keyID: "release",
            publicKeyX963Base64: privateKey.publicKey.x963Representation.base64EncodedString(),
            teamID: "ABCDEFGHIJ"
        )
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(AppConfig(scope: .init(path: sandbox.scope.path), updates: updates))
        let release = Self.updateRelease()
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw NSError(domain: "unused", code: 1) },
            updaterFactory: { _ in
                GuardUpdaterActions(
                    check: {
                        events.withLock { $0.append("check") }
                        return GuardUpdateCheck(availability: .available(release.version), source: .network)
                    },
                    download: {
                        ManualUpdateHandoff(
                            release: release,
                            verifiedArchiveURL: sandbox.root.appendingPathComponent("verified.zip"),
                            instructions: "Replace manually."
                        )
                    },
                    discard: { _ in events.withLock { $0.append("discard") } }
                )
            }
        )
        viewModel.checkForUpdates(); await waitForUpdates(viewModel)
        viewModel.downloadAvailableUpdate(); await waitForUpdates(viewModel)
        viewModel.checkForUpdates(); await waitForUpdates(viewModel)

        XCTAssertNil(viewModel.operations.updateHandoff)
        XCTAssertEqual(events.withLock { $0 }, ["check", "discard", "check"])
    }

    func testConfigurationInvalidationDiscardsHandoffBeforeReplacingUpdater() async throws {
        let sandbox = try makeLifecycleSandbox()
        let privateKey = P256.Signing.PrivateKey()
        var updates = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .stable,
            feedURL: "https://updates.example.test/feed.json",
            keyID: "release",
            publicKeyX963Base64: privateKey.publicKey.x963Representation.base64EncodedString(),
            teamID: "ABCDEFGHIJ"
        )
        let store = ConfigStore(configURL: sandbox.configURL)
        var config = AppConfig(scope: .init(path: sandbox.scope.path), updates: updates)
        try store.save(config)
        let release = Self.updateRelease()
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw NSError(domain: "unused", code: 1) },
            updaterFactory: { _ in
                GuardUpdaterActions(
                    check: { GuardUpdateCheck(availability: .available(release.version), source: .network) },
                    download: {
                        ManualUpdateHandoff(
                            release: release,
                            verifiedArchiveURL: sandbox.root.appendingPathComponent("verified.zip"),
                            instructions: "Replace manually."
                        )
                    },
                    discard: { _ in events.withLock { $0.append("discard") } }
                )
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )
        viewModel.checkForUpdates(); await waitForUpdates(viewModel)
        viewModel.downloadAvailableUpdate(); await waitForUpdates(viewModel)

        updates.channel = .beta
        config.updates = updates
        try store.save(config)
        viewModel.reloadConfig(config: config, selectedScopeID: "default")
        await viewModel.waitForServiceReconciliation()

        XCTAssertNil(viewModel.operations.updateHandoff)
        XCTAssertEqual(events.withLock { $0 }, ["discard"])
        XCTAssertEqual(viewModel.operations.updateStatus, "Update configuration changed. Check for updates again.")
    }

    func testStopAwaitsBlockedDownloadCancellationCleanup() async throws {
        let sandbox = try makeLifecycleSandbox()
        let privateKey = P256.Signing.PrivateKey()
        let updates = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .stable,
            feedURL: "https://updates.example.test/feed.json",
            keyID: "release",
            publicKeyX963Base64: privateKey.publicKey.x963Representation.base64EncodedString(),
            teamID: "ABCDEFGHIJ"
        )
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(AppConfig(scope: .init(path: sandbox.scope.path), updates: updates))
        let release = Self.updateRelease()
        let downloadStarted = AsyncTestGate()
        let cancellationObserved = AsyncTestGate()
        let releaseCleanup = AsyncTestGate()
        let discards = OSAllocatedUnfairLock(initialState: 0)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw NSError(domain: "unused", code: 1) },
            updaterFactory: { _ in
                GuardUpdaterActions(
                    check: { GuardUpdateCheck(availability: .available(release.version), source: .network) },
                    download: {
                        await downloadStarted.open()
                        while !Task.isCancelled { await Task.yield() }
                        await cancellationObserved.open()
                        await releaseCleanup.wait()
                        return ManualUpdateHandoff(
                            release: release,
                            verifiedArchiveURL: sandbox.root.appendingPathComponent("late-verified.zip"),
                            instructions: "Replace manually."
                        )
                    },
                    discard: { _ in discards.withLock { $0 += 1 } }
                )
            }
        )
        viewModel.checkForUpdates(); await waitForUpdates(viewModel)
        viewModel.downloadAvailableUpdate(); await downloadStarted.wait()
        let stop = Task { await viewModel.stopGuardServiceAndWait() }
        await cancellationObserved.wait()
        XCTAssertTrue(viewModel.operations.updateLoading)
        await releaseCleanup.open()
        let stopped = await stop.value
        XCTAssertTrue(stopped)
        XCTAssertNil(viewModel.operations.updateHandoff)
        XCTAssertFalse(viewModel.operations.updateLoading)
        XCTAssertEqual(discards.withLock { $0 }, 1, "a verified handoff returned after cancellation must still be discarded")
    }

    func testStaleCancelledUpdateCheckCannotOverwriteNewerCheckOrDownload() async throws {
        enum StaleCheckFailure: LocalizedError {
            case delayedFailure
            var errorDescription: String? { "stale check failed" }
        }

        let sandbox = try makeLifecycleSandbox()
        let privateKey = P256.Signing.PrivateKey()
        let updates = AppConfig.UpdatesConfig(
            enabled: true,
            channel: .stable,
            feedURL: "https://updates.example.test/feed.json",
            keyID: "release",
            publicKeyX963Base64: privateKey.publicKey.x963Representation.base64EncodedString(),
            teamID: "ABCDEFGHIJ"
        )
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(AppConfig(scope: .init(path: sandbox.scope.path), updates: updates))
        let release = Self.updateRelease()
        let archive = sandbox.root.appendingPathComponent("verified.zip")
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let staleStarted = AsyncTestGate()
        let releaseStale = AsyncTestGate()
        let staleFinished = AsyncTestGate()
        let downloadStarted = AsyncTestGate()
        let releaseDownload = AsyncTestGate()
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw NSError(domain: "unused", code: 1) },
            updaterFactory: { _ in
                GuardUpdaterActions(
                    check: {
                        let invocation = checks.withLock { value in
                            value += 1
                            return value
                        }
                        if invocation == 1 {
                            await staleStarted.open()
                            await releaseStale.wait()
                            await staleFinished.open()
                            throw StaleCheckFailure.delayedFailure
                        }
                        return GuardUpdateCheck(availability: .available(release.version), source: .network)
                    },
                    download: {
                        await downloadStarted.open()
                        await releaseDownload.wait()
                        return ManualUpdateHandoff(
                            release: release,
                            verifiedArchiveURL: archive,
                            instructions: "Replace the app manually."
                        )
                    }
                )
            }
        )

        viewModel.checkForUpdates()
        await staleStarted.wait()
        viewModel.checkForUpdates()
        await waitForUpdates(viewModel)
        XCTAssertEqual(viewModel.operations.updateCandidateVersion, release.version)
        XCTAssertEqual(viewModel.operations.updateStatus, "Version \(release.version) is available.")
        XCTAssertNil(viewModel.operations.error)

        viewModel.downloadAvailableUpdate()
        await downloadStarted.wait()
        XCTAssertTrue(viewModel.operations.updateLoading)
        await releaseStale.open()
        await staleFinished.wait()
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertTrue(viewModel.operations.updateLoading, "the stale check must not clear the newer download's loading state")
        XCTAssertEqual(viewModel.operations.updateCandidateVersion, release.version)
        XCTAssertEqual(viewModel.operations.updateStatus, "Version \(release.version) is available.")
        XCTAssertNil(viewModel.operations.error)
        XCTAssertNil(viewModel.operations.updateHandoff)

        await releaseDownload.open()
        await waitForUpdates(viewModel)
        XCTAssertEqual(viewModel.operations.updateHandoff?.verifiedArchiveURL, archive)
        XCTAssertEqual(viewModel.operations.updateStatus, "Version \(release.version) was downloaded and verified.")
        XCTAssertNil(viewModel.operations.error)
    }

    func testManagedScopesUseDistinctRuntimeConfigurationAndSelectionIsFailClosed() async throws {
        let sandbox = try makeLifecycleSandbox()
        let firstPath = sandbox.root.appendingPathComponent("First", isDirectory: true)
        let secondPath = sandbox.root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        let first = ManagedScopeConfig(
            id: "first", name: "First", automaticEnabled: false,
            scope: .init(path: firstPath.path), policy: .init(targetLocalGiB: 11, trimLocalGiB: 12)
        )
        let second = ManagedScopeConfig(
            id: "second", name: "Second", automaticEnabled: false,
            scope: .init(path: secondPath.path), policy: .init(targetLocalGiB: 21, trimLocalGiB: 22)
        )
        let config = AppConfig(scopes: [first, second])
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(config)
        let created = OSAllocatedUnfairLock(initialState: [(String, String, Int, String?)]())
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let handlers = OSAllocatedUnfairLock(initialState: [String: @Sendable (GuardServiceEvent) -> Void]())
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: { context, provider, panicLock, eventHandler in
                let runtime = try provider()
                created.withLock { $0.append((context.config.id, context.paths.root.path, runtime.policy.targetLocalGiB, panicLock)) }
                handlers.withLock { $0[context.config.id] = eventHandler }
                return try GuardService(
                    scopePath: runtime.scope.path,
                    appHomeURL: context.paths.root,
                    scanProvider: { _, _, _, _ in
                        scans.withLock { $0 += 1 }
                        return Self.completeBundle()
                    },
                    suppressionProvider: { _, _ in
                        DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
                    },
                    runtimeConfigProvider: provider,
                    automaticPanicLockPath: panicLock,
                    eventHandler: eventHandler
                )
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )

        viewModel.startGuardServices(config: config, selectedScopeID: "first")
        await viewModel.waitForServiceReconciliation()
        let records = created.withLock { $0 }
        XCTAssertEqual(Set(records.map(\.0)), ["first", "second"])
        XCTAssertEqual(Set(records.map(\.1)).count, 2)
        XCTAssertTrue(records.allSatisfy { $0.1.hasPrefix(sandbox.root.path + "/state-") })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: records.map { ($0.0, $0.2) }), ["first": 11, "second": 21])
        XCTAssertTrue(records.allSatisfy { $0.3?.hasSuffix("automatic-panic.lock") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: records[0].1 + "/config.toml"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: records[1].1 + "/config.toml"))
        XCTAssertEqual(scans.withLock { $0 }, 0, "disabled scopes must not start automatic scans")
        viewModel.trimNow()
        for _ in 0..<1_000 where scans.withLock({ $0 }) < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(scans.withLock { $0 }, 1, "disabled scopes must still be ready for selected manual actions")

        let firstStats: DriveStats = { var value = DriveStats(); value.materializedBytes = 111; value.scanComplete = true; return value }()
        let secondStats: DriveStats = { var value = DriveStats(); value.materializedBytes = 222; value.scanComplete = true; return value }()
        handlers.withLock { $0["second"]?(.statsUpdated(secondStats)); $0["first"]?(.statsUpdated(firstStats)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.status.materializedBytes, 111)
        XCTAssertTrue(viewModel.selectScope(id: "second"))
        XCTAssertEqual(viewModel.status.materializedBytes, 222)

        XCTAssertFalse(viewModel.selectScope(id: "missing"))
        viewModel.trimNow()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(scans.withLock { $0 }, 1, "an invalid selection must leave no service target")

        XCTAssertTrue(viewModel.selectScope(id: "first"))
        viewModel.startGuardServices(config: config, selectedScopeID: "missing")
        await viewModel.waitForServiceReconciliation()
        XCTAssertNil(viewModel.selectedScopeID)
        XCTAssertEqual(viewModel.status.lastError, MultiScopeError.unknownScope("missing").localizedDescription)
        viewModel.trimNow()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(scans.withLock { $0 }, 1, "an invalid start selector must retain background services without a manual target")
        await viewModel.stopGuardServiceAndWait()
    }

    func testNotificationActionTargetsItsScopeWhileAnotherIsSelectedAndRejectsRemovedScope() async throws {
        let sandbox = try makeLifecycleSandbox()
        let firstPath = sandbox.root.appendingPathComponent("First", isDirectory: true)
        let secondPath = sandbox.root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        let first = ManagedScopeConfig(
            id: "first", name: "First", automaticEnabled: false, scope: .init(path: firstPath.path)
        )
        let second = ManagedScopeConfig(
            id: "second", name: "Second", automaticEnabled: false, scope: .init(path: secondPath.path)
        )
        var config = AppConfig(scopes: [first, second])
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(config)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: { context, provider, panicLock, eventHandler in
                try GuardService(
                    scopePath: context.config.scope.path,
                    appHomeURL: context.paths.root,
                    suppressionProvider: { _, _ in
                        DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
                    },
                    runtimeConfigProvider: provider,
                    automaticPanicLockPath: panicLock,
                    eventHandler: eventHandler
                )
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )

        viewModel.startGuardServices(config: config, selectedScopeID: "second")
        await viewModel.waitForServiceReconciliation()
        NotificationCenter.default.post(
            name: .icloudGuardPause,
            object: nil,
            userInfo: [
                GuardNotificationProvenance.scopeIDKey: "first",
                GuardNotificationProvenance.scopeGenerationKey: "1",
            ]
        )
        XCTAssertTrue(viewModel.selectScope(id: "first"))
        for _ in 0..<1_000 where !viewModel.status.isPaused {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(viewModel.status.isPaused, "a notification for First must not be routed through the selected Second service")
        XCTAssertTrue(viewModel.selectScope(id: "second"))
        XCTAssertFalse(viewModel.status.isPaused)

        config.scopes = [second]
        try store.save(config)
        viewModel.reloadConfig(config: config, selectedScopeID: "second")
        await viewModel.waitForServiceReconciliation()
        NotificationCenter.default.post(
            name: .icloudGuardPause,
            object: nil,
            userInfo: [
                GuardNotificationProvenance.scopeIDKey: "first",
                GuardNotificationProvenance.scopeGenerationKey: "1",
            ]
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.selectedScopeID, "second")
        XCTAssertFalse(viewModel.status.isPaused, "an action for a removed service generation must be rejected")
        await viewModel.stopGuardServiceAndWait()
    }

    func testIPCMutationKeepsCapturedScopeReceiptWhenSelectionChangesDuringScan() async throws {
        let sandbox = try makeLifecycleSandbox()
        let firstPath = sandbox.root.appendingPathComponent("First", isDirectory: true)
        let secondPath = sandbox.root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        let first = ManagedScopeConfig(
            id: "first", name: "First", automaticEnabled: false, scope: .init(path: firstPath.path)
        )
        let second = ManagedScopeConfig(
            id: "second", name: "Second", automaticEnabled: false, scope: .init(path: secondPath.path)
        )
        let config = AppConfig(scopes: [first, second])
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(config)
        let firstScanStarted = OSAllocatedUnfairLock(initialState: false)
        let releaseFirstScan = DispatchSemaphore(value: 0)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: { context, provider, panicLock, eventHandler in
                try GuardService(
                    scopePath: context.config.scope.path,
                    appHomeURL: context.paths.root,
                    scanProvider: { _, _, _, _ in
                        if context.config.id == "first" {
                            firstScanStarted.withLock { $0 = true }
                            releaseFirstScan.wait()
                        }
                        return Self.completeBundle()
                    },
                    suppressionProvider: { _, _ in
                        DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
                    },
                    runtimeConfigProvider: provider,
                    automaticPanicLockPath: panicLock,
                    eventHandler: eventHandler
                )
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )

        viewModel.startGuardServices(config: config, selectedScopeID: "first")
        await viewModel.waitForServiceReconciliation()
        let execution = Task {
            await viewModel.executeIPCCommand(
                .run,
                dryRun: true,
                cancellation: EvictionCancellation(),
                progress: { _ in }
            )
        }
        for _ in 0..<2_000 where !firstScanStarted.withLock({ $0 }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(firstScanStarted.withLock { $0 })
        XCTAssertTrue(viewModel.selectScope(id: "second"))
        releaseFirstScan.signal()
        let result = await execution.value

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.receipt?.sourceScopeIdentifier, PrivacyIdentifier.scope(firstPath.path))
        XCTAssertNotNil(result.runID)
        let firstHistory = RunHistoryStore(
            url: sandbox.root.appendingPathComponent("state-first/history.json")
        )
        XCTAssertEqual(try firstHistory.receipt(id: result.runID ?? "")?.id, result.runID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sandbox.root.appendingPathComponent("state-second/history.json").path
        ))
        await viewModel.stopGuardServiceAndWait()
    }

    func testSelectedScopeRoutesDoctorOperationsAndSupportBundleInputs() async throws {
        let sandbox = try makeLifecycleSandbox()
        let firstPath = sandbox.root.appendingPathComponent("First", isDirectory: true)
        let secondPath = sandbox.root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        let first = ManagedScopeConfig(
            id: "first", name: "First", automaticEnabled: false,
            scope: .init(path: firstPath.path), policy: .init(targetLocalGiB: 11)
        )
        let second = ManagedScopeConfig(
            id: "second", name: "Second", automaticEnabled: false,
            scope: .init(path: secondPath.path), policy: .init(targetLocalGiB: 22)
        )
        let config = AppConfig(scopes: [first, second])
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(config)
        let operationsInputs = OSAllocatedUnfairLock(initialState: [(String, Int)]())
        let supportInputs = OSAllocatedUnfairLock(initialState: [(String, Int)]())
        let output = sandbox.root.appendingPathComponent("support.zip")
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: { context, provider, panicLock, eventHandler in
                try GuardService(
                    scopePath: context.config.scope.path,
                    appHomeURL: context.paths.root,
                    suppressionProvider: { _, _ in
                        DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
                    },
                    runtimeConfigProvider: provider,
                    automaticPanicLockPath: panicLock,
                    eventHandler: eventHandler
                )
            },
            operationsLoader: { paths, _, runtimeConfig, _ in
                operationsInputs.withLock { $0.append((paths.root.path, runtimeConfig.policy.targetLocalGiB)) }
                return Self.operationsSnapshot(scopePath: runtimeConfig.scope.path, revealPaths: false)
            },
            supportBundleCreator: { destination, runtimeConfig, paths in
                supportInputs.withLock { $0.append((paths.root.path, runtimeConfig.policy.targetLocalGiB)) }
                return SupportBundleResult(outputPath: destination.path, manifestSHA256: String(repeating: "a", count: 64), fileCount: 1)
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )
        viewModel.startGuardServices(config: config, selectedScopeID: "second")
        await viewModel.waitForServiceReconciliation()

        viewModel.refreshOperations()
        for _ in 0..<1_000 where viewModel.operations.loading {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        viewModel.createSupportBundle(at: output)
        for _ in 0..<1_000 where viewModel.operations.lastSupportBundlePath == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let expectedRoot = sandbox.root.appendingPathComponent("state-second").path
        XCTAssertEqual(operationsInputs.withLock { $0.last?.0 }, expectedRoot)
        XCTAssertEqual(operationsInputs.withLock { $0.last?.1 }, 22)
        XCTAssertEqual(supportInputs.withLock { $0.last?.0 }, expectedRoot)
        XCTAssertEqual(supportInputs.withLock { $0.last?.1 }, 22)
        XCTAssertEqual(viewModel.operations.lastSupportBundlePath, output.path)
        await viewModel.stopGuardServiceAndWait()
    }

    func testManagedScopeReloadRecreatesChangedDisabledServiceAndRemovesMissingScope() async throws {
        let sandbox = try makeLifecycleSandbox()
        let physicalRoot = sandbox.root
        try FileManager.default.createDirectory(at: physicalRoot.appendingPathComponent("First"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: physicalRoot.appendingPathComponent("Second"), withIntermediateDirectories: true)
        let first = ManagedScopeConfig(id: "first", name: "First", automaticEnabled: true, scope: .init(path: physicalRoot.appendingPathComponent("First").path))
        let second = ManagedScopeConfig(id: "second", name: "Second", automaticEnabled: false, scope: .init(path: physicalRoot.appendingPathComponent("Second").path))
        let store = ConfigStore(configURL: sandbox.configURL)
        let calls = OSAllocatedUnfairLock(initialState: [String: Int]())
        let handlers = OSAllocatedUnfairLock(initialState: [String: [@Sendable (GuardServiceEvent) -> Void]]())
        let factory: ManagedGuardServiceFactory = { context, provider, panicLock, eventHandler in
            calls.withLock { $0[context.config.id, default: 0] += 1 }
            handlers.withLock { $0[context.config.id, default: []].append(eventHandler) }
            return try GuardService(
                scopePath: context.config.scope.path,
                appHomeURL: context.paths.root,
                suppressionProvider: { _, _ in DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled) },
                runtimeConfigProvider: provider,
                automaticPanicLockPath: panicLock,
                eventHandler: eventHandler
            )
        }
        var config = AppConfig(scopes: [first, second]); try store.save(config)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: factory,
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )
        viewModel.startGuardServices(config: config, selectedScopeID: "first")
        await viewModel.waitForServiceReconciliation()
        var changed = first; changed.automaticEnabled = false; changed.policy.targetLocalGiB = 37
        config.scopes = [changed]; try store.save(config)
        viewModel.reloadConfig(config: config, selectedScopeID: "first")
        await viewModel.waitForServiceReconciliation()

        XCTAssertEqual(calls.withLock { $0["first"] }, 2, "an enabled service becoming disabled must be rebuilt with current runtime config")
        XCTAssertEqual(viewModel.scopeSelections.map(\.id), ["first"])
        let firstHandlers = handlers.withLock { $0["first"] ?? [] }
        XCTAssertEqual(firstHandlers.count, 2)
        var stale = DriveStats(); stale.materializedBytes = 999; stale.scanComplete = true
        var current = DriveStats(); current.materializedBytes = 123; current.scanComplete = true
        firstHandlers[0](.statsUpdated(stale))
        firstHandlers[1](.statsUpdated(current))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.status.materializedBytes, 123, "events from a replaced service generation must be ignored")
        await viewModel.stopGuardServiceAndWait()
    }

    func testReloadStorageBindingFailureStopsExistingServiceAndFailsClosed() async throws {
        enum BindingFailure: LocalizedError {
            case mismatch
            var errorDescription: String? { "scope storage binding mismatch" }
        }
        let sandbox = try makeLifecycleSandbox()
        let scopePath = sandbox.root.appendingPathComponent("First", isDirectory: true)
        try FileManager.default.createDirectory(at: scopePath, withIntermediateDirectories: true)
        let scope = ManagedScopeConfig(id: "first", name: "First", automaticEnabled: false, scope: .init(path: scopePath.path))
        let config = AppConfig(scopes: [scope])
        let store = ConfigStore(configURL: sandbox.configURL)
        try store.save(config)
        let ensureCalls = OSAllocatedUnfairLock(initialState: 0)
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: { context, provider, panicLock, eventHandler in
                try GuardService(
                    scopePath: context.config.scope.path,
                    appHomeURL: context.paths.root,
                    scanProvider: { _, _, _, _ in
                        scans.withLock { $0 += 1 }
                        return Self.completeBundle()
                    },
                    suppressionProvider: { _, _ in
                        DownloadSuppressionResult(ioPolicy: .disabled, spotlight: .disabled, quickLook: .disabled)
                    },
                    runtimeConfigProvider: provider,
                    automaticPanicLockPath: panicLock,
                    eventHandler: eventHandler
                )
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: { _ in
                let call = ensureCalls.withLock { value -> Int in
                    value += 1
                    return value
                }
                if call > 1 { throw BindingFailure.mismatch }
            }
        )
        viewModel.startGuardServices(config: config, selectedScopeID: "first")
        await viewModel.waitForServiceReconciliation()
        XCTAssertTrue(viewModel.isGuardServiceActive)

        viewModel.reloadConfig(config: config, selectedScopeID: "first")
        await viewModel.waitForServiceReconciliation()
        XCTAssertFalse(viewModel.isGuardServiceActive)
        XCTAssertEqual(viewModel.status.lastError, "scope storage binding mismatch")
        viewModel.trimNow()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(scans.withLock { $0 }, 0)
    }

    func testValidReloadStartsServiceAfterMalformedInitialConfiguration() async throws {
        let sandbox = try makeLifecycleSandbox()
        let malformed = "[suppression]\nspotlight = maybe\n"
        try malformed.write(to: sandbox.configURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: sandbox.configURL)
        let model = AppConfigModel(store: store)
        let factoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let activations = OSAllocatedUnfairLock(initialState: 0)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { scopePath, eventHandler in
                factoryCalls.withLock { $0 += 1 }
                return try GuardService(
                    scopePath: scopePath,
                    appHomeURL: sandbox.root,
                    scanProvider: { _, _, _, _ in Self.completeBundle() },
                    suppressionProvider: { _, _ in
                        DownloadSuppressionResult(ioPolicy: .succeeded, spotlight: .succeeded, quickLook: .disabled)
                    },
                    evictionNotification: { _, _ in },
                    eventHandler: eventHandler
                )
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )
        viewModel.onServiceActivated = { activations.withLock { $0 += 1 } }
        viewModel.startGuardService(scopePath: model.config.scope.path)
        await viewModel.waitForServiceReconciliation()
        XCTAssertFalse(viewModel.isGuardServiceActive)
        XCTAssertNotNil(viewModel.status.lastError)

        model.onChange = {
            viewModel.reloadConfig(scopePath: model.config.scope.path)
        }
        try writeValidRecovery(scopePath: sandbox.scope.path, destination: sandbox.configURL)
        model.reload()
        await viewModel.waitForServiceReconciliation()

        XCTAssertTrue(model.isConfigurationValid)
        XCTAssertTrue(viewModel.isGuardServiceActive)
        XCTAssertNil(viewModel.status.lastError)
        XCTAssertEqual(factoryCalls.withLock { $0 }, 1)
        XCTAssertEqual(activations.withLock { $0 }, 1)
        await viewModel.stopGuardServiceAndWait()
    }

    func testServiceCreationFailureAfterValidReloadRemainsVisible() async throws {
        enum FactoryFailure: LocalizedError {
            case unavailable
            var errorDescription: String? { "service factory unavailable" }
        }
        let sandbox = try makeLifecycleSandbox()
        try "[scope]\npath =".write(to: sandbox.configURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: sandbox.configURL)
        let model = AppConfigModel(store: store)
        let viewModel = GuardViewModel(
            configStore: store,
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw FactoryFailure.unavailable },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )
        model.onChange = { viewModel.reloadConfig(scopePath: model.config.scope.path) }

        try writeValidRecovery(scopePath: sandbox.scope.path, destination: sandbox.configURL)
        model.reload()
        await viewModel.waitForServiceReconciliation()

        XCTAssertTrue(model.isConfigurationValid)
        XCTAssertFalse(viewModel.isGuardServiceActive)
        XCTAssertEqual(viewModel.status.lastError, "service factory unavailable")
    }

    func testStaleRevealRefreshCannotPublishPathsAfterRevealDisabled() async throws {
        enum UnusedFactory: Error { case called }
        let sandbox = try makeLifecycleSandbox()
        try ConfigStore(configURL: sandbox.configURL).save(AppConfig(scope: .init(path: sandbox.scope.path)))
        let revealStarted = DispatchSemaphore(value: 0)
        let releaseReveal = DispatchSemaphore(value: 0)
        let revealFinished = DispatchSemaphore(value: 0)
        let redactedLoaded = DispatchSemaphore(value: 0)
        let viewModel = GuardViewModel(
            configStore: ConfigStore(configURL: sandbox.configURL),
            lifetimeURL: sandbox.root.appendingPathComponent("lifetime.json"),
            guardServiceFactory: { _, _ in throw UnusedFactory.called },
            operationsLoader: { _, _, revealPaths in
                if revealPaths {
                    revealStarted.signal()
                    releaseReveal.wait()
                    revealFinished.signal()
                } else {
                    redactedLoaded.signal()
                }
                return Self.operationsSnapshot(scopePath: sandbox.scope.path, revealPaths: revealPaths)
            },
            scopePathsResolver: Self.scopePathsResolver(root: sandbox.root),
            scopeStorageEnsurer: Self.scopeStorageEnsurer(root: sandbox.root)
        )

        viewModel.startGuardServices(config: try ConfigStore(configURL: sandbox.configURL).loadValidated())
        await viewModel.waitForServiceReconciliation()

        viewModel.refreshOperations(revealWatchlistPaths: true)
        XCTAssertEqual(revealStarted.wait(timeout: .now() + 2), .success)
        viewModel.refreshOperations(revealWatchlistPaths: false)
        XCTAssertEqual(redactedLoaded.wait(timeout: .now() + 2), .success)
        for _ in 0..<200 where viewModel.operations.loading {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(viewModel.operations.watchlist.first?.displayPath.hasPrefix("path:"), true)

        releaseReveal.signal()
        XCTAssertEqual(revealFinished.wait(timeout: .now() + 2), .success)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(viewModel.operations.watchlist.first?.displayPath.hasPrefix("path:"), true)
    }

    private func makeLifecycleSandbox() throws -> (root: URL, scope: URL, configURL: URL) {
        let temporary = FileManager.default.temporaryDirectory
        let physicalTemporary = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true)
            : temporary
        let root = physicalTemporary
            .appendingPathComponent("icloud-guard-view-model-\(UUID().uuidString)", isDirectory: true)
        let scope = root.appendingPathComponent("CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (root, scope, root.appendingPathComponent("config.toml"))
    }

    private func writeValidRecovery(scopePath: String, destination: URL) throws {
        let recovery = destination.deletingLastPathComponent().appendingPathComponent("recovery.toml")
        try ConfigStore(configURL: recovery).save(AppConfig(scope: .init(path: scopePath)))
        try Data(contentsOf: recovery).write(to: destination, options: .atomic)
    }

    nonisolated private static func operationsSnapshot(scopePath: String, revealPaths: Bool) -> GuardOperationsSnapshot {
        let entry = WatchlistEntry(
            path: URL(fileURLWithPath: scopePath).appendingPathComponent("Secret/plan.pdf").path,
            addedAt: Date(timeIntervalSince1970: 1),
            nextCheckAt: .distantFuture
        )
        return GuardOperationsSnapshot(
            doctor: DoctorReport(generatedAt: Date(timeIntervalSince1970: 1), version: "test", checks: []),
            history: [],
            watchlist: [
                WatchlistInspection(
                    entry: entry,
                    scopePath: scopePath,
                    revealPaths: revealPaths,
                    maxFights: WatchlistWatcher.defaultMaxFights
                ),
            ]
        )
    }

    nonisolated private static func completeBundle() -> ScanBundle {
        var stats = DriveStats()
        stats.scanComplete = true
        stats.freeSpaceAvailable = true
        stats.completedAt = Date()
        return ScanBundle(stats: stats, candidates: [])
    }

    nonisolated private static func eventMonitorFactory(
        scopePath: String,
        harness: EventHintSourceHarness
    ) -> GuardEventHintMonitorFactory {
        { handler in
            try EventScanHintMonitor(
                scopePath: scopePath,
                maxPendingTargets: 8,
                debounceSeconds: 0.01,
                source: harness.source,
                handler: handler
            )
        }
    }

    nonisolated private static func scopePathsResolver(root: URL) -> ManagedScopePathsResolver {
        { context in
            AppPaths.ScopePaths(
                root: root.appendingPathComponent("state-\(context.config.id)", isDirectory: true),
                storageIdentifier: context.usesLegacyStorage ? nil : context.config.id
            )
        }
    }

    nonisolated private static func scopeStorageEnsurer(root: URL) -> ManagedScopeStorageEnsurer {
        { paths in
            guard paths.root.path.hasPrefix(root.path + "/") else {
                throw NSError(domain: "GuardViewModelLifecycleTests.unsafeStorageRoot", code: 1)
            }
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        }
    }

    private func waitForUpdates(_ viewModel: GuardViewModel) async {
        for _ in 0..<200 where viewModel.operations.updateLoading {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    nonisolated private static func updateRelease() -> UpdateRelease {
        UpdateRelease(
            channel: .stable,
            version: SemanticVersion("0.5.0")!,
            tag: "v0.5.0",
            commit: String(repeating: "a", count: 40),
            artifactURL: URL(string: "https://updates.example.test/iCloudGuard.zip")!,
            artifactFilename: "iCloudGuard.zip",
            artifactSHA256: String(repeating: "b", count: 64),
            artifactSize: 100,
            executableSHA256: String(repeating: "c", count: 64),
            executableUUID: "00000000-0000-0000-0000-000000000001",
            signingIdentity: "Developer ID Application: Example (ABCDEFGHIJ)",
            signingType: "developer-id",
            teamID: "ABCDEFGHIJ",
            notarized: true,
            stapled: true,
            buildToolchain: "Xcode 16.2",
            minimumMacOS: "15.0",
            sourceEpoch: 1,
            provenance: .trustedCI
        )
    }
}

final class IPCServerAppTargetTests: XCTestCase {
    func testServerRoundTripUsesInjectedSocketAndToken() throws {
        // Unix-domain socket paths are limited to 103 UTF-8 bytes on macOS.
        let root = URL(
            fileURLWithPath: "/private/tmp/ig-ipc-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let socketURL = root.appendingPathComponent("guard.sock")
        let token = "isolated-test-token"
        let server = try IPCServer(
            socketURL: socketURL,
            token: token,
            installSignalHandlers: false
        )
        server.commandHandler = { command, dryRun, _, progress in
            guard command == .status, !dryRun else {
                return IPCCommandResult(output: "unexpected request", exitCode: 1)
            }
            progress("scan shared")
            return IPCCommandResult(output: "ready", exitCode: 0)
        }
        server.start()
        defer { server.stop() }

        let response = try IPCClient(
            socketPath: socketURL.path,
            token: token,
            responseTimeoutSeconds: 2
        ).send(command: .status)

        XCTAssertEqual(response.exitCode, 0)
        XCTAssertEqual(response.output, "ready")
    }

    func testStaleTokenAuthRejectionCarriesRequestIDAndNeverInvokesHandler() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/ig-ipc-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let socketURL = root.appendingPathComponent("guard.sock")
        let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let server = try IPCServer(
            socketURL: socketURL,
            token: "fresh-token",
            installSignalHandlers: false
        )
        server.commandHandler = { _, _, _, _ in
            handlerCalls.withLock { $0 += 1 }
            return IPCCommandResult(output: "should not run", exitCode: 99)
        }
        server.start()
        defer { server.stop() }

        do {
            let requestID = "stale-\(UUID().uuidString)"
            let fd = try Self.connectedSocket(to: socketURL.path)
            defer { Darwin.close(fd) }
            try IPCSocketIO.configure(fd: fd, sendTimeoutSeconds: 1, receiveTimeoutSeconds: 1)
            var auth = try JSONSerialization.data(withJSONObject: [
                "auth": "stale-token",
                "auth_ack": true,
                "request_id": requestID,
            ])
            auth.append(UInt8(ascii: "\n"))
            try IPCSocketIO.writeAll(fd: fd, data: auth, deadline: .now() + .seconds(1))
            let line = try IPCSocketIO.readLine(fd: fd, maxBytes: 4_096, deadline: .now() + .seconds(1))
            let data = try XCTUnwrap(line.data(using: .utf8))
            let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(frame["request_id"] as? String, requestID)
            XCTAssertEqual(frame["auth"] as? String, "rejected")
            XCTAssertEqual(frame["error"] as? String, "Auth rejected")
        }

        XCTAssertThrowsError(try IPCClient(
            socketPath: socketURL.path,
            token: "stale-token",
            responseTimeoutSeconds: 2
        ).send(command: .evict)) { error in
            guard let ipcError = error as? IPCClient.IPCError else {
                XCTFail("Expected IPCError.authFailed, got \(error)")
                return
            }
            XCTAssertEqual(ipcError, .authFailed)
            XCTAssertTrue(ipcError.allowsLocalFallback)
        }
        XCTAssertEqual(handlerCalls.withLock { $0 }, 0)
    }

    private static func connectedSocket(to socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "IPCServerAppTargetTests", code: 1) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < sunPathSize else {
            Darwin.close(fd)
            throw NSError(domain: "IPCServerAppTargetTests", code: 2)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cPath in
                _ = strncpy(UnsafeMutableRawPointer(ptr), cPath, sunPathSize - 1)
            }
        }
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let errorNumber = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
        }
        return fd
    }
}

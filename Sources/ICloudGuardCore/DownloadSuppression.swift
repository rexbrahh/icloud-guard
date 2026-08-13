import Darwin
import Foundation
import os

public enum SuppressionMechanismResult: Equatable, Sendable {
    case disabled
    case succeeded
    case failed(String)
    case cancelled
    case timedOut

    public var succeededOrDisabled: Bool {
        self == .disabled || self == .succeeded
    }
}

public struct DownloadSuppressionResult: Equatable, Sendable {
    public var ioPolicy: SuppressionMechanismResult
    public var spotlight: SuppressionMechanismResult
    public var quickLook: SuppressionMechanismResult

    public init(
        ioPolicy: SuppressionMechanismResult,
        spotlight: SuppressionMechanismResult,
        quickLook: SuppressionMechanismResult
    ) {
        self.ioPolicy = ioPolicy
        self.spotlight = spotlight
        self.quickLook = quickLook
    }

    public var allConfiguredSucceeded: Bool {
        ioPolicy.succeededOrDisabled && spotlight.succeededOrDisabled && quickLook.succeededOrDisabled
    }
}

typealias QuickLookRunner = @Sendable (
    _ timeout: TimeInterval,
    _ cancellation: EvictionCancellation
) -> SuppressionMechanismResult

struct QuickLookProcessOperations: Sendable {
    let run: @Sendable () throws -> Void
    let isRunning: @Sendable () -> Bool
    let terminationStatus: @Sendable () -> Int32
    let terminate: @Sendable () -> Void
    let kill: @Sendable () -> Void
}

typealias QuickLookProcessFactory = @Sendable () -> QuickLookProcessOperations
typealias MonotonicNow = @Sendable () -> UInt64
typealias QuickLookSleep = @Sendable (_ microseconds: useconds_t) -> Void
typealias IOPolicyProvider = @Sendable (_ policy: Int32) -> SuppressionMechanismResult

/// Applies process I/O policy, a Spotlight marker, and a bounded QuickLook
/// cache reset. Each mechanism reports its own outcome.
public final class DownloadSuppression {
    private let logger: GuardLogging
    private let config: DownloadSuppressionConfig
    private let quickLookRunner: QuickLookRunner
    private let ioPolicyProvider: IOPolicyProvider

    public init(config: DownloadSuppressionConfig, logger: GuardLogging) {
        self.config = config
        self.logger = logger
        self.ioPolicyProvider = { Self.applyIOPolicy($0) }
        self.quickLookRunner = { timeout, cancellation in
            Self.runQuickLook(timeout: timeout, cancellation: cancellation)
        }
    }

    init(
        config: DownloadSuppressionConfig,
        logger: GuardLogging,
        quickLookProcessFactory: @escaping QuickLookProcessFactory,
        monotonicNow: @escaping MonotonicNow,
        sleep: @escaping QuickLookSleep,
        ioPolicyProvider: @escaping IOPolicyProvider = { DownloadSuppression.applyIOPolicy($0) }
    ) {
        self.config = config
        self.logger = logger
        self.ioPolicyProvider = ioPolicyProvider
        self.quickLookRunner = { timeout, cancellation in
            Self.runQuickLook(
                timeout: timeout,
                cancellation: cancellation,
                processFactory: quickLookProcessFactory,
                monotonicNow: monotonicNow,
                sleep: sleep
            )
        }
    }

    init(
        config: DownloadSuppressionConfig,
        logger: GuardLogging,
        quickLookRunner: @escaping QuickLookRunner,
        ioPolicyProvider: @escaping IOPolicyProvider = { DownloadSuppression.applyIOPolicy($0) }
    ) {
        self.config = config
        self.logger = logger
        self.quickLookRunner = quickLookRunner
        self.ioPolicyProvider = ioPolicyProvider
    }

    public func apply(
        cancellation suppliedCancellation: EvictionCancellation? = nil,
        quickLookTimeout: TimeInterval = 10
    ) async -> DownloadSuppressionResult {
        let config = config
        let quickLookRunner = quickLookRunner
        let ioPolicyProvider = ioPolicyProvider
        let cancellation = suppliedCancellation ?? EvictionCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                if cancellation.isCancelled {
                    return DownloadSuppressionResult(ioPolicy: .cancelled, spotlight: .cancelled, quickLook: .cancelled)
                }
                let ioPolicy = ioPolicyProvider(
                    config.materializeDatalessFiles
                        ? ioPolicyMaterializeDatalessFilesDefault
                        : ioPolicyMaterializeDatalessFilesOff
                )
                let spotlight = config.spotlightSuppression
                    ? Self.applySpotlightSuppression(scopePath: config.scopePath)
                    : SuppressionMechanismResult.disabled
                let quickLook = config.quickLookCacheClear
                    ? quickLookRunner(max(0.1, quickLookTimeout), cancellation)
                    : SuppressionMechanismResult.disabled
                return DownloadSuppressionResult(ioPolicy: ioPolicy, spotlight: spotlight, quickLook: quickLook)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
        log(result)
        return result
    }

    @discardableResult
    public func removeSpotlightSuppression() -> SuppressionMechanismResult {
        guard !config.scopePath.isEmpty else { return .disabled }
        let markerURL = Self.markerURL(scopePath: config.scopePath)
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return .succeeded }
        do {
            try FileManager.default.removeItem(at: markerURL)
            logger.log("suppression spotlight marker-removed path=\(markerURL.path)")
            return .succeeded
        } catch {
            logger.log("suppression spotlight marker-remove-failed error=\(error)")
            return .failed(error.localizedDescription)
        }
    }

    private static func applyIOPolicy(_ policy: Int32) -> SuppressionMechanismResult {
        let result = setiopolicy_np(
            ioPolicyTypeVFSMaterializeDatalessFiles,
            IOPOL_SCOPE_PROCESS,
            policy
        )
        guard result == 0 else {
            return .failed(String(cString: strerror(errno)))
        }
        return .succeeded
    }

    private static func applySpotlightSuppression(scopePath: String) -> SuppressionMechanismResult {
        guard !scopePath.isEmpty else { return .failed("scope path is empty") }
        let markerURL = markerURL(scopePath: scopePath)
        if FileManager.default.fileExists(atPath: markerURL.path) { return .succeeded }
        do {
            try Data().write(to: markerURL, options: [.atomic])
            return .succeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func markerURL(scopePath: String) -> URL {
        URL(
            fileURLWithPath: NSString(string: scopePath).expandingTildeInPath,
            isDirectory: true
        ).appendingPathComponent(".metadata_never_index")
    }

    private static func runQuickLook(
        timeout: TimeInterval,
        cancellation: EvictionCancellation,
        processFactory: QuickLookProcessFactory = { DownloadSuppression.liveQuickLookProcess() },
        monotonicNow: MonotonicNow = { DispatchTime.now().uptimeNanoseconds },
        sleep: QuickLookSleep = { usleep($0) }
    ) -> SuppressionMechanismResult {
        guard !cancellation.isCancelled else { return .cancelled }
        let process = processFactory()
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }

        let deadline = Self.deadline(after: timeout, now: monotonicNow())
        while process.isRunning() {
            if cancellation.isCancelled {
                guard terminate(process, monotonicNow: monotonicNow, sleep: sleep) else {
                    return .failed("QuickLook process did not exit after SIGKILL")
                }
                return .cancelled
            }
            if monotonicNow() >= deadline {
                guard terminate(process, monotonicNow: monotonicNow, sleep: sleep) else {
                    return .failed("QuickLook process did not exit after SIGKILL")
                }
                return .timedOut
            }
            sleep(20_000)
        }
        return process.terminationStatus() == 0
            ? .succeeded
            : .failed("exit status \(process.terminationStatus())")
    }

    private static func terminate(
        _ process: QuickLookProcessOperations,
        monotonicNow: MonotonicNow,
        sleep: QuickLookSleep
    ) -> Bool {
        process.terminate()
        var deadline = Self.deadline(after: 0.5, now: monotonicNow())
        while process.isRunning(), monotonicNow() < deadline { sleep(10_000) }
        guard process.isRunning() else { return true }

        process.kill()
        deadline = Self.deadline(after: 0.5, now: monotonicNow())
        while process.isRunning(), monotonicNow() < deadline { sleep(10_000) }
        return !process.isRunning()
    }

    private static func deadline(after seconds: TimeInterval, now: UInt64) -> UInt64 {
        let interval = UInt64(max(0, seconds) * 1_000_000_000)
        let (result, overflow) = now.addingReportingOverflow(interval)
        return overflow ? .max : result
    }

    private static func liveQuickLookProcess() -> QuickLookProcessOperations {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-r", "cache"]
        let storage = OSAllocatedUnfairLock(initialState: process)
        return QuickLookProcessOperations(
            run: { try storage.withLock { try $0.run() } },
            isRunning: { storage.withLock { $0.isRunning } },
            terminationStatus: { storage.withLock { $0.terminationStatus } },
            terminate: { storage.withLock { $0.terminate() } },
            kill: {
                let pid = storage.withLock { $0.processIdentifier }
                if pid > 0 { Darwin.kill(pid, SIGKILL) }
            }
        )
    }

    private func log(_ result: DownloadSuppressionResult) {
        logger.log("suppression iopolicy=\(result.ioPolicy) spotlight=\(result.spotlight) quicklook=\(result.quickLook)")
    }
}

private let ioPolicyTypeVFSMaterializeDatalessFiles: Int32 = 3
let ioPolicyMaterializeDatalessFilesDefault: Int32 = 0
let ioPolicyMaterializeDatalessFilesOff: Int32 = 1

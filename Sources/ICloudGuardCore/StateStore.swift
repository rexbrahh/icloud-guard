import Darwin
import Foundation

/// Shared persistence for `GuardState` (samples, last remediation, summaries).
/// Used by both the in-app scheduler and the CLI fallback runner, so cooldown
/// and growth detection behave identically no matter who runs.
public final class StateStore {
    public enum StateError: LocalizedError, Equatable, Sendable {
        case corrupt(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .corrupt(let message): return "state is corrupt: \(message)"
            case .io(let message): return "state I/O failed: \(message)"
            }
        }
    }

    static let maximumStateBytes: UInt64 = 16 * 1024 * 1024

    private let stateURL: URL

    public init(statePath: String = AppPaths.state.path) {
        self.stateURL = URL(fileURLWithPath: NSString(string: statePath).expandingTildeInPath)
    }

    public func load() throws -> GuardState {
        let data: Data
        do {
            data = try SecureRegularFile.read(stateURL, maximumBytes: Self.maximumStateBytes).data
        } catch let SecureRegularFile.ReadError.open(errorNumber) where errorNumber == ENOENT {
            return GuardState()
        } catch let SecureRegularFile.ReadError.tooLarge(size) {
            throw StateError.corrupt("state file exceeds safety limit (\(size) bytes)")
        } catch {
            throw StateError.io("state file is not a readable regular file")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var state = try decoder.decode(GuardState.self, from: data)
            if state.lastSummary == nil, let latest = try? RunHistoryStore(
                url: stateURL.deletingLastPathComponent().appendingPathComponent("history.json")
            ).load().last {
                state.lastSummary = latest.summary
            }
            return state
        } catch let error as StateError {
            throw error
        } catch {
            throw StateError.corrupt(error.localizedDescription)
        }
    }

    public func save(_ state: GuardState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    /// Read-modify-write seam for callers that hold the shared advisory lock.
    /// Reloading here prevents a long-lived GUI snapshot from overwriting a
    /// newer CLI cooldown or receipt.
    @discardableResult
    public func update(_ body: (inout GuardState) throws -> Void) throws -> GuardState {
        var state = try load()
        try body(&state)
        try save(state)
        return state
    }
}

/// Single mapping from the TOML-facing `AppConfig` to the core `PolicyConfig`
/// used by `PolicyEngine`. Previously duplicated (and drifting) inside
/// `GuardRunner.mapConfig`.
public enum PolicyMapping {
    public static func corePolicy(from appConfig: AppConfig) -> PolicyConfig {
        PolicyConfig(
            sampleIntervalSeconds: appConfig.watcher.pollutionCheckIntervalSeconds,
            targetLocalGiB: appConfig.policy.targetLocalGiB,
            trimLocalGiB: appConfig.policy.trimLocalGiB,
            warnFreeGiB: appConfig.policy.warnFreeGiB,
            remediateFreeGiB: appConfig.policy.remediateFreeGiB,
            panicFreeGiB: appConfig.policy.panicFreeGiB,
            growthTriggerGiB: appConfig.policy.growthTriggerGiB,
            growthWindowMinutes: appConfig.policy.growthWindowMinutes,
            cooldownMinutes: appConfig.policy.cooldownMinutes,
            protectedPaths: appConfig.scope.protectedPaths,
            keepDownloadedPaths: appConfig.scope.keepDownloadedPaths,
            folderPolicies: appConfig.scope.folderPolicies
        )
    }
}

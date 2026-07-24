import Foundation

/// Shared persistence for `GuardState` (samples, last remediation, summaries).
/// Used by both the in-app scheduler and the CLI fallback runner, so cooldown
/// and growth detection behave identically no matter who runs.
public final class StateStore {
    private let stateURL: URL

    public init(statePath: String = AppPaths.state.path) {
        self.stateURL = URL(fileURLWithPath: NSString(string: statePath).expandingTildeInPath)
    }

    public func load() throws -> GuardState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return GuardState()
        }

        let data = try Data(contentsOf: stateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GuardState.self, from: data)
    }

    public func save(_ state: GuardState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
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
            protectedPaths: appConfig.scope.protectedPaths
        )
    }
}

import Foundation

/// TOML-based application configuration.
///
/// Lives at ~/.icloud-guard/config.toml
/// No JSON anywhere in the app. The TOML is hand-writable and human-readable.
///
/// Example config.toml:
/// ```toml
/// [suppression]
/// spotlight = true
/// quicklook = true
/// materialize_dataless = false
///
/// [eviction]
/// batch_limit = 500
/// panic_limit = 2000
///
/// [watcher]
/// metadata_watcher_enabled = false
/// backoff_max_seconds = 60
/// pollution_check_interval_seconds = 300
///
/// [scope]
/// path = "~/Library/Mobile Documents/com~apple~CloudDocs"
/// ```
public struct AppConfig: Equatable, Sendable {
    public var suppression: SuppressionConfig
    public var eviction: EvictionConfig
    public var watcher: WatcherConfig
    public var scope: ScopeConfig
    public var policy: PolicyConfig

    public init(
        suppression: SuppressionConfig = .init(),
        eviction: EvictionConfig = .init(),
        watcher: WatcherConfig = .init(),
        scope: ScopeConfig = .init(),
        policy: PolicyConfig = .init()
    ) {
        self.suppression = suppression
        self.eviction = eviction
        self.watcher = watcher
        self.scope = scope
        self.policy = policy.normalized()
    }

    public func normalized() -> AppConfig {
        AppConfig(
            suppression: suppression,
            eviction: eviction,
            watcher: watcher,
            scope: scope,
            policy: policy.normalized()
        )
    }

    public struct SuppressionConfig: Equatable, Sendable, Codable {
        public var spotlight: Bool
        public var quicklook: Bool
        public var materializeDataless: Bool

        public init(spotlight: Bool = true, quicklook: Bool = true, materializeDataless: Bool = false) {
            self.spotlight = spotlight
            self.quicklook = quicklook
            self.materializeDataless = materializeDataless
        }

        public var nonMaterializingIOPolicyEnabled: Bool {
            get { !materializeDataless }
            set { materializeDataless = !newValue }
        }
    }

    public struct EvictionConfig: Equatable, Sendable, Codable {
        public var batchLimit: Int
        public var panicLimit: Int

        public init(batchLimit: Int = 500, panicLimit: Int = 2000) {
            self.batchLimit = batchLimit
            self.panicLimit = panicLimit
        }
    }

    public struct WatcherConfig: Equatable, Sendable, Codable {
        public var metadataWatcherEnabled: Bool
        public var backoffMaxSeconds: Int
        public var pollutionCheckIntervalSeconds: Int

        public init(
            metadataWatcherEnabled: Bool = false,
            backoffMaxSeconds: Int = 60,
            pollutionCheckIntervalSeconds: Int = 300
        ) {
            self.metadataWatcherEnabled = metadataWatcherEnabled
            self.backoffMaxSeconds = backoffMaxSeconds
            self.pollutionCheckIntervalSeconds = pollutionCheckIntervalSeconds
        }
    }

    public struct ScopeConfig: Equatable, Sendable, Codable {
        public var path: String
        public var protectedPaths: [String]

        public init(path: String = "~/Library/Mobile Documents/com~apple~CloudDocs", protectedPaths: [String] = []) {
            self.path = path
            self.protectedPaths = protectedPaths
        }
    }

    public struct PolicyConfig: Equatable, Sendable, Codable {
        public var targetLocalGiB: Int
        public var trimLocalGiB: Int
        public var warnFreeGiB: Int
        public var remediateFreeGiB: Int
        public var panicFreeGiB: Int
        public var cooldownMinutes: Int
        public var growthTriggerGiB: Int
        public var growthWindowMinutes: Int

        public init(
            targetLocalGiB: Int = 30,
            trimLocalGiB: Int = 35,
            warnFreeGiB: Int = 80,
            remediateFreeGiB: Int = 50,
            panicFreeGiB: Int = 25,
            cooldownMinutes: Int = 30,
            growthTriggerGiB: Int = 20,
            growthWindowMinutes: Int = 10
        ) {
            self.targetLocalGiB = targetLocalGiB
            self.trimLocalGiB = trimLocalGiB
            self.warnFreeGiB = warnFreeGiB
            self.remediateFreeGiB = remediateFreeGiB
            self.panicFreeGiB = panicFreeGiB
            self.cooldownMinutes = cooldownMinutes
            self.growthTriggerGiB = growthTriggerGiB
            self.growthWindowMinutes = growthWindowMinutes
        }

        public func normalized() -> PolicyConfig {
            let target = max(targetLocalGiB, 0)
            let trim = target == 0 && trimLocalGiB == 0 ? 0 : max(trimLocalGiB, target + 1)
            let panic = max(panicFreeGiB, 0)
            let remediate = max(remediateFreeGiB, panic)
            let warn = max(warnFreeGiB, remediate)
            return PolicyConfig(
                targetLocalGiB: target,
                trimLocalGiB: trim,
                warnFreeGiB: warn,
                remediateFreeGiB: remediate,
                panicFreeGiB: panic,
                cooldownMinutes: max(cooldownMinutes, 0),
                growthTriggerGiB: max(growthTriggerGiB, 0),
                growthWindowMinutes: max(growthWindowMinutes, 1)
            )
        }
    }
}

/// Minimal TOML reader/writer for simple flat key-value config sections.
/// Does not require any external dependencies.
/// Supports: [section] headers, key = value, bool, int, string.
public final class ConfigStore {
    private let configURL: URL

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? AppPaths.config
    }

    public var configURLPath: String { configURL.path }

    public func load() -> AppConfig {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return AppConfig()
        }
        return parseToml(content)
    }

    public func save(_ config: AppConfig) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toml = serializeToml(config.normalized())
        try toml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Minimal TOML Parser

    private func parseToml(_ content: String) -> AppConfig {
        var suppression = AppConfig.SuppressionConfig()
        var eviction = AppConfig.EvictionConfig()
        var watcher = AppConfig.WatcherConfig()
        var scope = AppConfig.ScopeConfig()
        var policy = AppConfig.PolicyConfig()

        var currentSection = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let rawValue = parts[1].trimmingCharacters(in: .whitespaces)

            switch currentSection {
            case "suppression":
                switch key {
                case "spotlight": suppression.spotlight = parseBool(rawValue)
                case "quicklook": suppression.quicklook = parseBool(rawValue)
                case "materialize_dataless": suppression.materializeDataless = parseBool(rawValue)
                default: break
                }
            case "eviction":
                switch key {
                case "batch_limit": eviction.batchLimit = parseInt(rawValue) ?? 500
                case "panic_limit": eviction.panicLimit = parseInt(rawValue) ?? 2000
                default: break
                }
            case "watcher":
                switch key {
                case "metadata_watcher_enabled": watcher.metadataWatcherEnabled = parseBool(rawValue)
                case "backoff_max_seconds": watcher.backoffMaxSeconds = parseInt(rawValue) ?? 60
                case "pollution_check_interval_seconds": watcher.pollutionCheckIntervalSeconds = parseInt(rawValue) ?? 300
                default: break
                }
            case "scope":
                switch key {
                case "path":
                    let unquoted = rawValue.replacingOccurrences(of: "\"", with: "")
                    scope.path = unquoted
                case "protected_paths":
                    scope.protectedPaths = parseStringArray(rawValue)
                default: break
                }
            case "policy":
                switch key {
                case "target_local_gib": policy.targetLocalGiB = parseInt(rawValue) ?? 30
                case "trim_local_gib": policy.trimLocalGiB = parseInt(rawValue) ?? 35
                case "warn_free_gib": policy.warnFreeGiB = parseInt(rawValue) ?? 80
                case "remediate_free_gib": policy.remediateFreeGiB = parseInt(rawValue) ?? 50
                case "panic_free_gib": policy.panicFreeGiB = parseInt(rawValue) ?? 25
                case "cooldown_minutes": policy.cooldownMinutes = parseInt(rawValue) ?? 30
                case "growth_trigger_gib": policy.growthTriggerGiB = parseInt(rawValue) ?? 20
                case "growth_window_minutes": policy.growthWindowMinutes = parseInt(rawValue) ?? 10
                default: break
                }
            default: break
            }
        }

        return AppConfig(suppression: suppression, eviction: eviction, watcher: watcher, scope: scope, policy: policy)
    }

    private func parseBool(_ value: String) -> Bool {
        value.lowercased() == "true"
    }

    private func parseInt(_ value: String) -> Int? {
        Int(value)
    }

    private func parseStringArray(_ value: String) -> [String] {
        // Parse ["path1", "path2"] format
        var stripped = value
        if stripped.hasPrefix("[") { stripped = String(stripped.dropFirst()) }
        if stripped.hasSuffix("]") { stripped = String(stripped.dropLast()) }
        return stripped.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        }.filter { !$0.isEmpty }
    }

    // MARK: - Minimal TOML Serializer

    private func serializeToml(_ config: AppConfig) -> String {
        var lines: [String] = []
        lines.append("# iCloud Guard configuration")
        lines.append("# Generated by iCloud Guard — do not edit while app is running")
        lines.append("")
        lines.append("[suppression]")
        lines.append("spotlight = \(config.suppression.spotlight)")
        lines.append("quicklook = \(config.suppression.quicklook)")
        lines.append("materialize_dataless = \(config.suppression.materializeDataless)")
        lines.append("")
        lines.append("[eviction]")
        lines.append("batch_limit = \(config.eviction.batchLimit)")
        lines.append("panic_limit = \(config.eviction.panicLimit)")
        lines.append("")
        lines.append("[watcher]")
        lines.append("metadata_watcher_enabled = \(config.watcher.metadataWatcherEnabled)")
        lines.append("backoff_max_seconds = \(config.watcher.backoffMaxSeconds)")
        lines.append("pollution_check_interval_seconds = \(config.watcher.pollutionCheckIntervalSeconds)")
        lines.append("")
        lines.append("[scope]")
        lines.append("path = \"\(config.scope.path)\"")
        let paths = config.scope.protectedPaths.map { "\"\($0)\"" }.joined(separator: ", ")
        lines.append("protected_paths = [\(paths)]")
        lines.append("")
        lines.append("[policy]")
        lines.append("target_local_gib = \(config.policy.targetLocalGiB)")
        lines.append("trim_local_gib = \(config.policy.trimLocalGiB)")
        lines.append("warn_free_gib = \(config.policy.warnFreeGiB)")
        lines.append("remediate_free_gib = \(config.policy.remediateFreeGiB)")
        lines.append("panic_free_gib = \(config.policy.panicFreeGiB)")
        lines.append("cooldown_minutes = \(config.policy.cooldownMinutes)")
        lines.append("growth_trigger_gib = \(config.policy.growthTriggerGiB)")
        lines.append("growth_window_minutes = \(config.policy.growthWindowMinutes)")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

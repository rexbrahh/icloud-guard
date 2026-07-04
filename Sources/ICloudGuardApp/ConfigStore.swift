import Foundation

/// TOML-based application configuration.
///
/// Lives at ~/Library/Application Support/ICloudGuard/config.toml
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

    public init(
        suppression: SuppressionConfig = .init(),
        eviction: EvictionConfig = .init(),
        watcher: WatcherConfig = .init(),
        scope: ScopeConfig = .init()
    ) {
        self.suppression = suppression
        self.eviction = eviction
        self.watcher = watcher
        self.scope = scope
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
        public var backoffMaxSeconds: Int
        public var pollutionCheckIntervalSeconds: Int

        public init(backoffMaxSeconds: Int = 60, pollutionCheckIntervalSeconds: Int = 300) {
            self.backoffMaxSeconds = backoffMaxSeconds
            self.pollutionCheckIntervalSeconds = pollutionCheckIntervalSeconds
        }
    }

    public struct ScopeConfig: Equatable, Sendable, Codable {
        public var path: String

        public init(path: String = "~/Library/Mobile Documents/com~apple~CloudDocs") {
            self.path = path
        }
    }
}

/// Minimal TOML reader/writer for simple flat key-value config sections.
/// Does not require any external dependencies.
/// Supports: [section] headers, key = value, bool, int, string.
public final class ConfigStore {
    private let configURL: URL

    public init(configDir: String? = nil) {
        let dir = configDir ?? "\(NSHomeDirectory())/Library/Application Support/ICloudGuard"
        self.configURL = URL(fileURLWithPath: dir).appendingPathComponent("config.toml")
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
        let toml = serializeToml(config)
        try toml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Minimal TOML Parser

    private func parseToml(_ content: String) -> AppConfig {
        var suppression = AppConfig.SuppressionConfig()
        var eviction = AppConfig.EvictionConfig()
        var watcher = AppConfig.WatcherConfig()
        var scope = AppConfig.ScopeConfig()

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
                case "backoff_max_seconds": watcher.backoffMaxSeconds = parseInt(rawValue) ?? 60
                case "pollution_check_interval_seconds": watcher.pollutionCheckIntervalSeconds = parseInt(rawValue) ?? 300
                default: break
                }
            case "scope":
                switch key {
                case "path":
                    let unquoted = rawValue.replacingOccurrences(of: "\"", with: "")
                    scope.path = unquoted
                default: break
                }
            default: break
            }
        }

        return AppConfig(suppression: suppression, eviction: eviction, watcher: watcher, scope: scope)
    }

    private func parseBool(_ value: String) -> Bool {
        value.lowercased() == "true"
    }

    private func parseInt(_ value: String) -> Int? {
        Int(value)
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
        lines.append("backoff_max_seconds = \(config.watcher.backoffMaxSeconds)")
        lines.append("pollution_check_interval_seconds = \(config.watcher.pollutionCheckIntervalSeconds)")
        lines.append("")
        lines.append("[scope]")
        lines.append("path = \"\(config.scope.path)\"")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

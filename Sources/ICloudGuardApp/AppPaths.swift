import Foundation

/// Centralized path management for the iCloud Guard app.
///
/// All app files live under `~/.icloud-guard/`. This is the single source of truth
/// for every path the app uses — config, logs, state, future caches, etc.
/// Nothing else in the app should construct paths manually.
public enum AppPaths {
    /// Root directory for all app files: `~/.icloud-guard/`
    public static let homeDir: URL = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home.appendingPathComponent(".icloud-guard", isDirectory: true)
    }()

    /// TOML config: `~/.icloud-guard/config.toml`
    public static var config: URL { homeDir.appendingPathComponent("config.toml") }

    /// Log file: `~/.icloud-guard/icloud-guard.log`
    public static var log: URL { homeDir.appendingPathComponent("icloud-guard.log") }

    /// State file (future use): `~/.icloud-guard/state.json`
    public static var state: URL { homeDir.appendingPathComponent("state.json") }

    /// Cache directory (future use): `~/.icloud-guard/cache/`
    public static var cache: URL { homeDir.appendingPathComponent("cache", isDirectory: true) }

    /// Ensure the home directory exists. Call once at startup.
    public static func ensureHomeDir() {
        try? FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }
}

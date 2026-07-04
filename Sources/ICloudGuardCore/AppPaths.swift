import Foundation
import Darwin

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

    /// PID file: `~/.icloud-guard/icloud-guard.pid`
    public static var pidFile: URL { homeDir.appendingPathComponent("icloud-guard.pid") }

    /// Unix domain socket for IPC: `~/.icloud-guard/guard.sock`
    public static var socket: URL { homeDir.appendingPathComponent("guard.sock") }

    /// Eviction log: `~/.icloud-guard/evictions.log`
    public static var evictionLog: URL { homeDir.appendingPathComponent("evictions.log") }

    /// Stats file (JSONL): `~/.icloud-guard/stats.jsonl`
    public static var stats: URL { homeDir.appendingPathComponent("stats.jsonl") }

    /// Run lock: `~/.icloud-guard/run.lock`
    public static var lock: URL { homeDir.appendingPathComponent("run.lock") }

    /// Auth token file for IPC: `~/.icloud-guard/guard.token`
    public static var tokenFile: URL { homeDir.appendingPathComponent("guard.token") }

    // MARK: - Directory Management

    /// Ensure the home directory exists with 0700 permissions. Call once at startup.
    public static func ensureHomeDir() {
        try? FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homeDir.path)
    }

    // MARK: - PID Management

    /// Write the current PID (or a specified PID) to the PID file with mode 0600.
    public static func writePID(_ pid: Int32 = getpid()) throws {
        ensureHomeDir()
        let pidString = "\(pid)\n"
        try pidString.write(to: pidFile, atomically: true, encoding: .utf8)
        chmod(pidFile.path, 0o600)
    }

    /// Remove the PID file if it exists. Swallows ENOENT.
    public static func removePID() {
        unlink(pidFile.path)
    }

    /// Check if the GUI app process is alive by reading the PID file and sending signal 0.
    /// Returns true if the process exists (kill returns 0) or if we lack permission (EPERM).
    public static func isGUIAlive() -> Bool {
        guard let pidString = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        if pid <= 0 { return false }
        let result = kill(pid, 0)
        if result == 0 { return true }
        return errno == EPERM
    }

    /// Remove the PID file if the process it references is no longer alive.
    public static func reapStalePID() {
        guard FileManager.default.fileExists(atPath: pidFile.path) else { return }
        if !isGUIAlive() {
            removePID()
        }
    }

    // MARK: - Socket Management

    /// Remove the socket file if it exists and no process is listening on it.
    public static func reapStaleSocket() {
        guard FileManager.default.fileExists(atPath: socket.path) else { return }
        // Try to connect — if connection fails, the socket is stale
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socket.path
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cPath in
                strncpy(UnsafeMutableRawPointer(ptr), cPath, sunPathSize - 1)
            }
        }
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            // Connection failed — no one is listening, safe to remove
            unlink(socket.path)
        }
    }

    /// Remove the socket file unconditionally. Swallows ENOENT.
    public static func unlinkSocket() {
        unlink(socket.path)
    }

    // MARK: - Config Seeding

    /// If config.toml does not exist, create it with default AppConfig values.
    public static func seedDefaultConfigIfMissing() {
        guard !FileManager.default.fileExists(atPath: config.path) else { return }
        ensureHomeDir()
        let store = ConfigStore()
        try? store.save(AppConfig())
    }

    // MARK: - Auth Token

    /// Generate a 32-byte random token, write it to the token file (mode 0600), and return the hex string.
    @discardableResult
    public static func generateToken() throws -> String {
        ensureHomeDir()
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: "AppPaths", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to generate random bytes"])
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try hex.write(to: tokenFile, atomically: true, encoding: .utf8)
        chmod(tokenFile.path, 0o600)
        return hex
    }

    /// Read the auth token from the token file. Returns nil if the file does not exist.
    public static func readToken() -> String? {
        guard let data = try? String(contentsOf: tokenFile, encoding: .utf8) else { return nil }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

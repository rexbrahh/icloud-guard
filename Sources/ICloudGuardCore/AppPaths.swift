import Foundation
import Darwin

/// Centralized path management for the iCloud Guard app.
///
/// All app files live under `~/.icloud-guard/`. This is the single source of truth
/// for every path the app uses — config, logs, state, future caches, etc.
/// Nothing else in the app should construct paths manually.
public enum AppPaths {
    public enum ScopeDirectoryError: LocalizedError, Equatable, Sendable {
        case unsafeComponent(String)
        case missingBindingExpectation(String)
        case unboundNonemptyStorage(String)
        case invalidBinding(String)
        case bindingMismatch(String)
        case bindingBusy(String)
        case system(operation: String, errorNumber: Int32)

        public var errorDescription: String? {
            switch self {
            case .unsafeComponent(let component):
                return "unsafe scope storage component \(component)"
            case .missingBindingExpectation(let identifier):
                return "scope storage \(identifier) has no binding expectation"
            case .unboundNonemptyStorage(let identifier):
                return "scope storage \(identifier) contains unbound data"
            case .invalidBinding(let identifier):
                return "scope storage \(identifier) has an invalid binding marker"
            case .bindingMismatch(let identifier):
                return "scope storage \(identifier) is bound to a different scope path"
            case .bindingBusy(let identifier):
                return "scope storage \(identifier) binding is busy"
            case .system(let operation, let errorNumber):
                return "\(operation) failed: \(String(cString: strerror(errorNumber)))"
            }
        }
    }

    public struct ScopePaths: Equatable, Sendable {
        public let root: URL
        public let state: URL
        public let watchlist: URL
        public let history: URL
        public let recovery: URL
        public let log: URL
        public let evictionLog: URL
        public let lock: URL
        public let browser: URL
        public let binding: URL
        fileprivate let storageIdentifier: String?
        fileprivate let expectedScopeIdentifier: String?

        init(root: URL, storageIdentifier: String? = nil, expectedScopeIdentifier: String? = nil) {
            self.root = root
            self.storageIdentifier = storageIdentifier
            self.expectedScopeIdentifier = expectedScopeIdentifier
            state = root.appendingPathComponent("state.json")
            watchlist = root.appendingPathComponent("watchlist.json")
            history = root.appendingPathComponent("history.json")
            recovery = root.appendingPathComponent("recovery.json")
            log = root.appendingPathComponent("icloud-guard.log")
            evictionLog = root.appendingPathComponent("evictions.log")
            lock = root.appendingPathComponent("run.lock")
            browser = root.appendingPathComponent("scope-browser.json")
            binding = root.appendingPathComponent(".scope-binding.json")
        }
    }

    private struct ScopeStorageBinding: Codable, Equatable {
        static let currentSchema = 1
        var schema = currentSchema
        var scopeID: String
        var scopeIdentifier: String
    }

    /// Tests and child tools can isolate all state without changing the user's
    /// real home. Production leaves this unset.
    public static let homeOverrideEnvironmentKey = "ICLOUD_GUARD_HOME"

    /// Root directory for all app files: `~/.icloud-guard/`
    public static var homeDir: URL {
        if let override = ProcessInfo.processInfo.environment[homeOverrideEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home.appendingPathComponent(".icloud-guard", isDirectory: true)
    }

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


    /// Run lock: `~/.icloud-guard/run.lock`
    public static var lock: URL { homeDir.appendingPathComponent("run.lock") }

    /// Single GUI-instance advisory lock.
    public static var instanceLock: URL { homeDir.appendingPathComponent("app.lock") }

    /// Auth token file for IPC: `~/.icloud-guard/guard.token`
    public static var tokenFile: URL { homeDir.appendingPathComponent("guard.token") }

    /// Rematerialization watchlist: `~/.icloud-guard/watchlist.json`
    public static var watchlist: URL { homeDir.appendingPathComponent("watchlist.json") }

    /// Bounded, versioned run history.
    public static var history: URL { homeDir.appendingPathComponent("history.json") }

    /// Bounded recovery journal for the legacy single-scope layout.
    public static var recovery: URL { homeDir.appendingPathComponent("recovery.json") }

    /// Optional bounded scope-browser state for the legacy layout.
    public static var browser: URL { homeDir.appendingPathComponent("scope-browser.json") }

    /// Existing installs continue using their original paths. Explicit
    /// multi-scope configurations use `paths(forManagedScope:)` instead.
    public static var legacyScopePaths: ScopePaths { ScopePaths(root: homeDir) }

    public static func paths(forManagedScope scope: ManagedScopeConfig) throws -> ScopePaths {
        try MultiScopeValidator.validateIdentifier(scope.id)
        let canonicalPath = try MultiScopeValidator.canonicalPath(for: scope)
        let root = homeDir
            .appendingPathComponent("scopes", isDirectory: true)
            .appendingPathComponent(scope.id, isDirectory: true)
        return ScopePaths(
            root: root,
            storageIdentifier: scope.id,
            expectedScopeIdentifier: PrivacyIdentifier.hash(canonicalPath)
        )
    }

    public static func ensureScopeDir(_ paths: ScopePaths) throws {
        try ensureHomeDir()
        let homeFD = Darwin.open(homeDir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw ScopeDirectoryError.unsafeComponent("home") }
            throw ScopeDirectoryError.system(operation: "open app home", errorNumber: errno)
        }
        defer { Darwin.close(homeFD) }
        try secureDirectoryDescriptor(homeFD, component: "home")

        guard let identifier = paths.storageIdentifier else { return }
        guard let expectedScopeIdentifier = paths.expectedScopeIdentifier else {
            throw ScopeDirectoryError.missingBindingExpectation(identifier)
        }

        try MultiScopeValidator.validateIdentifier(identifier)
        let scopesFD = try openOrCreateDirectory(at: homeFD, component: "scopes")
        defer { Darwin.close(scopesFD) }
        let scopeFD = try openOrCreateDirectory(at: scopesFD, component: identifier)
        defer { Darwin.close(scopeFD) }
        try secureDirectoryDescriptor(scopeFD, component: identifier)
        try validateScopeRootIdentity(paths.root, descriptor: scopeFD)
        try bindScopeStorage(
            descriptor: scopeFD,
            identifier: identifier,
            expectedScopeIdentifier: expectedScopeIdentifier
        )
    }

    private static func validateScopeRootIdentity(_ root: URL, descriptor: Int32) throws {
        let supplied = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard supplied >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw ScopeDirectoryError.unsafeComponent("scope root") }
            throw ScopeDirectoryError.system(operation: "open supplied scope root", errorNumber: errno)
        }
        defer { Darwin.close(supplied) }
        var expectedMetadata = stat()
        var suppliedMetadata = stat()
        guard fstat(descriptor, &expectedMetadata) == 0,
              fstat(supplied, &suppliedMetadata) == 0 else {
            throw ScopeDirectoryError.system(operation: "inspect supplied scope root", errorNumber: errno)
        }
        guard expectedMetadata.st_dev == suppliedMetadata.st_dev,
              expectedMetadata.st_ino == suppliedMetadata.st_ino else {
            throw ScopeDirectoryError.unsafeComponent("scope root")
        }
    }

    private static func bindScopeStorage(
        descriptor: Int32,
        identifier: String,
        expectedScopeIdentifier: String
    ) throws {
        try acquireBindingLock(descriptor: descriptor, identifier: identifier)
        defer { _ = flock(descriptor, LOCK_UN) }

        let expected = ScopeStorageBinding(scopeID: identifier, scopeIdentifier: expectedScopeIdentifier)
        if let existing = try readScopeBinding(descriptor: descriptor, identifier: identifier) {
            guard existing == expected else {
                throw ScopeDirectoryError.bindingMismatch(identifier)
            }
            return
        }
        guard try directoryIsEmpty(descriptor) else {
            throw ScopeDirectoryError.unboundNonemptyStorage(identifier)
        }
        try publishScopeBinding(expected, descriptor: descriptor, identifier: identifier)
        guard try readScopeBinding(descriptor: descriptor, identifier: identifier) == expected else {
            throw ScopeDirectoryError.invalidBinding(identifier)
        }
    }

    private static func acquireBindingLock(descriptor: Int32, identifier: String) throws {
        let deadline = DispatchTime.now() + .seconds(2)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                if DispatchTime.now() >= deadline { throw ScopeDirectoryError.bindingBusy(identifier) }
                usleep(10_000)
                continue
            }
            throw ScopeDirectoryError.system(operation: "lock scope storage binding", errorNumber: errno)
        }
    }

    private static func encodedScopeBinding(_ binding: ScopeStorageBinding) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(binding) }
        catch { throw ScopeDirectoryError.invalidBinding(binding.scopeID) }
    }

    private static func readScopeBinding(
        descriptor: Int32,
        identifier: String
    ) throws -> ScopeStorageBinding? {
        let marker = ".scope-binding.json"
        let fileDescriptor = openat(
            descriptor,
            marker,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR {
                throw ScopeDirectoryError.unsafeComponent(marker)
            }
            throw ScopeDirectoryError.system(operation: "open scope storage binding", errorNumber: errno)
        }
        defer { Darwin.close(fileDescriptor) }

        var before = stat()
        guard fstat(fileDescriptor, &before) == 0 else {
            throw ScopeDirectoryError.system(operation: "inspect scope storage binding", errorNumber: errno)
        }
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & mode_t(0o777) == mode_t(0o600),
              before.st_size > 0,
              before.st_size <= 4_096 else {
            throw ScopeDirectoryError.invalidBinding(identifier)
        }

        var data = Data(count: Int(before.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fileDescriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                throw ScopeDirectoryError.system(operation: "read scope storage binding", errorNumber: errno)
            }
            throw ScopeDirectoryError.invalidBinding(identifier)
        }
        var trailing: UInt8 = 0
        while true {
            let count = Darwin.read(fileDescriptor, &trailing, 1)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                throw ScopeDirectoryError.system(operation: "read scope storage binding", errorNumber: errno)
            }
            throw ScopeDirectoryError.invalidBinding(identifier)
        }
        var after = stat()
        guard fstat(fileDescriptor, &after) == 0 else {
            throw ScopeDirectoryError.system(operation: "reinspect scope storage binding", errorNumber: errno)
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ScopeDirectoryError.invalidBinding(identifier)
        }
        do {
            let binding = try JSONDecoder().decode(ScopeStorageBinding.self, from: data)
            guard binding.schema == ScopeStorageBinding.currentSchema,
                  try encodedScopeBinding(binding) == data else {
                throw ScopeDirectoryError.invalidBinding(identifier)
            }
            return binding
        } catch let error as ScopeDirectoryError {
            throw error
        } catch {
            throw ScopeDirectoryError.invalidBinding(identifier)
        }
    }

    private static func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw ScopeDirectoryError.system(operation: "duplicate scope storage descriptor", errorNumber: errno)
        }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ScopeDirectoryError.system(operation: "inspect scope storage contents", errorNumber: errno)
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno == 0 { return true }
                throw ScopeDirectoryError.system(operation: "inspect scope storage contents", errorNumber: errno)
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { return false }
        }
    }

    private static func publishScopeBinding(
        _ binding: ScopeStorageBinding,
        descriptor: Int32,
        identifier: String
    ) throws {
        let data = try encodedScopeBinding(binding)
        let marker = ".scope-binding.json"
        let temporary = ".scope-binding.\(UUID().uuidString).tmp"
        let fileDescriptor = openat(
            descriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fileDescriptor >= 0 else {
            throw ScopeDirectoryError.system(operation: "create scope storage binding", errorNumber: errno)
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { Darwin.close(fileDescriptor) }
            _ = unlinkat(descriptor, temporary, 0)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fileDescriptor, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                throw ScopeDirectoryError.system(operation: "write scope storage binding", errorNumber: errno)
            }
        }
        guard fchmod(fileDescriptor, 0o600) == 0 else {
            throw ScopeDirectoryError.system(operation: "secure scope storage binding", errorNumber: errno)
        }
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw ScopeDirectoryError.system(operation: "flush scope storage binding", errorNumber: errno)
        }
        var temporaryMetadata = stat()
        guard fstat(fileDescriptor, &temporaryMetadata) == 0 else {
            throw ScopeDirectoryError.system(operation: "inspect published scope storage binding", errorNumber: errno)
        }
        guard Darwin.close(fileDescriptor) == 0 else {
            throw ScopeDirectoryError.system(operation: "close scope storage binding", errorNumber: errno)
        }
        descriptorOpen = false

        let linkedByThisCall: Bool
        if linkat(descriptor, temporary, descriptor, marker, 0) == 0 {
            linkedByThisCall = true
        } else {
            let linkError = errno
            if linkError != EEXIST {
                throw ScopeDirectoryError.system(operation: "publish scope storage binding", errorNumber: linkError)
            }
            linkedByThisCall = false
        }
        _ = unlinkat(descriptor, temporary, 0)
        if linkedByThisCall {
            let publishedDescriptor = openat(
                descriptor,
                marker,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
            guard publishedDescriptor >= 0 else {
                throw ScopeDirectoryError.system(operation: "reopen published scope storage binding", errorNumber: errno)
            }
            defer { Darwin.close(publishedDescriptor) }
            var publishedMetadata = stat()
            guard fstat(publishedDescriptor, &publishedMetadata) == 0 else {
                throw ScopeDirectoryError.system(operation: "inspect linked scope storage binding", errorNumber: errno)
            }
            guard temporaryMetadata.st_dev == publishedMetadata.st_dev,
                  temporaryMetadata.st_ino == publishedMetadata.st_ino else {
                throw ScopeDirectoryError.invalidBinding(identifier)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ScopeDirectoryError.system(operation: "flush scope storage directory", errorNumber: errno)
        }
    }

    private static func openOrCreateDirectory(at parentFD: Int32, component: String) throws -> Int32 {
        if mkdirat(parentFD, component, 0o700) != 0, errno != EEXIST {
            throw ScopeDirectoryError.system(operation: "create \(component) directory", errorNumber: errno)
        }
        let descriptor = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw ScopeDirectoryError.unsafeComponent(component) }
            throw ScopeDirectoryError.system(operation: "open \(component) directory", errorNumber: errno)
        }
        do {
            try secureDirectoryDescriptor(descriptor, component: component)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func secureDirectoryDescriptor(_ descriptor: Int32, component: String) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ScopeDirectoryError.system(operation: "inspect \(component) directory", errorNumber: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ScopeDirectoryError.unsafeComponent(component)
        }
        guard metadata.st_uid == geteuid() else {
            throw ScopeDirectoryError.unsafeComponent(component)
        }
        guard fchmod(descriptor, 0o700) == 0 else {
            throw ScopeDirectoryError.system(operation: "secure \(component) directory", errorNumber: errno)
        }
    }

    // MARK: - Directory Management

    /// Ensure the home directory is an owned, no-follow directory with mode 0700.
    public static func ensureHomeDir() throws {
        if Darwin.mkdir(homeDir.path, 0o700) != 0, errno != EEXIST {
            throw ScopeDirectoryError.system(operation: "create app home", errorNumber: errno)
        }
        let descriptor = Darwin.open(homeDir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw ScopeDirectoryError.unsafeComponent("home") }
            throw ScopeDirectoryError.system(operation: "open app home", errorNumber: errno)
        }
        defer { Darwin.close(descriptor) }
        try secureDirectoryDescriptor(descriptor, component: "home")
    }

    // MARK: - PID Management

    /// Write the current PID (or a specified PID) to the PID file with mode 0600.
    public static func writePID(_ pid: Int32 = getpid()) throws {
        try ensureHomeDir()
        let pidString = "\(pid)\n"
        try pidString.write(to: pidFile, atomically: true, encoding: .utf8)
        chmod(pidFile.path, 0o600)
    }

    /// Remove the PID file if it exists. Swallows ENOENT.
    public static func removePID() {
        unlink(pidFile.path)
    }

    /// Remove the PID file only when it belongs to this process. A duplicate
    /// app instance must never remove the active instance's discovery file.
    public static func removeOwnedPID(_ pid: Int32 = getpid()) {
        guard let pidString = try? String(contentsOf: pidFile, encoding: .utf8),
              Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) == pid else {
            return
        }
        removePID()
    }

    public static func pidBelongsToCurrentProcess() -> Bool {
        guard let pidString = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
        return Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid()
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
        guard socketPathFitsUnixAddress(socket.path) else { return }
        guard FileManager.default.fileExists(atPath: socket.path) else { return }
        guard socketPathIsSocket(socket.path) else { return }
        // Try to connect — if connection fails, the socket is stale
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socket.path
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
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
        guard socketPathFitsUnixAddress(socket.path), socketPathIsSocket(socket.path) else { return }
        unlink(socket.path)
    }

    public static func socketPathFitsUnixAddress(_ path: String) -> Bool {
        let address = sockaddr_un()
        return path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
    }

    private static func socketPathIsSocket(_ path: String) -> Bool {
        var metadata = stat()
        guard path.withCString({ lstat($0, &metadata) }) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFSOCK
    }

    // MARK: - Config Seeding

    /// If config.toml does not exist, create it with default AppConfig values.
    public static func seedDefaultConfigIfMissing() throws {
        guard !FileManager.default.fileExists(atPath: config.path) else { return }
        try ensureHomeDir()
        let store = ConfigStore()
        try store.save(AppConfig())
    }

    // MARK: - Auth Token

    /// Generate a 32-byte random token, write it to the token file (mode 0600), and return the hex string.
    @discardableResult
    public static func generateToken() throws -> String {
        try ensureHomeDir()
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

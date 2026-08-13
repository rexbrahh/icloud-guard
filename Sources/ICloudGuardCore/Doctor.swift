import Darwin
import Foundation

public enum DoctorSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public enum DoctorStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
    case unavailable
}

public struct DoctorCheck: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var severity: DoctorSeverity
    public var status: DoctorStatus
    public var message: String
    public var remediation: String

    public init(id: String, severity: DoctorSeverity, status: DoctorStatus, message: String, remediation: String) {
        self.id = id
        self.severity = severity
        self.status = status
        self.message = message
        self.remediation = remediation
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var generatedAt: Date
    public var version: String
    public var checks: [DoctorCheck]

    public init(generatedAt: Date = Date(), version: String = ICloudGuardProduct.version, checks: [DoctorCheck]) {
        self.generatedAt = generatedAt
        self.version = version
        self.checks = checks
    }

    public var exitCode: Int32 {
        checks.contains {
            $0.severity == .error && ($0.status == .failed || $0.status == .unavailable)
        } ? 78 : 0
    }
}

public enum FirstRunDoctorState {
    public static let schemaVersion = 1
    public static let reviewedSchemaKey = "doctorReviewCompletedSchema"

    public static func needsReview(defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: reviewedSchemaKey) < schemaVersion
    }

    public static func acknowledge(defaults: UserDefaults) {
        defaults.set(schemaVersion, forKey: reviewedSchemaKey)
    }
}

public struct DoctorFileInfo: Sendable {
    public var isDirectory: Bool
    public var permissions: Int?

    public init(isDirectory: Bool, permissions: Int?) {
        self.isDirectory = isDirectory
        self.permissions = permissions
    }
}

public struct DoctorProbe: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var fileInfo: @Sendable (String) -> DoctorFileInfo?
    public var isWritable: @Sendable (String) -> Bool
    public var canonicalPath: @Sendable (String) -> String
    public var freeBytes: @Sendable (String) -> Int64?
    public var processAlive: @Sendable (Int32) -> Bool
    public var isSocket: @Sendable (String) -> Bool
    public var executable: @Sendable (String) -> Bool

    public init(
        fileExists: @escaping @Sendable (String) -> Bool,
        fileInfo: @escaping @Sendable (String) -> DoctorFileInfo?,
        isWritable: @escaping @Sendable (String) -> Bool,
        canonicalPath: @escaping @Sendable (String) -> String,
        freeBytes: @escaping @Sendable (String) -> Int64?,
        processAlive: @escaping @Sendable (Int32) -> Bool,
        isSocket: @escaping @Sendable (String) -> Bool,
        executable: @escaping @Sendable (String) -> Bool
    ) {
        self.fileExists = fileExists
        self.fileInfo = fileInfo
        self.isWritable = isWritable
        self.canonicalPath = canonicalPath
        self.freeBytes = freeBytes
        self.processAlive = processAlive
        self.isSocket = isSocket
        self.executable = executable
    }

    public static let live = DoctorProbe(
        fileExists: { path in FileManager.default.fileExists(atPath: path) },
        fileInfo: { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            return DoctorFileInfo(
                isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue
            )
        },
        isWritable: { access($0, W_OK) == 0 },
        canonicalPath: {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                .resolvingSymlinksInPath().standardizedFileURL.path
        },
        freeBytes: { path in DriveStatsCollector.freeDiskBytes(scopePath: path) },
        processAlive: { pid in
            guard pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        },
        isSocket: { path in
            var metadata = stat()
            return path.withCString { lstat($0, &metadata) } == 0 && metadata.st_mode & S_IFMT == S_IFSOCK
        },
        executable: { FileManager.default.isExecutableFile(atPath: $0) }
    )
}

public enum DoctorService {
    public static func run(
        appHome: URL = AppPaths.homeDir,
        configURL: URL = AppPaths.config,
        probe: DoctorProbe = .live
    ) -> DoctorReport {
        let inspection = ConfigStore(configURL: configURL).inspect()
        return run(
            config: inspection.config,
            scopePaths: AppPaths.ScopePaths(root: appHome),
            configValid: inspection.valid,
            configError: inspection.error,
            migrationNeeded: inspection.migrationNeeded,
            probe: probe
        )
    }

    /// Runs diagnostics from an already validated effective scope config and
    /// that scope's isolated storage. No legacy config or storage is consulted.
    public static func run(
        config: AppConfig,
        scopePaths: AppPaths.ScopePaths,
        probe: DoctorProbe = .live
    ) -> DoctorReport {
        return run(
            config: config,
            scopePaths: scopePaths,
            configValid: true,
            configError: nil,
            migrationNeeded: false,
            probe: probe
        )
    }

    private static func run(
        config: AppConfig?,
        scopePaths: AppPaths.ScopePaths,
        configValid: Bool,
        configError: String?,
        migrationNeeded: Bool,
        probe: DoctorProbe
    ) -> DoctorReport {
        var checks: [DoctorCheck] = []
        checks.append(check(
            id: "config.valid",
            passed: configValid,
            failureStatus: .failed,
            message: configValid ? "Configuration syntax is valid." : (configError ?? "Configuration is invalid."),
            remediation: "Correct config.toml, then run doctor again."
        ))
        checks.append(DoctorCheck(
            id: "config.migration",
            severity: migrationNeeded ? .warning : .info,
            status: migrationNeeded ? .warning : .passed,
            message: migrationNeeded ? "Configuration needs a non-destructive migration." : "Configuration schema is current.",
            remediation: "Start iCloud Guard once to preserve unknown keys and add current defaults."
        ))

        for (id, url) in [
            ("path.app-home", scopePaths.root),
            ("path.state", scopePaths.state.deletingLastPathComponent()),
            ("path.cache", scopePaths.root.appendingPathComponent("cache", isDirectory: true)),
        ] {
            let exists = probe.fileExists(url.path)
            let writable = exists && probe.isWritable(url.path)
            let mode = probe.fileInfo(url.path)?.permissions
            let safeMode = mode.map { $0 & 0o077 == 0 } ?? !exists
            checks.append(DoctorCheck(
                id: id,
                severity: exists && (!writable || !safeMode) ? .error : (exists ? .info : .warning),
                status: exists ? (writable && safeMode ? .passed : .failed) : .warning,
                message: exists ? (writable && safeMode ? "Directory is writable with private permissions." : "Directory is not writable or is accessible by other users.") : "Directory does not exist yet.",
                remediation: "Create the directory with mode 0700 and ensure the current user owns it."
            ))
        }

        guard let config else {
            return DoctorReport(checks: checks + [DoctorCheck(
                id: "scope.valid", severity: .error, status: .failed,
                message: "Scope checks require a valid configuration.",
                remediation: "Correct config.toml, then run doctor again."
            )])
        }
        let scope = probe.canonicalPath(config.scope.path)
        let scopeInfo = probe.fileInfo(scope)
        let scopeExists = probe.fileExists(scope)
        let isDirectory = scopeInfo?.isDirectory == true
        checks.append(check(
            id: "scope.directory",
            passed: scopeExists && isDirectory,
            failureStatus: .failed,
            message: scopeExists && isDirectory ? "Scope exists and is a directory." : "Scope is missing or is not a directory.",
            remediation: "Set scope.path to an existing iCloud Drive directory."
        ))
        let mobileDocuments = probe.canonicalPath("~/Library/Mobile Documents")
        let inMobileDocuments = scope == mobileDocuments || scope.hasPrefix(mobileDocuments + "/")
        checks.append(DoctorCheck(
            id: "scope.file-provider",
            severity: inMobileDocuments ? .info : .warning,
            status: inMobileDocuments ? .passed : .warning,
            message: inMobileDocuments ? "Scope is within Mobile Documents." : "Scope is not within the standard Mobile Documents tree.",
            remediation: "Confirm that scope.path is managed by iCloud FileProvider."
        ))
        let freeBytes = probe.freeBytes(scope)
        checks.append(DoctorCheck(
            id: "volume.free-space",
            severity: freeBytes == nil ? .error : .info,
            status: freeBytes == nil ? .unavailable : .passed,
            message: freeBytes.map { "Free-space telemetry is available (\($0) bytes)." } ?? "Free-space telemetry is unavailable.",
            remediation: "Mount the scope volume and grant iCloud Guard filesystem access."
        ))
        checks.append(lockCheck(path: scopePaths.lock.path, probe: probe))
        checks.append(contentsOf: ipcChecks(appHome: scopePaths.root, probe: probe))
        let mdutilExecutable = probe.executable("/usr/bin/mdutil")
        let qlmanageExecutable = probe.executable("/usr/bin/qlmanage")
        let suppressionToolsAvailable = mdutilExecutable && qlmanageExecutable
        checks.append(DoctorCheck(
            id: "suppression.tools",
            severity: suppressionToolsAvailable ? .info : .warning,
            status: suppressionToolsAvailable ? .passed : .unavailable,
            message: suppressionToolsAvailable ? "Spotlight and QuickLook tools are available." : "A suppression tool is unavailable.",
            remediation: "Use a supported macOS installation with mdutil and qlmanage."
        ))
        checks.append(DoctorCheck(
            id: "product.version", severity: .info, status: .passed,
            message: "iCloud Guard version \(ICloudGuardProduct.version).", remediation: "None."
        ))
        return DoctorReport(checks: checks)
    }

    private static func check(
        id: String,
        passed: Bool,
        failureStatus: DoctorStatus,
        message: String,
        remediation: String
    ) -> DoctorCheck {
        DoctorCheck(
            id: id,
            severity: passed ? .info : .error,
            status: passed ? .passed : failureStatus,
            message: message,
            remediation: remediation
        )
    }

    private static func lockCheck(path: String, probe: DoctorProbe) -> DoctorCheck {
        guard probe.fileExists(path) else {
            return DoctorCheck(id: "lock.owner", severity: .info, status: .passed, message: "No run lock exists yet.", remediation: "None.")
        }
        let owner = (try? SecureRegularFile.read(URL(fileURLWithPath: path), maximumBytes: 64).data)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let held: Bool
        do {
            held = try AdvisoryFileLock.isHeld(path: path)
        } catch {
            return DoctorCheck(
                id: "lock.owner",
                severity: .warning,
                status: .unavailable,
                message: "Run lock ownership could not be verified.",
                remediation: "Check run.lock permissions, then run doctor again."
            )
        }
        guard held else {
            return DoctorCheck(id: "lock.owner", severity: .info, status: .passed, message: "Run lock has no active advisory owner.", remediation: "None.")
        }
        let active = owner.map(probe.processAlive) ?? false
        let message = owner.map {
            active ? "Run lock advisory owner PID \($0) is active." : "Run lock is held, but owner PID \($0) is not active."
        } ?? "Run lock is held, but no owner PID is recorded."
        return DoctorCheck(
            id: "lock.owner",
            severity: .warning,
            status: .warning,
            message: message,
            remediation: "Wait for the active run to finish; remove stale state only after confirming the advisory lock is released."
        )
    }

    private static func ipcChecks(appHome: URL, probe: DoctorProbe) -> [DoctorCheck] {
        let pidURL = appHome.appendingPathComponent("icloud-guard.pid")
        let socketURL = appHome.appendingPathComponent("guard.sock")
        let tokenURL = appHome.appendingPathComponent("guard.token")
        let pid = (try? SecureRegularFile.read(pidURL, maximumBytes: 64).data)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let alive = pid.map(probe.processAlive) ?? false
        let socket = probe.fileExists(socketURL.path) && probe.isSocket(socketURL.path)
        let tokenMode = probe.fileInfo(tokenURL.path)?.permissions
        let tokenSafe = probe.fileExists(tokenURL.path) && tokenMode.map { $0 & 0o077 == 0 } == true
        let consistent = alive == socket && alive == probe.fileExists(tokenURL.path) && (!alive || tokenSafe)
        return [DoctorCheck(
            id: "ipc.consistency",
            severity: consistent ? .info : .warning,
            status: consistent ? .passed : .warning,
            message: consistent ? "PID, socket, and token state are consistent." : "PID, socket, or token state is inconsistent.",
            remediation: "Quit all iCloud Guard instances, then start one instance to recreate IPC state."
        )]
    }
}

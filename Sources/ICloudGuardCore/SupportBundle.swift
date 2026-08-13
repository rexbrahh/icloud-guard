import CryptoKit
import Darwin
import Foundation

public struct SupportBundleManifestEntry: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var bytes: Int
}

public struct SupportBundleManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var version: String
    public var redaction: String
    public var files: [SupportBundleManifestEntry]
}

public struct SupportBundleResult: Codable, Equatable, Sendable {
    public var outputPath: String
    public var manifestSHA256: String
    public var fileCount: Int
}

public final class SupportBundleService: Sendable {
    public enum BundleError: LocalizedError, Sendable {
        case invalidOutput(String)
        case malformed(String)
        case archive(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .invalidOutput(let message): return "invalid support-bundle output: \(message)"
            case .malformed(let message): return "support bundle input is malformed: \(message)"
            case .archive(let message): return "support bundle archive failed: \(message)"
            case .io(let message): return "support bundle I/O failed: \(message)"
            }
        }
    }

    private let processRunner: @Sendable (_ executable: String, _ arguments: [String]) throws -> Int32
    private let saltProvider: @Sendable () throws -> Data
    private let now: @Sendable () -> Date

    public init(
        processRunner: @escaping @Sendable (String, [String]) throws -> Int32 = { executable, arguments in
            try SupportBundleService.runProcess(executable, arguments)
        },
        saltProvider: @escaping @Sendable () throws -> Data = { try SupportBundleService.randomBytes(count: 32) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processRunner = processRunner
        self.saltProvider = saltProvider
        self.now = now
    }

    public func create(
        outputURL: URL,
        appHome: URL = AppPaths.homeDir,
        configURL: URL = AppPaths.config
    ) throws -> SupportBundleResult {
        try create(outputURL: outputURL, input: .stored(appHome: appHome, configURL: configURL))
    }

    /// Creates a bundle from an already validated effective scope config and
    /// that scope's isolated storage. No legacy config or storage is consulted.
    public func create(
        outputURL: URL,
        config: AppConfig,
        scopePaths: AppPaths.ScopePaths
    ) throws -> SupportBundleResult {
        try AppPaths.ensureScopeDir(scopePaths)
        return try create(outputURL: outputURL, input: .injected(config: config, scopePaths: scopePaths))
    }

    private enum Input {
        case stored(appHome: URL, configURL: URL)
        case injected(config: AppConfig, scopePaths: AppPaths.ScopePaths)
    }

    private func create(outputURL: URL, input: Input) throws -> SupportBundleResult {
        guard outputURL.pathExtension.lowercased() == "zip", outputURL.isFileURL else {
            throw BundleError.invalidOutput("output must be a local .zip file")
        }
        let rawComponents = outputURL.pathComponents
        let filename = outputURL.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..",
              !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw BundleError.invalidOutput("output path is not normalized")
        }

        let suppliedParent = outputURL.deletingLastPathComponent()
        let parent = suppliedParent.resolvingSymlinksInPath().standardizedFileURL
        let final = parent.appendingPathComponent(filename, isDirectory: false)
        guard final.deletingLastPathComponent() == parent else {
            throw BundleError.invalidOutput("output path is not normalized")
        }
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw BundleError.invalidOutput("output parent is not a stable directory")
        }
        defer { Darwin.close(parentDescriptor) }
        var parentIdentity = stat()
        guard fstat(parentDescriptor, &parentIdentity) == 0 else {
            throw BundleError.io("cannot inspect output parent: \(String(cString: strerror(errno)))")
        }
        let stagingParent = try Self.makePrivateStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stagingParent) }
        let stagingRoot = stagingParent.appendingPathComponent("icloud-guard-support", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let salt = try saltProvider()
        guard salt.count >= 16 else { throw BundleError.io("redaction salt is too short") }
        let config: AppConfig?
        let configValid: Bool
        let migrationNeeded: Bool
        let scopePaths: AppPaths.ScopePaths
        let doctorReport: DoctorReport
        switch input {
        case .stored(let appHome, let configURL):
            let inspection = ConfigStore(configURL: configURL).inspect()
            if inspection.exists, !inspection.valid {
                throw BundleError.malformed("configuration cannot be decoded")
            }
            config = inspection.config
            configValid = inspection.valid
            migrationNeeded = inspection.migrationNeeded
            scopePaths = AppPaths.ScopePaths(root: appHome)
            doctorReport = DoctorService.run(appHome: appHome, configURL: configURL)
        case .injected(let injectedConfig, let injectedPaths):
            config = injectedConfig
            configValid = true
            migrationNeeded = false
            scopePaths = injectedPaths
            doctorReport = DoctorService.run(config: injectedConfig, scopePaths: injectedPaths)
        }
        let scopePath = config?.scope.path ?? ""
        let redact: (String) -> String = { value in
            "hash:" + String(PrivacyIdentifier.hash(value, salt: salt).prefix(24))
        }
        var payloads: [String: Data] = [:]
        payloads["product.json"] = try jsonData([
            "schema": "1",
            "version": ICloudGuardProduct.version,
            "build": ICloudGuardProduct.build,
            "platform": "macOS",
            "bundle_id": redact("bundle"),
        ])
        payloads["doctor.json"] = try encoded(RedactedDoctor(report: doctorReport))
        payloads["config.json"] = try encoded(RedactedConfig(
            config: config,
            valid: configValid,
            migrationNeeded: migrationNeeded,
            scopeIdentifier: scopePath.isEmpty ? nil : redact(scopePath)
        ))
        let history: [GuardRunReceipt]
        do { history = try RunHistoryStore(url: scopePaths.history).load() }
        catch { throw BundleError.malformed("run history cannot be decoded") }
        payloads["history.json"] = try encoded(Array(history.suffix(50)).enumerated().map { index, receipt in
            RedactedReceipt(receipt: receipt, ordinal: index + 1, redact: redact)
        })
        let entries: [WatchlistEntry]
        do {
            entries = try WatchlistInspectionService.loadEntries(
                storageURL: scopePaths.watchlist,
                scopePath: scopePath
            )
        } catch { throw BundleError.malformed("watchlist cannot be decoded or validated") }
        payloads["watchlist.json"] = try encoded(WatchlistAggregate(
            entries: entries,
            maxFights: config?.watcher.maxFights ?? WatchlistWatcher.defaultMaxFights
        ))
        payloads["system.json"] = try jsonData([
            "schema": "1",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.architecture,
            "scope_id": scopePath.isEmpty ? "unavailable" : redact(scopePath),
            "free_space_available": scopePath.isEmpty ? "false" : String(DriveStatsCollector.freeDiskBytes(scopePath: scopePath) != nil),
        ])
        var manifestEntries: [SupportBundleManifestEntry] = []
        for name in payloads.keys.sorted() {
            guard let data = payloads[name] else { continue }
            let url = stagingRoot.appendingPathComponent(name)
            try RunHistoryStore.atomicWrite(data, to: url)
            try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            manifestEntries.append(SupportBundleManifestEntry(path: name, sha256: sha256(data), bytes: data.count))
        }
        let manifest = SupportBundleManifest(
            version: ICloudGuardProduct.version,
            redaction: "per-bundle-salted-sha256",
            files: manifestEntries
        )
        let manifestData = try encoded(manifest)
        let manifestURL = stagingRoot.appendingPathComponent("manifest.json")
        try RunHistoryStore.atomicWrite(manifestData, to: manifestURL)
        try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: manifestURL.path)
        try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: stagingRoot.path)

        let temporaryOutput = stagingParent.appendingPathComponent("bundle.zip")
        let status: Int32
        do {
            status = try processRunner("/usr/bin/ditto", ["-c", "-k", "--keepParent", stagingRoot.path, temporaryOutput.path])
        } catch {
            throw BundleError.archive("archive tool failed or timed out")
        }
        guard status == 0, FileManager.default.fileExists(atPath: temporaryOutput.path) else {
            throw BundleError.archive("ditto exited with status \(status)")
        }
        guard chmod(temporaryOutput.path, 0o600) == 0 else {
            throw BundleError.io("cannot set archive mode: \(String(cString: strerror(errno)))")
        }
        let descriptor = open(temporaryOutput.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw BundleError.io("cannot open temporary archive: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw BundleError.io("cannot synchronize archive: \(String(cString: strerror(errno)))")
        }
        do {
            try SupportBundleVerifier().verify(
                archiveURL: temporaryOutput,
                expectedManifestSHA256: sha256(manifestData)
            )
        } catch {
            throw BundleError.archive("verification failed: \(error.localizedDescription)")
        }
        let publishName = ".icloud-guard-publish-\(UUID().uuidString).zip"
        let publishDescriptor = openat(
            parentDescriptor,
            publishName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard publishDescriptor >= 0 else {
            throw BundleError.io("cannot create private output: \(String(cString: strerror(errno)))")
        }
        var published = false
        defer {
            Darwin.close(publishDescriptor)
            if !published { _ = unlinkat(parentDescriptor, publishName, 0) }
        }
        try Self.copyArchive(from: descriptor, to: publishDescriptor)
        guard fsync(publishDescriptor) == 0 else {
            throw BundleError.io("cannot synchronize private output: \(String(cString: strerror(errno)))")
        }
        var currentParentIdentity = stat()
        guard parent.path.withCString({ lstat($0, &currentParentIdentity) }) == 0,
              currentParentIdentity.st_mode & S_IFMT == S_IFDIR,
              currentParentIdentity.st_dev == parentIdentity.st_dev,
              currentParentIdentity.st_ino == parentIdentity.st_ino else {
            throw BundleError.invalidOutput("output parent changed during bundle creation")
        }
        guard renameat(parentDescriptor, publishName, parentDescriptor, filename) == 0 else {
            throw BundleError.io("cannot replace output: \(String(cString: strerror(errno)))")
        }
        published = true
        guard fsync(parentDescriptor) == 0 else {
            throw BundleError.io("cannot synchronize output directory: \(String(cString: strerror(errno)))")
        }
        return SupportBundleResult(
            outputPath: final.path,
            manifestSHA256: sha256(manifestData),
            fileCount: manifestEntries.count + 1
        )
    }

    private static func makePrivateStagingDirectory() throws -> URL {
        let templatePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(".icloud-guard-support.XXXXXX", isDirectory: true)
            .path
        var template = Array(templatePath.utf8CString)
        let createdPath: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress, let result = Darwin.mkdtemp(baseAddress) else { return nil }
            return String(cString: result)
        }
        guard let createdPath else {
            throw BundleError.io("cannot create private staging directory: \(String(cString: strerror(errno)))")
        }
        return URL(fileURLWithPath: createdPath, isDirectory: true)
    }

    private static func copyArchive(from source: Int32, to destination: Int32) throws {
        guard lseek(source, 0, SEEK_SET) == 0 else {
            throw BundleError.io("cannot rewind temporary archive: \(String(cString: strerror(errno)))")
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw BundleError.io("cannot read temporary archive: \(String(cString: strerror(errno)))")
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(destination, bytes.baseAddress?.advanced(by: offset), count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BundleError.io("cannot write private output: \(String(cString: strerror(errno)))")
                }
                guard written > 0 else { throw BundleError.io("cannot write private output") }
                offset += written
            }
        }
    }

    private struct RedactedConfig: Codable {
        var schema = 1
        var valid: Bool
        var migrationNeeded: Bool
        var scopeIdentifier: String?
        var suppression: AppConfig.SuppressionConfig?
        var eviction: AppConfig.EvictionConfig?
        var watcher: AppConfig.WatcherConfig?
        var policy: AppConfig.PolicyConfig?

        init(config: AppConfig?, valid: Bool, migrationNeeded: Bool, scopeIdentifier: String?) {
            self.valid = valid
            self.migrationNeeded = migrationNeeded
            self.scopeIdentifier = scopeIdentifier
            suppression = config?.suppression
            eviction = config?.eviction
            watcher = config?.watcher
            policy = config?.policy
        }
    }

    private struct RedactedReceipt: Codable {
        var schema: Int
        var id: String
        var startedAt: Date
        var endedAt: Date
        var trigger: GuardRunTrigger
        var command: String
        var action: GuardDecisionKind
        var dryRun: Bool
        var status: GuardRunStatus
        var exitCode: Int32
        var scopeIdentifier: String
        var plannedCount: Int
        var plannedBytes: Int64
        var verifiedCount: Int
        var verifiedBytes: Int64
        var pendingCount: Int
        var failedCount: Int

        init(receipt: GuardRunReceipt, ordinal: Int, redact: (String) -> String) {
            schema = receipt.schema
            id = "run-\(ordinal)"
            startedAt = receipt.startedAt
            endedAt = receipt.endedAt
            trigger = receipt.trigger
            let knownCommands = Set(["status", "run", "panic-evict", "explain", "trim", "panic", "preview", "folder"])
            command = knownCommands.contains(receipt.command) ? receipt.command : redact(receipt.command)
            action = receipt.action
            dryRun = receipt.dryRun
            status = receipt.status
            exitCode = receipt.exitCode
            scopeIdentifier = redact(receipt.sourceScopeIdentifier)
            plannedCount = receipt.plannedCount
            plannedBytes = receipt.plannedBytes
            verifiedCount = receipt.verifiedCount
            verifiedBytes = receipt.verifiedBytes
            pendingCount = receipt.pendingCount
            failedCount = receipt.failedCount
        }
    }

    private struct RedactedDoctor: Codable {
        struct Check: Codable {
            var id: String
            var severity: DoctorSeverity
            var status: DoctorStatus
        }
        var schema = 1
        var version: String
        var checks: [Check]

        init(report: DoctorReport) {
            version = report.version
            checks = report.checks.map { Check(id: $0.id, severity: $0.severity, status: $0.status) }
        }
    }

    private struct WatchlistAggregate: Codable {
        var schema = 1
        var total: Int
        var pending: Int
        var suspended: Int
        var fighting: Int
        var identityMismatch: Int

        init(entries: [WatchlistEntry], maxFights: Int = WatchlistWatcher.defaultMaxFights) {
            total = entries.count
            pending = entries.filter(\.pendingVerification).count
            suspended = entries.filter(\.suspended).count
            fighting = entries.filter {
                WatchlistFightPolicy.isFighting(count: $0.reEvictCount, maxFights: maxFights)
            }.count
            identityMismatch = entries.filter(\.identityMismatch).count
        }
    }

    private static var architecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    public static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw BundleError.io("cannot generate redaction salt")
        }
        return Data(bytes)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func jsonData(_ value: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func runProcess(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 30
    ) throws -> Int32 {
        try SupportBundleVerifier.runVerifierProcess(
            executable,
            arguments,
            timeoutSeconds: timeoutSeconds
        ).status
    }
}

public struct SupportBundleVerifier: Sendable {
    public enum VerificationError: LocalizedError, Equatable, Sendable {
        case invalid(String)
        public var errorDescription: String? {
            guard case .invalid(let message) = self else { return nil }
            return "invalid support bundle: \(message)"
        }
    }

    public static let maximumEntryCount = 8
    public static let maximumEntryBytes = 2 * 1024 * 1024
    public static let maximumTotalBytes = 8 * 1024 * 1024
    public static let maximumListingBytes = 64 * 1024
    public static let maximumArchiveBytes: UInt64 = 32 * 1024 * 1024

    private static let rootName = "icloud-guard-support/"
    private static let allowedFiles: Set<String> = [
        "config.json",
        "doctor.json",
        "history.json",
        "manifest.json",
        "product.json",
        "system.json",
        "watchlist.json",
    ]

    public init() {}

    public func verify(archiveURL: URL, expectedManifestSHA256: String? = nil) throws {
        guard archiveURL.isFileURL else { throw VerificationError.invalid("archive must be local") }
        let source: SecureRegularFile.Snapshot
        do { source = try SecureRegularFile.read(archiveURL, maximumBytes: Self.maximumArchiveBytes) }
        catch { throw VerificationError.invalid("archive is not a bounded regular file") }
        guard source.permissions == 0o600 else { throw VerificationError.invalid("archive mode must be 0600") }

        let privateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: privateDirectory) }
        let snapshotURL = privateDirectory.appendingPathComponent("bundle.zip")
        try source.data.write(to: snapshotURL, options: [.atomic])
        guard chmod(snapshotURL.path, 0o600) == 0 else {
            throw VerificationError.invalid("archive snapshot permissions failed")
        }

        let names = try Self.archiveNames(snapshotURL)
        let entries = try Self.archiveEntries(snapshotURL, names: names)
        let actualFiles = Set(entries.filter { !$0.isDirectory }.map(\.relativePath))
        guard actualFiles.contains("manifest.json") else { throw VerificationError.invalid("manifest is missing") }

        let extraction = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-guard-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: extraction) }
        let extractionResult = try Self.runVerifierProcess("/usr/bin/unzip", ["-qq", snapshotURL.path, "-d", extraction.path])
        guard extractionResult.status == 0, !extractionResult.overflow else {
            throw VerificationError.invalid("archive extraction failed")
        }
        let root = extraction.appendingPathComponent("icloud-guard-support", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw VerificationError.invalid("symbolic link is not allowed") }
        }
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        if let expectedManifestSHA256, Self.sha256(manifestData) != expectedManifestSHA256 {
            throw VerificationError.invalid("manifest checksum differs")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: SupportBundleManifest
        do { manifest = try decoder.decode(SupportBundleManifest.self, from: manifestData) }
        catch { throw VerificationError.invalid("manifest cannot be decoded") }
        guard manifest.schema == SupportBundleManifest.schemaVersion,
              manifest.redaction == "per-bundle-salted-sha256" else {
            throw VerificationError.invalid("manifest schema or redaction mode is unsupported")
        }
        let manifestPaths = manifest.files.map(\.path)
        guard Set(manifestPaths).count == manifestPaths.count,
              Set(manifestPaths).union(["manifest.json"]) == actualFiles else {
            throw VerificationError.invalid("manifest file set differs from archive")
        }
        for entry in manifest.files {
            guard !entry.path.contains("/"), !entry.path.contains("..") else {
                throw VerificationError.invalid("manifest path is unsafe")
            }
            let data = try Data(contentsOf: root.appendingPathComponent(entry.path))
            guard data.count == entry.bytes, Self.sha256(data) == entry.sha256 else {
                throw VerificationError.invalid("file checksum or size differs")
            }
        }
    }

    private struct ArchiveEntry {
        var relativePath: String
        var isDirectory: Bool
    }

    private static func archiveNames(_ archiveURL: URL) throws -> [String] {
        let names = try capture("/usr/bin/unzip", ["-Z1", archiveURL.path])
            .split(whereSeparator: \.isNewline).map(String.init)
        guard !names.isEmpty, names.count <= maximumEntryCount, Set(names).count == names.count else {
            throw VerificationError.invalid("archive is empty, duplicated, or too large")
        }
        for name in names {
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains(".."),
                  name == rootName || name.hasPrefix(rootName) else {
                throw VerificationError.invalid("unsafe archive path")
            }
            if name != rootName {
                let relative = String(name.dropFirst(rootName.count))
                guard allowedFiles.contains(relative), !relative.hasSuffix("/"), !relative.contains("/") else {
                    throw VerificationError.invalid("unexpected archive entry")
                }
            }
        }
        return names
    }

    private static func archiveEntries(_ archiveURL: URL, names: [String]) throws -> [ArchiveEntry] {
        let lines = try capture("/usr/bin/zipinfo", ["-l", archiveURL.path])
            .split(whereSeparator: \.isNewline).map(String.init)
        var entriesByName: [String: ArchiveEntry] = [:]
        var totalBytes = 0
        for line in lines {
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard fields.count == 10, let mode = fields.first else { continue }
            let name = String(fields[9])
            guard names.contains(name) else { continue }
            guard let bytes = Int(fields[3]) else {
                throw VerificationError.invalid("archive listing is malformed")
            }
            guard mode.first != "l" else { throw VerificationError.invalid("symbolic link is not allowed") }
            let isDirectory = name.hasSuffix("/")
            let relative = isDirectory ? "" : String(name.dropFirst(rootName.count))
            guard isDirectory == (mode.first == "d") else {
                throw VerificationError.invalid("archive entry type is inconsistent")
            }
            guard bytes <= maximumEntryBytes else {
                throw VerificationError.invalid("archive entry exceeds size limit")
            }
            totalBytes += bytes
            guard totalBytes <= maximumTotalBytes else {
                throw VerificationError.invalid("archive exceeds total size limit")
            }
            entriesByName[name] = ArchiveEntry(relativePath: relative, isDirectory: isDirectory)
        }
        guard Set(entriesByName.keys) == Set(names) else {
            throw VerificationError.invalid("archive listing is incomplete")
        }
        return names.compactMap { entriesByName[$0] }
    }

    static func capture(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 5
    ) throws -> String {
        let result = try runVerifierProcess(executable, arguments, timeoutSeconds: timeoutSeconds)
        guard !result.overflow else { throw VerificationError.invalid("archive listing exceeds size limit") }
        guard result.status == 0 else { throw VerificationError.invalid("archive listing failed") }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    struct ProcessResult: Sendable {
        var status: Int32
        var stdout: Data
        var overflow: Bool
    }

    static func runVerifierProcess(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 5
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let buffer = ProcessCaptureBuffer(limit: maximumListingBytes)
        let group = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        drain(output.fileHandleForReading, stdout: true, buffer: buffer, group: group)
        drain(error.fileHandleForReading, stdout: false, buffer: buffer, group: group)
        if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            try? output.fileHandleForWriting.close()
            try? error.fileHandleForWriting.close()
            group.wait()
            throw VerificationError.invalid("archive tool timed out")
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        group.wait()
        let result = buffer.result()
        return ProcessResult(status: process.terminationStatus, stdout: result.stdout, overflow: result.overflow)
    }

    private static func drain(
        _ handle: FileHandle,
        stdout: Bool,
        buffer: ProcessCaptureBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            while true {
                let chunk = handle.readData(ofLength: 4096)
                if chunk.isEmpty { return }
                buffer.append(chunk, stdout: stdout)
            }
        }
    }

    private final class ProcessCaptureBuffer: @unchecked Sendable {
        private let limit: Int
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var overflow = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data, stdout isStdout: Bool) {
            lock.lock()
            defer { lock.unlock() }
            var target = isStdout ? stdout : stderr
            let remaining = max(0, limit - stdout.count - stderr.count)
            if remaining > 0 { target.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { overflow = true }
            if isStdout {
                stdout = target
            } else {
                stderr = target
            }
        }

        func result() -> (stdout: Data, overflow: Bool) {
            lock.lock()
            defer { lock.unlock() }
            _ = stderr
            return (stdout, overflow)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

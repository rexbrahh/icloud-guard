import ArgumentParser
import Foundation
import ICloudGuardCore

public func runICloudGuardCLI() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let wantsJSON = arguments.contains("--json")
    if wantsJSON {
        arguments.removeAll { $0 == "--json" }
        arguments.insert("--json", at: 0)
    }
    if !arguments.contains("--help"), !arguments.contains("-h"), !arguments.contains("--version") {
        var command: any ParsableCommand
        do {
            command = try CLIEntrypoint.parseAsRoot(arguments)
        } catch {
            if wantsJSON {
                CLIOutput.jsonError(
                    command: canonicalCommandName(arguments),
                    code: "usage",
                    message: String(describing: error),
                    exitCode: CLIExitCode.usage
                )
            }
            fputs("icloud-guard: \(String(describing: error))\n", stderr)
            Foundation.exit(CLIExitCode.usage)
        }
        do {
            try command.run()
            Foundation.exit(0)
        } catch let cleanExit as CleanExit {
            CLIEntrypoint.exit(withError: cleanExit)
        } catch {
            let classified = CLIErrorClassifier.classify(error)
            if wantsJSON {
                CLIOutput.jsonError(
                    command: canonicalCommandName(arguments),
                    code: classified.code,
                    message: classified.message,
                    exitCode: classified.exitCode
                )
            }
            fputs("icloud-guard: \(classified.message)\n", stderr)
            Foundation.exit(classified.exitCode)
        }
    }
    CLIEntrypoint.main(arguments)
}

private var jsonRequested: Bool {
    CommandLine.arguments.contains("--json")
}

private func canonicalCommandName(_ arguments: [String]) -> String {
    let words = arguments.filter { !$0.hasPrefix("-") }
    guard let first = words.first else { return "icloud-guard" }
    if ["history", "config", "scope", "update"].contains(first), words.count > 1 {
        return "\(first).\(words[1])"
    }
    return first
}

public enum CLIExitCode {
    public static let success: Int32 = 0
    public static let partial: Int32 = 1
    public static let usage: Int32 = 64
    public static let data: Int32 = 65
    public static let unavailable: Int32 = 69
    public static let io: Int32 = 74
    public static let temporary: Int32 = 75
    public static let configuration: Int32 = 78
    public static let cancelled: Int32 = 130
}

public enum CLIEnvelopeStatus: String, Codable, Sendable {
    case succeeded
    case noAction = "no-action"
    case partial
    case pending
    case failed
    case cancelled
    case contended
}

public struct CLIPathResult: Codable, Equatable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct CLIRestorationItem: Codable, Equatable, Sendable {
    public var displayPath: String
    public var status: RestorationItemStatus
    public var reason: String
}

public struct CLIRestorationResult: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var sourceRunID: String?
    public var verifiedCount: Int
    public var pendingCount: Int
    public var failedCount: Int
    public var cancelled: Bool
    public var items: [CLIRestorationItem]
}

public struct CLIKeepDownloadedItem: Codable, Equatable, Sendable {
    public var displayPath: String
    public var status: KeepDownloadedStatus
    public var reason: KeepDownloadedReasonCode
    public var requestAttempts: Int
}

public struct CLIKeepDownloadedResult: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var scannedEntries: Int
    public var requestsAttempted: Int
    public var verifiedCount: Int
    public var pendingCount: Int
    public var failedCount: Int
    public var cancelled: Bool
    public var items: [CLIKeepDownloadedItem]
}

public struct CLIUpdateRelease: Codable, Equatable, Sendable {
    public var channel: UpdateChannel
    public var version: String
    public var tag: String
    public var commit: String
    public var artifactFilename: String
    public var artifactSHA256: String
    public var artifactSize: Int64

    init(_ release: UpdateRelease) {
        channel = release.channel
        version = release.version.description
        tag = release.tag
        commit = release.commit
        artifactFilename = release.artifactFilename
        artifactSHA256 = release.artifactSHA256
        artifactSize = release.artifactSize
    }
}

public struct CLIUpdateCheckResult: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var availability: String
    public var source: String
    public var checkedAt: Date
    public var currentVersion: String?
    public var release: CLIUpdateRelease?
    public var unsupportedReason: String?

    init(_ result: UpdateCheckResult) {
        source = result.source.rawValue
        checkedAt = result.checkedAt
        switch result.availability {
        case .upToDate(let current):
            availability = "up-to-date"
            currentVersion = current.description
        case .available(let candidate):
            availability = "available"
            release = CLIUpdateRelease(candidate.release)
        case .unsupported(_, let reason):
            availability = "unsupported"
            unsupportedReason = reason.rawValue
        }
    }
}

public struct CLIUpdateDownloadResult: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var release: CLIUpdateRelease
    public var verifiedArchivePath: String
    public var instructions: String

    init(_ handoff: ManualUpdateHandoff) {
        release = CLIUpdateRelease(handoff.release)
        verifiedArchivePath = handoff.verifiedArchiveURL.path
        instructions = handoff.instructions
    }
}

public enum CLIJSONPayload: Encodable {
    case status(GuardRunTelemetry)
    case run(GuardRunReceipt)
    case explain(ExplainablePreview)
    case doctor(DoctorReport)
    case historyList([GuardRunReceipt])
    case historyShow(GuardRunReceipt)
    case watchlist([WatchlistInspection])
    case file(CLIPathResult)
    case support(SupportBundleResult)
    case config(ConfigJSON)
    case scopeBrowser(ScopeBrowserReport)
    case restoration(CLIRestorationResult)
    case keepDownloaded(CLIKeepDownloadedResult)
    case scopeList([ScopeSelectionResult])
    case updateCheck(CLIUpdateCheckResult)
    case updateDownload(CLIUpdateDownloadResult)

    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let value): try container.encode("status", forKey: .type); try container.encode(value, forKey: .value)
        case .run(let value): try container.encode("run", forKey: .type); try container.encode(value, forKey: .value)
        case .explain(let value): try container.encode("explain", forKey: .type); try container.encode(value, forKey: .value)
        case .doctor(let value): try container.encode("doctor", forKey: .type); try container.encode(value, forKey: .value)
        case .historyList(let value): try container.encode("history-list", forKey: .type); try container.encode(value, forKey: .value)
        case .historyShow(let value): try container.encode("history-show", forKey: .type); try container.encode(value, forKey: .value)
        case .watchlist(let value): try container.encode("watchlist", forKey: .type); try container.encode(value, forKey: .value)
        case .file(let value): try container.encode("file", forKey: .type); try container.encode(value, forKey: .value)
        case .support(let value): try container.encode("support-bundle", forKey: .type); try container.encode(value, forKey: .value)
        case .config(let value): try container.encode("config", forKey: .type); try container.encode(value, forKey: .value)
        case .scopeBrowser(let value): try container.encode("scope-browser", forKey: .type); try container.encode(value, forKey: .value)
        case .restoration(let value): try container.encode("restoration", forKey: .type); try container.encode(value, forKey: .value)
        case .keepDownloaded(let value): try container.encode("keep-downloaded", forKey: .type); try container.encode(value, forKey: .value)
        case .scopeList(let value): try container.encode("scope-list", forKey: .type); try container.encode(value, forKey: .value)
        case .updateCheck(let value): try container.encode("update-check", forKey: .type); try container.encode(value, forKey: .value)
        case .updateDownload(let value): try container.encode("update-download", forKey: .type); try container.encode(value, forKey: .value)
        }
    }
}

public struct CLIJSONEnvelope: Encodable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var requestID: String
    public var command: String
    public var runID: String?
    public var exitCode: Int32
    public var status: CLIEnvelopeStatus
    public var payload: CLIJSONPayload?
    public var error: CLIJSONError?

    private enum CodingKeys: String, CodingKey {
        case schema
        case requestID = "request_id"
        case command
        case runID = "run_id"
        case exitCode = "exit_code"
        case status
        case payload
        case error
    }

    public init(
        requestID: String,
        command: String,
        runID: String? = nil,
        exitCode: Int32,
        status: CLIEnvelopeStatus,
        payload: CLIJSONPayload? = nil,
        error: CLIJSONError? = nil
    ) {
        self.requestID = requestID
        self.command = command
        self.runID = runID
        self.exitCode = exitCode
        self.status = status
        self.payload = payload
        self.error = error
    }
}

public struct CLIJSONError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
}

struct CLIExecutionError: LocalizedError {
    var code: String
    var message: String
    var exitCode: Int32
    var errorDescription: String? { message }
}

enum CLIErrorClassifier {
    static func classify(_ error: Error) -> CLIExecutionError {
        if let error = error as? CLIExecutionError { return error }
        if error is ValidationError {
            return CLIExecutionError(code: "usage", message: error.localizedDescription, exitCode: CLIExitCode.usage)
        }
        if let error = error as? ConfigStore.ConfigError {
            return CLIExecutionError(code: "configuration", message: error.localizedDescription, exitCode: CLIExitCode.configuration)
        }
        if let error = error as? MultiScopeError {
            return CLIExecutionError(code: "configuration", message: error.localizedDescription, exitCode: CLIExitCode.configuration)
        }
        if let error = error as? AppPaths.ScopeDirectoryError {
            return CLIExecutionError(code: "configuration", message: error.localizedDescription, exitCode: CLIExitCode.configuration)
        }
        if let error = error as? AppConfig.UpdatesConfig.ValidationError {
            return CLIExecutionError(code: "configuration", message: error.localizedDescription, exitCode: CLIExitCode.configuration)
        }
        if let error = error as? UpdaterError {
            switch error {
            case .invalidConfiguration:
                return CLIExecutionError(code: "configuration", message: error.localizedDescription, exitCode: CLIExitCode.configuration)
            case .operationInProgress, .backoffActive, .candidateExpired:
                return CLIExecutionError(code: "temporary", message: error.localizedDescription, exitCode: CLIExitCode.temporary)
            case .temporaryStorageUnavailable:
                return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
            case .transportFailed, .responseRejected:
                return CLIExecutionError(code: "unavailable", message: error.localizedDescription, exitCode: CLIExitCode.unavailable)
            case .feedMalformed, .feedAuthenticationFailed, .feedExpired, .releaseMetadataRejected,
                 .artifactIntegrityFailed, .artifactVerificationFailed:
                return CLIExecutionError(code: "malformed-data", message: error.localizedDescription, exitCode: CLIExitCode.data)
            }
        }
        if let error = error as? RunHistoryStore.HistoryError {
            switch error {
            case .corrupt: return CLIExecutionError(code: "malformed-data", message: error.localizedDescription, exitCode: CLIExitCode.data)
            case .io: return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
            }
        }
        if let error = error as? RecoveryJournalStore.JournalError {
            switch error {
            case .corrupt: return CLIExecutionError(code: "malformed-data", message: error.localizedDescription, exitCode: CLIExitCode.data)
            case .invalidMutation, .io: return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
            }
        }
        if let error = error as? RestorationService.RestorationError {
            switch error {
            case .contention: return CLIExecutionError(code: "contention", message: error.localizedDescription, exitCode: CLIExitCode.temporary)
            case .lock: return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
            }
        }
        if let error = error as? KeepDownloadedOperationError {
            switch error {
            case .contention: return CLIExecutionError(code: "contention", message: error.localizedDescription, exitCode: CLIExitCode.temporary)
            case .lockFailed: return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
            }
        }
        if let error = error as? WatchlistInspectionService.InspectionError {
            switch error {
            case .corrupt: return CLIExecutionError(code: "malformed-data", message: error.localizedDescription, exitCode: CLIExitCode.data)
            case .unreadable: return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
            }
        }
        if let error = error as? SupportBundleService.BundleError {
            switch error {
            case .invalidOutput: return CLIExecutionError(code: "usage", message: error.localizedDescription, exitCode: CLIExitCode.usage)
            case .malformed: return CLIExecutionError(code: "malformed-data", message: error.localizedDescription, exitCode: CLIExitCode.data)
            case .archive, .io: return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
            }
        }
        if let error = error as? GuardError {
            switch error {
            case .usage(let message): return CLIExecutionError(code: "usage", message: message, exitCode: CLIExitCode.usage)
            case .lockUnavailable(let message): return CLIExecutionError(code: "contention", message: message, exitCode: CLIExitCode.temporary)
            case .runtime(let message): return CLIExecutionError(code: "unavailable", message: message, exitCode: CLIExitCode.unavailable)
            }
        }
        if error is CancellationError {
            return CLIExecutionError(code: "cancelled", message: "operation cancelled", exitCode: CLIExitCode.cancelled)
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain || cocoa.domain == NSPOSIXErrorDomain {
            return CLIExecutionError(code: "io", message: error.localizedDescription, exitCode: CLIExitCode.io)
        }
        return CLIExecutionError(code: "unavailable", message: error.localizedDescription, exitCode: CLIExitCode.unavailable)
    }
}

private enum CLIOutput {
    static func json(
        command: String,
        payload: CLIJSONPayload,
        runID: String? = nil,
        exitCode: Int32 = 0,
        status: CLIEnvelopeStatus? = nil,
        requestID: String = UUID().uuidString.lowercased()
    ) -> Never {
        emit(CLIJSONEnvelope(
            requestID: requestID,
            command: command,
            runID: runID,
            exitCode: exitCode,
            status: status ?? (exitCode == 0 ? .succeeded : .failed),
            payload: payload
        ))
        Foundation.exit(exitCode)
    }

    static func jsonError(command: String, code: String, message: String, exitCode: Int32) -> Never {
        emit(CLIJSONEnvelope(
            requestID: UUID().uuidString.lowercased(),
            command: command,
            exitCode: exitCode,
            status: exitCode == CLIExitCode.cancelled ? .cancelled : (exitCode == CLIExitCode.temporary ? .contended : .failed),
            error: CLIJSONError(code: code, message: message)
        ))
        Foundation.exit(exitCode)
    }

    static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            fputs("icloud-guard: JSON encoding failed\n", stderr)
            return
        }
        FileHandle.standardOutput.write(data + Data([UInt8(ascii: "\n")]))
    }
}

private func envelopeStatus(for receipt: GuardRunReceipt) -> CLIEnvelopeStatus {
    switch receipt.status {
    case .succeeded: return .succeeded
    case .noAction: return .noAction
    case .partial: return .partial
    case .pending: return .pending
    case .failed: return .failed
    case .cancelled: return .cancelled
    case .contended: return .contended
    }
}

private enum TerminalDisplay {
    static func sanitize(_ value: String) -> String {
        ReceiptPrivacy.terminalSafe(value)
    }
}

private func selectedScope(_ selector: String?, config: AppConfig? = nil) throws -> ManagedScopeContext? {
    let config = try config ?? ConfigStore().loadValidated()
    let catalog = try MultiScopeCatalog(config: config)
    if let selector {
        let context = try catalog.context(for: ScopeSelector(selector))
        try AppPaths.ensureScopeDir(context.paths)
        return context
    }
    guard config.scopes != nil else { return nil }
    guard catalog.contexts.count == 1 else {
        throw CLIExecutionError(
            code: "scope-required",
            message: "multiple scopes are configured; select one with --scope",
            exitCode: CLIExitCode.usage
        )
    }
    let context = catalog.contexts[0]
    try AppPaths.ensureScopeDir(context.paths)
    return context
}

private func effectiveConfig(for selected: ManagedScopeContext, global: AppConfig) -> AppConfig {
    AppConfig(
        suppression: global.suppression,
        eviction: selected.config.eviction,
        watcher: selected.config.watcher,
        scope: selected.config.scope,
        policy: selected.config.policy,
        notifications: global.notifications,
        energy: global.energy,
        updates: global.updates
    )
}

private struct ScopedOperationSelection {
    var context: ManagedScopeContext
    var config: AppConfig
}

private func scopedOperationSelection(
    _ selector: String?,
    migrating: Bool = false
) throws -> ScopedOperationSelection? {
    let store = ConfigStore()
    let global: AppConfig
    if migrating {
        global = try store.loadMigratingValidated()
    } else {
        global = try store.loadValidated()
    }
    guard let context = try selectedScope(selector, config: global) else { return nil }
    return ScopedOperationSelection(context: context, config: effectiveConfig(for: context, global: global))
}

private func runScopedMutation(
    _ selected: ScopedOperationSelection,
    command: GuardCommand,
    dryRun: Bool,
    reclaimGoalBytes: Int64? = nil,
    receiptCommand: String,
    requestedAction: String
) throws -> Never {
    try AppPaths.ensureScopeDir(selected.context.paths)
    let result = try GuardRunner().runResult(
        command: command,
        config: selected.config,
        scopePaths: selected.context.paths,
        dryRun: dryRun,
        reclaimGoalBytes: reclaimGoalBytes,
        quiet: jsonRequested,
        receiptCommand: receiptCommand,
        requestedAction: requestedAction
    )
    if jsonRequested {
        let receipt = try requireReceipt(result.receipt)
        CLIOutput.json(
            command: receiptCommand,
            payload: .run(receipt),
            runID: receipt.id,
            exitCode: result.exitCode,
            status: envelopeStatus(for: receipt)
        )
    }
    Foundation.exit(result.exitCode)
}

private final class CLIAsyncResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private func waitForAsync<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = CLIAsyncResultBox<Value>()
    Task.detached {
        do { box.store(.success(try await operation())) }
        catch { box.store(.failure(error)) }
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.load() else {
        throw CLIExecutionError(code: "unavailable", message: "asynchronous operation did not complete", exitCode: CLIExitCode.unavailable)
    }
    return try result.get()
}

struct CLIEntrypoint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icloud-guard",
        abstract: "Protect local storage from iCloud Drive rematerialization",
        version: ICloudGuardProduct.version,
        subcommands: [Status.self, Evict.self, PanicEvict.self, Reclaim.self, Explain.self, Doctor.self, History.self, Watchlist.self, Scope.self, RestoreLast.self, KeepDownloaded.self, SupportBundle.self, Config.self, Update.self]
    )

    @Flag(name: .long, help: "Emit one versioned JSON document")
    var json = false

    func run() throws {
        throw ValidationError("a subcommand is required; run 'icloud-guard --help' for usage")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show iCloud Guard status")
    @Flag(help: "Show what would happen without making changes") var dryRun = false
    @Option(help: "Scope ID or name") var scope: String?

    func run() throws {
        if let selected = try selectedScope(scope) {
            let stats = try DriveStatsCollector.collect(scopePath: selected.config.scope.path)
            if jsonRequested {
                CLIOutput.json(command: "status", payload: .status(GuardRunTelemetry(stats)), exitCode: stats.scanComplete ? 0 : CLIExitCode.data)
            }
            print("Scope: \(TerminalDisplay.sanitize(selected.config.name)) [\(selected.config.id)]")
            print("Local: \(formatBytes(stats.materializedBytes))")
            print("Free: \(stats.freeSpaceAvailable ? formatBytes(stats.freeBytes) : "unavailable")")
            Foundation.exit(stats.scanComplete ? 0 : CLIExitCode.data)
        }
        if jsonRequested {
            do {
                let result = try IPCClient().send(command: .status, dryRun: dryRun)
                if let telemetry = result.telemetry {
                    CLIOutput.json(
                        command: "status",
                        payload: .status(telemetry),
                        exitCode: Int32(clamping: result.exitCode)
                    )
                }
            } catch let error as IPCClient.IPCError where error.allowsLocalFallback {
            } catch {
                throw CLIExecutionError(code: "ipc-unavailable", message: error.localizedDescription, exitCode: CLIExitCode.unavailable)
            }
            let config = try ConfigStore().loadValidated()
            let stats = try DriveStatsCollector.collect(scopePath: config.scope.path)
            CLIOutput.json(
                command: "status",
                payload: .status(GuardRunTelemetry(stats)),
                exitCode: stats.scanComplete ? 0 : CLIExitCode.data
            )
        }
        let client = IPCClient()
        do {
            let result = try client.send(command: .status, dryRun: dryRun)
            if result.exitCode == 0 {
                print(result.output)
                Foundation.exit(0)
            }
        } catch let error as IPCClient.IPCError where error.allowsLocalFallback {
        } catch {
            fputs("icloud-guard: status IPC failed: \(error)\n", stderr)
        }
        Foundation.exit(try GuardRunner().run(command: .status, configPath: nil, dryRun: dryRun))
    }
}

struct Evict: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "evict", abstract: "Evict eligible local copies")
    @Flag(help: "Show what would happen without evicting") var dryRun = false
    @Option(help: "Scope ID or name") var scope: String?

    func run() throws {
        if let selected = try scopedOperationSelection(scope, migrating: true) {
            try runScopedMutation(selected, command: .run, dryRun: dryRun, receiptCommand: "evict", requestedAction: "evict")
        }
        let client = IPCClient()
        do {
            let result = try client.send(command: .evict, dryRun: dryRun)
            if jsonRequested {
                guard let receipt = result.receipt else {
                    if result.exitCode == Int(CLIExitCode.io) {
                        throw CLIExecutionError(code: "io", message: "current run receipt was not persisted", exitCode: CLIExitCode.io)
                    }
                    throw CLIExecutionError(
                        code: "structured-ipc-unavailable",
                        message: "running app did not return a structured run receipt",
                        exitCode: CLIExitCode.unavailable
                    )
                }
                CLIOutput.json(
                    command: "evict",
                    payload: .run(receipt),
                    runID: receipt.id,
                    exitCode: Int32(clamping: result.exitCode),
                    status: envelopeStatus(for: receipt)
                )
            }
            print(result.output)
            Foundation.exit(Int32(clamping: result.exitCode))
        } catch let error as IPCClient.IPCError where error.allowsLocalFallback {
        } catch let error as CLIExecutionError {
            throw error
        } catch {
            if jsonRequested { CLIOutput.jsonError(command: "evict", code: "ambiguous", message: "GUI accepted the request but the result is unknown", exitCode: CLIExitCode.temporary) }
            throw CLIExecutionError(code: "ambiguous", message: "GUI accepted the eviction request but its result is unknown; local fallback was not run (\(error))", exitCode: CLIExitCode.temporary)
        }
        let result = try GuardRunner().runResult(command: .run, configPath: nil, dryRun: dryRun, quiet: jsonRequested)
        if jsonRequested {
            let receipt = try requireReceipt(result.receipt)
            CLIOutput.json(
                command: "evict",
                payload: .run(receipt),
                runID: receipt.id,
                exitCode: result.exitCode,
                status: envelopeStatus(for: receipt)
            )
        }
        Foundation.exit(result.exitCode)
    }
}

struct PanicEvict: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "panic-evict", abstract: "Evict all eligible local copies up to the panic limit")
    @Flag(help: "Show what would happen without evicting") var dryRun = false
    @Option(help: "Scope ID or name") var scope: String?

    func run() throws {
        if let selected = try scopedOperationSelection(scope, migrating: true) {
            try runScopedMutation(selected, command: .panicEvict, dryRun: dryRun, receiptCommand: "panic-evict", requestedAction: "panic-evict")
        }
        let client = IPCClient()
        do {
            let result = try client.send(command: .panicEvict, dryRun: dryRun)
            if jsonRequested {
                guard let receipt = result.receipt else {
                    if result.exitCode == Int(CLIExitCode.io) {
                        throw CLIExecutionError(code: "io", message: "current run receipt was not persisted", exitCode: CLIExitCode.io)
                    }
                    throw CLIExecutionError(code: "structured-ipc-unavailable", message: "running app did not return a structured run receipt", exitCode: CLIExitCode.unavailable)
                }
                CLIOutput.json(
                    command: "panic-evict",
                    payload: .run(receipt),
                    runID: receipt.id,
                    exitCode: Int32(clamping: result.exitCode),
                    status: envelopeStatus(for: receipt)
                )
            }
            print(result.output)
            Foundation.exit(Int32(clamping: result.exitCode))
        } catch let error as IPCClient.IPCError where error.allowsLocalFallback {
        } catch let error as CLIExecutionError {
            throw error
        } catch {
            if jsonRequested { CLIOutput.jsonError(command: "panic-evict", code: "ambiguous", message: "GUI accepted the request but the result is unknown", exitCode: CLIExitCode.temporary) }
            throw CLIExecutionError(code: "ambiguous", message: "GUI accepted the panic eviction request but its result is unknown; local fallback was not run (\(error))", exitCode: CLIExitCode.temporary)
        }
        let result = try GuardRunner().runResult(command: .panicEvict, configPath: nil, dryRun: dryRun, quiet: jsonRequested)
        if jsonRequested {
            let receipt = try requireReceipt(result.receipt)
            CLIOutput.json(command: "panic-evict", payload: .run(receipt), runID: receipt.id, exitCode: result.exitCode, status: envelopeStatus(for: receipt))
        }
        Foundation.exit(result.exitCode)
    }
}

struct Reclaim: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reclaim", abstract: "Reclaim an exact byte goal")
    @Argument(help: "Byte goal, for example 5GiB or 750MB") var goal: String
    @Flag(help: "Show the plan without evicting") var dryRun = false
    @Option(help: "Scope ID or name") var scope: String?

    func validate() throws {
        guard HumanByteCount.parse(goal) != nil else { throw ValidationError("goal must be a positive byte count such as 5GiB") }
    }

    func run() throws {
        guard let bytes = HumanByteCount.parse(goal) else { throw ValidationError("invalid reclaim goal") }
        if let selected = try scopedOperationSelection(scope, migrating: true) {
            try runScopedMutation(
                selected,
                command: .run,
                dryRun: dryRun,
                reclaimGoalBytes: bytes,
                receiptCommand: "reclaim",
                requestedAction: "reclaim"
            )
        }
        let result = try GuardRunner().runResult(
            command: .run,
            configPath: nil,
            dryRun: dryRun,
            reclaimGoalBytes: bytes,
            quiet: jsonRequested,
            receiptCommand: "reclaim",
            requestedAction: "reclaim"
        )
        if jsonRequested {
            let receipt = try requireReceipt(result.receipt)
            CLIOutput.json(command: "reclaim", payload: .run(receipt), runID: receipt.id, exitCode: result.exitCode, status: envelopeStatus(for: receipt))
        }
        Foundation.exit(result.exitCode)
    }
}

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "explain", abstract: "Explain the current dry-run plan")
    @Flag(help: "Explain panic eviction") var panic = false
    @Option(help: "Scope ID or name") var scope: String?

    func run() throws {
        let preview: ExplainablePreview
        if let selected = try scopedOperationSelection(scope) {
            preview = try ExplainablePreviewService().run(
                config: selected.config,
                appHome: selected.context.paths.root,
                command: panic ? .panicEvict : .run
            )
        } else {
            preview = try ExplainablePreviewService().run(command: panic ? .panicEvict : .run)
        }
        if jsonRequested { CLIOutput.json(command: "explain", payload: .explain(preview), runID: preview.runID, exitCode: preview.scan.scanComplete ? 0 : CLIExitCode.data) }
        print("Action: \(preview.action.rawValue)")
        print("Reason: \(preview.reason)")
        print("Target: \(formatBytes(preview.targetBytes))")
        print("Planned: \(preview.plannedCount) item(s), \(formatBytes(preview.plannedBytes))")
        for candidate in preview.candidates.prefix(20) {
            print("  \(candidate.displayPath) (\(formatBytes(candidate.bytes)))")
        }
        if preview.candidates.count > 20 {
            print("  … and \(preview.candidates.count - 20) more")
        }
        for warning in preview.warnings { print("Warning: \(warning)") }
        for (reason, count) in preview.exclusions.sorted(by: { $0.key < $1.key }) where count > 0 {
            print("Excluded \(reason): \(count)")
        }
        Foundation.exit(preview.scan.scanComplete ? 0 : CLIExitCode.data)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Run read-only diagnostics")
    @Option(help: "Scope ID or name") var scope: String?

    func run() throws {
        let report: DoctorReport
        if let selected = try scopedOperationSelection(scope) {
            report = DoctorService.run(config: selected.config, scopePaths: selected.context.paths)
        } else {
            report = DoctorService.run()
        }
        if jsonRequested { CLIOutput.json(command: "doctor", payload: .doctor(report), exitCode: report.exitCode) }
        for check in report.checks {
            print("[\(check.status.rawValue)] \(check.id): \(check.message)")
            if check.status != .passed { print("  Fix: \(check.remediation)") }
        }
        Foundation.exit(report.exitCode)
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "Inspect verified run receipts", subcommands: [HistoryList.self, HistoryShow.self, HistoryExport.self])
    func run() throws { throw ValidationError("a history subcommand is required; run 'icloud-guard history --help' for usage") }
}

struct HistoryList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent receipts")
    @Option(name: .shortAndLong, help: "Maximum receipts") var limit = 20
    @Option(help: "Filter by status") var status: GuardRunStatus?
    @Option(help: "Scope ID or name") var scope: String?

    func validate() throws { if !(1...500).contains(limit) { throw ValidationError("limit must be in 1...500") } }
    func run() throws {
        let selected = try selectedScope(scope)
        var receipts = try RunHistoryStore(url: selected?.paths.history ?? AppPaths.history).load()
        if let status { receipts = receipts.filter { $0.status == status } }
        receipts = Array(receipts.suffix(limit).reversed())
        if jsonRequested { CLIOutput.json(command: "history.list", payload: .historyList(receipts)) }
        let formatter = ISO8601DateFormatter()
        for receipt in receipts {
            print("\(TerminalDisplay.sanitize(receipt.id)) \(formatter.string(from: receipt.endedAt)) \(receipt.status.rawValue) \(TerminalDisplay.sanitize(receipt.command)) verified=\(formatBytes(receipt.verifiedBytes))")
        }
    }
}

extension GuardRunStatus: ExpressibleByArgument {}

struct HistoryShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one receipt")
    @Argument(help: "Receipt run ID") var id: String
    @Option(help: "Scope ID or name") var scope: String?
    func run() throws {
        let selected = try selectedScope(scope)
        guard let receipt = try RunHistoryStore(url: selected?.paths.history ?? AppPaths.history).receipt(id: id) else {
            throw CLIExecutionError(code: "not-found", message: "receipt not found", exitCode: CLIExitCode.data)
        }
        if jsonRequested { CLIOutput.json(command: "history.show", payload: .historyShow(receipt), runID: receipt.id) }
        print("Run: \(TerminalDisplay.sanitize(receipt.id))")
        print("Status: \(receipt.status.rawValue) (exit \(receipt.exitCode))")
        print("Command: \(TerminalDisplay.sanitize(receipt.command))\(receipt.dryRun ? " (dry run)" : "")")
        print("Requested: \(TerminalDisplay.sanitize(receipt.requestedAction))")
        print("Reason: \(TerminalDisplay.sanitize(receipt.reason))")
        print("Planned: \(receipt.plannedCount) item(s), \(formatBytes(receipt.plannedBytes))")
        print("Verified: \(receipt.verifiedCount) item(s), \(formatBytes(receipt.verifiedBytes))")
        print("Pending: \(receipt.pendingCount) item(s), \(formatBytes(receipt.pendingBytes))")
        print("Failed: \(receipt.failedCount) item(s), \(formatBytes(receipt.failedBytes))")
    }
}

private func requireReceipt(_ receipt: GuardRunReceipt?) throws -> GuardRunReceipt {
    guard let receipt else {
        throw CLIExecutionError(code: "receipt-unavailable", message: "current run receipt was not persisted", exitCode: CLIExitCode.io)
    }
    return receipt
}

struct HistoryExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export deterministic RFC4180 CSV")
    @Argument(help: "Output CSV path") var output: String
    @Flag(help: "Include receipt reason text") var revealReasons = false
    @Option(help: "Scope ID or name") var scope: String?
    func run() throws {
        let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        let selected = try selectedScope(scope)
        try RunHistoryStore(url: selected?.paths.history ?? AppPaths.history).exportCSV(to: url, privacyMode: !revealReasons)
        if jsonRequested { CLIOutput.json(command: "history.export", payload: .file(CLIPathResult(path: url.path))) }
        print(url.path)
    }
}

struct Watchlist: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watchlist", abstract: "Inspect pending, retrying, and fighting paths")
    @Flag(help: "Show scope-relative paths instead of hashes") var revealPaths = false
    @Option(help: "Scope ID or name") var scope: String?
    func run() throws {
        let config = try ConfigStore().loadValidated()
        let selected = try selectedScope(scope, config: config)
        let scopePath = selected?.config.scope.path ?? config.scope.path
        let entries = try WatchlistInspectionService.load(
            storageURL: selected?.paths.watchlist ?? AppPaths.watchlist,
            scopePath: scopePath,
            revealPaths: revealPaths,
            maxFights: selected?.config.watcher.maxFights ?? config.watcher.maxFights
        )
        if jsonRequested { CLIOutput.json(command: "watchlist", payload: .watchlist(entries)) }
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            let next = entry.nextRetryAt.map(formatter.string) ?? "none"
            print("\(entry.state.rawValue) \(TerminalDisplay.sanitize(entry.displayPath)) fights=\(entry.fightCount) retries=\(entry.retryCount) next=\(next)")
        }
    }
}

struct Scope: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scope", abstract: "Inspect configured iCloud scopes", subcommands: [ScopeList.self, ScopeBrowse.self])
    func run() throws { throw ValidationError("a scope subcommand is required; run 'icloud-guard scope --help' for usage") }
}

struct ScopeList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List configured scopes without revealing paths")

    func run() throws {
        let selections = try MultiScopeCatalog(config: ConfigStore().loadValidated()).selections
        if jsonRequested { CLIOutput.json(command: "scope.list", payload: .scopeList(selections)) }
        for selection in selections {
            print("\(selection.id)\t\(TerminalDisplay.sanitize(selection.name))\t\(selection.scopeIdentifier)")
        }
    }
}

struct ScopeBrowse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "browse", abstract: "Browse read-only iCloud scope metadata")
    @Flag(help: "Show scope-relative paths instead of hashes") var revealPaths = false
    @Option(name: .shortAndLong, help: "Maximum metadata rows") var limit = 2_000
    @Option(help: "Scope ID or name") var scope: String?

    func validate() throws {
        guard (1...10_000).contains(limit) else { throw ValidationError("limit must be in 1...10000") }
    }

    func run() throws {
        let report: ScopeBrowserReport
        if let selected = try scopedOperationSelection(scope) {
            report = try ScopeBrowserService().browse(
                config: selected.config,
                revealPaths: revealPaths,
                limit: limit
            )
        } else {
            report = try ScopeBrowserService().browse(revealPaths: revealPaths, limit: limit)
        }
        let exitCode = report.scanComplete || report.truncated ? CLIExitCode.success : CLIExitCode.data
        if jsonRequested { CLIOutput.json(command: "scope.browse", payload: .scopeBrowser(report), exitCode: exitCode) }
        for row in report.rows {
            print("\(TerminalDisplay.sanitize(row.displayPath)) \(row.kind.rawValue) \(row.residency.rawValue) \(row.policy.rawValue) \(row.allocatedBytes)")
        }
        if report.truncated { print("Result bounded at \(report.rows.count) entries") }
        Foundation.exit(exitCode)
    }
}

struct RestoreLast: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore-last", abstract: "Restore the last verified eviction run locally")
    @Flag(help: "Show scope-relative paths instead of hashes") var revealPaths = false
    @Option(help: "Scope ID or name") var scope: String?

    func run() throws {
        let config = try ConfigStore().loadValidated()
        let selected = try selectedScope(scope, config: config)
        if let selected { try AppPaths.ensureScopeDir(selected.paths) }
        let execution = try RestorationOperations.restoreLastRun(
            appHomeURL: selected?.paths.root ?? AppPaths.homeDir,
            scopePath: selected?.config.scope.path ?? config.scope.path,
            trigger: .cli
        )
        let result = execution.result
        let payload = CLIRestorationResult(
            sourceRunID: result.runID,
            verifiedCount: result.verifiedCount,
            pendingCount: result.pendingCount,
            failedCount: result.failedCount,
            cancelled: result.cancelled,
            items: result.items.map {
                CLIRestorationItem(
                    displayPath: revealPaths ? $0.relativePath : "path:\(PrivacyIdentifier.hash($0.relativePath).prefix(24))",
                    status: $0.status,
                    reason: $0.reason
                )
            }
        )
        let receipt = execution.receipt
        if jsonRequested {
            CLIOutput.json(
                command: "restore-last",
                payload: .restoration(payload),
                runID: receipt.id,
                exitCode: receipt.exitCode,
                status: envelopeStatus(for: receipt)
            )
        }
        print("Restore: \(result.verifiedCount) local, \(result.pendingCount) pending, \(result.failedCount) failed")
        for item in payload.items {
            print("\(item.status.rawValue) \(TerminalDisplay.sanitize(item.displayPath)) \(TerminalDisplay.sanitize(item.reason))")
        }
        Foundation.exit(receipt.exitCode)
    }
}

struct KeepDownloaded: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keep-downloaded", abstract: "Enforce configured keep-downloaded rules")
    @Flag(help: "Show scope-relative paths instead of hashes") var revealPaths = false
    @Option(help: "Scope ID or name") var scope: String?

    func run() throws {
        let config = try ConfigStore().loadValidated()
        let selected = try selectedScope(scope, config: config)
        if let selected { try AppPaths.ensureScopeDir(selected.paths) }
        let execution = try KeepDownloadedOperations.enforce(
            appHomeURL: selected?.paths.root ?? AppPaths.homeDir,
            scopePath: selected?.config.scope.path ?? config.scope.path,
            patterns: selected?.config.scope.keepDownloadedPaths ?? config.scope.keepDownloadedPaths,
            trigger: .cli
        )
        let outcome = execution.outcome
        let payload = CLIKeepDownloadedResult(
            scannedEntries: outcome.scannedEntries,
            requestsAttempted: outcome.requestsAttempted,
            verifiedCount: outcome.verifiedCount,
            pendingCount: outcome.pendingCount,
            failedCount: outcome.failedCount,
            cancelled: outcome.cancelled,
            items: outcome.items.map {
                CLIKeepDownloadedItem(
                    displayPath: revealPaths ? $0.relativePath : "path:\(PrivacyIdentifier.hash($0.relativePath).prefix(24))",
                    status: $0.status,
                    reason: $0.reason,
                    requestAttempts: $0.requestAttempts
                )
            }
        )
        let receipt = execution.receipt
        if jsonRequested {
            CLIOutput.json(
                command: "keep-downloaded",
                payload: .keepDownloaded(payload),
                runID: receipt.id,
                exitCode: receipt.exitCode,
                status: envelopeStatus(for: receipt)
            )
        }
        print("Keep downloaded: \(outcome.verifiedCount) local, \(outcome.pendingCount) pending, \(outcome.failedCount) failed")
        for item in payload.items {
            print("\(item.status.rawValue) \(TerminalDisplay.sanitize(item.displayPath)) \(item.reason.rawValue)")
        }
        Foundation.exit(receipt.exitCode)
    }
}

struct SupportBundle: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "support-bundle", abstract: "Create a privacy-redacted local support ZIP")
    @Argument(help: "Output .zip path") var output: String
    @Option(help: "Scope ID or name") var scope: String?
    func run() throws {
        let outputURL = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        let result: SupportBundleResult
        if let selected = try scopedOperationSelection(scope) {
            result = try SupportBundleService().create(
                outputURL: outputURL,
                config: selected.config,
                scopePaths: selected.context.paths
            )
        } else {
            result = try SupportBundleService().create(outputURL: outputURL)
        }
        if jsonRequested { CLIOutput.json(command: "support-bundle", payload: .support(result)) }
        print("Created \(result.outputPath)")
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Configuration commands", subcommands: [ConfigShow.self])
    func run() throws { throw ValidationError("a config subcommand is required; run 'icloud-guard config --help' for usage") }
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show current config")
    func run() throws {
        let inspection = ConfigStore().inspect()
        if jsonRequested { CLIOutput.json(command: "config.show", payload: .config(ConfigJSON(inspection: inspection)), exitCode: inspection.valid ? 0 : CLIExitCode.configuration) }
        if let content = inspection.source {
            print(content)
        } else if inspection.exists {
            print("# \(inspection.error ?? "Config file is invalid.")")
        } else {
            print("# Config file not found at \(AppPaths.config.path)")
            print("# Run the app once to create the default configuration.")
        }
        Foundation.exit(inspection.valid ? 0 : CLIExitCode.configuration)
    }
}

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check or download a verified update for manual installation",
        subcommands: [UpdateCheck.self, UpdateDownload.self]
    )

    func run() throws {
        throw ValidationError("an update subcommand is required; run 'icloud-guard update --help' for usage")
    }
}

struct UpdateCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Authenticate update metadata without downloading an app archive"
    )

    func run() throws {
        let configuration = try cliUpdaterConfiguration()
        let result = try waitForAsync {
            try await VerifiedReleaseUpdater(configuration: configuration).check()
        }
        let payload = CLIUpdateCheckResult(result)
        if jsonRequested {
            CLIOutput.json(
                command: "update.check",
                payload: .updateCheck(payload),
                status: payload.availability == "up-to-date" ? .noAction : .succeeded
            )
        }
        printUpdateCheck(payload)
    }
}

private struct CLIUpdateDownloadExecution: Sendable {
    var check: UpdateCheckResult
    var handoff: ManualUpdateHandoff?
}

struct UpdateDownload: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Authenticate metadata, download one verified archive, and print manual handoff instructions"
    )

    func run() throws {
        let configuration = try cliUpdaterConfiguration()
        let execution = try waitForAsync {
            let updater = try VerifiedReleaseUpdater(configuration: configuration)
            let check = try await updater.check()
            guard case .available(let candidate) = check.availability else {
                return CLIUpdateDownloadExecution(check: check, handoff: nil)
            }
            return CLIUpdateDownloadExecution(check: check, handoff: try await updater.download(candidate))
        }
        guard let handoff = execution.handoff else {
            let checked = CLIUpdateCheckResult(execution.check)
            if jsonRequested {
                CLIOutput.jsonError(
                    command: "update.download",
                    code: checked.availability == "unsupported" ? "unsupported" : "no-update",
                    message: checked.availability == "unsupported"
                        ? "the configured update channel is unsupported"
                        : "no newer authenticated update is available",
                    exitCode: checked.availability == "unsupported" ? CLIExitCode.unavailable : CLIExitCode.data
                )
            }
            throw CLIExecutionError(
                code: "no-update",
                message: "no newer authenticated update is available",
                exitCode: CLIExitCode.data
            )
        }
        let payload = CLIUpdateDownloadResult(handoff)
        if jsonRequested { CLIOutput.json(command: "update.download", payload: .updateDownload(payload)) }
        print("Verified archive: \(TerminalDisplay.sanitize(payload.verifiedArchivePath))")
        print(TerminalDisplay.sanitize(payload.instructions))
    }
}

private func cliUpdaterConfiguration() throws -> VerifiedUpdaterConfiguration {
    let config = try ConfigStore().loadValidated()
    guard config.updates.enabled else {
        throw CLIExecutionError(
            code: "updates-disabled",
            message: "updates are disabled; configure the [updates] trust settings first",
            exitCode: CLIExitCode.configuration
        )
    }
    guard let configuration = try config.updates.verifiedUpdaterConfiguration(temporaryRoot: AppPaths.cache) else {
        throw CLIExecutionError(
            code: "updates-disabled",
            message: "updates are disabled; configure the [updates] trust settings first",
            exitCode: CLIExitCode.configuration
        )
    }
    return configuration
}

private func printUpdateCheck(_ result: CLIUpdateCheckResult) {
    switch result.availability {
    case "available":
        if let release = result.release {
            print("Update available: \(release.version) [\(release.channel.rawValue)]")
            print("Archive: \(TerminalDisplay.sanitize(release.artifactFilename)) (\(formatBytes(release.artifactSize)))")
        }
    case "up-to-date":
        print("Up to date: \(result.currentVersion ?? ICloudGuardProduct.version)")
    default:
        print("Update channel unsupported: \(result.unsupportedReason ?? "unsupported")")
    }
}

public struct ConfigJSON: Codable {
    var exists: Bool
    var valid: Bool
    var migrationNeeded: Bool
    var error: String?
    init(inspection: ConfigStore.Inspection) {
        exists = inspection.exists
        valid = inspection.valid
        migrationNeeded = inspection.migrationNeeded
        error = inspection.error
    }
}

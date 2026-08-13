import CryptoKit
import Darwin
import Foundation

public enum GuardRunTrigger: String, Codable, Sendable {
    case cli
    case ipc
    case appManual = "app-manual"
    case scheduled
    case legacy
}

public enum GuardRunStatus: String, Codable, Sendable {
    case succeeded
    case noAction = "no-action"
    case partial
    case pending
    case failed
    case cancelled
    case contended
}

public struct GuardRunTelemetry: Codable, Equatable, Sendable {
    public var scanComplete: Bool
    public var freeSpaceAvailable: Bool
    public var localBytes: Int64?
    public var freeBytes: Int64?
    public var skippedDirectories: Int
    public var readErrors: Int

    public init(
        scanComplete: Bool = false,
        freeSpaceAvailable: Bool = false,
        localBytes: Int64? = nil,
        freeBytes: Int64? = nil,
        skippedDirectories: Int = 0,
        readErrors: Int = 0
    ) {
        self.scanComplete = scanComplete
        self.freeSpaceAvailable = freeSpaceAvailable
        self.localBytes = localBytes
        self.freeBytes = freeBytes
        self.skippedDirectories = skippedDirectories
        self.readErrors = readErrors
    }

    public init(_ stats: DriveStats) {
        self.init(
            scanComplete: stats.scanComplete,
            freeSpaceAvailable: stats.freeSpaceAvailable,
            localBytes: stats.scanComplete ? stats.materializedBytes : nil,
            freeBytes: stats.freeSpaceAvailable ? stats.freeBytes : nil,
            skippedDirectories: stats.skippedDirectories,
            readErrors: stats.scanReadErrors
        )
    }
}

public struct GuardRunReceipt: Codable, Equatable, Identifiable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var trigger: GuardRunTrigger
    public var command: String
    public var requestedAction: String
    public var action: GuardDecisionKind
    public var dryRun: Bool
    public var reason: String
    public var reasonCode: String?
    public var reasonMetadata: [String: String]?
    public var requestedGoalBytes: Int64?
    public var sourceScopeIdentifier: String
    public var preScan: GuardRunTelemetry?
    public var postScan: GuardRunTelemetry?
    public var plannedCount: Int
    public var plannedBytes: Int64
    public var verifiedCount: Int
    public var verifiedBytes: Int64
    public var pendingCount: Int
    public var pendingBytes: Int64
    public var failedCount: Int
    public var failedBytes: Int64
    public var cancelled: Bool
    public var exitCode: Int32
    public var status: GuardRunStatus
    public var statePersisted: Bool
    public var watchlistPersisted: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        startedAt: Date,
        endedAt: Date = Date(),
        trigger: GuardRunTrigger,
        command: String,
        requestedAction: String,
        action: GuardDecisionKind,
        dryRun: Bool,
        reason: String,
        reasonCode: String? = nil,
        reasonMetadata: [String: String] = [:],
        requestedGoalBytes: Int64? = nil,
        sourceScopeIdentifier: String,
        privacyScopePath: String? = nil,
        preScan: GuardRunTelemetry? = nil,
        postScan: GuardRunTelemetry? = nil,
        plannedCount: Int = 0,
        plannedBytes: Int64 = 0,
        verifiedCount: Int = 0,
        verifiedBytes: Int64 = 0,
        pendingCount: Int = 0,
        pendingBytes: Int64 = 0,
        failedCount: Int = 0,
        failedBytes: Int64 = 0,
        cancelled: Bool = false,
        exitCode: Int32,
        status: GuardRunStatus,
        statePersisted: Bool,
        watchlistPersisted: Bool
    ) {
        let preparedReason = ReceiptPrivacy.prepare(
            reason: reason,
            scopePath: privacyScopePath,
            requestedGoalBytes: requestedGoalBytes
        )
        var metadata = preparedReason.metadata
        for (key, value) in reasonMetadata {
            metadata[key] = ReceiptPrivacy.redacted(value, scopePath: privacyScopePath)
        }
        self.schema = Self.schemaVersion
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trigger = trigger
        self.command = command
        self.requestedAction = requestedAction
        self.action = action
        self.dryRun = dryRun
        self.reason = preparedReason.reason
        self.reasonCode = reasonCode ?? preparedReason.code
        self.reasonMetadata = metadata.isEmpty ? nil : metadata
        self.requestedGoalBytes = requestedGoalBytes.map { max(0, $0) }
        self.sourceScopeIdentifier = sourceScopeIdentifier
        self.preScan = preScan
        self.postScan = postScan
        self.plannedCount = max(0, plannedCount)
        self.plannedBytes = max(0, plannedBytes)
        self.verifiedCount = max(0, verifiedCount)
        self.verifiedBytes = max(0, verifiedBytes)
        self.pendingCount = max(0, pendingCount)
        self.pendingBytes = max(0, pendingBytes)
        self.failedCount = max(0, failedCount)
        self.failedBytes = max(0, failedBytes)
        self.cancelled = cancelled
        self.exitCode = exitCode
        self.status = status
        self.statePersisted = statePersisted
        self.watchlistPersisted = watchlistPersisted
    }

    public init(
        summary: GuardRunSummary,
        startedAt: Date,
        trigger: GuardRunTrigger,
        command: String,
        requestedAction: String,
        scopePath: String,
        preScan: DriveStats?,
        plannedBytes: Int64,
        pendingBytes: Int64 = 0,
        failedBytes: Int64 = 0,
        requestedGoalBytes: Int64? = nil,
        cancelled: Bool = false,
        exitCode: Int32,
        statePersisted: Bool,
        watchlistPersisted: Bool
    ) {
        let status = Self.status(for: summary, exitCode: exitCode, cancelled: cancelled)
        self.init(
            startedAt: startedAt,
            endedAt: summary.timestamp,
            trigger: trigger,
            command: command,
            requestedAction: requestedAction,
            action: summary.action,
            dryRun: summary.dryRun,
            reason: summary.reason,
            requestedGoalBytes: requestedGoalBytes,
            sourceScopeIdentifier: PrivacyIdentifier.scope(scopePath),
            privacyScopePath: scopePath,
            preScan: preScan.map(GuardRunTelemetry.init),
            postScan: GuardRunTelemetry(
                scanComplete: summary.postScanComplete,
                freeSpaceAvailable: summary.freeSpaceAvailable,
                localBytes: summary.postScanComplete ? summary.remainingLocalBytes : nil,
                freeBytes: summary.freeSpaceAvailable ? summary.remainingFreeBytes : nil
            ),
            plannedCount: summary.candidateCount,
            plannedBytes: plannedBytes,
            verifiedCount: summary.evictedCount,
            verifiedBytes: summary.reclaimedBytes,
            pendingCount: summary.pendingEvictionCount,
            pendingBytes: pendingBytes,
            failedCount: summary.failedEvictionCount,
            failedBytes: failedBytes,
            cancelled: cancelled,
            exitCode: exitCode,
            status: status,
            statePersisted: statePersisted,
            watchlistPersisted: watchlistPersisted
        )
    }

    static func status(for summary: GuardRunSummary, exitCode: Int32, cancelled: Bool) -> GuardRunStatus {
        if cancelled || exitCode == 130 { return .cancelled }
        if exitCode == 75 { return .contended }
        if summary.pendingEvictionCount > 0,
           summary.evictedCount == 0,
           summary.failedEvictionCount == 0,
           !summary.dryRun {
            return .pending
        }
        if summary.pendingEvictionCount > 0 || summary.failedEvictionCount > 0 {
            return .partial
        }
        if exitCode != 0,
           summary.evictedCount > 0
            || (summary.dryRun && summary.candidateCount > 0) {
            return .partial
        }
        if exitCode != 0 { return .failed }
        if summary.evictedCount == 0 && !summary.dryRun { return .noAction }
        return .succeeded
    }

    public var summary: GuardRunSummary {
        GuardRunSummary(
            timestamp: endedAt,
            action: action,
            reason: reason,
            dryRun: dryRun,
            candidateCount: plannedCount,
            evictedCount: verifiedCount,
            pendingEvictionCount: pendingCount,
            failedEvictionCount: failedCount,
            reclaimedBytes: verifiedBytes,
            remainingLocalBytes: postScan?.localBytes ?? 0,
            remainingFreeBytes: postScan?.freeBytes ?? 0,
            postScanComplete: postScan?.scanComplete ?? false,
            freeSpaceAvailable: postScan?.freeSpaceAvailable ?? false,
            escalatedToPanic: requestedAction != GuardDecisionKind.panic.rawValue && action == .panic
        )
    }

    public static func legacy(_ summary: GuardRunSummary) -> GuardRunReceipt {
        GuardRunReceipt(
            id: "legacy-\(Int(summary.timestamp.timeIntervalSince1970))",
            startedAt: summary.timestamp,
            endedAt: summary.timestamp,
            trigger: .legacy,
            command: "legacy",
            requestedAction: summary.action.rawValue,
            action: summary.action,
            dryRun: summary.dryRun,
            reason: summary.reason,
            sourceScopeIdentifier: "legacy",
            postScan: GuardRunTelemetry(
                scanComplete: summary.postScanComplete,
                freeSpaceAvailable: summary.freeSpaceAvailable,
                localBytes: summary.postScanComplete ? summary.remainingLocalBytes : nil,
                freeBytes: summary.freeSpaceAvailable ? summary.remainingFreeBytes : nil
            ),
            plannedCount: summary.candidateCount,
            plannedBytes: summary.reclaimedBytes,
            verifiedCount: summary.evictedCount,
            verifiedBytes: summary.reclaimedBytes,
            pendingCount: summary.pendingEvictionCount,
            failedCount: summary.failedEvictionCount,
            exitCode: summary.failedEvictionCount > 0 || summary.pendingEvictionCount > 0 ? 1 : 0,
            status: status(
                for: summary,
                exitCode: summary.failedEvictionCount > 0 || summary.pendingEvictionCount > 0 ? 1 : 0,
                cancelled: false
            ),
            statePersisted: true,
            watchlistPersisted: true
        )
    }
}

public enum PrivacyIdentifier {
    public static func hash(_ value: String, salt: Data = Data("icloud-guard-v1".utf8)) -> String {
        var input = salt
        input.append(contentsOf: value.utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    public static func scope(_ path: String) -> String {
        let canonical = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return String(hash(canonical).prefix(24))
    }
}

public enum ReceiptPrivacy {
    public static func prepare(
        reason: String,
        scopePath: String?,
        requestedGoalBytes: Int64? = nil
    ) -> (reason: String, code: String, metadata: [String: String]) {
        var metadata: [String: String] = [:]
        if let requestedGoalBytes {
            metadata["requested_goal_bytes"] = String(max(0, requestedGoalBytes))
        }
        if reason.hasPrefix("manual reclaim goal") {
            return ("manual reclaim goal", "manual-reclaim-goal", metadata)
        }
        if reason.hasPrefix("evict folder ") {
            let folder = String(reason.dropFirst("evict folder ".count))
            metadata["folder_id"] = String(PrivacyIdentifier.hash(folder).prefix(24))
            return ("manual folder eviction", "manual-folder-eviction", metadata)
        }
        if reason.hasPrefix("failed: ") {
            return ("run failed", "run-failed", metadata)
        }
        if reason.hasPrefix("mutation lock failed: ") {
            return ("mutation lock failed", "mutation-lock-failed", metadata)
        }
        if reason == "another run is active" || reason == "another mutation owner is active" {
            return (reason, "contention", metadata)
        }
        if reason == "cancelled" {
            return (reason, "cancelled", metadata)
        }
        let redacted = redacted(reason, scopePath: scopePath)
        return (redacted, reasonCode(redacted), metadata)
    }

    public static func redacted(_ value: String, scopePath: String?) -> String {
        guard let scopePath, !scopePath.isEmpty else { return value }
        let expanded = NSString(string: scopePath).expandingTildeInPath
        var redacted = value
        let urls = [
            URL(fileURLWithPath: scopePath),
            URL(fileURLWithPath: expanded),
            URL(fileURLWithPath: expanded).standardizedFileURL,
            URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL,
        ]
        for path in Set(urls.map(\.path)) where !path.isEmpty && path != "/" {
            redacted = redacted.replacingOccurrences(of: path, with: "<scope>")
            for component in URL(fileURLWithPath: path).pathComponents where component.count >= 3 && component != "/" {
                redacted = redacted.replacingOccurrences(of: component, with: "<path-component>")
            }
        }
        return redacted
    }

    public static func terminalSafe(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            if scalar.value <= 0x1F
                || (0x80...0x9F).contains(scalar.value)
                || scalar.value == 0x7F
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) {
                output += "\\u{\(String(format: "%04X", scalar.value))}"
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func reasonCode(_ reason: String) -> String {
        let scalars = reason.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "unspecified" : collapsed
    }
}

/// Coordinates the two durable records for one terminal operation.
///
/// State is saved first because `lastSummary` is the compatibility view. The
/// final receipt is then appended exactly once with the observed state result.
/// If state persistence fails, the transaction still attempts to append a
/// failure receipt so the operational failure remains diagnosable.
public enum RunPersistenceTransaction {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case state(String, receiptPersisted: Bool)
        case history(String, statePersisted: Bool)

        public var errorDescription: String? {
            switch self {
            case .state(let message, let receiptPersisted):
                return "state persistence failed (receipt persisted: \(receiptPersisted)): \(message)"
            case .history(let message, let statePersisted):
                return "receipt persistence failed (state persisted: \(statePersisted)): \(message)"
            }
        }

        public var statePersisted: Bool {
            switch self {
            case .state: return false
            case .history(_, let statePersisted): return statePersisted
            }
        }

        public var receiptPersisted: Bool {
            switch self {
            case .state(_, let receiptPersisted): return receiptPersisted
            case .history: return false
            }
        }
    }

    public static func perform(
        receipt: inout GuardRunReceipt,
        saveState: () throws -> Void,
        appendReceipt: (GuardRunReceipt) throws -> Void
    ) throws {
        do {
            try saveState()
            receipt.statePersisted = true
        } catch {
            receipt.statePersisted = false
            receipt.exitCode = 74
            if receipt.cancelled {
                receipt.status = .cancelled
            } else if receipt.verifiedCount > 0 || receipt.pendingCount > 0 || receipt.failedCount > 0 {
                receipt.status = .partial
            } else {
                receipt.status = .failed
            }
            do {
                try appendReceipt(receipt)
            } catch {
                throw Failure.state("state write failed and the failure receipt could not be written: \(error.localizedDescription)", receiptPersisted: false)
            }
            throw Failure.state(error.localizedDescription, receiptPersisted: true)
        }

        do {
            try appendReceipt(receipt)
        } catch {
            throw Failure.history(error.localizedDescription, statePersisted: true)
        }
    }
}

public final class RunHistoryStore: Sendable {
    public enum HistoryError: LocalizedError, Equatable, Sendable {
        case corrupt(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .corrupt(let message): return "run history is corrupt: \(message)"
            case .io(let message): return "run history I/O failed: \(message)"
            }
        }
    }

    private struct Document: Codable {
        var schema = 1
        var receipts: [GuardRunReceipt]
    }

    static let maximumHistoryBytes: UInt64 = 16 * 1024 * 1024
    private static let maximumDecodedReceipts = 10_000

    private let url: URL
    private let lockPath: String
    public let maximumReceipts: Int

    public init(url: URL = AppPaths.history, maximumReceipts: Int = 500) {
        self.url = url
        self.lockPath = url.deletingPathExtension().appendingPathExtension("lock").path
        self.maximumReceipts = max(1, min(maximumReceipts, 10_000))
    }

    public func load(legacySummary: GuardRunSummary? = nil) throws -> [GuardRunReceipt] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return legacySummary.map { [GuardRunReceipt.legacy($0)] } ?? []
        }
        let data: Data
        do { data = try SecureRegularFile.read(url, maximumBytes: Self.maximumHistoryBytes).data }
        catch let SecureRegularFile.ReadError.tooLarge(size) {
            throw HistoryError.corrupt("history file exceeds safety limit (\(size) bytes)")
        } catch { throw HistoryError.io("history file is not a readable regular file") }
        let decoder = Self.decoder()
        do {
            if let document = try? decoder.decode(Document.self, from: data) {
                guard document.schema == 1 else { throw HistoryError.corrupt("unsupported schema \(document.schema)") }
                return try validated(document.receipts)
            }
            if let receipts = try? decoder.decode([GuardRunReceipt].self, from: data) {
                return try validated(receipts)
            }
            if let summaries = try? decoder.decode([GuardRunSummary].self, from: data) {
                return try validated(summaries.map(GuardRunReceipt.legacy))
            }
            throw HistoryError.corrupt("invalid JSON document")
        } catch let error as HistoryError {
            throw error
        } catch {
            throw HistoryError.corrupt(error.localizedDescription)
        }
    }

    @discardableResult
    public func append(_ receipt: GuardRunReceipt, legacySummary: GuardRunSummary? = nil) throws -> [GuardRunReceipt] {
        let lock: AdvisoryFileLock
        do { lock = try AdvisoryFileLock(path: lockPath) }
        catch { throw HistoryError.io("cannot acquire history lock: \(error)") }
        defer { withExtendedLifetime(lock) {} }

        let legacyToMigrate = legacySummary.flatMap { summary in
            Self.representsSameRun(summary, receipt: receipt) ? nil : summary
        }
        var receipts = try load()
        if let legacyToMigrate,
           !receipts.contains(where: { Self.representsSameRun(legacyToMigrate, receipt: $0) }) {
            receipts.append(GuardRunReceipt.legacy(legacyToMigrate))
        }
        receipts.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
        receipts = Array(receipts.suffix(maximumReceipts))
        try save(receipts)
        return receipts
    }

    private static func representsSameRun(_ summary: GuardRunSummary, receipt: GuardRunReceipt) -> Bool {
        summary.timestamp == receipt.endedAt
            && summary.action == receipt.action
            && summary.reason == receipt.reason
            && summary.dryRun == receipt.dryRun
            && summary.candidateCount == receipt.plannedCount
            && summary.evictedCount == receipt.verifiedCount
            && summary.pendingEvictionCount == receipt.pendingCount
            && summary.failedEvictionCount == receipt.failedCount
            && summary.reclaimedBytes == receipt.verifiedBytes
            && summary.postScanComplete == (receipt.postScan?.scanComplete ?? false)
            && summary.freeSpaceAvailable == (receipt.postScan?.freeSpaceAvailable ?? false)
    }

    public func receipt(id: String) throws -> GuardRunReceipt? {
        try load().first { $0.id == id }
    }

    public func exportCSV(to outputURL: URL, privacyMode: Bool = true) throws {
        let receipts = try load()
        let columns = [
            "schema", "run_id", "started_at", "ended_at", "trigger", "command", "requested_action",
            "action", "dry_run", "status", "exit_code", "reason", "scope_id", "planned_count", "planned_bytes",
            "verified_count", "verified_bytes", "pending_count", "pending_bytes", "failed_count", "failed_bytes",
            "cancelled", "pre_scan_complete", "pre_free_available", "post_scan_complete", "post_free_available",
            "state_persisted", "watchlist_persisted",
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var rows = [columns.map(Self.csvField).joined(separator: ",")]
        for receipt in receipts {
            let reason = privacyMode ? "redacted" : receipt.reason
            var values: [String] = [
                String(receipt.schema), receipt.id, formatter.string(from: receipt.startedAt), formatter.string(from: receipt.endedAt),
                receipt.trigger.rawValue, receipt.command, receipt.requestedAction, receipt.action.rawValue,
                String(receipt.dryRun), receipt.status.rawValue, String(receipt.exitCode), reason, receipt.sourceScopeIdentifier,
            ]
            values.append(contentsOf: [
                String(receipt.plannedCount), String(receipt.plannedBytes), String(receipt.verifiedCount), String(receipt.verifiedBytes),
                String(receipt.pendingCount), String(receipt.pendingBytes), String(receipt.failedCount), String(receipt.failedBytes),
            ])
            values.append(contentsOf: [
                String(receipt.cancelled), String(receipt.preScan?.scanComplete ?? false),
                String(receipt.preScan?.freeSpaceAvailable ?? false), String(receipt.postScan?.scanComplete ?? false),
                String(receipt.postScan?.freeSpaceAvailable ?? false), String(receipt.statePersisted), String(receipt.watchlistPersisted),
            ])
            rows.append(values.map { Self.csvField(Self.formulaSafe($0)) }.joined(separator: ","))
        }
        try Self.atomicWrite(Data((rows.joined(separator: "\r\n") + "\r\n").utf8), to: outputURL)
    }

    private func validated(_ receipts: [GuardRunReceipt]) throws -> [GuardRunReceipt] {
        guard receipts.count <= Self.maximumDecodedReceipts else {
            throw HistoryError.corrupt("too many receipts")
        }
        var ids = Set<String>()
        for receipt in receipts {
            guard receipt.schema == GuardRunReceipt.schemaVersion,
                  !receipt.id.isEmpty,
                  receipt.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  receipt.endedAt.timeIntervalSinceReferenceDate.isFinite,
                  receipt.endedAt >= receipt.startedAt,
                  receipt.plannedCount >= 0,
                  receipt.verifiedCount >= 0,
                  receipt.pendingCount >= 0,
                  receipt.failedCount >= 0,
                  receipt.plannedBytes >= 0,
                  receipt.verifiedBytes >= 0,
                  receipt.pendingBytes >= 0,
                  receipt.failedBytes >= 0 else {
                throw HistoryError.corrupt("invalid receipt fields")
            }
            guard ids.insert(receipt.id).inserted else {
                throw HistoryError.corrupt("duplicate receipt id \(receipt.id)")
            }
            try validateInvariants(receipt)
        }
        // The durable array is append ordered. ISO-8601 encoding can collapse
        // multiple receipt timestamps into one second, so sorting equal dates
        // by random IDs would make `last` return an older run.
        return Array(receipts.suffix(maximumReceipts))
    }

    private func validateInvariants(_ receipt: GuardRunReceipt) throws {
        if receipt.cancelled != (receipt.exitCode == 130) {
            throw HistoryError.corrupt("cancelled receipt must have exit code 130")
        }
        guard receipt.verifiedCount <= receipt.plannedCount,
              receipt.pendingCount <= receipt.plannedCount - receipt.verifiedCount,
              receipt.failedCount <= receipt.plannedCount - receipt.verifiedCount - receipt.pendingCount else {
            throw HistoryError.corrupt("receipt counts exceed planned count")
        }
        guard (receipt.plannedCount > 0 || receipt.plannedBytes == 0),
              (receipt.verifiedCount > 0 || receipt.verifiedBytes == 0),
              (receipt.pendingCount > 0 || receipt.pendingBytes == 0),
              (receipt.failedCount > 0 || receipt.failedBytes == 0) else {
            throw HistoryError.corrupt("receipt has bytes without matching item count")
        }
        guard receipt.verifiedBytes <= receipt.plannedBytes,
              receipt.pendingBytes <= receipt.plannedBytes - receipt.verifiedBytes,
              receipt.failedBytes <= receipt.plannedBytes - receipt.verifiedBytes - receipt.pendingBytes else {
            throw HistoryError.corrupt("receipt bytes exceed planned bytes")
        }
        switch receipt.status {
        case .succeeded:
            guard receipt.exitCode == 0 && !receipt.cancelled else {
                throw HistoryError.corrupt("succeeded receipt has nonzero exit code")
            }
            guard receipt.pendingCount == 0,
                  receipt.pendingBytes == 0,
                  receipt.failedCount == 0,
                  receipt.failedBytes == 0,
                  receipt.dryRun
                    ? receipt.verifiedCount == 0 && receipt.verifiedBytes == 0
                    : receipt.verifiedCount > 0 else {
                throw HistoryError.corrupt("succeeded receipt has residual or incoherent work")
            }
        case .noAction:
            guard receipt.exitCode == 0 && !receipt.cancelled,
                  receipt.verifiedCount == 0,
                  receipt.pendingCount == 0,
                  receipt.failedCount == 0,
                  !receipt.dryRun else {
                throw HistoryError.corrupt("no-action receipt is not coherent")
            }
        case .failed:
            guard receipt.exitCode != 0,
                  receipt.exitCode != 75,
                  receipt.exitCode != 130,
                  !receipt.cancelled,
                  receipt.verifiedCount == 0,
                  receipt.pendingCount == 0,
                  receipt.failedCount == 0 else {
                throw HistoryError.corrupt("failed receipt is not coherent")
            }
        case .cancelled:
            guard receipt.exitCode == 130 && receipt.cancelled else {
                throw HistoryError.corrupt("cancelled receipt is not coherent")
            }
        case .contended:
            guard receipt.exitCode == 75 && !receipt.cancelled else {
                throw HistoryError.corrupt("contended receipt must have exit code 75")
            }
        case .partial:
            guard receipt.exitCode != 0,
                  receipt.exitCode != 75,
                  receipt.exitCode != 130,
                  !receipt.cancelled,
                  receipt.verifiedCount > 0
                    || receipt.failedCount > 0
                    || (receipt.dryRun && receipt.plannedCount > 0)
                    || (receipt.pendingCount > 0 && (receipt.verifiedCount > 0 || receipt.failedCount > 0)) else {
                throw HistoryError.corrupt("partial receipt is not coherent")
            }
        case .pending:
            guard receipt.exitCode != 0,
                  receipt.exitCode != 75,
                  receipt.exitCode != 130,
                  !receipt.cancelled,
                  receipt.pendingCount > 0,
                  receipt.verifiedCount == 0,
                  receipt.failedCount == 0 else {
                throw HistoryError.corrupt("pending receipt is not coherent")
            }
        }

    }

    private func save(_ receipts: [GuardRunReceipt]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try Self.atomicWrite(try encoder.encode(Document(receipts: receipts)), to: url) }
        catch let error as HistoryError { throw error }
        catch { throw HistoryError.io(error.localizedDescription) }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func formulaSafe(_ value: String) -> String {
        let firstMeaningful = value.unicodeScalars.first {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }
        guard let firstMeaningful, "=+-@".unicodeScalars.contains(firstMeaningful) else { return value }
        return "'" + value
    }

    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw HistoryError.io("cannot create output directory: \(error.localizedDescription)") }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            guard chmod(temporary.path, 0o600) == 0 else {
                throw HistoryError.io("cannot set output permissions: \(String(cString: strerror(errno)))")
            }
            let descriptor = open(temporary.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw HistoryError.io("cannot open temporary output: \(String(cString: strerror(errno)))")
            }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else {
                throw HistoryError.io("cannot synchronize output: \(String(cString: strerror(errno)))")
            }
            if rename(temporary.path, url.path) != 0 {
                throw HistoryError.io("cannot replace output: \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }
}

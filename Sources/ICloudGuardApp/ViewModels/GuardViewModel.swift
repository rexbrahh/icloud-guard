import Combine
import SwiftUI
import ICloudGuardCore

/// The complete, atomically-updated menu bar status. One @Published struct
/// means one view invalidation per update instead of a storm of them.
struct GuardStatus: Equatable {
    var isPaused = false
    var suppressionActive = false
    var watchlistCount = 0
    var rematerializedTotal = 0
    var lastRematerializedPath: String?

    // Drive statistics (regular files only, full-drive)
    var materializedFiles = 0
    var datalessFiles = 0
    var materializedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var topFolders: [FolderUsage] = []
    var hasStats = false

    // Scan state
    var scanInProgress = false
    var scanFilesScanned = 0
    var lastScanCompletedAt: Date?
    var lastScanDuration: Double = 0
    var cooldownRemainingSeconds: Int?

    // Watchlist
    var fightingCount = 0

    // Footprint history (24h of scan samples)
    var footprintSamples: [GuardSample] = []

    // Active run
    var activeRunKind: GuardRunKind?
    var progress: EvictionProgress?
    var runStartedAt: Date?

    // Last completed run
    var lastReport: GuardRunReport?

    // Lifetime
    var lifetimeEvictedCount = 0
    var lifetimeReclaimedBytes: Int64 = 0

    var lastError: String?

    var isRunning: Bool { activeRunKind != nil }

    var materializedRatio: Double {
        let total = materializedFiles + datalessFiles
        return total > 0 ? Double(materializedFiles) / Double(total) : 0
    }
}

@MainActor
final class GuardViewModel: ObservableObject {
    @Published private(set) var status = GuardStatus()

    private var guardService: GuardService?
    private var evictObserver: NSObjectProtocol?
    private var targetLocalBytes: Int64 = 5 * 1024 * 1024 * 1024
    private var panicFreeBytes: Int64 = 25 * 1024 * 1024 * 1024

    init() {
        loadLifetimeStats()
        evictObserver = NotificationCenter.default.addObserver(
            forName: .icloudGuardEvict,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.trimNow() }
        }
    }

    deinit {
        if let observer = evictObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Derived presentation state

    var statusIcon: String {
        if status.isPaused { return "icloud.slash" }
        if status.isRunning { return "arrow.2.circlepath" }
        if status.lastError != nil { return "exclamationmark.icloud.fill" }
        if isCriticalDisk { return "exclamationmark.icloud.fill" }
        if status.materializedBytes > targetLocalBytes { return "icloud.and.arrow.down" }
        return "icloud"
    }

    var statusIconColor: Color {
        if status.isPaused { return .secondary }
        if status.lastError != nil { return .red }
        if isCriticalDisk { return .red }
        if status.materializedBytes > targetLocalBytes { return .orange }
        return .primary
    }

    var isCriticalDisk: Bool {
        status.freeBytes > 0 && status.freeBytes < panicFreeBytes
    }

    var statusText: String {
        if status.isPaused { return "Paused" }
        if let kind = status.activeRunKind {
            switch kind {
            case .trim: return "Trimming…"
            case .panic: return "Panic evicting…"
            case .folder: return "Evicting folder…"
            case .preview: return "Previewing…"
            }
        }
        if status.lastError != nil { return "Error" }
        if !status.suppressionActive { return "Starting…" }
        return "Guarding"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter
    }()

    func formatBytes(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    var footprintLabel: String {
        guard status.hasStats else { return "Scanning…" }
        return "\(formatBytes(status.materializedBytes)) local · target \(formatBytes(targetLocalBytes))"
    }

    var freeSpaceLabel: String {
        guard status.freeBytes > 0 else { return "" }
        return "\(formatBytes(status.freeBytes)) free"
    }

    var pollutionLabel: String {
        guard status.hasStats else { return "" }
        return "\(status.materializedFiles) materialized · \(status.datalessFiles) evicted"
    }

    var lifetimeLabel: String {
        "\(status.lifetimeEvictedCount) files · \(formatBytes(status.lifetimeReclaimedBytes)) reclaimed"
    }

    var isUnderTarget: Bool {
        status.hasStats && status.materializedBytes <= targetLocalBytes
    }

    // MARK: - Progress presentation

    func progressFraction(_ progress: EvictionProgress) -> Double {
        if let budget = progress.byteBudget, budget > 0 {
            return min(Double(progress.reclaimedBytes) / Double(budget), 1)
        }
        let processed = progress.evictedCount + progress.failedCount
        guard progress.candidateCount > 0 else { return 0 }
        return min(Double(processed) / Double(progress.candidateCount), 1)
    }

    /// "12/318 files · 145 MB/s · ~38s left"
    func progressDetail(_ progress: EvictionProgress) -> String {
        var parts: [String] = []
        let processed = progress.evictedCount + progress.failedCount
        parts.append("\(processed)/\(progress.candidateCount) files")
        parts.append("\(formatBytes(progress.reclaimedBytes)) reclaimed")

        if let startedAt = status.runStartedAt {
            let elapsed = max(Date().timeIntervalSince(startedAt), 0.1)
            let bytesPerSecond = Double(progress.reclaimedBytes) / elapsed
            if bytesPerSecond > 0 {
                parts.append("\(formatBytes(Int64(bytesPerSecond)))/s")

                let remaining: Int64? = {
                    if let budget = progress.byteBudget { return max(budget - progress.reclaimedBytes, 0) }
                    return nil
                }()
                if let remaining, remaining > 0 {
                    let eta = Int((Double(remaining) / bytesPerSecond).rounded())
                    if eta > 0, eta < 3600 {
                        parts.append("~\(eta)s left")
                    }
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Freshness

    /// Cheap volume-capacity refresh for every menu open — no scan needed.
    func refreshFreeSpace() {
        let scope = ConfigStore().load().scope.path
        let free = DriveStatsCollector.freeDiskBytes(scopePath: scope)
        guard free > 0, free != status.freeBytes else { return }
        var next = status
        next.freeBytes = free
        status = next
    }

    func requestScanIfStale() {
        Task { await guardService?.scanIfStale(maxAgeSeconds: 60) }
    }

    func dismissError() {
        guard status.lastError != nil else { return }
        var next = status
        next.lastError = nil
        status = next
    }

    // MARK: - Service lifecycle

    func startGuardService(scopePath: String) {
        guard guardService == nil else { return }
        let service = GuardService(scopePath: scopePath) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleServiceEvent(event) }
        }
        guardService = service
        Task { await service.start() }
    }

    func stopGuardService() {
        Task { await guardService?.stop(); guardService = nil }
    }

    func reloadConfig() {
        Task { await guardService?.reloadConfig() }
        refreshPolicyCache()
    }

    func refreshPolicyCache() {
        let config = ConfigStore().load()
        targetLocalBytes = Int64(config.policy.targetLocalGiB) * 1024 * 1024 * 1024
        panicFreeBytes = Int64(config.policy.panicFreeGiB) * 1024 * 1024 * 1024
    }

    // MARK: - Events → status

    /// Coalesced: mutate one local copy and assign once — a single
    /// objectWillChange per event instead of up to a dozen.
    private func handleServiceEvent(_ event: GuardServiceEvent) {
        var next = status

        switch event {
        case .statsUpdated(let stats):
            next.materializedFiles = stats.materializedFiles
            next.datalessFiles = stats.datalessFiles
            next.materializedBytes = stats.materializedBytes
            next.freeBytes = stats.freeBytes
            next.topFolders = stats.topFolders
            next.hasStats = true
            next.scanInProgress = false
            next.lastScanCompletedAt = stats.completedAt
            next.lastScanDuration = stats.scanDurationSeconds
            next.lastError = nil

        case .scanProgress(let files):
            next.scanInProgress = true
            next.scanFilesScanned = files

        case .progress(let progress):
            next.progress = progress

        case .runStarted(let kind):
            next.activeRunKind = kind
            next.progress = nil
            next.runStartedAt = Date()
            next.lastError = nil

        case .runFinished(let report):
            next.activeRunKind = nil
            next.progress = nil
            next.runStartedAt = nil
            next.lastReport = report
            if report.evictedCount > 0 || report.reclaimedBytes > 0 {
                next.lifetimeEvictedCount += report.evictedCount
                next.lifetimeReclaimedBytes += report.reclaimedBytes
            }

        case .suppressionApplied(let active):
            next.suppressionActive = active

        case .watchlistUpdated(let count):
            next.watchlistCount = count

        case .rematerialized(let paths):
            next.rematerializedTotal += paths.count
            next.lastRematerializedPath = paths.last

        case .fighting(let paths):
            next.fightingCount = paths.count

        case .cooldownUpdated(let seconds):
            next.cooldownRemainingSeconds = seconds

        case .samplesUpdated(let samples):
            next.footprintSamples = samples

        case .pausedChanged(let paused):
            next.isPaused = paused

        case .error(let message):
            next.lastError = message
            next.activeRunKind = nil
            next.progress = nil
            next.scanInProgress = false
        }

        let lifetimeChanged = next.lifetimeEvictedCount != status.lifetimeEvictedCount
            || next.lifetimeReclaimedBytes != status.lifetimeReclaimedBytes
        if next != status {
            status = next
        }
        if lifetimeChanged {
            saveLifetimeStats()
        }
    }

    // MARK: - Actions

    func trimNow() {
        Task { await guardService?.trimNow() }
    }

    func panicEvict() {
        Task { await guardService?.panicEvict() }
    }

    func preview() {
        Task { await guardService?.preview() }
    }

    func evictFolder(_ folderName: String) {
        Task { await guardService?.evictFolder(folderName) }
    }

    func cancelRun() {
        Task { await guardService?.cancelRun() }
    }

    func togglePause() {
        if status.isPaused {
            Task { await guardService?.resume() }
        } else {
            Task { await guardService?.pause() }
        }
    }

    // MARK: - IPC execution

    /// Executes a CLI command against the running service. Called by IPCServer.
    func executeIPCCommand(_ command: GuardCommand, dryRun: Bool, progress: @escaping @Sendable (String) -> Void) async -> (output: String, exitCode: Int) {
        guard let service = guardService else {
            return ("guard service not running", 1)
        }

        let progressForward: (EvictionProgress) -> Void = { update in
            progress("\(update.phase.rawValue): scanned=\(update.scannedFiles) candidates=\(update.candidateCount) evicted=\(update.evictedCount) reclaimed=\(update.reclaimedBytes)")
        }

        switch command {
        case .status:
            let text = await service.statusText()
            return (text, 0)
        case .run:
            if dryRun {
                let report = await service.preview()
                return (Self.describe(report: report, formatBytes: formatBytes), 0)
            }
            let report = await service.trimNow(progress: progressForward)
            return (Self.describe(report: report, formatBytes: formatBytes), 0)
        case .panicEvict:
            if dryRun {
                let report = await service.preview()
                return (Self.describe(report: report, formatBytes: formatBytes), 0)
            }
            let report = await service.panicEvict(progress: progressForward)
            return (Self.describe(report: report, formatBytes: formatBytes), 0)
        }
    }

    private static func describe(report: GuardRunReport, formatBytes: (Int64) -> String) -> String {
        var lines: [String] = []
        lines.append("Action: \(report.kind.rawValue)")
        lines.append("Reason: \(report.reason)")
        if report.kind == .preview {
            lines.append("Candidates: \(report.candidateCount) file(s), \(formatBytes(report.previewBytes)) reclaimable")
        } else {
            lines.append("Candidates: \(report.candidateCount)")
            lines.append("Evicted: \(report.evictedCount)")
            lines.append("Failed: \(report.failedCount)")
            lines.append("Reclaimed (verified): \(formatBytes(report.reclaimedBytes))")
            if report.cancelled { lines.append("Cancelled: yes") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lifetime stats persistence

    private var lifetimeURL: URL { AppPaths.homeDir.appendingPathComponent("lifetime.json") }

    private func loadLifetimeStats() {
        guard let data = try? Data(contentsOf: lifetimeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        status.lifetimeEvictedCount = json["evictedCount"] as? Int ?? 0
        status.lifetimeReclaimedBytes = Int64(json["reclaimedBytes"] as? Int ?? 0)
    }

    private func saveLifetimeStats() {
        let json: [String: Any] = [
            "evictedCount": status.lifetimeEvictedCount,
            "reclaimedBytes": Int(status.lifetimeReclaimedBytes),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: lifetimeURL, options: [.atomic])
        }
    }
}

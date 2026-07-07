import Combine
import SwiftUI
import ICloudGuardCore

@MainActor
final class GuardViewModel: ObservableObject {
    @Published var suppressionActive = false
    @Published var watcherActive = false
    @Published var rematerializationCount = 0
    @Published var lastRematerializationPath: String?
    @Published var lastRematerializationTime: Date?
    @Published var isEvicting = false
    @Published var isPaused = false
    @Published var lastError: String?

    // Pollution metrics
    @Published var materializedCount = 0
    @Published var datalessCount = 0
    @Published var pollutionRatio: Double = 0
    @Published var freeSpaceBytes: Int64 = 0

    // Lifetime stats
    @Published var lifetimeEvictedCount: Int = 0
    @Published var lifetimeReclaimedBytes: Int64 = 0

    // Top folders by local space
    @Published var topFolders: [(name: String, bytes: Int64)] = []

    private var guardService: GuardService?
    private var evictObserver: NSObjectProtocol?

    init() {
        loadLifetimeStats()
        evictObserver = NotificationCenter.default.addObserver(
            forName: .icloudGuardEvict,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runEviction() }
        }
    }

    deinit {
        if let observer = evictObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    // MARK: - Status

    var statusIcon: String {
        if isPaused { return "icloud.slash" }
        if isEvicting { return "arrow.2.circlepath" }
        if let err = lastError, !err.isEmpty { return "exclamationmark.icloud.fill" }
        if isCriticalDisk { return "exclamationmark.icloud.fill" }
        if pollutionRatio > 0.7 { return "icloud.fill" }
        if pollutionRatio > 0.3 { return "icloud.and.arrow.down" }
        if rematerializationCount > 0 { return "icloud.and.arrow.up" }
        return "icloud"
    }

    var statusIconColor: Color {
        if isPaused { return .secondary }
        if isEvicting { return .primary }
        if let err = lastError, !err.isEmpty { return .red }
        if isCriticalDisk { return .red }
        if pollutionRatio > 0.7 { return .orange }
        return .primary
    }

    var isCriticalDisk: Bool {
        let freeGiB = Double(freeSpaceBytes) / (1024 * 1024 * 1024)
        return freeGiB > 0 && freeGiB < 25
    }

    var statusText: String {
        if isPaused { return "Paused" }
        if isEvicting { return "Evicting…" }
        if let err = lastError, !err.isEmpty { return "Error" }
        if !suppressionActive && !watcherActive { return "Inactive" }
        if watcherActive && suppressionActive { return "Guarding" }
        if suppressionActive { return "Suppressed" }
        if watcherActive { return "Watching" }
        return "Idle"
    }

    var pollutionLabel: String {
        if materializedCount == 0 && datalessCount == 0 { return "—" }
        let pct = Int(pollutionRatio * 100)
        return "\(materializedCount) materialized / \(datalessCount) evicted (\(pct)% polluted)"
    }

    var freeSpaceLabel: String {
        Self.byteFormatter.string(fromByteCount: freeSpaceBytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f
    }()

    var lifetimeLabel: String {
        let reclaimed = Self.lifetimeFormatter.string(fromByteCount: lifetimeReclaimedBytes)
        return "\(lifetimeEvictedCount) files, \(reclaimed) reclaimed"
    }

    private static let lifetimeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .file
        return f
    }()

    // MARK: - Service

    func startGuardService(scopePath: String) {
        guard guardService == nil else { return }
        let service = GuardService(scopePath: scopePath) { [weak self] event in
            Task { @MainActor in self?.handleServiceEvent(event) }
        }
        guardService = service
        Task { await service.start() }
    }

    func stopGuardService() {
        Task { await guardService?.stop(); guardService = nil }
    }

    func reloadConfig() {
        Task { await guardService?.reloadConfig() }
    }

    private func handleServiceEvent(_ event: GuardServiceEvent) {
        switch event {
        case .suppressionApplied:
            suppressionActive = true
        case .watcherStarted:
            watcherActive = true
        case .watcherStopped:
            watcherActive = false
        case .rematerializationBatchDetected(let events):
            rematerializationCount += events.count
            if let last = events.last {
                lastRematerializationPath = last.itemPath
                lastRematerializationTime = last.detectedAt
            }
        case .evictionStarted:
            isEvicting = true
        case .evictionCompleted:
            isEvicting = false
        case .error(let message):
            lastError = message
            isEvicting = false
        case .pollutionUpdated(let materialized, let dataless, let freeSpace, let folders):
            materializedCount = materialized
            datalessCount = dataless
            freeSpaceBytes = freeSpace
            let total = materialized + dataless
            pollutionRatio = total > 0 ? Double(materialized) / Double(total) : 0
            topFolders = folders
        case .evictionResult(let evicted, let reclaimed):
            lifetimeEvictedCount += evicted
            lifetimeReclaimedBytes += reclaimed
            saveLifetimeStats()
        }
    }

    func runEviction() {
        Task { await guardService?.runEviction() }
    }

    func panicEvict() {
        Task { await guardService?.panicEvict() }
    }

    func previewEviction() {
        Task { await guardService?.previewEviction() }
    }

    func evictFolder(_ folderPath: String) {
        Task { await guardService?.evictFolder(folderPath) }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            Task { await guardService?.pause() }
        } else {
            Task { await guardService?.resume() }
        }
    }

    // MARK: - Lifetime Stats Persistence

    private func loadLifetimeStats() {
        let url = AppPaths.homeDir.appendingPathComponent("lifetime.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lifetimeEvictedCount = json["evictedCount"] as? Int ?? 0
        lifetimeReclaimedBytes = Int64(json["reclaimedBytes"] as? Int ?? 0)
    }

    private func saveLifetimeStats() {
        let url = AppPaths.homeDir.appendingPathComponent("lifetime.json")
        let json: [String: Any] = [
            "evictedCount": lifetimeEvictedCount,
            "reclaimedBytes": Int(lifetimeReclaimedBytes),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

enum GuardServiceEvent {
    case suppressionApplied
    case watcherStarted
    case watcherStopped
    case rematerializationBatchDetected([RematerializationEvent])
    case evictionStarted
    case evictionCompleted
    case error(String)
    case pollutionUpdated(materialized: Int, dataless: Int, freeSpace: Int64, folders: [(name: String, bytes: Int64)])
    case evictionResult(evicted: Int, reclaimed: Int64)
}

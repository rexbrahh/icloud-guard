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

    // Lightweight iCloud pollution metric: ratio of materialized vs dataless files
    @Published var materializedCount = 0
    @Published var datalessCount = 0
    @Published var pollutionRatio: Double = 0

    private var guardService: GuardService?

    var statusIcon: String {
        if isPaused { return "icloud.slash" }
        if isEvicting { return "arrow.2.circlepath" }
        if let err = lastError, !err.isEmpty { return "exclamationmark.icloud" }
        if pollutionRatio > 0.5 { return "icloud.and.arrow.down" }
        if rematerializationCount > 0 { return "icloud.and.arrow.up" }
        return "icloud"
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

    /// Simple pollution gauge: how many iCloud files are locally materialized vs dataless.
    /// 0.0 = everything evicted (clean), 1.0 = everything downloaded (polluted).
    var pollutionLabel: String {
        if materializedCount == 0 && datalessCount == 0 { return "—" }
        let pct = Int(pollutionRatio * 100)
        return "\(materializedCount) materialized / \(datalessCount) evicted (\(pct)% polluted)"
    }

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

    private func handleServiceEvent(_ event: GuardServiceEvent) {
        switch event {
        case .suppressionApplied:
            suppressionActive = true
        case .watcherStarted:
            watcherActive = true
        case .watcherStopped:
            watcherActive = false
        case .rematerializationDetected(let event):
            rematerializationCount += 1
            lastRematerializationPath = event.itemPath
            lastRematerializationTime = event.detectedAt
        case .evictionStarted:
            isEvicting = true
        case .evictionCompleted:
            isEvicting = false
        case .error(let message):
            lastError = message
            isEvicting = false
        case .pollutionUpdated(let materialized, let dataless):
            materializedCount = materialized
            datalessCount = dataless
            let total = materialized + dataless
            pollutionRatio = total > 0 ? Double(materialized) / Double(total) : 0
        }
    }

    func runEviction() {
        Task { await guardService?.runEviction() }
    }

    func panicEvict() {
        Task { await guardService?.panicEvict() }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            Task { await guardService?.pause() }
        } else {
            Task { await guardService?.resume() }
        }
    }
}

enum GuardServiceEvent {
    case suppressionApplied
    case watcherStarted
    case watcherStopped
    case rematerializationDetected(RematerializationEvent)
    case evictionStarted
    case evictionCompleted
    case error(String)
    case pollutionUpdated(materialized: Int, dataless: Int)
}

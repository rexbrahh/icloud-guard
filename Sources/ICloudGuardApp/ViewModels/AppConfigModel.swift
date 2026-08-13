import Foundation
import Observation
import ICloudGuardCore

/// `@Observable` model wrapping `ConfigStore` with typed mutators and auto-persist.
///
/// `AppConfigModel` is the single source of truth for the in-memory `AppConfig`
/// while the app is running. Each typed mutator updates the corresponding nested
/// config struct, persists the change to `~/.icloud-guard/config.toml` via
/// `ConfigStore.save(_:)`, and then fires the optional `onChange` callback.
///
/// `reload()` flushes pending edits before re-reading the on-disk TOML.
@MainActor
@Observable
final class AppConfigModel {
    /// The current in-memory configuration. Mutations happen exclusively through
    /// the typed mutator methods on this class.
    private(set) var config: AppConfig

    /// Optional callback fired after every successful persist and after `reload()`.
    var onChange: (() -> Void)?
    var lastError: String?
    private(set) var isConfigurationValid: Bool
    private(set) var selectedScopeID: String?

    private let store: ConfigStore
    private var persistTask: Task<Void, Never>?
    private var pendingSnapshot: AppConfig?

    init(store: ConfigStore? = nil) {
        let resolvedStore = store ?? ConfigStore()
        self.store = resolvedStore
        do {
            let inspection = resolvedStore.inspect()
            self.config = try inspection.exists && inspection.valid && inspection.migrationNeeded
                ? resolvedStore.loadMigratingValidated()
                : resolvedStore.loadValidated()
            self.isConfigurationValid = true
            self.selectedScopeID = Self.initialScopeID(for: self.config)
        } catch {
            self.config = AppConfig()
            self.isConfigurationValid = false
            self.selectedScopeID = nil
            self.lastError = error.localizedDescription
        }
    }

    var scopeSelections: [ScopeSelectionResult] {
        (try? MultiScopeCatalog(config: config).selections) ?? []
    }

    var selectedScopeName: String {
        selectedManagedScope?.name ?? "iCloud Drive"
    }

    var selectedScope: AppConfig.ScopeConfig {
        selectedManagedScope?.scope ?? config.scope
    }

    var selectedWatcher: AppConfig.WatcherConfig {
        selectedManagedScope?.watcher ?? config.watcher
    }

    var selectedPolicy: AppConfig.PolicyConfig {
        selectedManagedScope?.policy ?? config.policy
    }

    var selectedEviction: AppConfig.EvictionConfig {
        selectedManagedScope?.eviction ?? config.eviction
    }

    @discardableResult
    func selectScope(id: String) -> Bool {
        guard scopeSelections.contains(where: { $0.id == id }) else {
            selectedScopeID = nil
            lastError = MultiScopeError.unknownScope(id).localizedDescription
            return false
        }
        selectedScopeID = id
        lastError = nil
        return true
    }
    func updateSuppression(_ suppression: AppConfig.SuppressionConfig) {
        guard isConfigurationValid else { return }
        config.suppression = suppression
        persist()
    }

    func updateEviction(_ eviction: AppConfig.EvictionConfig) {
        guard isConfigurationValid else { return }
        guard updateSelectedScope({ $0.eviction = eviction }, legacy: { config.eviction = eviction }) else { return }
        persist()
    }

    func updateWatcher(_ watcher: AppConfig.WatcherConfig) {
        guard isConfigurationValid else { return }
        guard updateSelectedScope({ $0.watcher = watcher }, legacy: { config.watcher = watcher }) else { return }
        persist()
    }

    func updateScope(_ scope: AppConfig.ScopeConfig) {
        guard isConfigurationValid else { return }
        guard updateSelectedScope({ $0.scope = scope }, legacy: { config.scope = scope }) else { return }
        persist()
    }

    func updatePolicy(_ policy: AppConfig.PolicyConfig) {
        guard isConfigurationValid else { return }
        guard updateSelectedScope({ $0.policy = policy.normalized() }, legacy: { config.policy = policy.normalized() }) else { return }
        persist()
    }

    func updateNotifications(_ notifications: AppConfig.NotificationsConfig) {
        guard isConfigurationValid else { return }
        config.notifications = notifications
        persist()
    }

    func reload() {
        guard flushPending() else { return }
        do {
            let reloaded = try store.loadValidated()
            config = reloaded
            if let selectedScopeID,
               !(try MultiScopeCatalog(config: reloaded).selections.contains { $0.id == selectedScopeID }) {
                self.selectedScopeID = Self.initialScopeID(for: reloaded)
            } else if selectedScopeID == nil {
                selectedScopeID = Self.initialScopeID(for: reloaded)
            }
            isConfigurationValid = true
            lastError = nil
            onChange?()
        } catch {
            isConfigurationValid = false
            report(error)
        }
    }

    private func persist() {
        persistTask?.cancel()
        let snapshot = config
        pendingSnapshot = snapshot
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            self.save(snapshot)
        }
    }

    /// Flush the final debounced edit before reload or application shutdown.
    @discardableResult
    func flushPending() -> Bool {
        persistTask?.cancel()
        persistTask = nil
        guard let pendingSnapshot else { return true }
        return save(pendingSnapshot)
    }

    @discardableResult
    private func save(_ snapshot: AppConfig) -> Bool {
        do {
            try store.save(snapshot)
            if pendingSnapshot == snapshot { pendingSnapshot = nil }
            lastError = nil
            onChange?()
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        FileHandle.standardError.write(Data("AppConfigModel: \(error.localizedDescription)\n".utf8))
    }

    private var selectedManagedScope: ManagedScopeConfig? {
        guard let selectedScopeID, let scopes = config.scopes else { return nil }
        return scopes.first { $0.id == selectedScopeID }
    }

    @discardableResult
    private func updateSelectedScope(
        _ mutation: (inout ManagedScopeConfig) -> Void,
        legacy: () -> Void
    ) -> Bool {
        guard var scopes = config.scopes else {
            legacy()
            return true
        }
        guard let selectedScopeID,
              let index = scopes.firstIndex(where: { $0.id == selectedScopeID }) else {
            lastError = "Select a valid scope before changing scope-specific settings."
            return false
        }
        mutation(&scopes[index])
        config.scopes = scopes
        return true
    }

    private static func initialScopeID(for config: AppConfig) -> String? {
        (try? MultiScopeCatalog(config: config).selections.first?.id) ?? nil
    }
}

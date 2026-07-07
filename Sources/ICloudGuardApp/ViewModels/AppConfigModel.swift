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
/// `reload()` re-reads the on-disk TOML into memory and also fires `onChange`.
/// Persist failures are logged to stderr and swallowed — `persist()` never throws.
@MainActor
@Observable
final class AppConfigModel {
    /// The current in-memory configuration. Mutations happen exclusively through
    /// the typed mutator methods on this class.
    private(set) var config: AppConfig

    /// Optional callback fired after every successful persist and after `reload()`.
    var onChange: (() -> Void)?

    private let store: ConfigStore
    private var persistWorkItem: DispatchWorkItem?

    init(store: ConfigStore? = nil) {
        let resolvedStore = store ?? ConfigStore()
        self.store = resolvedStore
        self.config = resolvedStore.load()
    }
    func updateSuppression(_ suppression: AppConfig.SuppressionConfig) {
        config.suppression = suppression
        persist()
    }

    func updateEviction(_ eviction: AppConfig.EvictionConfig) {
        config.eviction = eviction
        persist()
    }

    func updateWatcher(_ watcher: AppConfig.WatcherConfig) {
        config.watcher = watcher
        persist()
    }

    func updateScope(_ scope: AppConfig.ScopeConfig) {
        config.scope = scope
        persist()
    }

    func updatePolicy(_ policy: AppConfig.PolicyConfig) {
        config.policy = policy
        persist()
    }

    func reload() {
        config = store.load()
        onChange?()
    }

    private func persist() {
        // Debounce: cancel any pending write and schedule a new one 500ms later.
        // This prevents a stepper hold from writing TOML to disk on every increment.
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try self.store.save(self.config)
            } catch {
                let line = "AppConfigModel: save failed: \(error)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            self.onChange?()
        }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}

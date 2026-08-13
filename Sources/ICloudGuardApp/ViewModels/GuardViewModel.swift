import Combine
import SwiftUI
import ICloudGuardCore

typealias GuardServiceFactory = (
    _ scopePath: String,
    _ eventHandler: @escaping @Sendable (GuardServiceEvent) -> Void
) throws -> GuardService

typealias ManagedGuardServiceFactory = (
    _ context: ManagedScopeContext,
    _ runtimeConfigProvider: @escaping GuardRuntimeConfigProvider,
    _ automaticPanicLockPath: String?,
    _ eventHandler: @escaping @Sendable (GuardServiceEvent) -> Void
) throws -> GuardService

typealias ManagedScopePathsResolver = @Sendable (ManagedScopeContext) throws -> AppPaths.ScopePaths
typealias ManagedScopeStorageEnsurer = @Sendable (AppPaths.ScopePaths) throws -> Void

struct GuardUpdaterActions: Sendable {
    var check: @Sendable () async throws -> GuardUpdateCheck
    var download: @Sendable () async throws -> ManualUpdateHandoff
    var discard: @Sendable (ManualUpdateHandoff) async throws -> Void = { _ in }
}

struct GuardUpdateCheck: Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case upToDate(SemanticVersion)
        case available(SemanticVersion)
        case unsupported(UpdateChannel)
    }
    var availability: Availability
    var source: UpdateCheckSource
}

private enum GuardUpdateTaskKind {
    case check
    case download
    case discard
}

private actor GuardUpdateCandidateHolder {
    var candidate: UpdateCandidate?
    private var checkGeneration = 0

    func beginCheck() -> Int {
        checkGeneration += 1
        return checkGeneration
    }

    func replace(with candidate: UpdateCandidate?, checkGeneration: Int) {
        guard checkGeneration == self.checkGeneration else { return }
        self.candidate = candidate
    }
}

typealias GuardUpdaterFactory = @Sendable (VerifiedUpdaterConfiguration) throws -> GuardUpdaterActions

struct GuardOperationsSnapshot: Sendable {
    var doctor: DoctorReport
    var history: [GuardRunReceipt]
    var watchlist: [WatchlistInspection]
    var scopeBrowser: ScopeBrowserReport? = nil
}

private struct GuardOperationsLoadFailure: LocalizedError {
    var doctor: DoctorReport
    var message: String

    var errorDescription: String? { message }
}

typealias GuardOperationsLoader = @Sendable (
    _ scopePaths: AppPaths.ScopePaths,
    _ configURL: URL,
    _ runtimeConfig: AppConfig,
    _ revealWatchlistPaths: Bool
) throws -> GuardOperationsSnapshot

typealias LegacyGuardOperationsLoader = @Sendable (
    _ home: URL,
    _ configURL: URL,
    _ revealWatchlistPaths: Bool
) throws -> GuardOperationsSnapshot

typealias GuardSupportBundleCreator = @Sendable (
    _ outputURL: URL,
    _ runtimeConfig: AppConfig,
    _ scopePaths: AppPaths.ScopePaths
) throws -> SupportBundleResult

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
    var freeSpaceAvailable = false
    var scanComplete = false
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

struct GuardOperationsStatus: Equatable {
    var doctor: DoctorReport?
    var history: [GuardRunReceipt] = []
    var watchlist: [WatchlistInspection] = []
    var scopeBrowser: ScopeBrowserReport?
    var explanation: ExplainablePreview?
    var lastExportPath: String?
    var lastSupportBundlePath: String?
    var error: String?
    var loading = false
    var firstRunDoctorReviewRequired = false
    var updateStatus = "Update checks have not run."
    var updateChannel: UpdateChannel?
    var updateCandidateVersion: SemanticVersion?
    var updateHandoff: ManualUpdateHandoff?
    var updateLoading = false
}

@MainActor
final class GuardViewModel: NSObject, ObservableObject {
    @Published private(set) var status = GuardStatus()
    @Published private(set) var operations = GuardOperationsStatus()

    @Published private(set) var scopeSelections: [ScopeSelectionResult] = []
    @Published private(set) var selectedScopeID: String?

    private var guardServices: [String: GuardService] = [:]
    private var startedServiceIDs = Set<String>()
    private var serviceGenerations: [String: UInt64] = [:]
    private var serviceReconciliationTask: Task<Void, Never>?
    private var scopeContexts: [String: ManagedScopeContext] = [:]
    private var scopeStatuses: [String: GuardStatus] = [:]
    private let managedGuardServiceFactory: ManagedGuardServiceFactory
    private let scopePathsResolver: ManagedScopePathsResolver
    private let scopeStorageEnsurer: ManagedScopeStorageEnsurer
    private let configStore: ConfigStore
    private let lifetimeURL: URL
    private let operationsLoader: GuardOperationsLoader
    private let supportBundleCreator: GuardSupportBundleCreator
    private let updaterFactory: GuardUpdaterFactory
    private var updaterActions: GuardUpdaterActions?
    private var updaterConfigurationSource: AppConfig.UpdatesConfig?
    private var updateTask: Task<Void, Never>?
    private var updateTaskKind: GuardUpdateTaskKind?
    private var retiredUpdateTasks: [Task<Void, Never>] = []
    private var pendingUpdateCleanup: (actions: GuardUpdaterActions, handoff: ManualUpdateHandoff)?
    private var updateGeneration = 0
    private var operationsRefreshTask: Task<Void, Never>?
    private var operationsRefreshGeneration = 0
    private var currentOperationsRevealWatchlistPaths = false
    var onServiceActivated: (() -> Void)?
    var isGuardServiceActive: Bool { !guardServices.isEmpty }
    private var selectedService: GuardService? {
        selectedScopeID.flatMap { guardServices[$0] }
    }
    private var selectedContext: ManagedScopeContext? {
        selectedScopeID.flatMap { scopeContexts[$0] }
    }
    private var targetLocalBytes: Int64 = 5 * 1024 * 1024 * 1024
    private var panicFreeBytes: Int64 = 25 * 1024 * 1024 * 1024

    override convenience init() {
        self.init(
            configStore: ConfigStore(),
            lifetimeURL: AppPaths.homeDir.appendingPathComponent("lifetime.json"),
            managedGuardServiceFactory: { context, provider, panicLock, eventHandler in
                try GuardService(
                    scopePath: context.config.scope.path,
                    appHomeURL: context.paths.root,
                    runtimeConfigProvider: provider,
                    automaticPanicLockPath: panicLock,
                    eventHandler: eventHandler
                )
            }
        )
    }

    convenience init(
        configStore: ConfigStore,
        lifetimeURL: URL,
        guardServiceFactory: @escaping GuardServiceFactory,
        operationsLoader: @escaping LegacyGuardOperationsLoader = { home, configURL, revealWatchlistPaths in
            try GuardViewModel.loadLegacyOperations(
                home: home,
                configURL: configURL,
                runtimeConfig: try ConfigStore(configURL: configURL).loadValidated(),
                revealWatchlistPaths: revealWatchlistPaths
            )
        },
        updaterFactory: @escaping GuardUpdaterFactory = { configuration in
            try GuardViewModel.makeUpdater(configuration: configuration)
        },
        supportBundleCreator: @escaping GuardSupportBundleCreator = { output, config, paths in
            try SupportBundleService().create(outputURL: output, config: config, scopePaths: paths)
        },
        scopePathsResolver: @escaping ManagedScopePathsResolver = { $0.paths },
        scopeStorageEnsurer: @escaping ManagedScopeStorageEnsurer = { try AppPaths.ensureScopeDir($0) }
    ) {
        self.init(
            configStore: configStore,
            lifetimeURL: lifetimeURL,
            managedGuardServiceFactory: { context, _, _, eventHandler in
                try guardServiceFactory(context.config.scope.path, eventHandler)
            },
            operationsLoader: { scopePaths, configURL, _, reveal in
                try operationsLoader(scopePaths.root, configURL, reveal)
            },
            updaterFactory: updaterFactory,
            supportBundleCreator: supportBundleCreator,
            scopePathsResolver: scopePathsResolver,
            scopeStorageEnsurer: scopeStorageEnsurer
        )
    }

    init(
        configStore: ConfigStore,
        lifetimeURL: URL,
        managedGuardServiceFactory: @escaping ManagedGuardServiceFactory,
        operationsLoader: @escaping GuardOperationsLoader = { scopePaths, configURL, runtimeConfig, revealWatchlistPaths in
            try GuardViewModel.loadOperations(
                scopePaths: scopePaths,
                configURL: configURL,
                runtimeConfig: runtimeConfig,
                revealWatchlistPaths: revealWatchlistPaths
            )
        },
        updaterFactory: @escaping GuardUpdaterFactory = { configuration in
            try GuardViewModel.makeUpdater(configuration: configuration)
        },
        supportBundleCreator: @escaping GuardSupportBundleCreator = { output, config, paths in
            try SupportBundleService().create(outputURL: output, config: config, scopePaths: paths)
        },
        scopePathsResolver: @escaping ManagedScopePathsResolver = { $0.paths },
        scopeStorageEnsurer: @escaping ManagedScopeStorageEnsurer = { try AppPaths.ensureScopeDir($0) }
    ) {
        self.configStore = configStore
        self.lifetimeURL = lifetimeURL
        self.managedGuardServiceFactory = managedGuardServiceFactory
        self.scopePathsResolver = scopePathsResolver
        self.scopeStorageEnsurer = scopeStorageEnsurer
        self.operationsLoader = operationsLoader
        self.supportBundleCreator = supportBundleCreator
        self.updaterFactory = updaterFactory
        super.init()
        loadLifetimeStats()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEvictNotification),
            name: .icloudGuardEvict,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRestoreLastNotification(_:)),
            name: .icloudGuardRestoreLast,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePauseNotification(_:)),
            name: .icloudGuardPause,
            object: nil
        )
    }

    @objc private func handleEvictNotification() {
        trimNow()
    }

    @objc private func handleRestoreLastNotification(_ notification: Notification) {
        guard let service = notificationService(notification) else { return }
        restoreLastRun(service: service)
    }

    @objc private func handlePauseNotification(_ notification: Notification) {
        guard let service = notificationService(notification) else { return }
        Task { await service.pause() }
    }

    private func notificationService(_ notification: Notification) -> GuardService? {
        guard let scopeID = notification.userInfo?[GuardNotificationProvenance.scopeIDKey] as? String,
              let generationText = notification.userInfo?[GuardNotificationProvenance.scopeGenerationKey] as? String,
              let generation = UInt64(generationText),
              scopeContexts[scopeID] != nil,
              serviceGenerations[scopeID] == generation else { return nil }
        return guardServices[scopeID]
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
        status.freeSpaceAvailable && status.freeBytes < panicFreeBytes
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
        if status.hasStats && !status.scanComplete { return "Scan incomplete" }
        if isCriticalDisk { return "Critical free space" }
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
        guard status.hasStats else { return "" }
        guard status.freeSpaceAvailable else { return "Free space unavailable" }
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
        let processed = progress.evictedCount + progress.pendingCount + progress.failedCount
        guard progress.candidateCount > 0 else { return 0 }
        return min(Double(processed) / Double(progress.candidateCount), 1)
    }

    /// "12/318 files · 145 MB/s · ~38s left"
    func progressDetail(_ progress: EvictionProgress) -> String {
        var parts: [String] = []
        let processed = progress.evictedCount + progress.pendingCount + progress.failedCount
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
        guard let scope = selectedContext?.config.scope.path else { return }
        guard let free = DriveStatsCollector.freeDiskBytes(scopePath: scope), free != status.freeBytes else { return }
        var next = status
        next.freeBytes = free
        next.freeSpaceAvailable = true
        status = next
    }

    func requestScanIfStale() {
        Task { await selectedService?.scanIfStale(maxAgeSeconds: 60) }
    }

    func dismissError() {
        guard status.lastError != nil else { return }
        var next = status
        next.lastError = nil
        status = next
        if let selectedScopeID { scopeStatuses[selectedScopeID] = next }
    }

    // MARK: - Service lifecycle

    func startGuardService(scopePath: String) {
        do {
            let config = try configStore.loadValidated()
            guard config.scopes == nil, config.scope.path == scopePath else {
                setStatusError("The requested legacy scope does not match the validated configuration.")
                return
            }
            startGuardServices(config: config, selectedScopeID: "default")
        } catch {
            setStatusError(error.localizedDescription)
        }
    }

    func startGuardServices(config: AppConfig, selectedScopeID requestedScopeID: String? = nil) {
        _ = enqueueServiceOperation { [weak self] in
            guard let self else { return }
            await self.reconcileGuardServices(config: config, requestedScopeID: requestedScopeID)
        }
    }

    func waitForServiceReconciliation() async {
        await serviceReconciliationTask?.value
    }

    private func enqueueServiceOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = serviceReconciliationTask
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        serviceReconciliationTask = task
        return task
    }

    private func reconcileGuardServices(config: AppConfig, requestedScopeID: String?) async {
        let catalog: MultiScopeCatalog
        do {
            catalog = try MultiScopeCatalog(config: config)
        } catch {
            setStatusError(error.localizedDescription)
            return
        }

        let resolvedContexts: [ManagedScopeContext]
        do {
            resolvedContexts = try catalog.contexts.map { context in
                var resolved = context
                resolved.paths = try scopePathsResolver(context)
                return resolved
            }
        } catch {
            setStatusError(error.localizedDescription)
            return
        }
        let validIDs = Set(resolvedContexts.map(\.config.id))
        let selections = catalog.selections
        let invalidRequestedScope = requestedScopeID.flatMap { requested in
            selections.contains(where: { $0.id == requested }) ? nil : requested
        }
        scopeSelections = selections
        if invalidRequestedScope != nil {
            selectedScopeID = nil
        } else {
            let preferred = requestedScopeID ?? selectedScopeID
            selectedScopeID = selections.contains(where: { $0.id == preferred }) ? preferred : selections.first?.id
        }

        for id in guardServices.keys.sorted() where !validIDs.contains(id) {
            await removeService(id: id, clearStatus: true)
        }
        for id in scopeStatuses.keys where !validIDs.contains(id) {
            scopeStatuses[id] = nil
        }

        for context in resolvedContexts {
            let scopeID = context.config.id
            do {
                try scopeStorageEnsurer(context.paths)
            } catch {
                await removeService(id: scopeID, clearStatus: true)
                scopeContexts[scopeID] = context
                var failed = GuardStatus()
                failed.lastError = error.localizedDescription
                scopeStatuses[scopeID] = failed
                continue
            }
            let requiresReplacement: Bool
            if let previousContext = scopeContexts[scopeID] {
                requiresReplacement = previousContext.paths != context.paths
                    || previousContext.usesLegacyStorage != context.usesLegacyStorage
                    || previousContext.config.automaticEnabled != context.config.automaticEnabled
                    || (context.config.automaticEnabled == false && previousContext.config != context.config)
            } else {
                requiresReplacement = false
            }
            if requiresReplacement {
                await removeService(id: scopeID, clearStatus: false)
            }
            scopeContexts[scopeID] = context

            if let service = guardServices[scopeID] {
                if context.config.automaticEnabled {
                    if startedServiceIDs.insert(scopeID).inserted {
                        await service.start()
                    } else {
                        await service.reloadConfig()
                    }
                } else {
                    await service.reloadConfig()
                }
                continue
            }
            do {
                let usesLegacyStorage = context.usesLegacyStorage
                let store = configStore
                let pathsResolver = scopePathsResolver
                let servicePaths = context.paths
                let provider: GuardRuntimeConfigProvider = {
                    let current = try store.loadValidated()
                    let selector = try ScopeSelector(scopeID)
                    let currentContext = try MultiScopeCatalog(config: current).context(for: selector)
                    guard try pathsResolver(currentContext) == servicePaths else {
                        throw MultiScopeError.unknownScope(scopeID)
                    }
                    guard currentContext.usesLegacyStorage == usesLegacyStorage else {
                        throw MultiScopeError.unknownScope(scopeID)
                    }
                    return Self.runtimeConfig(global: current, context: currentContext)
                }
                let panicLock = context.usesLegacyStorage
                    ? nil
                    : URL(fileURLWithPath: configStore.configURLPath)
                        .deletingLastPathComponent()
                        .appendingPathComponent("automatic-panic.lock").path
                let generation = advanceServiceGeneration(for: scopeID)
                let service = try managedGuardServiceFactory(context, provider, panicLock) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleServiceEvent(event, scopeID: scopeID, generation: generation)
                    }
                }
                await service.bindNotificationProvenance(scopeID: scopeID, generation: generation)
                guardServices[scopeID] = service
                if scopeStatuses[scopeID] == nil {
                    var initial = GuardStatus()
                    let totals = loadLifetimeStats(at: lifetimeURL(for: context))
                    initial.lifetimeEvictedCount = totals.evictedCount
                    initial.lifetimeReclaimedBytes = totals.reclaimedBytes
                    scopeStatuses[scopeID] = initial
                }
                if context.config.automaticEnabled {
                    startedServiceIDs.insert(scopeID)
                    await service.start()
                } else {
                    do {
                        try await service.prepareForManualOperations()
                    } catch {
                        await removeService(id: scopeID, clearStatus: false)
                        throw error
                    }
                }
            } catch {
                var failed = scopeStatuses[context.config.id] ?? GuardStatus()
                failed.lastError = error.localizedDescription
                scopeStatuses[context.config.id] = failed
            }
        }

        publishSelectedStatus()
        await invalidateUpdaterIfConfigurationChanged(config.updates)
        if let invalidRequestedScope {
            setStatusError(MultiScopeError.unknownScope(invalidRequestedScope).localizedDescription)
        }
        refreshPolicyCache()
        if !guardServices.isEmpty { onServiceActivated?() }
    }

    private func advanceServiceGeneration(for id: String) -> UInt64 {
        let next = (serviceGenerations[id] ?? 0) &+ 1
        serviceGenerations[id] = next
        return next
    }

    private func removeService(id: String, clearStatus: Bool) async {
        _ = advanceServiceGeneration(for: id)
        startedServiceIDs.remove(id)
        scopeContexts[id] = nil
        if clearStatus { scopeStatuses[id] = nil }
        if let service = guardServices.removeValue(forKey: id) {
            await service.stop()
        }
    }

    func stopGuardService() {
        Task { await stopGuardServiceAndWait() }
    }

    @discardableResult
    func stopGuardServiceAndWait() async -> Bool {
        let task = enqueueServiceOperation { [weak self] in
            guard let self else { return }
            await self.stopGuardServicesNow()
        }
        await task.value
        return operations.updateHandoff == nil
    }

    private func stopGuardServicesNow() async {
        guard await invalidateUpdaterForStop() else { return }
        for id in guardServices.keys.sorted() {
            await removeService(id: id, clearStatus: false)
        }
    }

    func reloadConfig(scopePath: String? = nil) {
        do {
            let config = try configStore.loadValidated()
            if let scopePath, config.scopes == nil, config.scope.path != scopePath {
                setStatusError("The requested legacy scope does not match the validated configuration.")
                return
            }
            startGuardServices(config: config, selectedScopeID: selectedScopeID)
            refreshPolicyCache()
        } catch {
            setStatusError(error.localizedDescription)
        }
    }

    func reloadConfig(config: AppConfig, selectedScopeID: String?) {
        startGuardServices(config: config, selectedScopeID: selectedScopeID)
        refreshPolicyCache()
    }

    @discardableResult
    func selectScope(id: String) -> Bool {
        guard scopeSelections.contains(where: { $0.id == id }) else {
            selectedScopeID = nil
            setStatusError(MultiScopeError.unknownScope(id).localizedDescription)
            return false
        }
        selectedScopeID = id
        publishSelectedStatus()
        refreshPolicyCache()
        refreshOperations(revealWatchlistPaths: currentOperationsRevealWatchlistPaths)
        return true
    }

    func refreshPolicyCache() {
        guard let policy = selectedContext?.config.policy else { return }
        targetLocalBytes = Int64(policy.targetLocalGiB) * 1024 * 1024 * 1024
        panicFreeBytes = Int64(policy.panicFreeGiB) * 1024 * 1024 * 1024
    }

    func refreshOperations(revealWatchlistPaths: Bool = false) {
        guard let context = selectedContext else {
            operations.error = "Select a valid scope before loading operations."
            return
        }
        operationsRefreshTask?.cancel()
        operationsRefreshGeneration += 1
        currentOperationsRevealWatchlistPaths = revealWatchlistPaths
        let generation = operationsRefreshGeneration
        let scopePaths = context.paths
        let configURL = URL(fileURLWithPath: configStore.configURLPath)
        let runtimeConfig: AppConfig
        do {
            try scopeStorageEnsurer(scopePaths)
            runtimeConfig = Self.runtimeConfig(global: try configStore.loadValidated(), context: context)
        } catch {
            operations.error = error.localizedDescription
            return
        }
        let loader = operationsLoader
        var next = operations
        next.loading = true
        next.error = nil
        operations = next
        operationsRefreshTask = Task.detached(priority: .userInitiated) {
            do {
                let snapshot = try loader(scopePaths, configURL, runtimeConfig, revealWatchlistPaths)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.operationsRefreshGeneration == generation,
                          self.currentOperationsRevealWatchlistPaths == revealWatchlistPaths else { return }
                    self.operations.doctor = snapshot.doctor
                    self.operations.history = Array(snapshot.history.reversed())
                    self.operations.watchlist = snapshot.watchlist
                    self.operations.scopeBrowser = snapshot.scopeBrowser
                    self.operations.loading = false
                    self.operationsRefreshTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.operationsRefreshGeneration == generation,
                          self.currentOperationsRevealWatchlistPaths == revealWatchlistPaths else { return }
                    self.operations.loading = false
                    if let failure = error as? GuardOperationsLoadFailure {
                        self.operations.doctor = failure.doctor
                    }
                    self.operations.error = error.localizedDescription
                    self.operationsRefreshTask = nil
                }
            }
        }
    }

    nonisolated private static func loadOperations(
        scopePaths: AppPaths.ScopePaths,
        configURL: URL,
        runtimeConfig: AppConfig,
        revealWatchlistPaths: Bool
    ) throws -> GuardOperationsSnapshot {
        let home = scopePaths.root
        let doctor = DoctorService.run(config: runtimeConfig, scopePaths: scopePaths)
        do {
            let history = try RunHistoryStore(url: home.appendingPathComponent("history.json")).load()
            let watchlist = try WatchlistInspectionService.load(
                storageURL: home.appendingPathComponent("watchlist.json"),
                scopePath: runtimeConfig.scope.path,
                revealPaths: revealWatchlistPaths,
                maxFights: runtimeConfig.watcher.maxFights
            )
            let scopeBrowser = try ScopeBrowserService().browse(
                config: runtimeConfig,
                revealPaths: revealWatchlistPaths,
                limit: 1_000
            )
            return GuardOperationsSnapshot(
                doctor: doctor,
                history: history,
                watchlist: watchlist,
                scopeBrowser: scopeBrowser
            )
        } catch {
            throw GuardOperationsLoadFailure(doctor: doctor, message: error.localizedDescription)
        }
    }

    nonisolated private static func loadLegacyOperations(
        home: URL,
        configURL: URL,
        runtimeConfig: AppConfig,
        revealWatchlistPaths: Bool
    ) throws -> GuardOperationsSnapshot {
        let doctor = DoctorService.run(appHome: home, configURL: configURL)
        do {
            let history = try RunHistoryStore(url: home.appendingPathComponent("history.json")).load()
            let watchlist = try WatchlistInspectionService.load(
                storageURL: home.appendingPathComponent("watchlist.json"),
                scopePath: runtimeConfig.scope.path,
                revealPaths: revealWatchlistPaths,
                maxFights: runtimeConfig.watcher.maxFights
            )
            let scopeBrowser = try ScopeBrowserService().browse(
                config: runtimeConfig,
                revealPaths: revealWatchlistPaths,
                limit: 1_000
            )
            return GuardOperationsSnapshot(doctor: doctor, history: history, watchlist: watchlist, scopeBrowser: scopeBrowser)
        } catch {
            throw GuardOperationsLoadFailure(doctor: doctor, message: error.localizedDescription)
        }
    }

    func requestFirstRunDoctorReview(defaults: UserDefaults = .standard) {
        guard FirstRunDoctorState.needsReview(defaults: defaults) else { return }
        operations.firstRunDoctorReviewRequired = true
        refreshOperations()
    }

    func acknowledgeFirstRunDoctor(defaults: UserDefaults = .standard) {
        FirstRunDoctorState.acknowledge(defaults: defaults)
        operations.firstRunDoctorReviewRequired = false
    }

    func explainCurrentPlan(panic: Bool = false) {
        guard let context = selectedContext else {
            operations.error = "Select a valid scope before explaining a plan."
            return
        }
        let home = context.paths.root
        let runtimeConfig: AppConfig
        do {
            try scopeStorageEnsurer(context.paths)
            runtimeConfig = Self.runtimeConfig(global: try configStore.loadValidated(), context: context)
        }
        catch {
            operations.error = error.localizedDescription
            return
        }
        operations.loading = true
        Task.detached(priority: .userInitiated) {
            do {
                let explanation = try ExplainablePreviewService().run(
                    config: runtimeConfig,
                    appHome: home,
                    command: panic ? .panicEvict : .run,
                    trigger: .appManual
                )
                await MainActor.run {
                    self.operations.explanation = explanation
                    self.operations.loading = false
                    self.refreshOperations()
                }
            } catch {
                await MainActor.run {
                    self.operations.loading = false
                    self.operations.error = error.localizedDescription
                }
            }
        }
    }

    func reclaim(goal: String, dryRun: Bool) {
        guard let bytes = HumanByteCount.parse(goal) else {
            operations.error = "Enter a positive byte goal, such as 5GiB or 750MB."
            return
        }
        guard let guardService = selectedService else {
            operations.error = "Start the guard service before reclaiming space."
            return
        }
        Task {
            _ = await guardService.reclaim(bytes: bytes, dryRun: dryRun)
            refreshOperations()
        }
    }

    func exportHistory(to outputURL: URL) {
        guard let home = selectedContext?.paths.root else {
            operations.error = "Select a valid scope before exporting history."
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                try RunHistoryStore(url: home.appendingPathComponent("history.json")).exportCSV(to: outputURL)
                await MainActor.run {
                    self.operations.lastExportPath = outputURL.path
                    self.operations.error = nil
                }
            } catch {
                await MainActor.run { self.operations.error = error.localizedDescription }
            }
        }
    }

    func createSupportBundle(at outputURL: URL) {
        guard let context = selectedContext else {
            operations.error = "Select a valid scope before creating a support bundle."
            return
        }
        let runtimeConfig: AppConfig
        do {
            runtimeConfig = Self.runtimeConfig(global: try configStore.loadValidated(), context: context)
        } catch {
            operations.error = error.localizedDescription
            return
        }
        let scopePaths = context.paths
        let creator = supportBundleCreator
        Task.detached(priority: .userInitiated) {
            do {
                let result = try creator(outputURL, runtimeConfig, scopePaths)
                await MainActor.run {
                    self.operations.lastSupportBundlePath = result.outputPath
                    self.operations.error = nil
                }
            } catch {
                await MainActor.run { self.operations.error = error.localizedDescription }
            }
        }
    }

    // MARK: - Verified updates

    func checkForUpdates() {
        let previous = updateTask
        let previousKind = updateTaskKind
        let previousOwnsCleanup = operations.updateHandoff != nil || pendingUpdateCleanup != nil
        previous?.cancel()
        if let previous, previousKind == .check, !previousOwnsCleanup {
            retiredUpdateTasks.append(previous)
        }
        let prerequisite = previousKind == .check && !previousOwnsCleanup ? nil : previous
        updateGeneration += 1
        let generation = updateGeneration
        operations.updateLoading = true
        operations.error = nil
        updateTask = Task {
            await prerequisite?.value
            guard generation == updateGeneration else { return }
            guard await discardCurrentUpdateHandoffIfNeeded(generation: generation) else { return }
            guard generation == updateGeneration else { return }
            operations.updateLoading = true
            do {
                let config = try configStore.loadValidated()
                operations.updateChannel = config.updates.channel
                guard let updaterConfig = try config.updates.verifiedUpdaterConfiguration(
                    temporaryRoot: URL(fileURLWithPath: configStore.configURLPath)
                        .deletingLastPathComponent()
                        .appendingPathComponent("cache", isDirectory: true)
                ) else {
                    clearUpdaterState()
                    operations.updateStatus = "Update checks are disabled in configuration."
                    operations.updateLoading = false
                    return
                }
                let actions: GuardUpdaterActions
                if updaterConfigurationSource == config.updates, let existing = updaterActions {
                    actions = existing
                } else {
                    actions = try updaterFactory(updaterConfig)
                    updaterActions = actions
                    updaterConfigurationSource = config.updates
                }
                let result = try await actions.check()
                guard !Task.isCancelled, generation == updateGeneration else { return }
                operations.updateCandidateVersion = nil
                switch result.availability {
                case .upToDate(let version):
                    operations.updateStatus = "Version \(version) is up to date (\(result.source.rawValue))."
                case .available(let version):
                    operations.updateCandidateVersion = version
                    operations.updateStatus = "Version \(version) is available."
                case .unsupported(let channel):
                    operations.updateStatus = "The \(channel.rawValue) update channel is unsupported."
                }
                operations.updateLoading = false
            } catch is CancellationError {
                guard generation == updateGeneration else { return }
                operations.updateLoading = false
            } catch {
                guard generation == updateGeneration else { return }
                operations.updateCandidateVersion = nil
                operations.updateLoading = false
                operations.error = error.localizedDescription
                operations.updateStatus = "Update check failed."
            }
        }
        updateTaskKind = .check
    }

    func downloadAvailableUpdate() {
        guard operations.updateHandoff == nil else {
            operations.error = "Discard the existing verified download before downloading again."
            return
        }
        let previous = updateTask
        previous?.cancel()
        updateGeneration += 1
        let generation = updateGeneration
        guard let actions = updaterActions, operations.updateCandidateVersion != nil else {
            operations.updateLoading = false
            operations.error = "Check for updates before downloading."
            return
        }
        operations.updateLoading = true
        operations.error = nil
        updateTask = Task {
            await previous?.value
            guard generation == updateGeneration else { return }
            do {
                let handoff = try await actions.download()
                guard !Task.isCancelled, generation == updateGeneration else {
                    pendingUpdateCleanup = (actions, handoff)
                    return
                }
                operations.updateHandoff = handoff
                operations.updateStatus = "Version \(handoff.release.version) was downloaded and verified."
                operations.updateLoading = false
            } catch is CancellationError {
                guard generation == updateGeneration else { return }
                operations.updateLoading = false
            } catch {
                guard generation == updateGeneration else { return }
                operations.updateLoading = false
                operations.error = error.localizedDescription
                operations.updateStatus = "Verified download failed."
            }
        }
        updateTaskKind = .download
    }

    func discardDownloadedUpdate() {
        guard operations.updateHandoff != nil else { return }
        let previous = updateTask
        previous?.cancel()
        updateGeneration += 1
        let generation = updateGeneration
        operations.updateLoading = true
        operations.error = nil
        updateTask = Task {
            await previous?.value
            guard generation == updateGeneration else { return }
            _ = await discardCurrentUpdateHandoffIfNeeded(generation: generation)
        }
        updateTaskKind = .discard
    }

    private func discardCurrentUpdateHandoffIfNeeded(generation: Int) async -> Bool {
        if let pendingUpdateCleanup {
            do {
                try await pendingUpdateCleanup.actions.discard(pendingUpdateCleanup.handoff)
                self.pendingUpdateCleanup = nil
                guard generation == updateGeneration else { return false }
            } catch {
                guard generation == updateGeneration else { return false }
                self.pendingUpdateCleanup = nil
                operations.updateHandoff = pendingUpdateCleanup.handoff
                operations.updateLoading = false
                operations.error = error.localizedDescription
                operations.updateStatus = "Discard failed. The verified archive was preserved for retry."
                return false
            }
        }
        guard let handoff = operations.updateHandoff else { return true }
        guard let actions = updaterActions else {
            operations.updateLoading = false
            operations.error = "The verified download could not be discarded because its updater session is unavailable."
            operations.updateStatus = "Discard failed. The verified archive was preserved for retry."
            return false
        }
        do {
            try await actions.discard(handoff)
            if operations.updateHandoff == handoff { operations.updateHandoff = nil }
            guard generation == updateGeneration else { return false }
            operations.updateLoading = false
            operations.updateStatus = "Verified download discarded."
            return true
        } catch {
            guard generation == updateGeneration else { return false }
            operations.updateLoading = false
            operations.error = error.localizedDescription
            operations.updateStatus = "Discard failed. The verified archive was preserved for retry."
            return false
        }
    }

    private func clearUpdaterState() {
        updaterActions = nil
        updaterConfigurationSource = nil
        operations.updateCandidateVersion = nil
        operations.updateHandoff = nil
    }

    nonisolated private static func makeUpdater(
        configuration: VerifiedUpdaterConfiguration
    ) throws -> GuardUpdaterActions {
        let updater = try VerifiedReleaseUpdater(configuration: configuration)
        let holder = GuardUpdateCandidateHolder()
        return GuardUpdaterActions(
            check: {
                let checkGeneration = await holder.beginCheck()
                let result = try await updater.check()
                switch result.availability {
                case .upToDate(let version):
                    await holder.replace(with: nil, checkGeneration: checkGeneration)
                    return GuardUpdateCheck(availability: .upToDate(version), source: result.source)
                case .available(let candidate):
                    await holder.replace(with: candidate, checkGeneration: checkGeneration)
                    return GuardUpdateCheck(availability: .available(candidate.release.version), source: result.source)
                case .unsupported(let channel, _):
                    await holder.replace(with: nil, checkGeneration: checkGeneration)
                    return GuardUpdateCheck(availability: .unsupported(channel), source: result.source)
                }
            },
            download: {
                guard let candidate = await holder.candidate else { throw UpdaterError.candidateExpired }
                return try await updater.download(candidate)
            },
            discard: { handoff in
                try await updater.discard(handoff)
            }
        )
    }

    // MARK: - Events → status

    /// Coalesced: mutate one local copy and assign once — a single
    /// objectWillChange per event instead of up to a dozen.
    private func handleServiceEvent(_ event: GuardServiceEvent, scopeID: String, generation: UInt64) {
        guard scopeContexts[scopeID] != nil,
              serviceGenerations[scopeID] == generation,
              guardServices[scopeID] != nil else { return }
        var next = scopeStatuses[scopeID] ?? GuardStatus()

        switch event {
        case .statsUpdated(let stats):
            next.materializedFiles = stats.materializedFiles
            next.datalessFiles = stats.datalessFiles
            next.materializedBytes = stats.materializedBytes
            next.freeBytes = stats.freeBytes
            next.freeSpaceAvailable = stats.freeSpaceAvailable
            next.scanComplete = stats.scanComplete
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

        case .suppressionApplied(let result):
            next.suppressionActive = result.allConfiguredSucceeded
            if !result.allConfiguredSucceeded {
                next.lastError = "Download suppression is only partially active"
            }

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

        case .keepDownloadedFinished:
            if selectedScopeID == scopeID {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshOperations(revealWatchlistPaths: self.currentOperationsRevealWatchlistPaths)
                }
            }

        case .error(let message):
            next.lastError = message
            next.activeRunKind = nil
            next.progress = nil
            next.scanInProgress = false
        }

        let previous = scopeStatuses[scopeID] ?? GuardStatus()
        let lifetimeChanged = next.lifetimeEvictedCount != previous.lifetimeEvictedCount
            || next.lifetimeReclaimedBytes != previous.lifetimeReclaimedBytes
        scopeStatuses[scopeID] = next
        if selectedScopeID == scopeID, next != status {
            status = next
        }
        if lifetimeChanged {
            saveLifetimeStats(next, scopeID: scopeID)
        }
    }

    nonisolated private static func runtimeConfig(global: AppConfig, context: ManagedScopeContext) -> AppConfig {
        AppConfig(
            suppression: global.suppression,
            eviction: context.config.eviction,
            watcher: context.config.watcher,
            scope: context.config.scope,
            policy: context.config.policy,
            notifications: global.notifications,
            energy: global.energy,
            updates: global.updates
        )
    }

    private func publishSelectedStatus() {
        guard let selectedScopeID else {
            status = GuardStatus(lastError: "Select a valid scope before running an operation.")
            return
        }
        status = scopeStatuses[selectedScopeID] ?? GuardStatus()
    }

    private func setStatusError(_ message: String) {
        var next = selectedScopeID.flatMap { scopeStatuses[$0] } ?? status
        next.lastError = message
        if let selectedScopeID { scopeStatuses[selectedScopeID] = next }
        status = next
    }

    private func invalidateUpdaterIfConfigurationChanged(_ updates: AppConfig.UpdatesConfig) async {
        guard let source = updaterConfigurationSource, source != updates else { return }
        let previous = updateTask
        previous?.cancel()
        updateGeneration += 1
        let generation = updateGeneration
        await previous?.value
        await awaitRetiredUpdateTasks()
        guard generation == updateGeneration else { return }
        guard await discardCurrentUpdateHandoffIfNeeded(generation: generation) else { return }
        clearUpdaterState()
        operations.updateLoading = false
        operations.updateStatus = updates.enabled
            ? "Update configuration changed. Check for updates again."
            : "Update checks are disabled in configuration."
    }

    private func invalidateUpdaterForStop() async -> Bool {
        let previous = updateTask
        previous?.cancel()
        updateGeneration += 1
        let generation = updateGeneration
        await previous?.value
        await awaitRetiredUpdateTasks()
        guard generation == updateGeneration else { return false }
        guard await discardCurrentUpdateHandoffIfNeeded(generation: generation) else { return false }
        clearUpdaterState()
        operations.updateLoading = false
        return true
    }

    private func awaitRetiredUpdateTasks() async {
        let tasks = retiredUpdateTasks
        retiredUpdateTasks.removeAll()
        for task in tasks { await task.value }
    }

    // MARK: - Actions

    func trimNow() {
        Task { await selectedService?.trimNow() }
    }

    func panicEvict() {
        Task { await selectedService?.panicEvict() }
    }

    func preview() {
        Task { await selectedService?.preview() }
    }

    func evictFolder(_ folderName: String) {
        Task { await selectedService?.evictFolder(folderName) }
    }

    func cancelRun() {
        Task { await selectedService?.cancelRun() }
    }

    func togglePause() {
        if status.isPaused {
            Task { await selectedService?.resume() }
        } else {
            Task { await selectedService?.pause() }
        }
    }

    func pauseGuard() {
        guard !status.isPaused else { return }
        Task { await selectedService?.pause() }
    }

    func restoreLastRun() {
        guard let guardService = selectedService else {
            operations.error = "Restore requires the guard service to be running."
            return
        }
        restoreLastRun(service: guardService)
    }

    private func restoreLastRun(service guardService: GuardService) {
        operations.loading = true
        operations.error = nil
        Task {
            do {
                _ = try await guardService.restoreLastRun()
                operations.loading = false
                refreshOperations(revealWatchlistPaths: currentOperationsRevealWatchlistPaths)
            } catch {
                operations.loading = false
                operations.error = error.localizedDescription
            }
        }
    }

    func enforceKeepDownloaded() {
        guard let guardService = selectedService else {
            operations.error = "Keep-downloaded enforcement requires the guard service to be running."
            return
        }
        operations.loading = true
        operations.error = nil
        Task {
            do {
                _ = try await guardService.enforceKeepDownloaded()
                operations.loading = false
                refreshOperations(revealWatchlistPaths: currentOperationsRevealWatchlistPaths)
            } catch {
                operations.loading = false
                operations.error = error.localizedDescription
            }
        }
    }

    // MARK: - IPC execution

    /// Executes a CLI command against the running service. Called by IPCServer.
    func executeIPCCommand(
        _ command: GuardCommand,
        dryRun: Bool,
        cancellation: EvictionCancellation,
        progress: @escaping @Sendable (String) -> Void
    ) async -> IPCCommandResult {
        guard let scopeID = selectedScopeID,
              let service = guardServices[scopeID],
              let context = scopeContexts[scopeID] else {
            return IPCCommandResult(output: "guard service not running", exitCode: 69)
        }
        let historyURL = context.paths.history

        let progressForward: @Sendable (EvictionProgress) -> Void = { update in
            progress("\(update.phase.rawValue): scanned=\(update.scannedFiles) candidates=\(update.candidateCount) evicted=\(update.evictedCount) pending=\(update.pendingCount) reclaimed=\(update.reclaimedBytes)")
        }

        switch command {
        case .status:
            let result = await service.statusResult()
            return IPCCommandResult(output: result.text, exitCode: result.exitCode, telemetry: result.telemetry)
        case .run:
            if dryRun {
                let report = await service.preview(command: .run, cancellation: cancellation, trigger: .ipc)
                return ipcResult(report, historyURL: historyURL)
            }
            let report = await service.trimNow(progress: progressForward, cancellation: cancellation, trigger: .ipc)
            return ipcResult(report, historyURL: historyURL)
        case .panicEvict:
            if dryRun {
                let report = await service.preview(command: .panicEvict, cancellation: cancellation, trigger: .ipc)
                return ipcResult(report, historyURL: historyURL)
            }
            let report = await service.panicEvict(progress: progressForward, cancellation: cancellation, trigger: .ipc)
            return ipcResult(report, historyURL: historyURL)
        }
    }

    private func ipcResult(_ report: GuardRunReport, historyURL: URL) -> IPCCommandResult {
        let receipt: GuardRunReceipt?
        do {
            receipt = try RunHistoryStore(url: historyURL).receipt(id: report.runID)
        } catch {
            return IPCCommandResult(
                output: "current run receipt could not be read: \(error.localizedDescription)",
                exitCode: 74,
                runID: report.runID
            )
        }
        guard let receipt else {
            return IPCCommandResult(
                output: "current run receipt was not persisted",
                exitCode: 74,
                runID: report.runID
            )
        }
        return IPCCommandResult(
            output: Self.describe(report: report, formatBytes: formatBytes),
            exitCode: Int(report.exitCode),
            runID: report.runID,
            receipt: receipt
        )
    }

    private static func describe(report: GuardRunReport, formatBytes: (Int64) -> String) -> String {
        var lines: [String] = []
        lines.append("Action: \(report.dryRun ? report.action.rawValue + " (dry run)" : report.kind.rawValue)")
        lines.append("Reason: \(report.reason)")
        if report.kind == .preview {
            lines.append("Candidates: \(report.candidateCount) file(s), \(formatBytes(report.previewBytes)) reclaimable")
        } else {
            lines.append("Candidates: \(report.candidateCount)")
            lines.append("Evicted: \(report.evictedCount)")
            lines.append("Pending verification: \(report.pendingCount)")
            lines.append("Failed: \(report.failedCount)")
            lines.append("Reclaimed (verified): \(formatBytes(report.reclaimedBytes))")
            if report.cancelled { lines.append("Cancelled: yes") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lifetime stats persistence

    private func loadLifetimeStats() {
        let totals = loadLifetimeStats(at: lifetimeURL)
        status.lifetimeEvictedCount = totals.evictedCount
        status.lifetimeReclaimedBytes = totals.reclaimedBytes
    }

    private func loadLifetimeStats(at url: URL) -> (evictedCount: Int, reclaimedBytes: Int64) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, 0) }
        return (json["evictedCount"] as? Int ?? 0, Int64(json["reclaimedBytes"] as? Int ?? 0))
    }

    private func lifetimeURL(for context: ManagedScopeContext) -> URL {
        context.usesLegacyStorage ? lifetimeURL : context.paths.root.appendingPathComponent("lifetime.json")
    }

    private func saveLifetimeStats(_ value: GuardStatus, scopeID: String) {
        guard let context = scopeContexts[scopeID] else { return }
        let json: [String: Any] = [
            "evictedCount": value.lifetimeEvictedCount,
            "reclaimedBytes": Int(value.lifetimeReclaimedBytes),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: lifetimeURL(for: context), options: [.atomic])
        }
    }
}

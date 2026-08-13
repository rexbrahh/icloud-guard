import AppKit
import SwiftUI
import ServiceManagement
import ICloudGuardCore

struct SettingsView: View {
    @ObservedObject var viewModel: GuardViewModel
    @Environment(AppConfigModel.self) private var configModel

    var body: some View {
        VStack(spacing: 0) {
            if configModel.scopeSelections.count > 1 {
                Picker("Managed scope", selection: scopeSelection) {
                    ForEach(configModel.scopeSelections, id: \.id) { scope in
                        Text(scope.name).tag(scope.id)
                    }
                }
                .pickerStyle(.menu)
                .padding([.horizontal, .top])
                .accessibilityLabel("Managed scope")
                .accessibilityHint("Changes the scope shown in Policy and Operations")
            }
            TabView {
                GeneralSettingsView(viewModel: viewModel)
                    .tabItem { Label("General", systemImage: "gearshape") }
                PolicySettingsView()
                    .tabItem { Label("Policy", systemImage: "slider.horizontal.3") }
                OperationsSettingsView(viewModel: viewModel)
                    .tabItem { Label("Operations", systemImage: "checkmark.shield") }
                AboutView()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 560)
    }

    private var scopeSelection: Binding<String> {
        Binding(
            get: { configModel.selectedScopeID ?? "" },
            set: { id in
                guard configModel.selectScope(id: id) else { return }
                _ = viewModel.selectScope(id: id)
            }
        )
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var viewModel: GuardViewModel
    @AppStorage("runAtLogin") private var runAtLogin = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @Environment(AppConfigModel.self) private var configModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = configModel.lastError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .accessibilityLabel("Configuration error: \(error)")
                        if !configModel.isConfigurationValid {
                            Button("Reload configuration") { configModel.reload() }
                        }
                    }
                }
                Group {
                    Text("Startup")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Toggle("Launch at login", isOn: $runAtLogin)
                        .toggleStyle(.switch)
                        .onChange(of: runAtLogin) { _, enabled in
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                runAtLogin = !enabled
                            }
                        }
                    Toggle("Notifications", isOn: $notificationsEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: notificationsEnabled) { _, enabled in
                            let policy = configModel.config.notifications
                            Task {
                                await Notifier.shared.configure(
                                    policy,
                                    notificationsEnabled: enabled
                                )
                            }
                        }
                    if notificationsEnabled {
                        Toggle("Eviction completed", isOn: notificationBinding(\.evictionCompleted))
                        Toggle("Partial failures", isOn: notificationBinding(\.partialFailure))
                        Toggle("Fighting files", isOn: notificationBinding(\.fightingFiles))
                        Toggle("Restore completed", isOn: notificationBinding(\.restoreCompleted))
                        Toggle("Keep-downloaded checks", isOn: notificationBinding(\.keepDownloaded))
                        Toggle("Notification actions", isOn: notificationBinding(\.actionsEnabled))
                            .accessibilityHint("Allows Restore last run and Pause actions in notifications")
                    }
                }

                Divider()

                Group {
                    Text("Download Suppression")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Toggle(SettingsPresentation.spotlightSuppressionLabel, isOn: Binding(get: { configModel.config.suppression.spotlight }, set: { configModel.updateSuppression(.init(spotlight: $0, quicklook: configModel.config.suppression.quicklook, materializeDataless: configModel.config.suppression.materializeDataless)) }))
                        .toggleStyle(.switch)
                    Toggle("QuickLook cache clearing", isOn: Binding(get: { configModel.config.suppression.quicklook }, set: { configModel.updateSuppression(.init(spotlight: configModel.config.suppression.spotlight, quicklook: $0, materializeDataless: configModel.config.suppression.materializeDataless)) }))
                        .toggleStyle(.switch)
                    Toggle("Non-materializing I/O policy", isOn: Binding(get: { configModel.config.suppression.nonMaterializingIOPolicyEnabled }, set: { configModel.updateSuppression(.init(spotlight: configModel.config.suppression.spotlight, quicklook: configModel.config.suppression.quicklook, materializeDataless: !$0)) }))
                        .toggleStyle(.switch)
                    Text("Rematerialization defense is always on: recently evicted files are watched and re-evicted if iCloud downloads them again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!configModel.isConfigurationValid)

                Divider()

                Group {
                    Text("Active Defense")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    SettingsKeyValueRow(
                        label: "Watchlist",
                        systemImage: "eye.fill",
                        value: "\(viewModel.status.watchlistCount) path(s)",
                        vertical: SettingsLayout.usesVerticalRows(for: dynamicTypeSize)
                    )
                    SettingsKeyValueRow(
                        label: "Suppression",
                        systemImage: viewModel.status.suppressionActive ? "checkmark.circle.fill" : "circle",
                        value: viewModel.status.suppressionActive ? "Active" : "Inactive",
                        vertical: SettingsLayout.usesVerticalRows(for: dynamicTypeSize)
                    )
                    if viewModel.status.rematerializedTotal > 0 {
                        SettingsKeyValueRow(
                            label: "Re-evictions",
                            systemImage: "arrow.2.circlepath",
                            value: "\(viewModel.status.rematerializedTotal)",
                            vertical: SettingsLayout.usesVerticalRows(for: dynamicTypeSize)
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notificationBinding(_ keyPath: WritableKeyPath<AppConfig.NotificationsConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { configModel.config.notifications[keyPath: keyPath] },
            set: { value in
                var notifications = configModel.config.notifications
                notifications[keyPath: keyPath] = value
                configModel.updateNotifications(notifications)
            }
        )
    }
}

private struct PolicySettingsView: View {
    @Environment(AppConfigModel.self) private var configModel
    @State private var newProtectedPath = ""
    @State private var newKeepDownloadedPath = ""
    @State private var newFolderPolicyPath = ""
    @State private var newFolderPolicyMode: FolderPolicyMode = .protect
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @MainActor private var protectedPaths: [String] { configModel.selectedScope.protectedPaths }

    @MainActor private func saveProtectedPaths(_ paths: [String]) {
        var scope = configModel.selectedScope
        scope.protectedPaths = paths
        configModel.updateScope(scope)
    }

    @MainActor private func saveKeepDownloadedPaths(_ paths: [String]) {
        var scope = configModel.selectedScope
        scope.keepDownloadedPaths = paths
        configModel.updateScope(scope)
    }

    @MainActor private func saveFolderPolicies(_ policies: [FolderPolicyRule]) {
        var scope = configModel.selectedScope
        scope.folderPolicies = policies
        configModel.updateScope(scope)
    }

    /// Write a policy while preserving the trim > target invariant in the UI
    /// itself, so what you see is what the engine enforces.
    @MainActor private func savePolicy(_ mutate: (inout AppConfig.PolicyConfig) -> Void) {
        var policy = configModel.selectedPolicy
        mutate(&policy)
        policy.targetLocalGiB = max(policy.targetLocalGiB, 1)
        policy.trimLocalGiB = max(policy.trimLocalGiB, policy.targetLocalGiB + 1)
        policy.panicFreeGiB = max(policy.panicFreeGiB, 1)
        policy.remediateFreeGiB = max(policy.remediateFreeGiB, policy.panicFreeGiB)
        policy.warnFreeGiB = max(policy.warnFreeGiB, policy.remediateFreeGiB)
        configModel.updatePolicy(policy)
    }

    @MainActor private func saveWatcher(_ mutate: (inout AppConfig.WatcherConfig) -> Void) {
        var watcher = configModel.selectedWatcher
        mutate(&watcher)
        configModel.updateWatcher(watcher)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Local iCloud Thresholds")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Stepper("Target local: \(configModel.selectedPolicy.targetLocalGiB) GiB", value: Binding(get: { configModel.selectedPolicy.targetLocalGiB }, set: { newValue in savePolicy { $0.targetLocalGiB = newValue } }), in: 1...200)
                    Stepper("Trim trigger: \(configModel.selectedPolicy.trimLocalGiB) GiB", value: Binding(get: { configModel.selectedPolicy.trimLocalGiB }, set: { newValue in savePolicy { $0.trimLocalGiB = newValue } }), in: 1...300)
                    Text("When local iCloud copies exceed the trim trigger, the largest/oldest files are evicted (local copies only) until the footprint is back at the target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Group {
                    Text("Free Space Thresholds")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Stepper("Warn at: \(configModel.selectedPolicy.warnFreeGiB) GiB free", value: Binding(get: { configModel.selectedPolicy.warnFreeGiB }, set: { newValue in savePolicy { $0.warnFreeGiB = newValue } }), in: 10...500)
                    Stepper("Remediate at: \(configModel.selectedPolicy.remediateFreeGiB) GiB free", value: Binding(get: { configModel.selectedPolicy.remediateFreeGiB }, set: { newValue in savePolicy { $0.remediateFreeGiB = newValue } }), in: 10...500)
                    Stepper("Panic at: \(configModel.selectedPolicy.panicFreeGiB) GiB free", value: Binding(get: { configModel.selectedPolicy.panicFreeGiB }, set: { newValue in savePolicy { $0.panicFreeGiB = newValue } }), in: 5...500)
                }

                Divider()

                Group {
                    Text("Eviction Limits")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Stepper("Batch limit: \(configModel.selectedEviction.batchLimit) files", value: Binding(get: { configModel.selectedEviction.batchLimit }, set: { configModel.updateEviction(.init(batchLimit: $0, panicLimit: configModel.selectedEviction.panicLimit, protectBusyPackages: configModel.selectedEviction.protectBusyPackages)) }), in: 50...5000, step: 50)
                    Stepper("Panic limit: \(configModel.selectedEviction.panicLimit) files", value: Binding(get: { configModel.selectedEviction.panicLimit }, set: { configModel.updateEviction(.init(batchLimit: configModel.selectedEviction.batchLimit, panicLimit: $0, protectBusyPackages: configModel.selectedEviction.protectBusyPackages)) }), in: 100...10000, step: 100)
                    Toggle("Protect packages that are in use", isOn: Binding(
                        get: { configModel.selectedEviction.protectBusyPackages },
                        set: { configModel.updateEviction(.init(batchLimit: configModel.selectedEviction.batchLimit, panicLimit: configModel.selectedEviction.panicLimit, protectBusyPackages: $0)) }
                    ))
                    .accessibilityHint("Fails closed if native process inspection cannot determine whether a package is busy")
                }

                Divider()

                Group {
                    Text("Timing")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Stepper("Cooldown: \(configModel.selectedPolicy.cooldownMinutes)min", value: Binding(get: { configModel.selectedPolicy.cooldownMinutes }, set: { newValue in savePolicy { $0.cooldownMinutes = newValue } }), in: 1...120)
                    Stepper("Scan interval: \(configModel.selectedWatcher.pollutionCheckIntervalSeconds)s", value: Binding(get: { configModel.selectedWatcher.pollutionCheckIntervalSeconds }, set: { value in saveWatcher { $0.pollutionCheckIntervalSeconds = value } }), in: 60...3600, step: 60)
                    Stepper("Watchlist poll: \(configModel.selectedWatcher.watchlistPollSeconds)s", value: Binding(get: { configModel.selectedWatcher.watchlistPollSeconds }, set: { value in saveWatcher { $0.watchlistPollSeconds = value } }), in: 5...300, step: 5)
                    Stepper("Re-evict backoff max: \(configModel.selectedWatcher.backoffMaxSeconds)s", value: Binding(get: { configModel.selectedWatcher.backoffMaxSeconds }, set: { value in saveWatcher { $0.backoffMaxSeconds = value } }), in: 10...300, step: 10)
                    Stepper("Watchlist limit: \(configModel.selectedWatcher.watchlistMaxEntries)", value: Binding(get: { configModel.selectedWatcher.watchlistMaxEntries }, set: { value in saveWatcher { $0.watchlistMaxEntries = value } }), in: 100...100_000, step: 100)
                    Stepper("Verified retention: \(configModel.selectedWatcher.verifiedRetentionHours)h", value: Binding(get: { configModel.selectedWatcher.verifiedRetentionHours }, set: { value in saveWatcher { $0.verifiedRetentionHours = value } }), in: 1...8_760)
                    Stepper("Pending grace: \(configModel.selectedWatcher.pendingVerificationGraceSeconds)s", value: Binding(get: { configModel.selectedWatcher.pendingVerificationGraceSeconds }, set: { value in saveWatcher { $0.pendingVerificationGraceSeconds = value } }), in: 1...300)
                    Stepper("Pending retry limit: \(configModel.selectedWatcher.pendingRetryLimit)", value: Binding(get: { configModel.selectedWatcher.pendingRetryLimit }, set: { value in saveWatcher { $0.pendingRetryLimit = value } }), in: 1...100)
                    Stepper("Fight limit: \(configModel.selectedWatcher.maxFights)", value: Binding(get: { configModel.selectedWatcher.maxFights }, set: { value in saveWatcher { $0.maxFights = value } }), in: 1...100)
                }


                Divider()

                Group {
                    Text("Keep downloaded")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Scope-relative paths or globs that should remain local. These are separate from protected paths and are never eviction candidates.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Relative path or glob", text: $newKeepDownloadedPath)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("New keep-downloaded rule")
                        Button("Add") {
                            guard let rule = KeepDownloadedRule(pattern: newKeepDownloadedPath) else { return }
                            saveKeepDownloadedPaths(configModel.selectedScope.keepDownloadedPaths + [rule.pattern])
                            newKeepDownloadedPath = ""
                        }
                        .disabled(KeepDownloadedRule(pattern: newKeepDownloadedPath) == nil)
                    }
                    ForEach(configModel.selectedScope.keepDownloadedPaths, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Button {
                                saveKeepDownloadedPaths(configModel.selectedScope.keepDownloadedPaths.filter { $0 != path })
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove keep-downloaded rule \(path)")
                        }
                    }
                }

                Divider()

                Group {
                    Text("Per-folder policy")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("The most-specific scope-relative rule wins. Protect is enforced as an exclusion; evict-first and evict-last change candidate order.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("Mode", selection: $newFolderPolicyMode) {
                            ForEach(FolderPolicyMode.allCases, id: \.rawValue) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        TextField("Relative folder", text: $newFolderPolicyPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            guard let rule = try? FolderPolicyRule(path: newFolderPolicyPath, mode: newFolderPolicyMode) else { return }
                            let retained = configModel.selectedScope.folderPolicies.filter { $0.path != rule.path }
                            saveFolderPolicies(retained + [rule])
                            newFolderPolicyPath = ""
                        }
                        .disabled((try? FolderPolicyRule(path: newFolderPolicyPath, mode: newFolderPolicyMode)) == nil)
                    }
                    ForEach(configModel.selectedScope.folderPolicies, id: \.self) { rule in
                        HStack {
                            Text("\(rule.mode.rawValue): \(rule.path)").font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Button {
                                saveFolderPolicies(configModel.selectedScope.folderPolicies.filter { $0 != rule })
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove folder policy \(rule.serialized)")
                        }
                    }
                }

                Divider()

                Group {
                    Text("Protected Paths")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Files in these paths will never be evicted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let pathEditorLayout = SettingsLayout.usesVerticalRows(for: dynamicTypeSize)
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 8))
                    pathEditorLayout {
                        TextField("iCloud Drive path…", text: $newProtectedPath)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Protected iCloud Drive path")
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: newProtectedPath.isEmpty ? NSHomeDirectory() : (newProtectedPath as NSString).expandingTildeInPath)
                            if panel.runModal() == .OK, let url = panel.url {
                                newProtectedPath = url.path
                            }
                        }
                        .accessibilityHint("Selects a folder that iCloud Guard must never evict")
                        Button("Add") {
                            let trimmed = newProtectedPath.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            var paths = protectedPaths
                            paths.append(trimmed)
                            saveProtectedPaths(paths)
                            newProtectedPath = ""
                        }
                        .disabled(newProtectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                    }
                    ForEach(protectedPaths, id: \.self) { path in
                        let rowLayout = SettingsLayout.usesVerticalRows(for: dynamicTypeSize)
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                            : AnyLayout(HStackLayout(spacing: 8))
                        rowLayout {
                            Text(path)
                                .font(.caption)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Button {
                                var paths = protectedPaths
                                paths.removeAll { $0 == path }
                                saveProtectedPaths(paths)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, minHeight: 24)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove protected path")
                            .accessibilityValue(path)
                        }
                    }
                }
            }
            .disabled(!configModel.isConfigurationValid)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsKeyValueRow: View {
    let label: String
    let systemImage: String
    let value: String
    let vertical: Bool

    var body: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Label(label, systemImage: systemImage)
                .foregroundStyle(.secondary)
            if !vertical { Spacer() }
            Text(value)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

enum SettingsLayout {
    static func usesVerticalRows(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }
}

enum SettingsPresentation {
    static let spotlightSuppressionLabel = "Suppress Spotlight indexing"
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text("iCloud Guard")
                .font(.title3.bold())
            Text("Proactive suppression, correct eviction, and active defense against iCloud Drive rematerialization.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text("Version \(ICloudGuardProduct.version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iCloud Guard")
        .accessibilityValue("Version \(ICloudGuardProduct.version)")
    }
}

import AppKit
import SwiftUI
import ServiceManagement
import ICloudGuardCore

struct SettingsView: View {
    @ObservedObject var viewModel: GuardViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gearshape") }
            PolicySettingsView()
                .tabItem { Label("Policy", systemImage: "slider.horizontal.3") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 460, minHeight: 480)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var viewModel: GuardViewModel
    @AppStorage("runAtLogin") private var runAtLogin = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @Environment(AppConfigModel.self) private var configModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Startup")
                        .font(.headline)
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
                }

                Divider()

                Group {
                    Text("Download Suppression")
                        .font(.headline)
                    Toggle("Spotlight indexing of iCloud Drive", isOn: Binding(get: { configModel.config.suppression.spotlight }, set: { configModel.updateSuppression(.init(spotlight: $0, quicklook: configModel.config.suppression.quicklook, materializeDataless: configModel.config.suppression.materializeDataless)) }))
                        .toggleStyle(.switch)
                    Toggle("QuickLook cache clearing", isOn: Binding(get: { configModel.config.suppression.quicklook }, set: { configModel.updateSuppression(.init(spotlight: configModel.config.suppression.spotlight, quicklook: $0, materializeDataless: configModel.config.suppression.materializeDataless)) }))
                        .toggleStyle(.switch)
                    Toggle("Non-materializing I/O policy", isOn: Binding(get: { configModel.config.suppression.nonMaterializingIOPolicyEnabled }, set: { configModel.updateSuppression(.init(spotlight: configModel.config.suppression.spotlight, quicklook: configModel.config.suppression.quicklook, materializeDataless: !$0)) }))
                        .toggleStyle(.switch)
                    Text("Rematerialization defense is always on: recently evicted files are watched and re-evicted if iCloud downloads them again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Group {
                    Text("Active Defense")
                        .font(.headline)
                    HStack {
                        Label("Watchlist", systemImage: "eye.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(viewModel.status.watchlistCount) path(s)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Suppression", systemImage: viewModel.status.suppressionActive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.status.suppressionActive ? "Active" : "Inactive")
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.status.rematerializedTotal > 0 {
                        HStack {
                            Label("Re-evictions", systemImage: "arrow.2.circlepath")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(viewModel.status.rematerializedTotal)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PolicySettingsView: View {
    @Environment(AppConfigModel.self) private var configModel
    @State private var newProtectedPath = ""

    @MainActor private var protectedPaths: [String] { configModel.config.scope.protectedPaths }

    @MainActor private func saveProtectedPaths(_ paths: [String]) {
        configModel.updateScope(.init(path: configModel.config.scope.path, protectedPaths: paths))
    }

    /// Write a policy while preserving the trim > target invariant in the UI
    /// itself, so what you see is what the engine enforces.
    @MainActor private func savePolicy(_ mutate: (inout AppConfig.PolicyConfig) -> Void) {
        var policy = configModel.config.policy
        mutate(&policy)
        policy.targetLocalGiB = max(policy.targetLocalGiB, 1)
        policy.trimLocalGiB = max(policy.trimLocalGiB, policy.targetLocalGiB + 1)
        policy.panicFreeGiB = max(policy.panicFreeGiB, 1)
        policy.remediateFreeGiB = max(policy.remediateFreeGiB, policy.panicFreeGiB)
        policy.warnFreeGiB = max(policy.warnFreeGiB, policy.remediateFreeGiB)
        configModel.updatePolicy(policy)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Local iCloud Thresholds")
                        .font(.headline)
                    Stepper("Target local: \(configModel.config.policy.targetLocalGiB) GiB", value: Binding(get: { configModel.config.policy.targetLocalGiB }, set: { newValue in savePolicy { $0.targetLocalGiB = newValue } }), in: 1...200)
                    Stepper("Trim trigger: \(configModel.config.policy.trimLocalGiB) GiB", value: Binding(get: { configModel.config.policy.trimLocalGiB }, set: { newValue in savePolicy { $0.trimLocalGiB = newValue } }), in: 1...300)
                    Text("When local iCloud copies exceed the trim trigger, the largest/oldest files are evicted (local copies only) until the footprint is back at the target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Group {
                    Text("Free Space Thresholds")
                        .font(.headline)
                    Stepper("Warn at: \(configModel.config.policy.warnFreeGiB) GiB free", value: Binding(get: { configModel.config.policy.warnFreeGiB }, set: { newValue in savePolicy { $0.warnFreeGiB = newValue } }), in: 10...500)
                    Stepper("Remediate at: \(configModel.config.policy.remediateFreeGiB) GiB free", value: Binding(get: { configModel.config.policy.remediateFreeGiB }, set: { newValue in savePolicy { $0.remediateFreeGiB = newValue } }), in: 10...500)
                    Stepper("Panic at: \(configModel.config.policy.panicFreeGiB) GiB free", value: Binding(get: { configModel.config.policy.panicFreeGiB }, set: { newValue in savePolicy { $0.panicFreeGiB = newValue } }), in: 5...500)
                }

                Divider()

                Group {
                    Text("Eviction Limits")
                        .font(.headline)
                    Stepper("Batch limit: \(configModel.config.eviction.batchLimit) files", value: Binding(get: { configModel.config.eviction.batchLimit }, set: { configModel.updateEviction(.init(batchLimit: $0, panicLimit: configModel.config.eviction.panicLimit)) }), in: 50...5000, step: 50)
                    Stepper("Panic limit: \(configModel.config.eviction.panicLimit) files", value: Binding(get: { configModel.config.eviction.panicLimit }, set: { configModel.updateEviction(.init(batchLimit: configModel.config.eviction.batchLimit, panicLimit: $0)) }), in: 100...10000, step: 100)
                }

                Divider()

                Group {
                    Text("Timing")
                        .font(.headline)
                    Stepper("Cooldown: \(configModel.config.policy.cooldownMinutes)min", value: Binding(get: { configModel.config.policy.cooldownMinutes }, set: { newValue in savePolicy { $0.cooldownMinutes = newValue } }), in: 1...120)
                    Stepper("Scan interval: \(configModel.config.watcher.pollutionCheckIntervalSeconds)s", value: Binding(get: { configModel.config.watcher.pollutionCheckIntervalSeconds }, set: { configModel.updateWatcher(.init(backoffMaxSeconds: configModel.config.watcher.backoffMaxSeconds, pollutionCheckIntervalSeconds: $0, watchlistPollSeconds: configModel.config.watcher.watchlistPollSeconds)) }), in: 60...3600, step: 60)
                    Stepper("Watchlist poll: \(configModel.config.watcher.watchlistPollSeconds)s", value: Binding(get: { configModel.config.watcher.watchlistPollSeconds }, set: { configModel.updateWatcher(.init(backoffMaxSeconds: configModel.config.watcher.backoffMaxSeconds, pollutionCheckIntervalSeconds: configModel.config.watcher.pollutionCheckIntervalSeconds, watchlistPollSeconds: $0)) }), in: 5...300, step: 5)
                    Stepper("Re-evict backoff max: \(configModel.config.watcher.backoffMaxSeconds)s", value: Binding(get: { configModel.config.watcher.backoffMaxSeconds }, set: { configModel.updateWatcher(.init(backoffMaxSeconds: $0, pollutionCheckIntervalSeconds: configModel.config.watcher.pollutionCheckIntervalSeconds, watchlistPollSeconds: configModel.config.watcher.watchlistPollSeconds)) }), in: 10...300, step: 10)
                }

                Divider()

                Group {
                    Text("Protected Paths")
                        .font(.headline)
                    Text("Files in these paths will never be evicted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("iCloud Drive path…", text: $newProtectedPath)
                            .textFieldStyle(.roundedBorder)
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
                        Button("Add") {
                            let trimmed = newProtectedPath.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            var paths = protectedPaths
                            paths.append(trimmed)
                            saveProtectedPaths(paths)
                            newProtectedPath = ""
                        }
                    }
                    ForEach(protectedPaths, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                var paths = protectedPaths
                                paths.removeAll { $0 == path }
                                saveProtectedPaths(paths)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(.primary)
            Text("iCloud Guard")
                .font(.title3.bold())
            Text("Proactive suppression, correct eviction, and active defense against iCloud Drive rematerialization.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text("Version 0.4.4")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

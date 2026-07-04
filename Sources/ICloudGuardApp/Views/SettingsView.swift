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
                    Toggle("Non-materializing I/O policy", isOn: Binding(get: { configModel.config.suppression.materializeDataless }, set: { configModel.updateSuppression(.init(spotlight: configModel.config.suppression.spotlight, quicklook: configModel.config.suppression.quicklook, materializeDataless: $0)) }))
                        .toggleStyle(.switch)
                }

                Divider()

                Group {
                    Text("Active Defense")
                        .font(.headline)
                    HStack {
                        Label("Watcher", systemImage: viewModel.watcherActive ? "eye.fill" : "eye.slash")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.watcherActive ? "Active" : "Inactive")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Suppression", systemImage: viewModel.suppressionActive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.suppressionActive ? "Active" : "Inactive")
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.rematerializationCount > 0 {
                        HStack {
                            Label("Re-evictions", systemImage: "arrow.2.circlepath")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(viewModel.rematerializationCount)")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Local iCloud Thresholds")
                        .font(.headline)
                    Stepper("Target local: \(configModel.config.policy.targetLocalGiB) GiB", value: Binding(get: { configModel.config.policy.targetLocalGiB }, set: { configModel.updatePolicy(.init(targetLocalGiB: $0, trimLocalGiB: configModel.config.policy.trimLocalGiB, warnFreeGiB: configModel.config.policy.warnFreeGiB, remediateFreeGiB: configModel.config.policy.remediateFreeGiB, panicFreeGiB: configModel.config.policy.panicFreeGiB, cooldownMinutes: configModel.config.policy.cooldownMinutes, growthTriggerGiB: configModel.config.policy.growthTriggerGiB, growthWindowMinutes: configModel.config.policy.growthWindowMinutes)) }), in: 1...200)
                    Stepper("Trim trigger: \(configModel.config.policy.trimLocalGiB) GiB", value: Binding(get: { configModel.config.policy.trimLocalGiB }, set: { configModel.updatePolicy(.init(targetLocalGiB: configModel.config.policy.targetLocalGiB, trimLocalGiB: $0, warnFreeGiB: configModel.config.policy.warnFreeGiB, remediateFreeGiB: configModel.config.policy.remediateFreeGiB, panicFreeGiB: configModel.config.policy.panicFreeGiB, cooldownMinutes: configModel.config.policy.cooldownMinutes, growthTriggerGiB: configModel.config.policy.growthTriggerGiB, growthWindowMinutes: configModel.config.policy.growthWindowMinutes)) }), in: 1...300)
                }

                Divider()

                Group {
                    Text("Free Space Thresholds")
                        .font(.headline)
                    Stepper("Warn at: \(configModel.config.policy.warnFreeGiB) GiB free", value: Binding(get: { configModel.config.policy.warnFreeGiB }, set: { configModel.updatePolicy(.init(targetLocalGiB: configModel.config.policy.targetLocalGiB, trimLocalGiB: configModel.config.policy.trimLocalGiB, warnFreeGiB: $0, remediateFreeGiB: configModel.config.policy.remediateFreeGiB, panicFreeGiB: configModel.config.policy.panicFreeGiB, cooldownMinutes: configModel.config.policy.cooldownMinutes, growthTriggerGiB: configModel.config.policy.growthTriggerGiB, growthWindowMinutes: configModel.config.policy.growthWindowMinutes)) }), in: 10...500)
                    Stepper("Remediate at: \(configModel.config.policy.remediateFreeGiB) GiB free", value: Binding(get: { configModel.config.policy.remediateFreeGiB }, set: { configModel.updatePolicy(.init(targetLocalGiB: configModel.config.policy.targetLocalGiB, trimLocalGiB: configModel.config.policy.trimLocalGiB, warnFreeGiB: configModel.config.policy.warnFreeGiB, remediateFreeGiB: $0, panicFreeGiB: configModel.config.policy.panicFreeGiB, cooldownMinutes: configModel.config.policy.cooldownMinutes, growthTriggerGiB: configModel.config.policy.growthTriggerGiB, growthWindowMinutes: configModel.config.policy.growthWindowMinutes)) }), in: 10...500)
                    Stepper("Panic at: \(configModel.config.policy.panicFreeGiB) GiB free", value: Binding(get: { configModel.config.policy.panicFreeGiB }, set: { configModel.updatePolicy(.init(targetLocalGiB: configModel.config.policy.targetLocalGiB, trimLocalGiB: configModel.config.policy.trimLocalGiB, warnFreeGiB: configModel.config.policy.warnFreeGiB, remediateFreeGiB: configModel.config.policy.remediateFreeGiB, panicFreeGiB: $0, cooldownMinutes: configModel.config.policy.cooldownMinutes, growthTriggerGiB: configModel.config.policy.growthTriggerGiB, growthWindowMinutes: configModel.config.policy.growthWindowMinutes)) }), in: 5...500)
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
                    Stepper("Cooldown: \(configModel.config.policy.cooldownMinutes)min", value: Binding(get: { configModel.config.policy.cooldownMinutes }, set: { configModel.updatePolicy(.init(targetLocalGiB: configModel.config.policy.targetLocalGiB, trimLocalGiB: configModel.config.policy.trimLocalGiB, warnFreeGiB: configModel.config.policy.warnFreeGiB, remediateFreeGiB: configModel.config.policy.remediateFreeGiB, panicFreeGiB: configModel.config.policy.panicFreeGiB, cooldownMinutes: $0, growthTriggerGiB: configModel.config.policy.growthTriggerGiB, growthWindowMinutes: configModel.config.policy.growthWindowMinutes)) }), in: 1...120)
                    Stepper("Pollution check: \(configModel.config.watcher.pollutionCheckIntervalSeconds)s", value: Binding(get: { configModel.config.watcher.pollutionCheckIntervalSeconds }, set: { configModel.updateWatcher(.init(backoffMaxSeconds: configModel.config.watcher.backoffMaxSeconds, pollutionCheckIntervalSeconds: $0)) }), in: 60...3600, step: 60)
                    Stepper("Watcher backoff max: \(configModel.config.watcher.backoffMaxSeconds)s", value: Binding(get: { configModel.config.watcher.backoffMaxSeconds }, set: { configModel.updateWatcher(.init(backoffMaxSeconds: $0, pollutionCheckIntervalSeconds: configModel.config.watcher.pollutionCheckIntervalSeconds)) }), in: 10...300, step: 10)
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
            Text("Version 0.3.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

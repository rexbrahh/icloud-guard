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
    @AppStorage("spotlightSuppression") private var spotlightSuppression = true
    @AppStorage("quickLookCacheClear") private var quickLookCacheClear = true
    @AppStorage("materializeDatalessFiles") private var materializeDatalessFiles = false

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
                    Toggle("Spotlight indexing of iCloud Drive", isOn: $spotlightSuppression)
                        .toggleStyle(.switch)
                    Toggle("QuickLook cache clearing", isOn: $quickLookCacheClear)
                        .toggleStyle(.switch)
                    Toggle("Non-materializing I/O policy", isOn: $materializeDatalessFiles)
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
    @AppStorage("targetLocalGiB") private var targetLocalGiB = 10
    @AppStorage("trimLocalGiB") private var trimLocalGiB = 15
    @AppStorage("warnFreeGiB") private var warnFreeGiB = 100
    @AppStorage("remediateFreeGiB") private var remediateFreeGiB = 80
    @AppStorage("panicFreeGiB") private var panicFreeGiB = 50
    @AppStorage("cooldownMinutes") private var cooldownMinutes = 2
    @AppStorage("evictionBatchLimit") private var evictionBatchLimit = 500
    @AppStorage("panicBatchLimit") private var panicBatchLimit = 2000
    @AppStorage("pollutionCheckIntervalSeconds") private var pollutionCheckInterval = 300
    @AppStorage("watcherBackoffMaxSeconds") private var watcherBackoffMax = 60
    @State private var newProtectedPath = ""
    @AppStorage("protectedPaths") private var protectedPathsData = Data()

    private var protectedPaths: [String] {
        get { (try? JSONDecoder().decode([String].self, from: protectedPathsData)) ?? [] }
    }

    private func saveProtectedPaths(_ paths: [String]) {
        protectedPathsData = (try? JSONEncoder().encode(paths)) ?? Data()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Local iCloud Thresholds")
                        .font(.headline)
                    Stepper("Target local: \(targetLocalGiB) GiB", value: $targetLocalGiB, in: 1...200)
                    Stepper("Trim trigger: \(trimLocalGiB) GiB", value: $trimLocalGiB, in: 1...300)
                }

                Divider()

                Group {
                    Text("Free Space Thresholds")
                        .font(.headline)
                    Stepper("Warn at: \(warnFreeGiB) GiB free", value: $warnFreeGiB, in: 10...500)
                    Stepper("Remediate at: \(remediateFreeGiB) GiB free", value: $remediateFreeGiB, in: 10...500)
                    Stepper("Panic at: \(panicFreeGiB) GiB free", value: $panicFreeGiB, in: 5...500)
                }

                Divider()

                Group {
                    Text("Eviction Limits")
                        .font(.headline)
                    Stepper("Batch limit: \(evictionBatchLimit) files", value: $evictionBatchLimit, in: 50...5000, step: 50)
                    Stepper("Panic limit: \(panicBatchLimit) files", value: $panicBatchLimit, in: 100...10000, step: 100)
                }

                Divider()

                Group {
                    Text("Timing")
                        .font(.headline)
                    Stepper("Cooldown: \(cooldownMinutes)min", value: $cooldownMinutes, in: 1...120)
                    Stepper("Pollution check: \(pollutionCheckInterval)s", value: $pollutionCheckInterval, in: 60...3600, step: 60)
                    Stepper("Watcher backoff max: \(watcherBackoffMax)s", value: $watcherBackoffMax, in: 10...300, step: 10)
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
            Text("Version 0.2.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

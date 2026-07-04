import SwiftUI
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
        .frame(width: 460, height: 420)
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
    @AppStorage("evictionBatchLimit") private var evictionBatchLimit = 500
    @AppStorage("panicBatchLimit") private var panicBatchLimit = 2000
    @AppStorage("pollutionCheckIntervalSeconds") private var pollutionCheckInterval = 300
    @AppStorage("watcherBackoffMaxSeconds") private var watcherBackoffMax = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                    Stepper("Pollution check: \(pollutionCheckInterval)s", value: $pollutionCheckInterval, in: 60...3600, step: 60)
                    Stepper("Watcher backoff max: \(watcherBackoffMax)s", value: $watcherBackoffMax, in: 10...300, step: 10)
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

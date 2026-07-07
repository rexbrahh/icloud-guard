import SwiftUI
import AppKit
import ICloudGuardCore

struct StatusBarView: View {
    @ObservedObject var viewModel: GuardViewModel
    @Environment(AppConfigModel.self) private var configModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status header
            HStack(spacing: 6) {
                Image(systemName: viewModel.statusIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Text(viewModel.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if viewModel.freeSpaceBytes > 0 {
                    Text(viewModel.freeSpaceLabel + " free")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Pollution gauge
            if viewModel.materializedCount > 0 || viewModel.datalessCount > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("iCloud pollution")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(viewModel.materializedCount) materialized")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.6))
                                .frame(width: geo.size.width * viewModel.pollutionRatio, height: 4)
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(viewModel.datalessCount > 0 ? "\(viewModel.datalessCount) evicted" : "")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(Int(viewModel.pollutionRatio * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Top folders by local space
            if !viewModel.topFolders.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top folders")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(viewModel.topFolders.prefix(3), id: \.name) { folder in
                        HStack {
                            Text(folder.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(formatBytes(folder.bytes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Defense status badges
            HStack(spacing: 8) {
                if viewModel.suppressionActive {
                    Label("Suppressed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if viewModel.watcherActive {
                    Label("Watching", systemImage: "eye.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if viewModel.rematerializationCount > 0 {
                    Label("\(viewModel.rematerializationCount)", systemImage: "arrow.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Lifetime stats
            if viewModel.lifetimeEvictedCount > 0 {
                Text("Lifetime: \(viewModel.lifetimeLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // Error display
            if let error = viewModel.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider()

            // Actions
            Button {
                viewModel.runEviction()
            } label: {
                Label("Evict Now", systemImage: "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isEvicting || viewModel.isPaused)
            .padding(.vertical, 2)

            Button {
                viewModel.panicEvict()
            } label: {
                Label("Panic Evict", systemImage: "exclamationmark.icloud")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isEvicting || viewModel.isPaused)
            .padding(.vertical, 2)

            Button {
                viewModel.togglePause()
            } label: {
                Label(viewModel.isPaused ? "Resume" : "Pause", systemImage: viewModel.isPaused ? "play.circle" : "pause.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            Divider()

            // Settings + Quit
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .padding(.vertical, 2)

            Button {
                viewModel.stopGuardService()
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .padding(.vertical, 2)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            viewModel.startGuardService(scopePath: configModel.config.scope.path)
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .file
        return f
    }()

    private func formatBytes(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }
}

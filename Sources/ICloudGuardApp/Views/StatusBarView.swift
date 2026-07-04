import SwiftUI
import AppKit
import ICloudGuardCore

struct StatusBarView: View {
    @ObservedObject var viewModel: GuardViewModel
    private let scopePath = "\(NSHomeDirectory())/Library/Mobile Documents/com~apple~CloudDocs"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status header — monochrome, compact
            HStack(spacing: 6) {
                Image(systemName: viewModel.statusIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Text(viewModel.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            // Pollution gauge — the key metric
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
                    // Pollution bar — monochrome
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

            // Defense status — compact badges
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

            // Error display — only if present
            if let error = viewModel.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider()

            // Actions — full width, vertical stack
            Button {
                viewModel.runEviction()
            } label: {
                Label("Evict Now", systemImage: "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isEvicting)
            .padding(.vertical, 2)

            Button {
                viewModel.panicEvict()
            } label: {
                Label("Panic Evict", systemImage: "exclamationmark.icloud")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isEvicting)
            .padding(.vertical, 2)

            Divider()

            // Settings + Quit — full width
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings…", systemImage: "gearshape")
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
        .frame(width: 260)
        .onAppear {
            viewModel.startGuardService(scopePath: scopePath)
        }
    }
}

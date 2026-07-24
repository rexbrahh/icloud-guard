import SwiftUI
import AppKit
import ICloudGuardCore

struct StatusBarView: View {
    @ObservedObject var viewModel: GuardViewModel
    @Environment(AppConfigModel.self) private var configModel
    @State private var showPanicConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection

            if let progress = viewModel.status.progress, viewModel.status.isRunning {
                progressSection(progress)
            }

            if viewModel.status.hasStats {
                statsSection
            }

            defenseSection

            if let report = viewModel.status.lastReport {
                lastRunSection(report)
            }

            if let error = viewModel.status.lastError {
                HStack(alignment: .top, spacing: 4) {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        viewModel.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }

            Divider()
            actionsSection
            Divider()
            footerSection
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            viewModel.startGuardService(scopePath: configModel.config.scope.path)
            viewModel.refreshPolicyCache()
            viewModel.refreshFreeSpace()
            viewModel.requestScanIfStale()
        }
        .confirmationDialog(
            "Panic evict everything eligible? Local copies are removed; cloud copies are retained.",
            isPresented: $showPanicConfirm,
            titleVisibility: .visible
        ) {
            Button("Panic Evict", role: .destructive) { viewModel.panicEvict() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.statusIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(viewModel.statusIconColor)
            Text(viewModel.statusText)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !viewModel.freeSpaceLabel.isEmpty {
                Text(viewModel.freeSpaceLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(viewModel.isCriticalDisk ? .red : .secondary)
            }
        }
    }

    // MARK: - Progress

    private func progressSection(_ progress: EvictionProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(progress.phase == .scanning ? "Scanning…" : "Evicting…")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("Cancel") { viewModel.cancelRun() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if progress.phase == .scanning {
                Text("\(progress.scannedFiles) files scanned · \(progress.candidateCount) candidates (\(viewModel.formatBytes(progress.candidateBytes)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: viewModel.progressFraction(progress))
                    .progressViewStyle(.linear)
                    .frame(height: 4)
                Text(viewModel.progressDetail(progress))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let currentPath = progress.currentPath {
                    Text(currentPath)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let failureSummary = progress.failureSummary {
                Text(failureSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.footprintLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(viewModel.isUnderTarget ? .secondary : .primary)
                Spacer()
                Text("\(Int(viewModel.status.materializedRatio * 100))% local")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(gaugeColor)
                        .frame(width: geo.size.width * min(gaugeFraction, 1), height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                Text(viewModel.pollutionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // Freshness: what the user is looking at and how old it is.
            if viewModel.status.scanInProgress {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Scanning… \(viewModel.status.scanFilesScanned) files")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            } else if let completedAt = viewModel.status.lastScanCompletedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(freshnessLabel(at: context.date, completedAt: completedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            if let cooldown = viewModel.status.cooldownRemainingSeconds, cooldown > 0 {
                Text("Auto-trim cooldown: \(cooldown / 60)m")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if viewModel.status.fightingCount > 0 {
                Text("\(viewModel.status.fightingCount) file(s) fighting iCloud re-downloads")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            if !viewModel.status.topFolders.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.status.topFolders.prefix(3), id: \.name) { folder in
                        HStack(spacing: 4) {
                            Text(folder.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(viewModel.formatBytes(folder.bytes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Button {
                                viewModel.evictFolder(folder.name)
                            } label: {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.status.isRunning || viewModel.status.isPaused)
                            .help("Evict local copies in \(folder.name)")
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Bar fills toward the trim trigger; color follows policy bands.
    private var gaugeFraction: Double {
        let trimBytes = Int64(configModel.config.policy.trimLocalGiB) * 1024 * 1024 * 1024
        guard trimBytes > 0 else { return 0 }
        return Double(viewModel.status.materializedBytes) / Double(trimBytes)
    }

    private var gaugeColor: Color {
        if viewModel.isCriticalDisk { return .red.opacity(0.8) }
        if gaugeFraction >= 1 { return .red.opacity(0.8) }
        if viewModel.isUnderTarget { return .green.opacity(0.7) }
        return .orange.opacity(0.8)
    }

    private func freshnessLabel(at now: Date, completedAt: Date) -> String {
        let age = max(Int(now.timeIntervalSince(completedAt)), 0)
        let ageText: String
        if age < 60 {
            ageText = "just now"
        } else if age < 3600 {
            ageText = "\(age / 60)m ago"
        } else {
            ageText = "\(age / 3600)h ago"
        }
        let duration = viewModel.status.lastScanDuration
        let durationText = duration > 0 ? String(format: " in %.0fs", duration) : ""
        return "Updated \(ageText)\(durationText)"
    }

    // MARK: - Defense badges

    private var defenseSection: some View {
        HStack(spacing: 8) {
            if viewModel.status.suppressionActive {
                Label("Suppressed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if viewModel.status.watchlistCount > 0 {
                Label("Watching \(viewModel.status.watchlistCount)", systemImage: "eye.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if viewModel.status.rematerializedTotal > 0 {
                Label("\(viewModel.status.rematerializedTotal) bounced", systemImage: "arrow.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(viewModel.status.lastRematerializedPath.map { "Latest: \($0)" } ?? "")
            }
            Spacer()
        }
    }

    // MARK: - Last run

    private func lastRunSection(_ report: GuardRunReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if report.kind == .preview {
                Text("Preview: \(report.candidateCount) file(s), \(viewModel.formatBytes(report.previewBytes)) reclaimable")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if report.cancelled {
                Text("Last run cancelled · \(viewModel.formatBytes(report.reclaimedBytes)) reclaimed")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("Last run: \(report.evictedCount) evicted · \(viewModel.formatBytes(report.reclaimedBytes)) reclaimed")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if report.failedCount > 0, let top = report.failureReasons.max(by: { $0.value < $1.value }) {
                Text("\(report.failedCount) failed (mostly \(top.key))")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            if viewModel.status.lifetimeEvictedCount > 0 {
                Text("Lifetime: \(viewModel.lifetimeLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 4) {
            Button {
                viewModel.trimNow()
            } label: {
                Label("Trim to Target", systemImage: "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.status.isRunning || viewModel.status.isPaused)

            HStack(spacing: 6) {
                Button {
                    viewModel.preview()
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.status.isRunning || viewModel.status.isPaused)

                Button(role: .destructive) {
                    showPanicConfirm = true
                } label: {
                    Label("Panic", systemImage: "exclamationmark.icloud")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.status.isRunning || viewModel.status.isPaused)

                Spacer()

                Button {
                    viewModel.togglePause()
                } label: {
                    Label(viewModel.status.isPaused ? "Resume" : "Pause",
                          systemImage: viewModel.status.isPaused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.status.isRunning)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Button {
                viewModel.stopGuardService()
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .keyboardShortcut("q")
        }
    }
}

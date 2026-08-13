import SwiftUI
import AppKit
import Charts
import ICloudGuardCore

struct StatusBarView: View {
    @ObservedObject var viewModel: GuardViewModel
    @Environment(AppConfigModel.self) private var configModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openSettings) private var openSettings
    @State private var showPanicConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                headerSection

                if configModel.scopeSelections.count > 1 {
                    Picker("Managed scope", selection: scopeSelection) {
                        ForEach(configModel.scopeSelections, id: \.id) { scope in
                            Text(scope.name).tag(scope.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityHint("Changes the scope shown here and targeted by manual actions")
                }

                if viewModel.operations.firstRunDoctorReviewRequired {
                    Label("Review first-run diagnostics in Settings > Operations.", systemImage: "stethoscope")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("First-run diagnostics review required")
                }

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
                    HStack(alignment: .top, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            viewModel.dismissError()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 24, minHeight: 24)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss error")
                        .help("Dismiss error")
                    }
                }

                Divider()
                actionsSection
                Divider()
                footerSection
            }
            .padding(12)
        }
        .frame(
            minWidth: StatusBarLayout.minimumWidth(for: dynamicTypeSize),
            idealWidth: StatusBarLayout.idealWidth(for: dynamicTypeSize),
            maxWidth: 480,
            minHeight: StatusBarLayout.minimumHeight(for: dynamicTypeSize),
            maxHeight: 700
        )
        .onAppear {
            viewModel.startGuardServices(
                config: configModel.config,
                selectedScopeID: configModel.selectedScopeID
            )
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

    private var scopeSelection: Binding<String> {
        Binding(
            get: { configModel.selectedScopeID ?? "" },
            set: { id in
                guard configModel.selectScope(id: id) else { return }
                _ = viewModel.selectScope(id: id)
            }
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.statusIcon)
                .font(.headline)
                .foregroundStyle(viewModel.statusIconColor)
                .accessibilityHidden(true)
            Text(viewModel.statusText)
                .font(.headline)
            Spacer()
            if !viewModel.freeSpaceLabel.isEmpty {
                Text(viewModel.freeSpaceLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(viewModel.isCriticalDisk ? .red : .secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("iCloud Guard status")
        .accessibilityValue(
            StatusBarAccessibility.statusValue(
                status: viewModel.status,
                title: viewModel.statusText,
                freeSpace: viewModel.freeSpaceLabel
            )
        )
    }

    // MARK: - Progress

    private func progressSection(_ progress: EvictionProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(progress.phase == .scanning ? "Scanning…" : "Evicting…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Cancel") { viewModel.cancelRun() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops the current scan or eviction run")
            }
            if progress.phase == .scanning {
                Text("\(progress.scannedFiles) files scanned · \(progress.candidateCount) candidates (\(viewModel.formatBytes(progress.candidateBytes)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: viewModel.progressFraction(progress))
                    .progressViewStyle(.linear)
                Text(viewModel.progressDetail(progress))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let currentPath = progress.currentPath {
                    Text(currentPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityLabel("Current path")
                        .accessibilityValue(currentPath)
                }
            }
            if let failureSummary = progress.failureSummary {
                Text(failureSummary)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.phase == .scanning ? "Scan progress" : "Eviction progress")
        .accessibilityValue(
            StatusBarAccessibility.progressValue(progress, formatBytes: viewModel.formatBytes)
        )
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.footprintLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(viewModel.isUnderTarget ? .secondary : .primary)
                Spacer()
                Text("\(Int(viewModel.status.materializedRatio * 100))% local")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: min(max(gaugeFraction, 0), 1))
                .progressViewStyle(.linear)
                .tint(gaugeColor)
                .accessibilityLabel("Local iCloud footprint")
                .accessibilityValue("\(Int((gaugeFraction * 100).rounded())) percent of the trim threshold")

            if let criticalState = StatusBarAccessibility.criticalFreeSpaceValue(
                hasStats: viewModel.status.hasStats,
                freeSpaceAvailable: viewModel.status.freeSpaceAvailable,
                freeBytes: viewModel.status.freeBytes,
                panicFreeBytes: Int64(configModel.selectedPolicy.panicFreeGiB) * 1024 * 1024 * 1024,
                formatBytes: viewModel.formatBytes
            ) {
                Label(criticalState, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Critical free-space warning")
                    .accessibilityValue(criticalState)
            }

            if viewModel.status.footprintSamples.count >= 2 {
                FootprintChart(
                    samples: viewModel.status.footprintSamples,
                    targetBytes: Int64(configModel.selectedPolicy.targetLocalGiB) * 1024 * 1024 * 1024
                )
                .frame(height: 34)
                .padding(.top, 2)
            }

            HStack {
                Text(viewModel.pollutionLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // Freshness: what the user is looking at and how old it is.
            if viewModel.status.scanInProgress {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Scanning… \(viewModel.status.scanFilesScanned) files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let completedAt = viewModel.status.lastScanCompletedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(freshnessLabel(at: context.date, completedAt: completedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let cooldown = viewModel.status.cooldownRemainingSeconds, cooldown > 0 {
                Text("Auto-trim cooldown: \(cooldown / 60)m")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if viewModel.status.fightingCount > 0 {
                Text("\(viewModel.status.fightingCount) file(s) fighting iCloud re-downloads")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if !viewModel.status.topFolders.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.status.topFolders.prefix(3), id: \.name) { folder in
                        let folderLayout = StatusBarLayout.usesVerticalRows(for: dynamicTypeSize)
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 4))
                        folderLayout {
                            Text(folder.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text(viewModel.formatBytes(folder.bytes))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            Button {
                                viewModel.evictFolder(folder.name)
                            } label: {
                                Image(systemName: "arrow.up.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, minHeight: 24)
                            }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.status.isRunning || viewModel.status.isPaused)
                            .accessibilityLabel("Evict local copies in \(folder.name)")
                            .accessibilityHint("Cloud copies are retained")
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
        let trimBytes = Int64(configModel.selectedPolicy.trimLocalGiB) * 1024 * 1024 * 1024
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
        let layout = StatusBarLayout.usesVerticalRows(for: dynamicTypeSize)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if viewModel.status.suppressionActive {
                Label("Suppressed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.status.watchlistCount > 0 {
                Label("Watching \(viewModel.status.watchlistCount)", systemImage: "eye.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.status.rematerializedTotal > 0 {
                Label("\(viewModel.status.rematerializedTotal) bounced", systemImage: "arrow.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(viewModel.status.lastRematerializedPath.map { "Latest: \($0)" } ?? "")
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        }
    }

    // MARK: - Last run

    private func lastRunSection(_ report: GuardRunReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if report.kind == .preview {
                Text("Preview: \(report.candidateCount) file(s), \(viewModel.formatBytes(report.previewBytes)) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if report.cancelled {
                Text("Last run cancelled · \(viewModel.formatBytes(report.reclaimedBytes)) reclaimed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Last run: \(report.evictedCount) evicted · \(viewModel.formatBytes(report.reclaimedBytes)) reclaimed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if report.failedCount > 0, let top = report.failureReasons.max(by: { $0.value < $1.value }) {
                Text("\(report.failedCount) failed (mostly \(top.key))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !report.busyProcessDisplayNames.isEmpty {
                Text(StatusBarAccessibility.busyPackageAssistance(
                    processDisplayNames: report.busyProcessDisplayNames
                ))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if report.pendingCount > 0 {
                Text("\(report.pendingCount) awaiting verification")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if viewModel.status.lifetimeEvictedCount > 0 {
                Text("Lifetime: \(viewModel.lifetimeLabel)")
                    .font(.caption2)
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
            .controlSize(.regular)
            .disabled(viewModel.status.isRunning || viewModel.status.isPaused)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Evicts local copies until the configured target is reached")

            let layout = StatusBarLayout.usesVerticalActions(for: dynamicTypeSize)
                ? AnyLayout(VStackLayout(spacing: 6))
                : AnyLayout(HStackLayout(spacing: 6))
            layout {
                Button {
                    viewModel.preview()
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(viewModel.status.isRunning || viewModel.status.isPaused)
                .accessibilityHint("Shows eligible files without changing them")

                Button(role: .destructive) {
                    showPanicConfirm = true
                } label: {
                    Label("Panic", systemImage: "exclamationmark.icloud")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(viewModel.status.isRunning || viewModel.status.isPaused)
                .accessibilityLabel("Panic eviction")
                .accessibilityHint("Asks for confirmation before evicting all eligible local copies")

                if !StatusBarLayout.usesVerticalActions(for: dynamicTypeSize) {
                    Spacer()
                }

                Button {
                    viewModel.togglePause()
                } label: {
                    Label(viewModel.status.isPaused ? "Resume" : "Pause",
                          systemImage: viewModel.status.isPaused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(viewModel.status.isRunning)
                .accessibilityHint(viewModel.status.isPaused ? "Restarts automatic protection" : "Stops automatic protection until resumed")
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .font(.body)
            .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .font(.body)
            .keyboardShortcut("q")
        }
    }
}

// MARK: - Footprint sparkline

private struct FootprintChart: View {
    let samples: [GuardSample]
    let targetBytes: Int64

    var body: some View {
        Chart(samples, id: \.timestamp) { sample in
            AreaMark(
                x: .value("Time", sample.timestamp),
                y: .value("Local", sample.localBytes)
            )
            .foregroundStyle(Color.blue.opacity(0.18))
            LineMark(
                x: .value("Time", sample.timestamp),
                y: .value("Local", sample.localBytes)
            )
            .foregroundStyle(Color.blue.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            if targetBytes > 0 {
                RuleMark(y: .value("Target", targetBytes))
                    .foregroundStyle(Color.green.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityLabel("Local iCloud footprint over 24 hours")
        .accessibilityValue(targetBytes > 0 ? "\(samples.count) samples with a target line" : "\(samples.count) samples")
    }
}

enum StatusBarLayout {
    static func minimumWidth(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? 400 : 320
    }

    static func idealWidth(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? 440 : 340
    }

    static func minimumHeight(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? 420 : 280
    }

    static func usesVerticalActions(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    static func usesVerticalRows(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }
}

enum StatusBarAccessibility {
    static func statusValue(status: GuardStatus, title: String, freeSpace: String) -> String {
        var parts = [title]
        if status.hasStats {
            let scanState = status.scanComplete ? "Scan complete" : "Scan incomplete"
            if scanState != title { parts.append(scanState) }
        }
        if !freeSpace.isEmpty { parts.append(freeSpace) }
        if let error = status.lastError { parts.append("Error: \(error)") }
        return parts.joined(separator: ", ")
    }

    static func progressValue(
        _ progress: EvictionProgress,
        formatBytes: (Int64) -> String
    ) -> String {
        if progress.phase == .scanning {
            return "\(progress.scannedFiles) files scanned, \(progress.candidateCount) candidates, \(formatBytes(progress.candidateBytes)) eligible"
        }
        let processed = progress.evictedCount + progress.pendingCount + progress.failedCount
        return "\(processed) of \(progress.candidateCount) files processed, \(formatBytes(progress.reclaimedBytes)) reclaimed, \(progress.pendingCount) awaiting verification, \(progress.failedCount) failed"
    }

    static func busyPackageAssistance(processDisplayNames: [String]) -> String {
        let boundedNames = processDisplayNames.prefix(5).joined(separator: ", ")
        return "Close \(boundedNames) and retry the package"
    }

    static func criticalFreeSpaceValue(
        hasStats: Bool,
        freeSpaceAvailable: Bool,
        freeBytes: Int64,
        panicFreeBytes: Int64,
        formatBytes: (Int64) -> String
    ) -> String? {
        guard hasStats, freeSpaceAvailable, freeBytes < panicFreeBytes else { return nil }
        return "Critical: \(formatBytes(freeBytes)) free, below the \(formatBytes(panicFreeBytes)) panic threshold"
    }
}

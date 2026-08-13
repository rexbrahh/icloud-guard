import AppKit
import ICloudGuardCore
import SwiftUI
import UniformTypeIdentifiers

struct OperationsSettingsView: View {
    @ObservedObject var viewModel: GuardViewModel
    @State private var historyStatus = "all"
    @State private var goal = "5GiB"
    @State private var revealWatchlistPaths = false

    private var filteredHistory: [GuardRunReceipt] {
        guard historyStatus != "all" else { return viewModel.operations.history }
        return viewModel.operations.history.filter { $0.status.rawValue == historyStatus }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                doctorSection
                Divider()
                reclaimSection
                Divider()
                recoverySection
                Divider()
                scopeBrowserSection
                Divider()
                historySection
                Divider()
                watchlistSection
                Divider()
                supportSection
                Divider()
                updateSection
                if let error = viewModel.operations.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Operations error: \(error)")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { viewModel.refreshOperations() }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local recovery and pinning").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Restore requests use the private identity-bound journal from the most recent verified eviction. Keep-downloaded rules only request local materialization; they never weaken protection.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restore last run locally") { viewModel.restoreLastRun() }
                    .disabled(viewModel.status.isRunning || viewModel.operations.loading)
                    .accessibilityHint("Requests local downloads only for identity-verified items from the last recorded eviction")
                Button("Enforce keep-downloaded rules") { viewModel.enforceKeepDownloaded() }
                    .disabled(viewModel.status.isRunning || viewModel.operations.loading)
                    .accessibilityHint("Requests local downloads for configured keep-downloaded paths")
            }
        }
    }

    private var scopeBrowserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iCloud scope browser").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle("Reveal relative paths", isOn: $revealWatchlistPaths)
                    .onChange(of: revealWatchlistPaths) { _, value in
                        viewModel.refreshOperations(revealWatchlistPaths: value)
                    }
            }
            Text("Read-only metadata view. It does not download or evict items.")
                .font(.caption).foregroundStyle(.secondary)
            if let report = viewModel.operations.scopeBrowser {
                Text("Showing \(report.rows.count) entries\(report.truncated ? " (bounded result)" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(report.rows.prefix(100)) { row in
                    HStack {
                        Text(row.displayPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(row.policy.rawValue) · \(row.residency.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.displayPath), \(row.policy.rawValue), \(row.residency.rawValue)")
                }
            } else {
                Text("Scope metadata is unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    private var doctorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.operations.firstRunDoctorReviewRequired ? "First-run diagnostics" : "Diagnostics")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Run doctor") { viewModel.refreshOperations(revealWatchlistPaths: revealWatchlistPaths) }
                    .accessibilityHint("Runs read-only configuration and system checks")
            }
            if let doctor = viewModel.operations.doctor {
                ForEach(doctor.checks) { check in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(check.message, systemImage: check.status == .passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.status == .failed ? .red : (check.status == .passed ? .secondary : .orange))
                        if check.status != .passed {
                            Text(check.remediation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(check.id), \(check.status.rawValue)")
                    .accessibilityValue("\(check.message) \(check.remediation)")
                }
            } else {
                ProgressView("Running read-only diagnostics")
            }
            if viewModel.operations.firstRunDoctorReviewRequired {
                Button("Mark diagnostics reviewed") { viewModel.acknowledgeFirstRunDoctor() }
                    .accessibilityHint("Keeps diagnostics available and dismisses the first-run label")
            }
        }
    }

    private var reclaimSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One-shot reclaim").font(.headline).accessibilityAddTraits(.isHeader)
            HStack {
                TextField("Byte goal", text: $goal)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("Enter a positive size such as 5GiB or 750MB")
                Button("Preview") { viewModel.reclaim(goal: goal, dryRun: true) }
                    .disabled(viewModel.status.isRunning)
                Button("Reclaim") { viewModel.reclaim(goal: goal, dryRun: false) }
                    .disabled(viewModel.status.isRunning || viewModel.status.isPaused)
                    .accessibilityHint("Evicts eligible local copies; cloud copies are retained")
            }
            Button("Explain current policy plan") { viewModel.explainCurrentPlan() }
                .disabled(viewModel.status.isRunning)
            if let preview = viewModel.operations.explanation {
                Text("\(preview.action.rawValue): \(preview.reason)")
                Text("Planned \(preview.plannedCount) item(s), \(viewModel.formatBytes(preview.plannedBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(preview.candidates.prefix(20), id: \.pathIdentifier) { candidate in
                    Text("\(candidate.displayPath) · \(viewModel.formatBytes(candidate.bytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Planned candidate \(candidate.displayPath), \(viewModel.formatBytes(candidate.bytes))")
                }
                ForEach(preview.exclusions.sorted(by: { $0.key < $1.key }), id: \.key) { reason, count in
                    if count > 0 { Text("Excluded \(reason): \(count)").font(.caption2).foregroundStyle(.secondary) }
                }
                ForEach(preview.warnings, id: \.self) { warning in
                    Text("Warning: \(warning)").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Run history").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Status filter", selection: $historyStatus) {
                    Text("All").tag("all")
                    ForEach([GuardRunStatus.succeeded, .pending, .partial, .failed, .cancelled], id: \.rawValue) {
                        Text($0.rawValue.capitalized).tag($0.rawValue)
                    }
                }.frame(width: 160)
                Button("Export CSV") { exportHistory() }
            }
            if filteredHistory.isEmpty {
                Text("No matching run receipts.").foregroundStyle(.secondary)
            }
            ForEach(filteredHistory.prefix(100), id: \.id) { receipt in
                DisclosureGroup {
                    Grid(alignment: .leading) {
                        GridRow { Text("Reason"); Text(receipt.reason) }
                        GridRow { Text("Planned"); Text("\(receipt.plannedCount) · \(viewModel.formatBytes(receipt.plannedBytes))") }
                        GridRow { Text("Verified"); Text("\(receipt.verifiedCount) · \(viewModel.formatBytes(receipt.verifiedBytes))") }
                        GridRow { Text("Pending"); Text("\(receipt.pendingCount) · \(viewModel.formatBytes(receipt.pendingBytes))") }
                        GridRow { Text("Failed"); Text("\(receipt.failedCount) · \(viewModel.formatBytes(receipt.failedBytes))") }
                        GridRow { Text("Persistence"); Text("state \(receipt.statePersisted ? "saved" : "not saved"), watchlist \(receipt.watchlistPersisted ? "saved" : "not saved")") }
                    }.font(.caption)
                } label: {
                    Text("\(receipt.command) · \(receipt.status.rawValue) · \(receipt.endedAt.formatted())")
                }
                .accessibilityLabel("Run \(receipt.id), \(receipt.status.rawValue)")
            }
            if let path = viewModel.operations.lastExportPath {
                Text("Exported to \(path)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var watchlistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fighting-file inspector").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle("Reveal relative paths", isOn: $revealWatchlistPaths)
                    .onChange(of: revealWatchlistPaths) { _, value in viewModel.refreshOperations(revealWatchlistPaths: value) }
            }
            if viewModel.operations.watchlist.isEmpty { Text("No watchlist entries.").foregroundStyle(.secondary) }
            ForEach(viewModel.operations.watchlist) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayPath).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                    Text("\(entry.state.rawValue) · fights \(entry.fightCount) · retries \(entry.retryCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let error = entry.lastError { Text(error).font(.caption2).foregroundStyle(.orange) }
                    if let reason = entry.suspensionReason { Text("Suspended: \(reason)").font(.caption2).foregroundStyle(.orange) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Watchlist entry \(entry.state.rawValue)")
                .accessibilityValue("\(entry.displayPath), \(entry.fightCount) fights, \(entry.retryCount) retries")
            }
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Support bundle").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Creates a local ZIP with salted path hashes. It excludes tokens, raw paths, file names, file contents, and log text.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Create support bundle…") { createSupportBundle() }
                .accessibilityHint("Selects a local destination; nothing is uploaded")
            if let path = viewModel.operations.lastSupportBundlePath {
                Text("Created at \(path)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verified updates").font(.headline).accessibilityAddTraits(.isHeader)
            if let channel = viewModel.operations.updateChannel {
                Text("Channel: \(channel.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            Text(viewModel.operations.updateStatus)
                .font(.caption)
                .accessibilityLabel("Update status")
                .accessibilityValue(viewModel.operations.updateStatus)
            HStack {
                Button("Check for updates") { viewModel.checkForUpdates() }
                    .disabled(viewModel.operations.updateLoading)
                    .accessibilityHint("Checks signed release metadata only")
                if viewModel.operations.updateCandidateVersion != nil {
                    Button("Download and verify") { viewModel.downloadAvailableUpdate() }
                        .disabled(viewModel.operations.updateLoading)
                        .accessibilityHint("Downloads to private temporary storage and verifies the archive; it does not install")
                }
                if viewModel.operations.updateLoading { ProgressView().controlSize(.small) }
            }
            if let handoff = viewModel.operations.updateHandoff {
                Text("Verified archive: \(handoff.verifiedArchiveURL.path)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Verified update archive")
                    .accessibilityValue(handoff.verifiedArchiveURL.path)
                Text(handoff.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Manual replacement instructions")
                Button("Discard verified download") { viewModel.discardDownloadedUpdate() }
                    .disabled(viewModel.operations.updateLoading)
                    .accessibilityLabel("Discard verified update download")
                    .accessibilityHint("Securely removes the downloaded archive without installing it")
            }
        }
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "icloud-guard-history.csv"
        if panel.runModal() == .OK, let url = panel.url { viewModel.exportHistory(to: url) }
    }

    private func createSupportBundle() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "icloud-guard-support.zip"
        if panel.runModal() == .OK, let url = panel.url { viewModel.createSupportBundle(at: url) }
    }
}

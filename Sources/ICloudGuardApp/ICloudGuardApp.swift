import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import ICloudGuardCore

public struct ICloudGuardApp: App {
    @StateObject private var viewModel = GuardViewModel()
    @State private var appConfigModel = AppConfigModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let instanceLock: AdvisoryFileLock?
    private var ipcServer: IPCServer?

    public init() {
        do {
            try AppPaths.ensureHomeDir()
        } catch {
            instanceLock = nil
            FileHandle.standardError.write(Data("Application home initialization failed: \(error.localizedDescription)\n".utf8))
            return
        }
        do {
            let lock = try AdvisoryFileLock(path: AppPaths.instanceLock.path)
            try lock.writeOwnerPID()
            instanceLock = lock
        } catch {
            instanceLock = nil
            FileHandle.standardError.write(Data("iCloud Guard is already running\n".utf8))
            return
        }

        do {
            try AppPaths.seedDefaultConfigIfMissing()
        } catch {
            FileHandle.standardError.write(Data("Configuration initialization failed: \(error.localizedDescription)\n".utf8))
        }
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])
        if SystemIntegrationPolicy.isEnabled() {
            let center = UNUserNotificationCenter.current()
            center.delegate = NotificationCenterDelegate.shared
            let restore = UNNotificationAction(
                identifier: GuardNotificationCategory.restoreLast,
                title: "Restore Last Run",
                options: [.foreground]
            )
            let pause = UNNotificationAction(
                identifier: GuardNotificationCategory.pause,
                title: "Pause Guard"
            )
            center.setNotificationCategories([
                UNNotificationCategory(
                    identifier: GuardNotificationCategory.eviction,
                    actions: [restore, pause],
                    intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: GuardNotificationCategory.attention,
                    actions: [pause],
                    intentIdentifiers: []
                ),
            ])
            let notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
            Task {
                await Notifier.shared.activateSystemNotificationCenter(
                    notificationsEnabled: notificationsEnabled
                )
            }
        }

        // Write PID file so CLI can detect the running GUI
        try? AppPaths.writePID()

        // Generate auth token if missing (used by IPC for CLI auth)
        if AppPaths.readToken() == nil {
            _ = try? AppPaths.generateToken()
        }

        // Start IPC server. Failure is non-fatal — CLI falls back to in-process mode.
        do {
            ipcServer = try IPCServer()
            ipcServer?.start()
        } catch {
            let msg = "IPCServer failed to start: \(error)"
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }
    }

    public var body: some Scene {
        // Hidden window must precede Settings for it to work from MenuBarExtra
        Window("_", id: "_hidden") {
            EmptyView()
                .onAppear {
                    guard instanceLock != nil else {
                        NSApplication.shared.terminate(nil)
                        return
                    }
                    appConfigModel.onChange = { [viewModel] in
                        Task { @MainActor in
                            viewModel.reloadConfig(
                                config: appConfigModel.config,
                                selectedScopeID: appConfigModel.selectedScopeID
                            )
                        }
                    }
                    // Route CLI commands (icloud-guard status/evict/panic-evict)
                    // to the live guard service so CLI and app share one engine.
                    viewModel.onServiceActivated = { [viewModel] in
                        ipcServer?.commandHandler = { [viewModel] command, dryRun, cancellation, progress in
                            await viewModel.executeIPCCommand(
                                command,
                                dryRun: dryRun,
                                cancellation: cancellation,
                                progress: progress
                            )
                        }
                    }
                    viewModel.onServiceActivated?()
                    appDelegate.prepareForTermination = { [viewModel] in
                        await viewModel.stopGuardServiceAndWait()
                    }
                    // Start guarding at launch — not on first menu-bar click.
                    viewModel.startGuardServices(
                        config: appConfigModel.config,
                        selectedScopeID: appConfigModel.selectedScopeID
                    )
                    viewModel.refreshPolicyCache()
                    viewModel.requestFirstRunDoctorReview()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appConfigModel.flushPending()
                }
        }
            .windowResizability(.contentSize)
            .defaultSize(width: 1, height: 1)

        MenuBarExtra {
            StatusBarView(viewModel: viewModel)
                .environment(appConfigModel)
        } label: {
            Image(systemName: viewModel.statusIcon)
                .accessibilityLabel("iCloud Guard: \(viewModel.statusText)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
                .environment(appConfigModel)
        }
        .windowResizability(.contentMinSize)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the app's lifetime: keeps scan and watchlist timers from
    /// being deferred by App Nap. Does NOT prevent system sleep.
    private var activity: NSObjectProtocol?
    var prepareForTermination: (@MainActor @Sendable () async -> Bool)?
    private var terminationPreparationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SystemIntegrationPolicy.isEnabled() else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "iCloud Guard background scanning"
        )

        // Register launch-at-login if the preference says so (idempotent).
        if UserDefaults.standard.bool(forKey: "runAtLogin") {
            try? SMAppService.mainApp.register()
        }

        // Global hotkey: Cmd+Shift+E to trigger eviction
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "e" {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .icloudGuardEvict, object: nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard AppPaths.pidBelongsToCurrentProcess() else { return }
        AppPaths.unlinkSocket()
        AppPaths.removeOwnedPID()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard !terminationPreparationInProgress else { return .terminateLater }
        terminationPreparationInProgress = true
        Task { @MainActor [weak self] in
            let ready = await prepareForTermination()
            self?.terminationPreparationInProgress = false
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}

enum SystemIntegrationPolicy {
    static let disableEnvironmentKey = "ICLOUD_GUARD_DISABLE_SYSTEM_INTEGRATIONS"

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[disableEnvironmentKey] != "1"
    }
}

extension Notification.Name {
    static let icloudGuardEvict = Notification.Name("icloudGuardEvict")
    static let icloudGuardRestoreLast = Notification.Name("icloudGuardRestoreLast")
    static let icloudGuardPause = Notification.Name("icloudGuardPause")
}

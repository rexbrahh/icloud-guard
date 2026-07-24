import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import ICloudGuardCore

public struct ICloudGuardApp: App {
    @StateObject private var viewModel = GuardViewModel()
    @State private var appConfigModel = AppConfigModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var ipcServer: IPCServer?

    public init() {
        AppPaths.ensureHomeDir()
        AppPaths.seedDefaultConfigIfMissing()
        UNUserNotificationCenter.current().delegate = NotificationCenterDelegate.shared
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])

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
                    appConfigModel.onChange = { [viewModel] in
                        Task { @MainActor in
                            viewModel.reloadConfig()
                        }
                    }
                    // Route CLI commands (icloud-guard status/evict/panic-evict)
                    // to the live guard service so CLI and app share one engine.
                    ipcServer?.commandHandler = { [viewModel] command, dryRun, progress in
                        await viewModel.executeIPCCommand(command, dryRun: dryRun, progress: progress)
                    }
                    // Start guarding at launch — not on first menu-bar click.
                    viewModel.startGuardService(scopePath: appConfigModel.config.scope.path)
                    viewModel.refreshPolicyCache()
                }
        }
            .windowResizability(.contentSize)
            .defaultSize(width: 1, height: 1)

        MenuBarExtra {
            StatusBarView(viewModel: viewModel)
                .environment(appConfigModel)
        } label: {
            Image(systemName: viewModel.statusIcon)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        AppPaths.unlinkSocket()
        AppPaths.removePID()
    }
}

extension Notification.Name {
    static let icloudGuardEvict = Notification.Name("icloudGuardEvict")
}

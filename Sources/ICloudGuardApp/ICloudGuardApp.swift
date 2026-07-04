import SwiftUI
import AppKit
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
        Window("_", id: "_hidden") { EmptyView() }
            .windowResizability(.contentSize)
            .defaultSize(width: 1, height: 1)

        MenuBarExtra {
            StatusBarView(viewModel: viewModel)
                .environment(appConfigModel)
        } label: {
            Label("iCloud Guard", systemImage: viewModel.statusIcon)
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
    func applicationWillTerminate(_ notification: Notification) {
        AppPaths.unlinkSocket()
        AppPaths.removePID()
    }
}

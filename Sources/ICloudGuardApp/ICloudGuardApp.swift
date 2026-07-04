import SwiftUI
import AppKit
import ICloudGuardCore

@main
struct ICloudGuardApp: App {
    @StateObject private var viewModel = GuardViewModel()

    var body: some Scene {
        // Hidden window must precede Settings for it to work from MenuBarExtra
        Window("_", id: "_hidden") { EmptyView() }
            .windowResizability(.contentSize)
            .defaultSize(width: 1, height: 1)

        MenuBarExtra {
            StatusBarView(viewModel: viewModel)
        } label: {
            Label("iCloud Guard", systemImage: viewModel.statusIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentMinSize)
    }
}

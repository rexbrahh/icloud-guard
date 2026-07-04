import SwiftUI
import AppKit
import ICloudGuardCore

@main
struct ICloudGuardApp: App {
    @StateObject private var viewModel = GuardViewModel()

    var body: some Scene {
        MenuBarExtra {
            StatusBarView(viewModel: viewModel)
        } label: {
            Label("iCloud Guard", systemImage: viewModel.statusIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

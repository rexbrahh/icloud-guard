import Foundation
import ICloudGuardApp
import ICloudGuardCLIKit

// Entry point: dispatch based on command-line arguments
// No arguments → GUI mode (launch the menu bar app)
// Any arguments → CLI mode (ArgumentParser handles subcommands)

if CommandLine.arguments.count > 1 {
    runICloudGuardCLI()
} else {
    // GUI mode — launch the SwiftUI menu bar app
    ICloudGuardApp.main()
}

import Foundation
import ArgumentParser
import ICloudGuardApp
import ICloudGuardCore

// Entry point: dispatch based on command-line arguments
// No arguments → GUI mode (launch the menu bar app)
// Any arguments → CLI mode (ArgumentParser handles subcommands)

if CommandLine.arguments.count > 1 {
    // CLI mode — ArgumentParser will parse subcommands
    // The actual subcommand implementations will be added by T18
    CLIEntrypoint.main()
} else {
    // GUI mode — launch the SwiftUI menu bar app
    ICloudGuardApp.main()
}

// MARK: - CLI Entry Point

struct CLIEntrypoint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icloud-guard",
        abstract: "iCloud Guard CLI — control the menu bar app from the command line",
        version: "0.3.0",
        subcommands: [Status.self, Evict.self, PanicEvict.self, Config.self]
    )

    func run() throws {
        // No subcommand specified — show help
        print("Run 'icloud-guard --help' for usage.")
    }
}

// MARK: - Subcommands

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show iCloud Guard status"
    )

    @Flag(help: "Show what would happen without making changes")
    var dryRun: Bool = false

    func run() throws {
        let client = IPCClient()
        do {
            let result = try client.send(command: .status, dryRun: dryRun)
            print(result.output)
            Foundation.exit(Int32(truncatingIfNeeded: result.exitCode))
        } catch {
            let runner = GuardRunner()
            let exitCode = try runner.run(command: .status, configPath: nil, dryRun: dryRun)
            Foundation.exit(exitCode)
        }
    }
}

struct Evict: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evict",
        abstract: "Evict iCloud files"
    )

    @Flag(help: "Show what would happen without evicting")
    var dryRun: Bool = false

    func run() throws {
        let client = IPCClient()
        do {
            let result = try client.send(command: .evict, dryRun: dryRun)
            print(result.output)
            Foundation.exit(Int32(truncatingIfNeeded: result.exitCode))
        } catch {
            let runner = GuardRunner()
            let exitCode = try runner.run(command: .run, configPath: nil, dryRun: dryRun)
            Foundation.exit(exitCode)
        }
    }
}

struct PanicEvict: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "panic-evict",
        abstract: "Panic eviction — evict everything up to panic limit"
    )

    @Flag(help: "Show what would happen without evicting")
    var dryRun: Bool = false

    func run() throws {
        let client = IPCClient()
        do {
            let result = try client.send(command: .panicEvict, dryRun: dryRun)
            print(result.output)
            Foundation.exit(Int32(truncatingIfNeeded: result.exitCode))
        } catch {
            let runner = GuardRunner()
            let exitCode = try runner.run(command: .panicEvict, configPath: nil, dryRun: dryRun)
            Foundation.exit(exitCode)
        }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Configuration commands",
        subcommands: [ConfigShow.self]
    )

    func run() throws {
        print("Run 'icloud-guard config --help' for usage.")
    }
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current config"
    )

    func run() throws {
        let store = ConfigStore()
        let config = store.load()
        if let content = try? String(contentsOf: AppPaths.config, encoding: .utf8) {
            print(content)
        } else {
            print("# Config file not found at \(AppPaths.config.path)")
            print("# Default configuration:")
            try store.save(config)
            if let content = try? String(contentsOf: AppPaths.config, encoding: .utf8) {
                print(content)
            }
        }
    }
}

import Foundation
import Darwin
import ICloudGuardCore

/// Unix domain socket IPC server for CLI ↔ GUI communication.
///
/// Uses raw POSIX AF_UNIX sockets at `AppPaths.socket`.
/// Protocol: streaming NDJSON (newline-delimited JSON).
/// Auth: first line from client must be `{"auth":"<token>"}` matching `guard.token`.
/// Server responds with `{"ok":"progress",...}` lines + final `{"done":true,"exit_code":0,"output":"..."}`.
final class IPCServer {
    private var listenFD: Int32 = -1
    private var acceptQueue: DispatchQueue!
    private var isRunning = false
    private let token: String

    /// Executes parsed commands against the live guard service.
    /// Parameters: command, dryRun, progress-callback. Returns (output, exitCode).
    var commandHandler: ((GuardCommand, Bool, @escaping @Sendable (String) -> Void) async -> (output: String, exitCode: Int))?

    init() throws {
        // Generate or read auth token
        if let existingToken = AppPaths.readToken() {
            token = existingToken
        } else {
            token = try AppPaths.generateToken()
        }

        // Crash recovery: reap stale socket and PID
        AppPaths.reapStaleSocket()
        AppPaths.reapStalePID()

        // Unlink any existing socket file before bind
        AppPaths.unlinkSocket()

        // Create socket — use a local so closures below don't capture self
        // before all stored members are initialized.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "IPCServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        // Bind to AppPaths.socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let socketPath = AppPaths.socket.path
        // Hoist size to a local before withUnsafeMutablePointer to avoid ExclusivityViolation.
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cPath in
                _ = strncpy(UnsafeMutableRawPointer(ptr), cPath, sunPathSize - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "IPCServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }

        // Set socket file permissions to 0600
        chmod(socketPath, 0o600)

        // Listen
        guard Darwin.listen(fd, 5) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "IPCServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        listenFD = fd

        acceptQueue = DispatchQueue(label: "icloud-guard.ipc.accept", qos: .utility)
    }

    /// Start the accept loop on a background queue.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Writes to clients that vanished mid-command must fail harmlessly,
        // not kill the app.
        signal(SIGPIPE, SIG_IGN)

        // Install signal handlers for clean shutdown
        signal(SIGTERM) { _ in
            AppPaths.unlinkSocket()
            AppPaths.removePID()
            exit(0)
        }
        signal(SIGINT) { _ in
            AppPaths.unlinkSocket()
            AppPaths.removePID()
            exit(0)
        }

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// Stop the server and clean up.
    func stop() {
        isRunning = false
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        AppPaths.unlinkSocket()
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            guard clientFD >= 0 else { continue }

            // Each connection gets its own queue — one slow or dead client
            // must never block the others.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    private func handleConnection(fd: Int32) {
        defer { Darwin.close(fd) }

        // Read auth line (first NDJSON frame)
        guard let authLine = readLine(fd: fd) else {
            sendError(fd: fd, message: "No auth received")
            return
        }

        // Verify auth token
        guard let authData = authLine.data(using: .utf8),
              let authJson = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let authToken = authJson["auth"] as? String,
              authToken == token else {
            sendError(fd: fd, message: "Auth rejected")
            return
        }

        // Read command line (second NDJSON frame)
        guard let cmdLine = readLine(fd: fd) else {
            sendError(fd: fd, message: "No command received")
            return
        }

        // Parse command
        guard let cmdData = cmdLine.data(using: .utf8),
              let cmdJson = try? JSONSerialization.jsonObject(with: cmdData) as? [String: Any],
              let cmd = cmdJson["cmd"] as? String else {
            sendError(fd: fd, message: "Invalid command")
            return
        }

        let dryRun = (cmdJson["dry_run"] as? Bool) ?? false

        let command: GuardCommand
        switch cmd {
        case "status": command = .status
        case "evict": command = .run
        case "panic-evict": command = .panicEvict
        default:
            sendError(fd: fd, message: "Unknown command: \(cmd)")
            return
        }

        guard let handler = commandHandler else {
            sendError(fd: fd, message: "GUI command execution unavailable; fall back to local runner")
            return
        }

        // Bridge the async handler into this serial queue with a semaphore.
        let semaphore = DispatchSemaphore(value: 0)
        var resultOutput = ""
        var resultCode = 1

        Task {
            let result = await handler(command, dryRun, { [weak self] message in
                self?.sendProgress(fd: fd, message: message)
            })
            resultOutput = result.output
            resultCode = result.exitCode
            semaphore.signal()
        }

        // Generous ceiling: a full-drive scan + trim can take minutes.
        if semaphore.wait(timeout: .now() + .seconds(900)) == .timedOut {
            sendError(fd: fd, message: "Command timed out")
            return
        }

        sendDone(fd: fd, exitCode: resultCode, output: resultOutput)
    }

    // MARK: - Socket I/O

    private func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
            if buffer.count > 4096 { return nil } // Max line length
        }
        return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8)
    }

    private func sendLine(fd: Int32, _ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress, data.count)
        }
    }

    private func sendProgress(fd: Int32, message: String) {
        let json = "{\"ok\":\"progress\",\"message\":\"\(escapeJSON(message))\"}"
        sendLine(fd: fd, json)
    }

    private func sendDone(fd: Int32, exitCode: Int, output: String) {
        let json = "{\"done\":true,\"exit_code\":\(exitCode),\"output\":\"\(escapeJSON(output))\"}"
        sendLine(fd: fd, json)
    }

    private func sendError(fd: Int32, message: String) {
        let json = "{\"done\":true,\"exit_code\":1,\"error\":\"\(escapeJSON(message))\"}"
        sendLine(fd: fd, json)
    }

    private func escapeJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

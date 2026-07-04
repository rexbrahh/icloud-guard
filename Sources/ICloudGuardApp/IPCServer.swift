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
    private let serialQueue: DispatchQueue
    private var isRunning = false
    private let token: String

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
        serialQueue = DispatchQueue(label: "icloud-guard.ipc.serial", qos: .utility)
    }

    /// Start the accept loop on a background queue.
    func start() {
        guard !isRunning else { return }
        isRunning = true

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

            // Dispatch to serial queue to prevent UI→IPC race
            serialQueue.async { [weak self] in
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

        // Execute command and send streaming response.
        // T18 will wire these to GuardService.
        switch cmd {
        case "status":
            sendProgress(fd: fd, message: "Checking status...")
            sendDone(fd: fd, exitCode: 0, output: "Status: OK")
        case "evict":
            sendProgress(fd: fd, message: "Starting eviction (dry_run: \(dryRun))...")
            sendDone(fd: fd, exitCode: 0, output: "Eviction complete")
        case "panic-evict":
            sendProgress(fd: fd, message: "Starting panic eviction...")
            sendDone(fd: fd, exitCode: 0, output: "Panic eviction complete")
        default:
            sendError(fd: fd, message: "Unknown command: \(cmd)")
        }
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
        let json = "{\"ok\":\"progress\",\"message\":\"\(message)\"}"
        sendLine(fd: fd, json)
    }

    private func sendDone(fd: Int32, exitCode: Int, output: String) {
        let escapedOutput = output.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"done\":true,\"exit_code\":\(exitCode),\"output\":\"\(escapedOutput)\"}"
        sendLine(fd: fd, json)
    }

    private func sendError(fd: Int32, message: String) {
        let escapedMessage = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"done\":true,\"exit_code\":1,\"error\":\"\(escapedMessage)\"}"
        sendLine(fd: fd, json)
    }
}

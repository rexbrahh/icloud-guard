import Foundation
import Darwin
import ICloudGuardCore
import os

/// Unix domain socket IPC server for CLI ↔ GUI communication.
///
/// Uses raw POSIX AF_UNIX sockets at `AppPaths.socket`.
/// Protocol: streaming NDJSON (newline-delimited JSON).
/// Auth: first line from client must be `{"auth":"<token>"}` matching `guard.token`.
/// Server responds with `{"ok":"progress",...}` lines + final `{"done":true,"exit_code":0,"output":"..."}`.
final class IPCServer: Sendable {
    private final class Connection: Sendable {
        private struct State {
            var fd: Int32
            var loggedClosedWrite = false
            var writeFailed = false
        }

        private let state: OSAllocatedUnfairLock<State>

        init(fd: Int32) { state = OSAllocatedUnfairLock(initialState: State(fd: fd)) }

        var fdForConfiguration: Int32 {
            state.withLock { $0.fd }
        }

        var isUsable: Bool {
            state.withLock { $0.fd >= 0 && !$0.writeFailed }
        }

        var peerDisconnected: Bool {
            let currentFD = state.withLock { $0.fd }
            return currentFD < 0 || IPCSocketIO.peerDisconnected(fd: currentFD)
        }

        func readLine(maxBytes: Int, deadline: DispatchTime) throws -> String {
            let currentFD = state.withLock { $0.fd }
            guard currentFD >= 0 else { throw IPCSocketIO.SocketError.closed }
            return try IPCSocketIO.readLine(fd: currentFD, maxBytes: maxBytes, deadline: deadline)
        }

        @discardableResult
        func send(_ object: [String: Any], deadline: DispatchTime) -> Bool {
            guard let json = try? JSONSerialization.data(withJSONObject: object) else {
                fputs("[icloud-guard] IPC response serialization failed\n", stderr)
                return false
            }
            return state.withLock { state in
                guard state.fd >= 0 else {
                    if !state.loggedClosedWrite {
                        state.loggedClosedWrite = true
                        fputs("[icloud-guard] IPC response write skipped: connection closed\n", stderr)
                    }
                    return false
                }
                do {
                    try IPCSocketIO.writeAll(
                        fd: state.fd,
                        data: json + Data([UInt8(ascii: "\n")]),
                        deadline: deadline
                    )
                    return true
                } catch {
                    state.writeFailed = true
                    Darwin.shutdown(state.fd, SHUT_RDWR)
                    fputs("[icloud-guard] IPC response write failed: \(error)\n", stderr)
                    return false
                }
            }
        }

        func close() {
            let currentFD = state.withLock { state in
                let currentFD = state.fd
                state.fd = -1
                return currentFD
            }
            if currentFD >= 0 {
                Darwin.shutdown(currentFD, SHUT_RDWR)
                Darwin.close(currentFD)
            }
        }

        deinit { close() }
    }

    private final class CommandResultBox: Sendable {
        private let result = OSAllocatedUnfairLock<IPCCommandResult?>(initialState: nil)

        func store(_ value: IPCCommandResult) {
            result.withLock { $0 = value }
        }

        func load() -> IPCCommandResult? {
            result.withLock { $0 }
        }
    }

    typealias CommandHandler = @Sendable (
        GuardCommand,
        Bool,
        EvictionCancellation,
        @escaping @Sendable (String) -> Void
    ) async -> IPCCommandResult

    private struct ServerState {
        var listenFD: Int32
        var isRunning = false
        var commandHandler: CommandHandler?
    }

    private let state: OSAllocatedUnfairLock<ServerState>
    private let acceptQueue: DispatchQueue
    private let token: String
    private let socketURL: URL
    private let installsSignalHandlers: Bool
    private let connectionSlots = DispatchSemaphore(value: 4)

    /// Executes parsed commands against the live guard service.
    /// Parameters: command, dryRun, progress-callback. Returns (output, exitCode).
    var commandHandler: CommandHandler? {
        get { state.withLock { $0.commandHandler } }
        set { state.withLock { $0.commandHandler = newValue } }
    }

    init(
        socketURL: URL = AppPaths.socket,
        token injectedToken: String? = nil,
        installSignalHandlers: Bool = true
    ) throws {
        let socketPath = socketURL.path
        let pathProbe = sockaddr_un()
        let sunPathSize = MemoryLayout.size(ofValue: pathProbe.sun_path)
        guard socketPath.utf8.count < sunPathSize else {
            throw NSError(domain: "IPCServer", code: 4, userInfo: [NSLocalizedDescriptionKey: "socket path is too long"])
        }

        // Generate or read auth token
        if let injectedToken {
            guard !injectedToken.isEmpty else {
                throw NSError(
                    domain: "IPCServer",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "injected IPC token must not be empty"]
                )
            }
            token = injectedToken
        } else if let existingToken = AppPaths.readToken() {
            token = existingToken
        } else {
            token = try AppPaths.generateToken()
        }

        // Crash recovery: reap stale socket and PID
        if socketURL.standardizedFileURL == AppPaths.socket.standardizedFileURL {
            AppPaths.reapStaleSocket()
            AppPaths.reapStalePID()
            AppPaths.unlinkSocket()
        } else {
            // A caller-provided socket is an explicit isolated lifecycle root.
            // It is safe to replace only that exact path.
            Darwin.unlink(socketPath)
        }

        self.socketURL = socketURL
        installsSignalHandlers = installSignalHandlers

        // Create socket — use a local so closures below don't capture self
        // before all stored members are initialized.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "IPCServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        // Bind to AppPaths.socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Hoist size to a local before withUnsafeMutablePointer to avoid ExclusivityViolation.
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

        state = OSAllocatedUnfairLock(initialState: ServerState(listenFD: fd))
        acceptQueue = DispatchQueue(label: "icloud-guard.ipc.accept", qos: .utility)
    }

    /// Start the accept loop on a background queue.
    func start() {
        let shouldStart = state.withLock { state in
            guard !state.isRunning, state.listenFD >= 0 else { return false }
            state.isRunning = true
            return true
        }
        guard shouldStart else { return }

        // Writes to clients that vanished mid-command must fail harmlessly,
        // not kill the app.
        signal(SIGPIPE, SIG_IGN)

        // Only the process-owning production server installs global handlers.
        if installsSignalHandlers {
            signal(SIGTERM) { _ in
                AppPaths.unlinkSocket()
                AppPaths.removeOwnedPID()
                exit(0)
            }
            signal(SIGINT) { _ in
                AppPaths.unlinkSocket()
                AppPaths.removeOwnedPID()
                exit(0)
            }
        }

        let state = state
        let token = token
        let slots = connectionSlots
        acceptQueue.async {
            Self.acceptLoop(state: state, token: token, connectionSlots: slots)
        }
    }

    /// Stop the server and clean up.
    func stop() {
        let listenFD = state.withLock { state in
            state.isRunning = false
            let descriptor = state.listenFD
            state.listenFD = -1
            return descriptor
        }
        if listenFD >= 0 { Darwin.close(listenFD) }
        Darwin.unlink(socketURL.path)
    }

    private static func acceptLoop(
        state: OSAllocatedUnfairLock<ServerState>,
        token: String,
        connectionSlots: DispatchSemaphore
    ) {
        while true {
            let listenFD = state.withLock { $0.isRunning ? $0.listenFD : -1 }
            guard listenFD >= 0 else { return }
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if state.withLock({ !$0.isRunning }) { return }
                continue
            }

            guard connectionSlots.wait(timeout: .now()) == .success else {
                Darwin.close(clientFD)
                continue
            }

            let slots = connectionSlots
            let connection = Connection(fd: clientFD)
            DispatchQueue.global(qos: .utility).async {
                defer { slots.signal() }
                Self.handleConnection(connection: connection, state: state, token: token)
            }
        }
    }

    private static func handleConnection(
        connection: Connection,
        state: OSAllocatedUnfairLock<ServerState>,
        token: String
    ) {
        defer { connection.close() }
        do {
            // The accepted descriptor is stable until Connection.close().
            try IPCSocketIO.configure(fd: connection.fdForConfiguration, sendTimeoutSeconds: 5, receiveTimeoutSeconds: 5)
        } catch {
            return
        }
        let requestDeadline = DispatchTime.now() + .seconds(5)

        // Read auth line (first NDJSON frame)
        guard let authLine = try? connection.readLine(maxBytes: 4_096, deadline: requestDeadline) else {
            sendError(connection: connection, message: "No auth received")
            return
        }

        // Verify auth token
        guard let authData = authLine.data(using: .utf8),
              let authJson = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let authToken = authJson["auth"] as? String else {
            sendError(connection: connection, message: "Auth rejected")
            return
        }
        let authRequestID = authJson["request_id"] as? String
        let wantsAuthAcknowledgement = authJson["auth_ack"] as? Bool == true
        let validAuthRequestID = authRequestID.flatMap { isValidRequestID($0) ? $0 : nil }
        guard authToken == token else {
            sendAuthRejected(connection: connection, requestID: validAuthRequestID)
            return
        }
        if wantsAuthAcknowledgement {
            guard let validAuthRequestID else {
                sendError(connection: connection, message: "Invalid auth acknowledgement request ID")
                return
            }
            sendAuthAccepted(connection: connection, requestID: validAuthRequestID)
        }

        // Read command line (second NDJSON frame)
        guard let cmdLine = try? connection.readLine(maxBytes: 4_096, deadline: requestDeadline) else {
            sendError(connection: connection, message: "No command received")
            return
        }

        // Parse command
        guard let cmdData = cmdLine.data(using: .utf8),
              let cmdJson = try? JSONSerialization.jsonObject(with: cmdData) as? [String: Any],
              let cmd = cmdJson["cmd"] as? String,
              let dryRun = cmdJson["dry_run"] as? Bool,
              let requestID = cmdJson["request_id"] as? String,
              isValidRequestID(requestID) else {
            sendError(connection: connection, message: "Invalid command envelope")
            return
        }

        let command: GuardCommand
        switch cmd {
        case "status": command = .status
        case "evict": command = .run
        case "panic-evict": command = .panicEvict
        default:
            sendError(connection: connection, message: "Unknown command: \(cmd)", requestID: requestID)
            return
        }

        guard let handler = state.withLock({ $0.commandHandler }) else {
            sendError(connection: connection, message: "GUI command execution unavailable", requestID: requestID)
            return
        }

        // Bridge the async handler into this serial queue with a semaphore.
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = CommandResultBox()
        let deadlineCommand: IPCClient.Command = command == .status
            ? .status
            : (command == .panicEvict ? .panicEvict : .evict)
        let commandDeadline = DispatchTime.now() + .seconds(
            IPCDeadlinePolicy.timeoutSeconds(command: deadlineCommand)
        )
        let commandCancellation = EvictionCancellation()

        let task = Task {
            let result = await handler(command, dryRun, commandCancellation, { message in
                Self.sendProgress(connection: connection, message: message, requestID: requestID, deadline: commandDeadline)
            })
            resultBox.store(result)
            semaphore.signal()
        }

        // Poll so a failed progress write releases this connection slot
        // promptly instead of waiting for the full command timeout.
        while resultBox.load() == nil {
            let now = DispatchTime.now()
            if now.uptimeNanoseconds >= commandDeadline.uptimeNanoseconds {
                commandCancellation.cancel()
                task.cancel()
                _ = semaphore.wait(timeout: .now() + .seconds(2))
                sendAmbiguous(connection: connection, message: "Command timed out after acceptance", requestID: requestID)
                return
            }
            let nextProbe = now + .milliseconds(250)
            let pollDeadline = nextProbe.uptimeNanoseconds < commandDeadline.uptimeNanoseconds
                ? nextProbe
                : commandDeadline
            if semaphore.wait(timeout: pollDeadline) == .success { break }
            if !connection.isUsable || connection.peerDisconnected {
                commandCancellation.cancel()
                task.cancel()
                _ = semaphore.wait(timeout: .now() + .seconds(2))
                return
            }
        }

        guard let result = resultBox.load() else {
            sendError(connection: connection, message: "Command completed without a result", requestID: requestID)
            return
        }
        sendDone(connection: connection, result: result, requestID: requestID)
    }

    // MARK: - Socket I/O

    private static func sendFrame(connection: Connection, _ object: [String: Any], deadline: DispatchTime? = nil) {
        _ = connection.send(object, deadline: deadline ?? DispatchTime.now() + .seconds(5))
    }

    private static func sendProgress(connection: Connection, message: String, requestID: String, deadline: DispatchTime) {
        var frame: [String: Any] = ["ok": "progress", "message": message]
        frame["request_id"] = requestID
        _ = connection.send(
            frame,
            deadline: IPCSocketIO.progressWriteDeadline(commandDeadline: deadline)
        )
    }

    private static func sendAuthAccepted(connection: Connection, requestID: String) {
        sendFrame(connection: connection, ["auth": "ok", "request_id": requestID])
    }

    private static func sendAuthRejected(connection: Connection, requestID: String?) {
        var frame: [String: Any] = [
            "done": true,
            "exit_code": 1,
            "error": "Auth rejected",
            "auth": "rejected",
        ]
        if let requestID { frame["request_id"] = requestID }
        sendFrame(connection: connection, frame)
    }

    private static func sendDone(connection: Connection, result: IPCCommandResult, requestID: String) {
        var frame: [String: Any] = ["done": true, "exit_code": result.exitCode, "output": result.output]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(result),
           let object = try? JSONSerialization.jsonObject(with: data) {
            frame["result"] = object
        }
        frame["request_id"] = requestID
        sendFrame(connection: connection, frame)
    }

    private static func sendError(connection: Connection, message: String, requestID: String? = nil) {
        var frame: [String: Any] = ["done": true, "exit_code": 1, "error": message]
        if let requestID { frame["request_id"] = requestID }
        sendFrame(connection: connection, frame)
    }

    private static func sendAmbiguous(connection: Connection, message: String, requestID: String) {
        sendFrame(connection: connection, [
            "done": true,
            "exit_code": 75,
            "error": message,
            "ambiguous": true,
            "request_id": requestID,
        ])
    }

    private static func isValidRequestID(_ requestID: String) -> Bool {
        !requestID.isEmpty && requestID.utf8.count <= 128
    }
}

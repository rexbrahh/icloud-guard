import Foundation
import Darwin

public enum IPCDeadlinePolicy {
    public static func timeoutSeconds(
        command: IPCClient.Command,
        globalTimeoutSeconds: Int = 1_900,
        statusTimeoutSeconds: Int = 120
    ) -> Int {
        let global = max(1, min(globalTimeoutSeconds, 1_900))
        return command == .status ? min(global, max(1, statusTimeoutSeconds)) : global
    }
}

/// Unix domain socket IPC client for CLI → GUI communication.
///
/// Connects to AppPaths.socket, authenticates with guard.token,
/// sends a command as NDJSON, and reads streaming NDJSON response
/// lines until a {"done":true} frame.
///
/// Local fallback is safe only before a mutating command has been accepted.
public struct IPCClient {
    public enum IPCError: Error, Equatable {
        case connectFailed(String)
        case authFailed
        case timeout
        case noToken
        case invalidResponse
        case ambiguousResult(String)

        public var allowsLocalFallback: Bool {
            switch self {
            case .connectFailed, .noToken, .authFailed: return true
            case .timeout, .invalidResponse, .ambiguousResult: return false
            }
        }
    }

    public enum Command: String, Sendable {
        case status
        case evict
        case panicEvict = "panic-evict"
    }

    private let socketPath: String
    private let token: String
    private let responseTimeoutSeconds: Int

    public init(socketPath: String? = nil, token: String? = nil, responseTimeoutSeconds: Int = 1_900) {
        self.socketPath = socketPath ?? AppPaths.socket.path
        self.token = token ?? AppPaths.readToken() ?? ""
        self.responseTimeoutSeconds = max(1, responseTimeoutSeconds)
    }

    /// Send a command to the IPC server and return the response.
    /// - Parameters:
    ///   - command: The command to send
    ///   - dryRun: Whether to run in dry-run mode
    /// - Returns: A tuple of (exitCode, output) from the server
    public func send(command: Command, dryRun: Bool = false) throws -> IPCCommandResult {
        guard !token.isEmpty else { throw IPCError.noToken }
        let commandTimeoutSeconds = IPCDeadlinePolicy.timeoutSeconds(
            command: command,
            globalTimeoutSeconds: responseTimeoutSeconds
        )

        // Create socket
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.connectFailed("socket() failed") }
        defer { Darwin.close(fd) }

        do {
            try IPCSocketIO.configure(fd: fd, sendTimeoutSeconds: 1, receiveTimeoutSeconds: commandTimeoutSeconds)
        } catch {
            throw IPCError.connectFailed("failed to configure socket: \(error)")
        }

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Hoist size to a local before withUnsafeMutablePointer to avoid ExclusivityViolation.
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < sunPathSize else {
            throw IPCError.connectFailed("socket path is too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cPath in
                _ = strncpy(UnsafeMutableRawPointer(ptr), cPath, sunPathSize - 1)
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCError.connectFailed("connect() failed: \(String(cString: strerror(errno)))")
        }
        let responseDeadline = DispatchTime.now() + .seconds(commandTimeoutSeconds)

        let requestID = UUID().uuidString

        // Send auth line
        guard let authLine = encodeLine(["auth": token, "auth_ack": true, "request_id": requestID]) else {
            throw IPCError.invalidResponse
        }
        do {
            try IPCSocketIO.writeAll(fd: fd, data: authLine, deadline: responseDeadline)
        } catch {
            throw IPCError.connectFailed("Failed to send auth")
        }

        if command != .status {
            try readAuthAcknowledgement(
                fd: fd,
                requestID: requestID,
                deadline: DispatchTime.now() + .seconds(min(commandTimeoutSeconds, 5))
            )
        }

        // Send command line
        guard let cmdLine = encodeLine(["cmd": command.rawValue, "dry_run": dryRun, "request_id": requestID]) else {
            throw IPCError.invalidResponse
        }
        do {
            try IPCSocketIO.writeAll(fd: fd, data: cmdLine, deadline: responseDeadline)
        } catch {
            throw IPCError.ambiguousResult("command write failed: \(error)")
        }

        // Read streaming NDJSON response until {"done":true} frame
        var output = ""
        var exitCode = 0
        var responseBytes = 0

        while true {
            let line: String
            do {
                line = try IPCSocketIO.readLine(fd: fd, maxBytes: 65_536, deadline: responseDeadline)
            } catch IPCSocketIO.SocketError.timeout {
                throw IPCError.ambiguousResult("command response timed out")
            } catch let IPCSocketIO.SocketError.system(errorNumber)
                where errorNumber == EAGAIN || errorNumber == EWOULDBLOCK || errorNumber == ETIMEDOUT {
                throw IPCError.ambiguousResult("command response timed out")
            } catch {
                throw IPCError.ambiguousResult("command response ended before completion: \(error)")
            }
            responseBytes += line.utf8.count
            guard responseBytes <= 1_048_576 else {
                throw IPCError.ambiguousResult("command response exceeded 1 MiB")
            }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IPCError.ambiguousResult("invalid response frame")
            }

            guard let echoedRequestID = json["request_id"] as? String,
                  echoedRequestID == requestID else {
                throw IPCError.ambiguousResult("response request ID missing or mismatched")
            }

            if json["ambiguous"] as? Bool == true {
                throw IPCError.ambiguousResult((json["error"] as? String) ?? "server reported ambiguous completion")
            }

            if let done = json["done"] as? Bool, done {
                guard let reportedExitCode = json["exit_code"] as? Int else {
                    throw IPCError.ambiguousResult("response exit code missing")
                }
                exitCode = reportedExitCode
                output = (json["output"] as? String) ?? (json["error"] as? String) ?? ""
                var result = IPCCommandResult(output: output, exitCode: exitCode)
                if let encoded = json["result"], JSONSerialization.isValidJSONObject(encoded),
                   let resultData = try? JSONSerialization.data(withJSONObject: encoded),
                   let structured = try? JSONDecoder.ipc.decode(IPCCommandResult.self, from: resultData) {
                    result = structured
                    guard result.exitCode == exitCode else {
                        throw IPCError.ambiguousResult("structured result exit code mismatched terminal frame")
                    }
                }
                return result
            }

            // Progress line — accumulate
            if let message = json["message"] as? String {
                output += message + "\n"
            }
        }
    }

    // MARK: - Socket I/O

    private func encodeLine(_ object: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return data + Data([UInt8(ascii: "\n")])
    }

    private func readAuthAcknowledgement(fd: Int32, requestID: String, deadline: DispatchTime) throws {
        let line: String
        do {
            line = try IPCSocketIO.readLine(fd: fd, maxBytes: 4_096, deadline: deadline)
        } catch {
            throw IPCError.connectFailed("auth acknowledgement failed before command was sent: \(error)")
        }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPCError.connectFailed("invalid auth acknowledgement")
        }
        guard json["request_id"] as? String == requestID else {
            throw IPCError.connectFailed("auth acknowledgement request ID missing or mismatched")
        }
        if json["auth"] as? String == "ok" { return }
        if json["auth"] as? String == "rejected" {
            throw IPCError.authFailed
        }
        throw IPCError.connectFailed("auth acknowledgement was not accepted")
    }
}

private extension JSONDecoder {
    static var ipc: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

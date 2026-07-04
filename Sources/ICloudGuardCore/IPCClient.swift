import Foundation
import Darwin

/// Unix domain socket IPC client for CLI → GUI communication.
///
/// Connects to AppPaths.socket, authenticates with guard.token,
/// sends a command as NDJSON, and reads streaming NDJSON response
/// lines until a {"done":true} frame.
///
/// If the connection fails or times out, the caller should fall back
/// to in-process GuardRunner.
public struct IPCClient {
    public enum IPCError: Error, Equatable {
        case connectFailed(String)
        case authFailed
        case timeout
        case noToken
        case invalidResponse
    }

    public enum Command: String, Sendable {
        case status
        case evict
        case panicEvict = "panic-evict"
    }

    private let socketPath: String
    private let token: String

    public init(socketPath: String? = nil, token: String? = nil) {
        self.socketPath = socketPath ?? AppPaths.socket.path
        self.token = token ?? AppPaths.readToken() ?? ""
    }

    /// Send a command to the IPC server and return the response.
    /// - Parameters:
    ///   - command: The command to send
    ///   - dryRun: Whether to run in dry-run mode
    /// - Returns: A tuple of (exitCode, output) from the server
    public func send(command: Command, dryRun: Bool = false) throws -> (exitCode: Int, output: String) {
        guard !token.isEmpty else { throw IPCError.noToken }

        // Create socket
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.connectFailed("socket() failed") }
        defer { Darwin.close(fd) }

        // Set connect timeout (SO_SNDTIMEO)
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 200_000) // 200ms
        Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Set receive timeout (SO_RCVTIMEO) — 60s for eviction
        var recvTimeout = timeval(tv_sec: 60, tv_usec: 0)
        Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Hoist size to a local before withUnsafeMutablePointer to avoid ExclusivityViolation.
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
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

        // Send auth line
        let authLine = "{\"auth\":\"\(token)\"}\n"
        guard sendLine(fd: fd, authLine) else {
            throw IPCError.connectFailed("Failed to send auth")
        }

        // Send command line
        let cmdLine = "{\"cmd\":\"\(command.rawValue)\",\"dry_run\":\(dryRun)}\n"
        guard sendLine(fd: fd, cmdLine) else {
            throw IPCError.connectFailed("Failed to send command")
        }

        // Read streaming NDJSON response until {"done":true} frame
        var output = ""
        var exitCode = 0

        while let line = readLine(fd: fd) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let done = json["done"] as? Bool, done {
                exitCode = (json["exit_code"] as? Int) ?? 0
                output = (json["output"] as? String) ?? (json["error"] as? String) ?? ""
                return (exitCode, output)
            }

            // Progress line — accumulate
            if let message = json["message"] as? String {
                output += message + "\n"
            }
        }

        // No done frame received — timeout or connection closed
        throw IPCError.timeout
    }

    // MARK: - Socket I/O

    private func sendLine(fd: Int32, _ line: String) -> Bool {
        let data = (line).data(using: .utf8) ?? Data()
        return data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, data.count) == data.count
        }
    }

    private func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
            if buffer.count > 65536 { return nil } // Max line length
        }
        return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8)
    }
}

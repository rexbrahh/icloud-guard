import Foundation
import Darwin
import XCTest
@testable import ICloudGuardCore

/// IPC client integration tests.
///
/// IPCServer lives in ICloudGuardApp, which is not visible from this test
/// target. We exercise IPCClient directly and cover:
///   - the failure paths the CLI uses to decide whether to fall back to
///     in-process GuardRunner (no token, no server)
///   - the wire protocol via a tiny POSIX listener that captures what
///     IPCClient actually writes, so we can assert auth + command +
///     dry_run round-trip without depending on IPCServer.
final class IPCIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var tempSocketPath: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPCIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempSocketPath = tempDir.appendingPathComponent("guard.sock").path
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    // MARK: - Failure paths

    /// Given an empty token, IPCClient must refuse before touching the
    /// network so the CLI can decide to fall back to GuardRunner.
    func testNoToken() {
        let client = IPCClient(socketPath: tempSocketPath, token: "")
        XCTAssertThrowsError(try client.send(command: .status)) { error in
            guard case IPCClient.IPCError.noToken = error else {
                XCTFail("Expected .noToken, got \(error)")
                return
            }
        }
    }

    /// Empty-token check fires before command parsing — .evict with dryRun
    /// must also short-circuit and never touch the socket.
    func testNoTokenIgnoresCommandAndDryRun() {
        let client = IPCClient(socketPath: tempSocketPath, token: "")
        XCTAssertThrowsError(try client.send(command: .evict, dryRun: true)) { error in
            guard case IPCClient.IPCError.noToken = error else {
                XCTFail("Expected .noToken, got \(error)")
                return
            }
        }
    }

    /// Given a valid token but no server listening, IPCClient must surface
    /// connectFailed so the CLI's fallback path can run GuardRunner locally.
    func testConnectFailFallback() {
        let client = IPCClient(socketPath: tempSocketPath, token: "any-token")
        XCTAssertThrowsError(try client.send(command: .status)) { error in
            guard case IPCClient.IPCError.connectFailed = error else {
                XCTFail("Expected .connectFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Wire protocol

    /// A minimal POSIX listener captures what IPCClient writes to the
    /// socket. This proves the auth + command + dry_run wire contract
    /// without depending on the ICloudGuardApp target.
    func testDryRunFlagIsPropagatedOnTheWire() throws {
        let server = try CapturingServer(socketPath: tempSocketPath)
        server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: tempSocketPath, token: "test-token")
        let result = try client.send(command: .evict, dryRun: true)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(server.capturedAuth, "test-token")
        XCTAssertEqual(server.capturedCommand, "evict")
        XCTAssertEqual(server.capturedDryRun, true)
    }

    func testServerErrorIsReturnedToCallerForFallbackDecision() throws {
        let server = try CapturingServer(
            socketPath: tempSocketPath,
            responseExitCode: 1,
            responseOutput: "fall back to local runner"
        )
        server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: tempSocketPath, token: "test-token")
        let result = try client.send(command: .panicEvict, dryRun: false)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.output, "fall back to local runner")
        XCTAssertEqual(server.capturedCommand, "panic-evict")
    }
}

/// Minimal POSIX AF_UNIX listener that accepts one connection, captures
/// the auth + command NDJSON frames, and replies with a single done frame.
/// Used by IPCIntegrationTests to verify the IPCClient wire contract.
private final class CapturingServer {
    let socketPath: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private let responseExitCode: Int
    private let responseOutput: String
    private var _capturedAuth: String?
    private var _capturedCommand: String?
    private var _capturedDryRun: Bool?

    init(socketPath: String, responseExitCode: Int = 0, responseOutput: String = "ok") throws {
        self.socketPath = socketPath
        self.responseExitCode = responseExitCode
        self.responseOutput = responseOutput
        Darwin.unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "CapturingServer", code: 1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        let path = socketPath
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cPath in
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
            throw NSError(domain: "CapturingServer", code: 2)
        }
        guard Darwin.listen(fd, 5) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "CapturingServer", code: 3)
        }
        listenFD = fd
    }

    deinit {
        if listenFD >= 0 {
            Darwin.close(listenFD)
        }
        Darwin.unlink(socketPath)
    }

    func start() {
        Thread { [weak self] in
            self?.serveOnce()
        }.start()
    }

    func stop() {
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    var capturedAuth: String? {
        lock.lock(); defer { lock.unlock() }
        return _capturedAuth
    }
    var capturedCommand: String? {
        lock.lock(); defer { lock.unlock() }
        return _capturedCommand
    }
    var capturedDryRun: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _capturedDryRun
    }

    private func serveOnce() {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { Darwin.close(clientFD) }

        if let authLine = readLine(fd: clientFD),
           let data = authLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.lock()
            _capturedAuth = json["auth"] as? String
            lock.unlock()
        }

        if let cmdLine = readLine(fd: clientFD),
           let data = cmdLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.lock()
            _capturedCommand = json["cmd"] as? String
            _capturedDryRun = json["dry_run"] as? Bool
            lock.unlock()
        }

        let escapedOutput = responseOutput
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let response = "{\"done\":true,\"exit_code\":\(responseExitCode),\"output\":\"\(escapedOutput)\"}\n"
        if let responseData = response.data(using: .utf8) {
            _ = responseData.withUnsafeBytes { ptr in
                Darwin.write(clientFD, ptr.baseAddress, responseData.count)
            }
        }
    }

    private func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
            if buffer.count > 4096 { return nil }
        }
        return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8)
    }
}

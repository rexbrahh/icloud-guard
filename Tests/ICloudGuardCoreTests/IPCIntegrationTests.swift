import Foundation
import Darwin
import os
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
        tempDir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ig-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    func testDeadlinePolicyCapsStatusAndKeepsMutationGlobal() {
        XCTAssertEqual(IPCDeadlinePolicy.timeoutSeconds(command: .status), 120)
        XCTAssertEqual(IPCDeadlinePolicy.timeoutSeconds(command: .evict), 1_900)
        XCTAssertEqual(IPCDeadlinePolicy.timeoutSeconds(command: .panicEvict), 1_900)
        XCTAssertEqual(IPCDeadlinePolicy.timeoutSeconds(command: .evict, globalTimeoutSeconds: 5_000), 1_900)
        XCTAssertEqual(
            IPCDeadlinePolicy.timeoutSeconds(command: .status, globalTimeoutSeconds: 60, statusTimeoutSeconds: 120),
            60
        )
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
        XCTAssertNotNil(server.capturedRequestID)
    }

    func testLegacyServerWithoutAuthAckDoesNotReceiveMutatingCommandAndAllowsFallback() throws {
        let server = try CapturingServer(socketPath: tempSocketPath, sendAuthAck: false, sendResponse: false)
        server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: tempSocketPath, token: "test-token", responseTimeoutSeconds: 1)
        XCTAssertThrowsError(try client.send(command: .evict)) { error in
            guard let ipcError = error as? IPCClient.IPCError,
                  case .connectFailed = ipcError else {
                XCTFail("Expected connectFailed, got \(error)")
                return
            }
            XCTAssertTrue(ipcError.allowsLocalFallback)
        }
        XCTAssertNil(server.capturedCommand)
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

    func testClosedConnectionAfterCommandIsAmbiguousAndForbidsFallback() throws {
        let server = try CapturingServer(socketPath: tempSocketPath, sendResponse: false)
        server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: tempSocketPath, token: "test-token", responseTimeoutSeconds: 1)
        XCTAssertThrowsError(try client.send(command: .evict)) { error in
            guard let ipcError = error as? IPCClient.IPCError,
                  case .ambiguousResult = ipcError else {
                XCTFail("Expected ambiguousResult, got \(error)")
                return
            }
            XCTAssertFalse(ipcError.allowsLocalFallback)
        }
    }

    func testSocketFramingRejectsOversizedLine() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { Darwin.close(sockets[0]); Darwin.close(sockets[1]) }
        try IPCSocketIO.writeAll(fd: sockets[0], data: Data("12345\n".utf8))

        XCTAssertThrowsError(try IPCSocketIO.readLine(fd: sockets[1], maxBytes: 4)) { error in
            XCTAssertEqual(error as? IPCSocketIO.SocketError, .lineTooLong)
        }
    }

    func testSocketReadUsesAbsoluteDeadline() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { Darwin.close(sockets[0]); Darwin.close(sockets[1]) }

        XCTAssertThrowsError(try IPCSocketIO.readLine(
            fd: sockets[1],
            maxBytes: 64,
            deadline: DispatchTime.now() + .milliseconds(50)
        )) { error in
            XCTAssertEqual(error as? IPCSocketIO.SocketError, .timeout)
        }
    }

    func testPeerDisconnectProbeDetectsEOFWithoutConsumingData() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { Darwin.close(sockets[0]) }

        XCTAssertFalse(IPCSocketIO.peerDisconnected(fd: sockets[0]))
        try IPCSocketIO.writeAll(fd: sockets[1], data: Data("x".utf8))
        XCTAssertFalse(IPCSocketIO.peerDisconnected(fd: sockets[0]))
        Darwin.close(sockets[1])
        XCTAssertTrue(IPCSocketIO.peerDisconnected(fd: sockets[0]))
    }

    func testProgressWriteDeadlineIsShortAndSlowReaderWriteReturnsBoundedly() throws {
        let now = DispatchTime.now()
        let commandDeadline = now + .seconds(1_900)
        let frameDeadline = IPCSocketIO.progressWriteDeadline(
            commandDeadline: commandDeadline,
            now: now,
            maxFrameWriteMilliseconds: 50
        )
        XCTAssertLessThanOrEqual(frameDeadline.uptimeNanoseconds - now.uptimeNanoseconds, 50_000_000)

        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { Darwin.close(sockets[0]) }
        let peerFD = sockets[1]
        Thread {
            // Test escape hatch: even a regression to blocking write cannot
            // hang the suite indefinitely.
            usleep(250_000)
            Darwin.close(peerFD)
        }.start()
        var sendBuffer: Int32 = 1_024
        XCTAssertEqual(
            setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)),
            0
        )
        try IPCSocketIO.configure(fd: sockets[0], sendTimeoutSeconds: 1, receiveTimeoutSeconds: 1)

        let startedAt = Date()
        XCTAssertThrowsError(try IPCSocketIO.writeAll(
            fd: sockets[0],
            data: Data(repeating: 0x41, count: 1 * 1_024 * 1_024),
            deadline: frameDeadline
        )) { error in
            XCTAssertEqual(error as? IPCSocketIO.SocketError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testDoneFrameRequiresMatchingRequestID() throws {
        let server = try CapturingServer(socketPath: tempSocketPath, includeRequestID: false)
        server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: tempSocketPath, token: "test-token")
        XCTAssertThrowsError(try client.send(command: .evict)) { error in
            guard case IPCClient.IPCError.ambiguousResult = error else {
                XCTFail("Expected ambiguousResult, got \(error)")
                return
            }
        }
    }

    func testDoneFrameRequiresExitCode() throws {
        let server = try CapturingServer(socketPath: tempSocketPath, includeExitCode: false)
        server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: tempSocketPath, token: "test-token")
        XCTAssertThrowsError(try client.send(command: .evict)) { error in
            guard case IPCClient.IPCError.ambiguousResult = error else {
                XCTFail("Expected ambiguousResult, got \(error)")
                return
            }
        }
    }

    func testExplicitAmbiguousCompletionForbidsFallback() throws {
        let server = try CapturingServer(socketPath: tempSocketPath, ambiguous: true)
        server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try IPCClient(socketPath: tempSocketPath, token: "test-token").send(command: .evict)) { error in
            guard let ipcError = error as? IPCClient.IPCError,
                  case .ambiguousResult = ipcError else {
                XCTFail("Expected ambiguousResult, got \(error)")
                return
            }
            XCTAssertFalse(ipcError.allowsLocalFallback)
        }
    }
}

/// Minimal POSIX AF_UNIX listener that accepts one connection, captures
/// the auth + command NDJSON frames, and replies with a single done frame.
/// Used by IPCIntegrationTests to verify the IPCClient wire contract.
private final class CapturingServer: Sendable {
    private struct State {
        var listenFD: Int32
        var capturedAuth: String?
        var capturedCommand: String?
        var capturedDryRun: Bool?
        var capturedRequestID: String?
    }

    let socketPath: String
    private let state: OSAllocatedUnfairLock<State>
    private let responseExitCode: Int
    private let responseOutput: String
    private let sendAuthAck: Bool
    private let sendResponse: Bool
    private let includeRequestID: Bool
    private let includeExitCode: Bool
    private let ambiguous: Bool
    init(
        socketPath: String,
        responseExitCode: Int = 0,
        responseOutput: String = "ok",
        sendAuthAck: Bool = true,
        sendResponse: Bool = true,
        includeRequestID: Bool = true,
        includeExitCode: Bool = true,
        ambiguous: Bool = false
    ) throws {
        self.socketPath = socketPath
        self.responseExitCode = responseExitCode
        self.responseOutput = responseOutput
        self.sendAuthAck = sendAuthAck
        self.sendResponse = sendResponse
        self.includeRequestID = includeRequestID
        self.includeExitCode = includeExitCode
        self.ambiguous = ambiguous
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
        state = OSAllocatedUnfairLock(initialState: State(listenFD: fd))
    }

    deinit {
        let descriptor = state.withLock { current in
            let descriptor = current.listenFD
            current.listenFD = -1
            return descriptor
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
        Darwin.unlink(socketPath)
    }

    func start() {
        Thread { [weak self] in
            self?.serveOnce()
        }.start()
    }

    func stop() {
        let descriptor = state.withLock { current in
            let descriptor = current.listenFD
            current.listenFD = -1
            return descriptor
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    var capturedAuth: String? {
        state.withLock { $0.capturedAuth }
    }
    var capturedCommand: String? {
        state.withLock { $0.capturedCommand }
    }
    var capturedDryRun: Bool? {
        state.withLock { $0.capturedDryRun }
    }
    var capturedRequestID: String? {
        state.withLock { $0.capturedRequestID }
    }

    private func serveOnce() {
        let listenFD = state.withLock { $0.listenFD }
        guard listenFD >= 0 else { return }
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { Darwin.close(clientFD) }

        if let authLine = readLine(fd: clientFD),
           let data = authLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let auth = json["auth"] as? String
            state.withLock { $0.capturedAuth = auth }
            if sendAuthAck, json["auth_ack"] as? Bool == true, let requestID = json["request_id"] as? String {
                writeFrame(fd: clientFD, ["auth": "ok", "request_id": requestID])
            }
        }

        if let cmdLine = readLine(fd: clientFD),
           let data = cmdLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let command = json["cmd"] as? String
            let dryRun = json["dry_run"] as? Bool
            let requestID = json["request_id"] as? String
            state.withLock { current in
                current.capturedCommand = command
                current.capturedDryRun = dryRun
                current.capturedRequestID = requestID
            }
        }

        guard sendResponse else { return }

        var response: [String: Any] = ["done": true, "output": responseOutput]
        if ambiguous {
            response["ambiguous"] = true
            response["error"] = "accepted command did not finish conclusively"
        }
        if includeExitCode { response["exit_code"] = responseExitCode }
        if includeRequestID, let requestID = capturedRequestID { response["request_id"] = requestID }
        writeFrame(fd: clientFD, response)
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

    private func writeFrame(fd: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, data.count)
        }
    }
}

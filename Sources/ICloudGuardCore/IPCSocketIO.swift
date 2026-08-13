import Darwin
import Foundation

public enum IPCSocketIO {
    public enum SocketError: Error, Equatable {
        case closed
        case lineTooLong
        case invalidUTF8
        case timeout
        case system(Int32)
    }

    public static func configure(
        fd: Int32,
        sendTimeoutSeconds: Int,
        receiveTimeoutSeconds: Int
    ) throws {
        let descriptorFlags = fcntl(fd, F_GETFL)
        guard descriptorFlags >= 0,
              fcntl(fd, F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
            throw SocketError.system(errno)
        }
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketError.system(errno)
        }
        var sendTimeout = timeval(tv_sec: sendTimeoutSeconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw SocketError.system(errno)
        }
        var receiveTimeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw SocketError.system(errno)
        }
    }

    /// Progress frames must never inherit a multi-minute command deadline.
    /// A client that stops reading gets only this short bounded write window.
    public static func progressWriteDeadline(
        commandDeadline: DispatchTime,
        now: DispatchTime = .now(),
        maxFrameWriteMilliseconds: Int = 2_000
    ) -> DispatchTime {
        let capped = now + .milliseconds(max(1, maxFrameWriteMilliseconds))
        return capped.uptimeNanoseconds < commandDeadline.uptimeNanoseconds ? capped : commandDeadline
    }

    public static func peerDisconnected(fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        guard Darwin.poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        guard descriptor.revents & Int16(POLLIN) != 0 else { return false }
        var byte: UInt8 = 0
        return Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    public static func writeAll(fd: Int32, data: Data, deadline: DispatchTime? = nil) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                try waitUntilReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                let result: Int
                if deadline != nil {
                    result = Darwin.send(
                        fd,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written,
                        MSG_DONTWAIT
                    )
                } else {
                    result = Darwin.write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
                }
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result < 0, deadline != nil, (errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else if result == 0 {
                    throw SocketError.closed
                } else {
                    throw SocketError.system(errno)
                }
            }
        }
    }

    public static func readLine(fd: Int32, maxBytes: Int, deadline: DispatchTime? = nil) throws -> String {
        precondition(maxBytes > 0)
        var buffer = [UInt8]()
        buffer.reserveCapacity(min(maxBytes, 4096))
        var byte: UInt8 = 0

        while true {
            try waitUntilReady(fd: fd, events: Int16(POLLIN), deadline: deadline)
            let result = Darwin.read(fd, &byte, 1)
            if result == 1 {
                if byte == UInt8(ascii: "\n") {
                    guard let line = String(bytes: buffer, encoding: .utf8) else { throw SocketError.invalidUTF8 }
                    return line
                }
                guard buffer.count < maxBytes else { throw SocketError.lineTooLong }
                buffer.append(byte)
            } else if result < 0, errno == EINTR {
                continue
            } else if result < 0, (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else if result == 0 {
                throw SocketError.closed
            } else {
                throw SocketError.system(errno)
            }
        }
    }

    private static func waitUntilReady(fd: Int32, events: Int16, deadline: DispatchTime?) throws {
        guard let deadline else { return }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let end = deadline.uptimeNanoseconds
            guard now < end else { throw SocketError.timeout }
            let remainingMilliseconds = min(
                (end - now + 999_999) / 1_000_000,
                UInt64(Int32.max)
            )
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(remainingMilliseconds))
            if result > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 { throw SocketError.closed }
                return
            }
            if result == 0 { throw SocketError.timeout }
            if errno == EINTR { continue }
            throw SocketError.system(errno)
        }
    }
}

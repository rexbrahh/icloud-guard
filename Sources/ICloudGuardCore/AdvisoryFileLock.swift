import Darwin
import Foundation
import os

public final class AdvisoryFileLock: Sendable {
    public enum LockError: Error, Equatable {
        case unavailable
        case system(Int32)
    }

    private let fileDescriptor: OSAllocatedUnfairLock<Int32>

    public static func isHeld(path: String) throws -> Bool {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let fd = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT { return false }
            throw LockError.system(errorNumber)
        }
        defer { Darwin.close(fd) }

        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw LockError.system(EINVAL)
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let errorNumber = errno
            if errorNumber == EWOULDBLOCK { return true }
            throw LockError.system(errorNumber)
        }
        _ = flock(fd, LOCK_UN)
        return false
    }

    public init(path: String) throws {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fd = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            0o600
        )
        guard fd >= 0 else { throw LockError.system(errno) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            let errorNumber = errno
            Darwin.close(fd)
            throw LockError.system(errorNumber)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw LockError.system(EINVAL)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let errorNumber = errno
            Darwin.close(fd)
            if errorNumber == EWOULDBLOCK { throw LockError.unavailable }
            throw LockError.system(errorNumber)
        }
        fileDescriptor = OSAllocatedUnfairLock(initialState: fd)
    }

    public func writeOwnerPID(_ pid: Int32 = getpid()) throws {
        try fileDescriptor.withLock { descriptor in
            guard descriptor >= 0 else { throw LockError.system(EBADF) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else {
                throw LockError.system(EINVAL)
            }
            guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
                throw LockError.system(errno)
            }
            let data = Data("\(pid)\n".utf8)
            try IPCSocketIO.writeAll(fd: descriptor, data: data)
            _ = fsync(descriptor)
        }
    }

    /// Releases ownership before the lock object leaves scope. Idempotent so
    /// callers can use it on the success path while deinit remains the safety
    /// net for every early return and thrown error.
    public func unlock() {
        fileDescriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        unlock()
    }
}

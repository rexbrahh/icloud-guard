import Darwin
import Foundation

enum SecureRegularFile {
    struct Snapshot: Sendable {
        var data: Data
        var permissions: Int
    }

    enum ReadError: Error, Equatable {
        case open(Int32)
        case notRegular
        case tooLarge(UInt64)
        case changed
        case read(Int32)
    }

    static func read(_ url: URL, maximumBytes: UInt64) throws -> Snapshot {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReadError.open(errno) }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ReadError.read(errno) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ReadError.notRegular }
        let size = UInt64(max(0, metadata.st_size))
        guard size <= maximumBytes else { throw ReadError.tooLarge(size) }

        var data = Data()
        data.reserveCapacity(Int(size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < Int(size) {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, Int(size) - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadError.read(errno)
            }
            guard count > 0 else { throw ReadError.changed }
            data.append(buffer, count: count)
        }
        var trailing: UInt8 = 0
        let trailingCount = Darwin.read(descriptor, &trailing, 1)
        guard trailingCount == 0 else {
            if trailingCount < 0, errno != EINTR { throw ReadError.read(errno) }
            throw ReadError.changed
        }
        return Snapshot(data: data, permissions: Int(metadata.st_mode & 0o777))
    }
}

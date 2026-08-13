import Darwin
import Foundation

public struct EvictionFileIdentity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case regular
        case directory
        case symbolicLink
        case other
    }

    public let device: UInt64
    public let inode: UInt64
    public let kind: Kind

    public init(device: UInt64, inode: UInt64, kind: Kind) {
        self.device = device
        self.inode = inode
        self.kind = kind
    }

    public static func capture(path: String) -> EvictionFileIdentity? {
        guard let info = BulkScanner.lstatPath(path) else { return nil }
        return from(info)
    }

    static func from(_ info: stat) -> EvictionFileIdentity {
        let kind: Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        return EvictionFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            kind: kind
        )
    }
}

/// Metadata-only footprint used to verify that an eviction actually removed
/// local data. Directories are measured as the sum of their regular files.
public struct EvictionFootprint: Equatable, Sendable {
    public let allocatedBytes: Int64
    public let isDataless: Bool
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let identity: EvictionFileIdentity?

    public init(
        allocatedBytes: Int64,
        isDataless: Bool,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        identity: EvictionFileIdentity? = nil
    ) {
        self.allocatedBytes = allocatedBytes
        self.isDataless = isDataless
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.identity = identity
    }

    public static func measure(path: String) -> EvictionFootprint? {
        guard case .found(let footprint) = measureResult(path: path) else { return nil }
        return footprint
    }

    public static func measureResult(path: String) -> EvictionFootprintReadResult {
        errno = 0
        guard let root = BulkScanner.lstatPath(path) else {
            return errno == ENOENT
                ? .vanished
                : .failed("lstat-error-\(errno)")
        }
        let isDataless = (root.st_flags & SF_DATALESS) != 0
        let fileType = root.st_mode & S_IFMT
        if fileType == S_IFLNK {
            return .found(EvictionFootprint(
                allocatedBytes: 0,
                isDataless: false,
                isSymbolicLink: true,
                identity: EvictionFileIdentity.from(root)
            ))
        }
        guard fileType == S_IFDIR else {
            return .found(EvictionFootprint(
                allocatedBytes: Int64(root.st_blocks) * 512,
                isDataless: isDataless,
                identity: EvictionFileIdentity.from(root)
            ))
        }

        // A package root can carry SF_DATALESS while one or more of its
        // children are still materialized. Directory truth therefore always
        // comes from walking the children, both before and after eviction.
        var allocatedBytes: Int64 = 0
        do {
            let summary = try BulkScanner.scan(rootPath: path) { entry in
                if entry.isRegularFile { allocatedBytes += entry.allocatedBytes }
            }
            guard summary.isComplete else { return .failed("incomplete-directory-scan") }
        } catch {
            return .failed("directory-scan-error")
        }
        return .found(EvictionFootprint(
            allocatedBytes: allocatedBytes,
            isDataless: isDataless,
            isDirectory: true,
            identity: EvictionFileIdentity.from(root)
        ))
    }

    public func verifiesEviction(from before: EvictionFootprint) -> Bool {
        guard !before.isSymbolicLink, !isSymbolicLink else { return false }
        if let beforeIdentity = before.identity, let identity, identity != beforeIdentity { return false }
        if before.isDirectory || isDirectory {
            return before.allocatedBytes > 0 && allocatedBytes == 0
        }
        return isDataless || (before.allocatedBytes > 0 && allocatedBytes == 0)
    }
}

public enum EvictionFootprintReadResult: Equatable, Sendable {
    case found(EvictionFootprint)
    case vanished
    case failed(String)
}

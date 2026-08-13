import Darwin
import Foundation

/// A single file-system entry discovered by `BulkScanner`.
///
/// All data comes from `getattrlistbulk(2)` + targeted `lstat(2)` — pure
/// metadata, never triggers materialization of dataless files. No Foundation
/// resource-value XPC calls.
public struct BulkScanEntry: Equatable, Sendable {
    /// Absolute path.
    public let path: String
    /// Path relative to the scan root (no leading slash).
    public let relativePath: String
    public let isDirectory: Bool
    public let isRegularFile: Bool
    /// APFS SF_DATALESS flag (0x40000000) — file has no local data blocks.
    public let isDataless: Bool
    /// Bytes actually allocated on disk (0 for dataless files).
    public let allocatedBytes: Int64
    /// Logical file size (0 when unknown for dataless files).
    public let logicalBytes: Int64
    public let modificationDate: Date?
    public let identity: EvictionFileIdentity?

    public init(
        path: String,
        relativePath: String,
        isDirectory: Bool,
        isRegularFile: Bool,
        isDataless: Bool,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        modificationDate: Date?,
        identity: EvictionFileIdentity? = nil
    ) {
        self.path = path
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isDataless = isDataless
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.modificationDate = modificationDate
        self.identity = identity
    }

    /// True when the file occupies local disk space and can be evicted.
    public var isLocallyResidentFile: Bool {
        isRegularFile && !isDataless && allocatedBytes > 0
    }
}

/// Completeness metadata for a bulk scan. Callers must not treat a partial
/// walk as a complete view of the scope.
public struct BulkScanSummary: Equatable, Sendable {
    public var scannedEntries: Int = 0
    public var skippedDirectories: Int = 0
    public var readErrors: Int = 0
    public var stoppedEarly: Bool = false

    public init() {}

    public var isComplete: Bool {
        !stoppedEarly && skippedDirectories == 0 && readErrors == 0
    }
}

/// Fast recursive directory scanner built on `getattrlistbulk(2)`.
///
/// One syscall per directory batch returns names + object types + file flags
/// for hundreds of entries at once. On macOS 26 FileProvider-backed trees do
/// not vend `ATTR_FILE_*` size attributes, so sizes come from a targeted
/// `lstat(2)` that runs only for materialized regular files (a small
/// fraction of an iCloud Drive — dataless files need no size lookup).
///
/// On a ~425k-file iCloud Drive this scans in ~14s, versus several minutes
/// for per-file `URL.resourceValues` round trips. Falls back to a plain
/// `lstat(2)` directory walk if the bulk call is unsupported.
public enum BulkScanner {
    private final class ScanAccumulator {
        var summary = BulkScanSummary()
    }

    public enum ScanError: Error, CustomStringConvertible {
        case cannotOpenRoot(String)

        public var description: String {
            switch self {
            case .cannotOpenRoot(let path): return "cannot open scan root: \(path)"
            }
        }
    }

    /// Recursively scan `rootPath`, invoking `onEntry` for every regular file
    /// and directory (including hidden entries; symlinks are not followed).
    ///
    /// - Parameters:
    ///   - rootPath: absolute path (supports ~).
    ///   - shouldStop: checked between directories; return true to abort early.
    ///   - onEntry: called on the current thread for each entry.
    @discardableResult
    public static func scan(
        rootPath: String,
        shouldStop: () -> Bool = { false },
        onEntry: (BulkScanEntry) -> Void
    ) throws -> BulkScanSummary {
        let expandedRoot = NSString(string: rootPath).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedRoot, isDirectory: true)
        let standardizedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootComponentCount = URL(fileURLWithPath: standardizedRoot).pathComponents.count

        var pendingDirectories: [String] = [standardizedRoot]
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let accumulator = ScanAccumulator()

        while let directoryPath = pendingDirectories.popLast() {
            if shouldStop() {
                accumulator.summary.stoppedEarly = true
                break
            }
            try scanDirectory(
                at: directoryPath,
                rootComponentCount: rootComponentCount,
                buffer: &buffer,
                isRoot: directoryPath == standardizedRoot,
                shouldStop: shouldStop,
                onEntry: {
                    accumulator.summary.scannedEntries += 1
                    onEntry($0)
                },
                onSubdirectory: { pendingDirectories.append($0) },
                accumulator: accumulator
            )
        }
        return accumulator.summary
    }

    // MARK: - Directory scanning

    private static func scanDirectory(
        at path: String,
        rootComponentCount: Int,
        buffer: inout [UInt8],
        isRoot: Bool,
        shouldStop: () -> Bool,
        onEntry: (BulkScanEntry) -> Void,
        onSubdirectory: (String) -> Void,
        accumulator: ScanAccumulator
    ) throws {
        // Never follow a directory that was replaced with a symlink between
        // discovery and traversal. The root is resolved once above; every
        // queued descendant must still be the directory we discovered.
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0) }
        guard fd >= 0 else {
            if isRoot { throw ScanError.cannotOpenRoot(path) }
            accumulator.summary.skippedDirectories += 1
            return
        }
        defer { close(fd) }
        guard openedDirectory(fd: fd, matchesPath: path) else {
            if isRoot { throw ScanError.cannotOpenRoot(path) }
            accumulator.summary.skippedDirectories += 1
            return
        }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(attrBitMapCount)
        attributes.commonattr = attrCMReturnedAttrs | attrCMName | attrCMObjType | attrCMFlags

        var usedBulk = false

        while true {
            if shouldStop() {
                accumulator.summary.stoppedEarly = true
                return
            }
            let recordCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                guard let bufferAddress = rawBuffer.baseAddress else { return -1 }
                return bulkListDirectory(
                    directoryFD: fd,
                    attributes: &attributes,
                    bufferAddress: bufferAddress,
                    bufferSize: rawBuffer.count
                )
            }

            if recordCount < 0 {
                let errorNumber = errno
                if !usedBulk {
                    // Bulk unsupported here — fall back to lstat walk once.
                    if !fallbackScanDirectory(
                        directoryFD: fd,
                        path: path,
                        rootComponentCount: rootComponentCount,
                        shouldStop: shouldStop,
                        onEntry: onEntry,
                        onSubdirectory: onSubdirectory,
                        onReadError: { accumulator.summary.readErrors += 1 },
                        onStopped: { accumulator.summary.stoppedEarly = true }
                    ) {
                        accumulator.summary.skippedDirectories += 1
                    }
                    return
                }
                if errorNumber == EINTR { continue }
                accumulator.summary.readErrors += 1
                return
            }

            if recordCount == 0 { return } // directory exhausted
            usedBulk = true

            buffer.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                if !parseRecords(
                    baseAddress: baseAddress,
                    recordCount: Int(recordCount),
                    directoryFD: fd,
                    directoryPath: path,
                    rootComponentCount: rootComponentCount,
                    onEntry: onEntry,
                    onSubdirectory: onSubdirectory,
                    onReadError: { accumulator.summary.readErrors += 1 }
                ) {
                    accumulator.summary.readErrors += 1
                }
            }
        }
    }

    // MARK: - Record parsing

    private static func parseRecords(
        baseAddress: UnsafeRawPointer,
        recordCount: Int,
        directoryFD: Int32,
        directoryPath: String,
        rootComponentCount: Int,
        onEntry: (BulkScanEntry) -> Void,
        onSubdirectory: (String) -> Void,
        onReadError: () -> Void
    ) -> Bool {
        var cursor = baseAddress

        for _ in 0..<recordCount {
            let recordStart = cursor
            let recordLength = Int(readUInt32(from: recordStart, at: 0))
            guard recordLength >= 24 else { return false }

            let returnedCommon = readUInt32(from: recordStart, at: 4)

            var field = recordStart + 24

            var name: String?
            var objectType: UInt32 = 0

            // Common attributes are returned in ascending bit order:
            // NAME (0x1) < OBJTYPE (0x8) < FLAGS (0x40000)
            if returnedCommon & attrCMName != 0 {
                let nameOffset = readInt32(from: field, at: 0)
                name = String(cString: field.advanced(by: Int(nameOffset)).assumingMemoryBound(to: CChar.self))
                field += 8 // attrreference_t
            }
            if returnedCommon & attrCMObjType != 0 {
                objectType = readUInt32(from: field, at: 0)
                field += 4
            }
            if returnedCommon & attrCMFlags != 0 {
                _ = readUInt32(from: field, at: 0)
                field += 4
            }

            if let entryName = name, entryName != ".", entryName != ".." {
                let entryPath = directoryPath == "/" ? "/\(entryName)" : "\(directoryPath)/\(entryName)"

                if objectType == vDir {
                    guard let statInfo = lstatAt(directoryFD: directoryFD, name: entryName),
                          statInfo.st_mode & S_IFMT == S_IFDIR else {
                        onReadError()
                        cursor = recordStart + recordLength
                        continue
                    }
                    onSubdirectory(entryPath)
                    onEntry(BulkScanEntry(
                        path: entryPath,
                        relativePath: makeRelativePath(fullPath: entryPath, rootComponentCount: rootComponentCount),
                        isDirectory: true,
                        isRegularFile: false,
                        isDataless: false,
                        allocatedBytes: 0,
                        logicalBytes: 0,
                        modificationDate: Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec)),
                        identity: EvictionFileIdentity.from(statInfo)
                    ))
                } else if objectType == vReg {
                    // The bulk record can become stale before parsing. Re-read
                    // the entry without following links and only accept the
                    // regular-file type observed at this boundary.
                    guard let statInfo = lstatAt(directoryFD: directoryFD, name: entryName),
                          statInfo.st_mode & S_IFMT == S_IFREG else {
                        onReadError()
                        cursor = recordStart + recordLength
                        continue
                    }
                    let isDataless = (statInfo.st_flags & sfDataless) != 0
                    let allocatedBytes = Int64(statInfo.st_blocks) * 512
                    let logicalBytes = Int64(statInfo.st_size)
                    let modificationDate = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))
                    onEntry(BulkScanEntry(
                        path: entryPath,
                        relativePath: makeRelativePath(fullPath: entryPath, rootComponentCount: rootComponentCount),
                        isDirectory: false,
                        isRegularFile: true,
                        isDataless: isDataless,
                        allocatedBytes: allocatedBytes,
                        logicalBytes: logicalBytes,
                        modificationDate: modificationDate,
                        identity: EvictionFileIdentity.from(statInfo)
                    ))
                }
                // symlinks, sockets, fifos — skipped entirely
            }

            cursor = recordStart + recordLength
        }
        return true
    }

    // MARK: - lstat fallback

    private static func fallbackScanDirectory(
        directoryFD: Int32,
        path: String,
        rootComponentCount: Int,
        shouldStop: () -> Bool,
        onEntry: (BulkScanEntry) -> Void,
        onSubdirectory: (String) -> Void,
        onReadError: () -> Void,
        onStopped: () -> Void
    ) -> Bool {
        let duplicatedFD = dup(directoryFD)
        guard duplicatedFD >= 0 else { return false }
        guard let directory = fdopendir(duplicatedFD) else {
            close(duplicatedFD)
            return false
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entryPointer = readdir(directory) else {
                if errno != 0 { onReadError() }
                break
            }
            if shouldStop() {
                onStopped()
                return true
            }
            let entry = entryPointer.pointee
            let name = withUnsafePointer(to: entry.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            guard let statInfo = lstatAt(directoryFD: directoryFD, name: name) else {
                onReadError()
                continue
            }

            let fileType = statInfo.st_mode & S_IFMT
            let relativePath = makeRelativePath(fullPath: childPath, rootComponentCount: rootComponentCount)
            let modificationDate = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))

            if fileType == S_IFDIR {
                onSubdirectory(childPath)
                onEntry(BulkScanEntry(
                    path: childPath,
                    relativePath: relativePath,
                    isDirectory: true,
                    isRegularFile: false,
                    isDataless: false,
                    allocatedBytes: 0,
                    logicalBytes: 0,
                    modificationDate: modificationDate,
                    identity: EvictionFileIdentity.from(statInfo)
                ))
            } else if fileType == S_IFREG {
                onEntry(BulkScanEntry(
                    path: childPath,
                    relativePath: relativePath,
                    isDirectory: false,
                    isRegularFile: true,
                    isDataless: (statInfo.st_flags & sfDataless) != 0,
                    allocatedBytes: Int64(statInfo.st_blocks) * 512,
                    logicalBytes: Int64(statInfo.st_size),
                    modificationDate: modificationDate,
                    identity: EvictionFileIdentity.from(statInfo)
                ))
            }
        }
        return true
    }

    // MARK: - Helpers

    static func lstatPath(_ path: String) -> stat? {
        var statInfo = stat()
        guard path.withCString({ lstat($0, &statInfo) }) == 0 else { return nil }
        return statInfo
    }

    private static func lstatAt(directoryFD: Int32, name: String) -> stat? {
        var statInfo = stat()
        let result = name.withCString {
            fstatat(directoryFD, $0, &statInfo, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 ? statInfo : nil
    }

    private static func openedDirectory(fd: Int32, matchesPath expectedPath: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
        let openedPath = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
        return openedPath == URL(fileURLWithPath: expectedPath).standardizedFileURL.path
    }

    private static func makeRelativePath(fullPath: String, rootComponentCount: Int) -> String {
        let components = URL(fileURLWithPath: fullPath).pathComponents
        guard components.count > rootComponentCount else { return "" }
        return components.dropFirst(rootComponentCount).joined(separator: "/")
    }

    private static func readUInt32(from pointer: UnsafeRawPointer, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            memcpy(destination.baseAddress!, pointer + offset, MemoryLayout<UInt32>.size)
        }
        return value
    }

    private static func readInt32(from pointer: UnsafeRawPointer, at offset: Int) -> Int32 {
        var value: Int32 = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            memcpy(destination.baseAddress!, pointer + offset, MemoryLayout<Int32>.size)
        }
        return value
    }

    // MARK: - Constants (mirroring sys/attr.h; defined locally to avoid macro bridging issues)

    private static let bufferSize = 256 * 1024
    private static let attrBitMapCount = 5

    private static let attrCMReturnedAttrs: UInt32 = 0x8000_0000
    private static let attrCMName: UInt32 = 0x0000_0001
    private static let attrCMObjType: UInt32 = 0x0000_0008
    private static let attrCMFlags: UInt32 = 0x0004_0000

    private static let vReg: UInt32 = 1
    private static let vDir: UInt32 = 2

    private static let sfDataless: UInt32 = 0x4000_0000
}

/// Thin wrapper around `getattrlistbulk(2)` to keep the call site type-simple.
private func bulkListDirectory(
    directoryFD: Int32,
    attributes: UnsafeMutablePointer<attrlist>,
    bufferAddress: UnsafeMutableRawPointer,
    bufferSize: Int
) -> Int32 {
    getattrlistbulk(directoryFD, UnsafeMutableRawPointer(attributes), bufferAddress, bufferSize, 0)
}

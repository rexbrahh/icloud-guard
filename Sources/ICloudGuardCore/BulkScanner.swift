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

    public init(
        path: String,
        relativePath: String,
        isDirectory: Bool,
        isRegularFile: Bool,
        isDataless: Bool,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        modificationDate: Date?
    ) {
        self.path = path
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isDataless = isDataless
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.modificationDate = modificationDate
    }

    /// True when the file occupies local disk space and can be evicted.
    public var isLocallyResidentFile: Bool {
        isRegularFile && !isDataless && allocatedBytes > 0
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
    public enum ScanError: Error, CustomStringConvertible {
        case cannotOpenRoot(String)

        public var description: String {
            switch self {
            case .cannotOpenRoot(let path): return "cannot open scan root: \(path)"
            }
        }
    }

    /// Recursively scan `rootPath`, invoking `onEntry` for every regular file
    /// and directory (hidden entries skipped, symlinks not followed).
    ///
    /// - Parameters:
    ///   - rootPath: absolute path (supports ~).
    ///   - shouldStop: checked between directories; return true to abort early.
    ///   - onEntry: called on the current thread for each entry.
    public static func scan(
        rootPath: String,
        shouldStop: () -> Bool = { false },
        onEntry: (BulkScanEntry) -> Void
    ) throws {
        let expandedRoot = NSString(string: rootPath).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedRoot, isDirectory: true)
        let standardizedRoot = rootURL.standardizedFileURL.path
        let rootComponentCount = rootURL.standardizedFileURL.pathComponents.count

        var pendingDirectories: [String] = [standardizedRoot]
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while let directoryPath = pendingDirectories.popLast() {
            if shouldStop() { return }
            try scanDirectory(
                at: directoryPath,
                rootComponentCount: rootComponentCount,
                buffer: &buffer,
                isRoot: directoryPath == standardizedRoot,
                onEntry: onEntry,
                onSubdirectory: { pendingDirectories.append($0) }
            )
        }
    }

    // MARK: - Directory scanning

    private static func scanDirectory(
        at path: String,
        rootComponentCount: Int,
        buffer: inout [UInt8],
        isRoot: Bool,
        onEntry: (BulkScanEntry) -> Void,
        onSubdirectory: (String) -> Void
    ) throws {
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY, 0) }
        guard fd >= 0 else {
            if isRoot { throw ScanError.cannotOpenRoot(path) }
            return // unreadable subdirectory — skip
        }
        defer { close(fd) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(attrBitMapCount)
        attributes.commonattr = attrCMReturnedAttrs | attrCMName | attrCMObjType | attrCMFlags

        var usedBulk = false

        while true {
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
                    fallbackScanDirectory(
                        at: path,
                        rootComponentCount: rootComponentCount,
                        onEntry: onEntry,
                        onSubdirectory: onSubdirectory
                    )
                    return
                }
                if errorNumber == EINTR { continue }
                return // mid-scan error — skip rest of this directory
            }

            if recordCount == 0 { return } // directory exhausted
            usedBulk = true

            buffer.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                parseRecords(
                    baseAddress: baseAddress,
                    recordCount: Int(recordCount),
                    directoryPath: path,
                    rootComponentCount: rootComponentCount,
                    onEntry: onEntry,
                    onSubdirectory: onSubdirectory
                )
            }
        }
    }

    // MARK: - Record parsing

    private static func parseRecords(
        baseAddress: UnsafeRawPointer,
        recordCount: Int,
        directoryPath: String,
        rootComponentCount: Int,
        onEntry: (BulkScanEntry) -> Void,
        onSubdirectory: (String) -> Void
    ) {
        var cursor = baseAddress

        for _ in 0..<recordCount {
            let recordStart = cursor
            let recordLength = Int(readUInt32(from: recordStart, at: 0))
            guard recordLength >= 24 else { break }

            let returnedCommon = readUInt32(from: recordStart, at: 4)

            var field = recordStart + 24

            var name: String?
            var objectType: UInt32 = 0
            var flags: UInt32 = 0

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
                flags = readUInt32(from: field, at: 0)
                field += 4
            }

            if let entryName = name, entryName != ".", entryName != "..", !entryName.hasPrefix(".") {
                let entryPath = directoryPath == "/" ? "/\(entryName)" : "\(directoryPath)/\(entryName)"

                if objectType == vDir {
                    onSubdirectory(entryPath)
                    onEntry(BulkScanEntry(
                        path: entryPath,
                        relativePath: makeRelativePath(fullPath: entryPath, rootComponentCount: rootComponentCount),
                        isDirectory: true,
                        isRegularFile: false,
                        isDataless: false,
                        allocatedBytes: 0,
                        logicalBytes: 0,
                        modificationDate: nil
                    ))
                } else if objectType == vReg {
                    let isDataless = (flags & sfDataless) != 0
                    // FileProvider trees do not vend ATTR_FILE_* sizes; lstat
                    // only materialized files to learn their footprint.
                    var allocatedBytes: Int64 = 0
                    var logicalBytes: Int64 = 0
                    var modificationDate: Date?
                    if !isDataless, let statInfo = lstatPath(entryPath) {
                        allocatedBytes = Int64(statInfo.st_blocks) * 512
                        logicalBytes = Int64(statInfo.st_size)
                        modificationDate = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))
                    }
                    onEntry(BulkScanEntry(
                        path: entryPath,
                        relativePath: makeRelativePath(fullPath: entryPath, rootComponentCount: rootComponentCount),
                        isDirectory: false,
                        isRegularFile: true,
                        isDataless: isDataless,
                        allocatedBytes: allocatedBytes,
                        logicalBytes: logicalBytes,
                        modificationDate: modificationDate
                    ))
                }
                // symlinks, sockets, fifos — skipped entirely
            }

            cursor = recordStart + recordLength
        }
    }

    // MARK: - lstat fallback

    private static func fallbackScanDirectory(
        at path: String,
        rootComponentCount: Int,
        onEntry: (BulkScanEntry) -> Void,
        onSubdirectory: (String) -> Void
    ) {
        guard let directory = opendir(path) else { return }
        defer { closedir(directory) }

        while let entryPointer = readdir(directory) {
            let entry = entryPointer.pointee
            let name = withUnsafePointer(to: entry.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }

            let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            guard let statInfo = lstatPath(childPath) else { continue }

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
                    modificationDate: modificationDate
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
                    modificationDate: modificationDate
                ))
            }
        }
    }

    // MARK: - Helpers

    static func lstatPath(_ path: String) -> stat? {
        var statInfo = stat()
        guard path.withCString({ lstat($0, &statInfo) }) == 0 else { return nil }
        return statInfo
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

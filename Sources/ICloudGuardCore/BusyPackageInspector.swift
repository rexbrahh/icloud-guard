import Darwin
import Foundation

public enum BusyPackageInspectionUnavailableReason: String, Equatable, Sendable {
    case invalidPackage = "invalid-package"
    case permissionDenied = "permission-denied"
    case truncated
    case deadlineExceeded = "deadline-exceeded"
    case providerError = "provider-error"
    case invalidResponse = "invalid-response"
}

public struct BusyPackageAssistance: Equatable, Sendable {
    public var processDisplayNames: [String]

    public init(processDisplayNames: [String]) {
        self.processDisplayNames = processDisplayNames
    }
}

public enum BusyPackageInspection: Equatable, Sendable {
    case clear
    case busy(BusyPackageAssistance)
    case unavailable(BusyPackageInspectionUnavailableReason)
}

public struct BusyPackageProcessList: Equatable, Sendable {
    public var processIDs: [pid_t]
    public var isComplete: Bool

    public init(processIDs: [pid_t], isComplete: Bool) {
        self.processIDs = processIDs
        self.isComplete = isComplete
    }
}

public enum BusyPackageProcessProviderError: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
}

public struct BusyPackageProcessInspectionLimits: Equatable, Sendable {
    public var maximumProcesses: Int
    public var maximumReferencePaths: Int
    public var maximumMatches: Int

    public init(
        maximumProcesses: Int,
        maximumReferencePaths: Int,
        maximumMatches: Int
    ) {
        self.maximumProcesses = maximumProcesses
        self.maximumReferencePaths = maximumReferencePaths
        self.maximumMatches = maximumMatches
    }
}

public protocol BusyPackageProcessProviding: Sendable {
    func processIDsReferencing(
        packagePath: String,
        limits: BusyPackageProcessInspectionLimits,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws -> BusyPackageProcessList
    func processDisplayName(for processID: pid_t) throws -> String
}

/// Finds processes with open file references at or below a package path.
///
/// Inspection is fail-closed: incomplete process results, lookup failures, and
/// deadline exhaustion return `unavailable` instead of incorrectly returning
/// `clear`.
public struct BusyPackageInspector: Sendable {
    public struct Limits: Equatable, Sendable {
        public var maximumProcesses: Int
        public var maximumProcessesInspected: Int
        public var maximumReferencePaths: Int
        public var maximumProcessNameBytes: Int
        public var deadlineNanoseconds: UInt64

        public init(
            maximumProcesses: Int = 64,
            maximumProcessesInspected: Int = 4_096,
            maximumReferencePaths: Int = 4_096,
            maximumProcessNameBytes: Int = 96,
            deadlineNanoseconds: UInt64 = 250_000_000
        ) {
            self.maximumProcesses = min(max(1, maximumProcesses), 256)
            self.maximumProcessesInspected = min(max(1, maximumProcessesInspected), 8_192)
            self.maximumReferencePaths = min(max(1, maximumReferencePaths), 100_000)
            self.maximumProcessNameBytes = min(max(1, maximumProcessNameBytes), 256)
            self.deadlineNanoseconds = deadlineNanoseconds
        }
    }

    private let provider: any BusyPackageProcessProviding
    private let limits: Limits
    private let currentProcessID: pid_t
    private let monotonicNanoseconds: @Sendable () -> UInt64

    public init(
        provider: any BusyPackageProcessProviding = LibprocBusyPackageProcessProvider(),
        limits: Limits = Limits(),
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.provider = provider
        self.limits = limits
        self.currentProcessID = currentProcessID
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    public func inspect(packagePath: String) -> BusyPackageInspection {
        guard packagePath.hasPrefix("/") else { return .unavailable(.invalidPackage) }
        guard let canonicalPath = Self.canonicalPath(packagePath) else {
            return .unavailable(.invalidPackage)
        }
        var metadata = stat()
        guard canonicalPath != "/",
              canonicalPath.withCString({ lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            return .unavailable(.invalidPackage)
        }

        let started = monotonicNanoseconds()
        let addition = started.addingReportingOverflow(limits.deadlineNanoseconds)
        let deadline = addition.overflow ? UInt64.max : addition.partialValue
        let deadlineNanoseconds = limits.deadlineNanoseconds
        let clock = monotonicNanoseconds
        let deadlineExpired: @Sendable () -> Bool = {
            deadlineNanoseconds == 0 || clock() >= deadline
        }
        guard !deadlineExpired() else { return .unavailable(.deadlineExceeded) }

        let processList: BusyPackageProcessList
        do {
            processList = try provider.processIDsReferencing(
                packagePath: canonicalPath,
                limits: BusyPackageProcessInspectionLimits(
                    maximumProcesses: limits.maximumProcessesInspected,
                    maximumReferencePaths: limits.maximumReferencePaths,
                    maximumMatches: limits.maximumProcesses
                ),
                shouldStop: deadlineExpired
            )
        } catch BusyPackageProcessProviderError.permissionDenied {
            return .unavailable(deadlineExpired() ? .deadlineExceeded : .permissionDenied)
        } catch {
            return .unavailable(deadlineExpired() ? .deadlineExceeded : .providerError)
        }

        guard !deadlineExpired() else { return .unavailable(.deadlineExceeded) }
        guard processList.isComplete else { return .unavailable(.truncated) }

        guard processList.processIDs.count <= limits.maximumProcesses else {
            return .unavailable(.invalidResponse)
        }
        let processIDs = Array(Set(processList.processIDs.filter { $0 != currentProcessID })).sorted()
        guard processIDs.count <= limits.maximumProcesses,
              processIDs.allSatisfy({ $0 > 0 }) else {
            return .unavailable(.invalidResponse)
        }
        guard !processIDs.isEmpty else { return .clear }

        var names = Set<String>()
        for processID in processIDs {
            guard !deadlineExpired() else { return .unavailable(.deadlineExceeded) }
            let rawName: String
            do {
                rawName = try provider.processDisplayName(for: processID)
            } catch BusyPackageProcessProviderError.permissionDenied {
                return .unavailable(deadlineExpired() ? .deadlineExceeded : .permissionDenied)
            } catch {
                return .unavailable(deadlineExpired() ? .deadlineExceeded : .providerError)
            }
            guard !deadlineExpired() else { return .unavailable(.deadlineExceeded) }
            guard let name = privacySafeDisplayName(rawName) else {
                return .unavailable(.invalidResponse)
            }
            names.insert(name)
        }

        return .busy(BusyPackageAssistance(processDisplayNames: names.sorted()))
    }

    private func privacySafeDisplayName(_ rawName: String) -> String? {
        let basename = NSString(string: rawName).lastPathComponent
        let visible = basename.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let trimmed = String(String.UnicodeScalarView(visible))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var result = ""
        result.reserveCapacity(min(trimmed.utf8.count, limits.maximumProcessNameBytes))
        for character in trimmed {
            let candidate = result + String(character)
            guard candidate.utf8.count <= limits.maximumProcessNameBytes else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }

    private static func canonicalPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { source in realpath(source, &buffer) }
        guard result != nil else { return nil }
        return String(cString: buffer)
    }
}

public struct LibprocBusyPackageProcessProvider: BusyPackageProcessProviding {
    public init() {}

    public func processIDsReferencing(
        packagePath: String,
        limits: BusyPackageProcessInspectionLimits,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws -> BusyPackageProcessList {
        guard (1...8_192).contains(limits.maximumProcesses),
              (1...100_000).contains(limits.maximumReferencePaths),
              (1...256).contains(limits.maximumMatches) else {
            throw BusyPackageProcessProviderError.unavailable
        }
        var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard packagePath.withCString({ realpath($0, &canonicalBuffer) }) != nil else {
            throw BusyPackageProcessProviderError.unavailable
        }
        let canonical = String(cString: canonicalBuffer)
        var matches = Set<pid_t>()
        var referencePathCount = 0
        var isComplete = true

        func inspectReference(_ referencePath: String) throws {
            if shouldStop() { throw BusyPackageProcessProviderError.unavailable }
            referencePathCount += 1
            guard referencePathCount <= limits.maximumReferencePaths else {
                isComplete = false
                return
            }
            var processIDs = [pid_t](repeating: 0, count: limits.maximumProcesses + 1)
            let listedBytes = referencePath.withCString { pathPointer in
                processIDs.withUnsafeMutableBytes {
                proc_listpidspath(
                    UInt32(PROC_UID_ONLY),
                    UInt32(getuid()),
                    pathPointer,
                    UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                    $0.baseAddress,
                    Int32($0.count)
                )
            }
            }
            guard listedBytes >= 0 else { throw providerError(for: errno) }
            let stride = MemoryLayout<pid_t>.stride
            guard listedBytes % Int32(stride) == 0 else {
                throw BusyPackageProcessProviderError.unavailable
            }
            let count = Int(listedBytes) / stride
            guard count <= limits.maximumProcesses,
                  listedBytes < processIDs.count * stride else {
                isComplete = false
                return
            }
            for processID in processIDs.prefix(count) where processID > 0 {
                matches.insert(processID)
                if matches.count > limits.maximumMatches {
                    isComplete = false
                    return
                }
            }
        }

        try inspectReference(canonical)
        if isComplete {
            let summary = try BulkScanner.scan(rootPath: canonical, shouldStop: {
                shouldStop() || !isComplete
            }) { entry in
                guard isComplete else { return }
                do {
                    try inspectReference(entry.path)
                } catch {
                    isComplete = false
                }
            }
            if !summary.isComplete { isComplete = false }
            if shouldStop() { throw BusyPackageProcessProviderError.unavailable }
        }
        return BusyPackageProcessList(
            processIDs: Array(matches).sorted(),
            isComplete: isComplete
        )
    }

    public func processDisplayName(for processID: pid_t) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes {
            proc_name(processID, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { throw providerError(for: errno) }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func providerError(for errorNumber: Int32) -> BusyPackageProcessProviderError {
        if errorNumber == EPERM || errorNumber == EACCES {
            return .permissionDenied
        }
        return .unavailable
    }
}

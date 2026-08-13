import CryptoKit
import Darwin
@preconcurrency import Foundation

public struct SemanticVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public let buildMetadata: [String]

    public init?(_ value: String) {
        guard value.unicodeScalars.allSatisfy({ $0.isASCII }), !value.isEmpty else { return nil }
        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let versionAndPrerelease = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2]) else { return nil }

        let prerelease = versionAndPrerelease.count == 2
            ? versionAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        let buildMetadata = buildParts.count == 2
            ? buildParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard Self.validIdentifiers(prerelease, rejectNumericLeadingZero: true),
              Self.validIdentifiers(buildMetadata, rejectNumericLeadingZero: false) else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata
    }

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { value += "-" + prerelease.joined(separator: ".") }
        if !buildMetadata.isEmpty { value += "+" + buildMetadata.joined(separator: ".") }
        return value
    }

    public var isRelease: Bool { prerelease.isEmpty && buildMetadata.isEmpty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber)
            let rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric && rightNumeric {
                return left.count == right.count ? left < right : left.count < right.count
            }
            if leftNumeric != rightNumeric { return leftNumeric }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = Self(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid semantic version.")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func parseCoreNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), value == "0" || value.first != "0" else { return nil }
        return Int(value)
    }

    private static func validIdentifiers(_ values: [String], rejectNumericLeadingZero: Bool) -> Bool {
        guard values.allSatisfy({ !$0.isEmpty }) else { return false }
        return values.allSatisfy { value in
            guard value.unicodeScalars.allSatisfy({
                ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                    || ($0.value >= 97 && $0.value <= 122) || $0.value == 45
            }) else { return false }
            return !rejectNumericLeadingZero || !value.allSatisfy(\.isNumber)
                || value == "0" || value.first != "0"
        }
    }
}

public enum UpdateChannel: String, Codable, Sendable, CaseIterable, Hashable {
    case stable
    case beta
    case tip
}

public enum UpdateProvenance: String, Codable, Sendable {
    case trustedCI = "trusted-ci"
    case unauthenticatedTip = "unauthenticated-tip"
}

public struct UpdateRelease: Codable, Equatable, Sendable {
    public var releaseManifestSchemaVersion: Int
    public var channel: UpdateChannel
    public var version: SemanticVersion
    public var tag: String
    public var commit: String
    public var sourceTreeClean: Bool
    public var artifactURL: URL
    public var artifactFilename: String
    public var artifactSHA256: String
    public var artifactSize: Int64
    public var executableSHA256: String
    public var executableUUID: String
    public var signingIdentity: String
    public var signingType: String
    public var teamID: String
    public var notarized: Bool
    public var stapled: Bool
    public var buildToolchain: String
    public var minimumMacOS: String
    public var sourceEpoch: Int64
    public var provenance: UpdateProvenance

    public init(
        releaseManifestSchemaVersion: Int = 2,
        channel: UpdateChannel,
        version: SemanticVersion,
        tag: String,
        commit: String,
        sourceTreeClean: Bool = true,
        artifactURL: URL,
        artifactFilename: String,
        artifactSHA256: String,
        artifactSize: Int64,
        executableSHA256: String,
        executableUUID: String,
        signingIdentity: String,
        signingType: String,
        teamID: String,
        notarized: Bool,
        stapled: Bool,
        buildToolchain: String,
        minimumMacOS: String,
        sourceEpoch: Int64,
        provenance: UpdateProvenance
    ) {
        self.releaseManifestSchemaVersion = releaseManifestSchemaVersion
        self.channel = channel
        self.version = version
        self.tag = tag
        self.commit = commit
        self.sourceTreeClean = sourceTreeClean
        self.artifactURL = artifactURL
        self.artifactFilename = artifactFilename
        self.artifactSHA256 = artifactSHA256
        self.artifactSize = artifactSize
        self.executableSHA256 = executableSHA256
        self.executableUUID = executableUUID
        self.signingIdentity = signingIdentity
        self.signingType = signingType
        self.teamID = teamID
        self.notarized = notarized
        self.stapled = stapled
        self.buildToolchain = buildToolchain
        self.minimumMacOS = minimumMacOS
        self.sourceEpoch = sourceEpoch
        self.provenance = provenance
    }
}

public struct UpdateFeedPayload: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    public var generatedAtEpoch: Int64
    public var expiresAtEpoch: Int64
    public var releases: [UpdateRelease]

    public init(
        schema: Int = schemaVersion,
        generatedAtEpoch: Int64,
        expiresAtEpoch: Int64,
        releases: [UpdateRelease]
    ) {
        self.schema = schema
        self.generatedAtEpoch = generatedAtEpoch
        self.expiresAtEpoch = expiresAtEpoch
        self.releases = releases
    }
}

public enum UpdateFeedCodec {
    private struct Envelope: Codable {
        var schema: Int
        var keyID: String
        var payload: String
        var signature: String
    }

    public static func canonicalPayloadData(_ payload: UpdateFeedPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    public static func envelopeData(
        payload: UpdateFeedPayload,
        keyID: String,
        signatureDER: Data
    ) throws -> Data {
        let canonical = try canonicalPayloadData(payload)
        let envelope = Envelope(
            schema: 1,
            keyID: keyID,
            payload: canonical.base64EncodedString(),
            signature: signatureDER.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    static func authenticatedPayload(
        from data: Data,
        expectedKeyID: String,
        publicKeyX963: Data
    ) throws -> UpdateFeedPayload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "keyID", "payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schema == 1,
              let payloadData = Data(base64Encoded: envelope.payload),
              let signatureData = Data(base64Encoded: envelope.signature),
              let payload = try? JSONDecoder().decode(UpdateFeedPayload.self, from: payloadData),
              let canonical = try? canonicalPayloadData(payload),
              canonical == payloadData else {
            throw UpdaterError.feedMalformed
        }
        guard envelope.keyID == expectedKeyID else { throw UpdaterError.feedAuthenticationFailed }
        do {
            let key = try P256.Signing.PublicKey(x963Representation: publicKeyX963)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            guard key.isValidSignature(signature, for: payloadData) else {
                throw UpdaterError.feedAuthenticationFailed
            }
        } catch let error as UpdaterError {
            throw error
        } catch {
            throw UpdaterError.feedAuthenticationFailed
        }
        return payload
    }
}

public struct UpdateTransportResponse: Sendable, Equatable {
    public var statusCode: Int
    public var finalURL: URL
    public var redirects: [URL]
    public var bytesWritten: Int64

    public init(statusCode: Int, finalURL: URL, redirects: [URL] = [], bytesWritten: Int64) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.redirects = redirects
        self.bytesWritten = bytesWritten
    }
}

public protocol UpdateTransport: Sendable {
    func fetch(
        _ url: URL,
        to destination: URL,
        timeout: TimeInterval,
        maximumBytes: Int64
    ) async throws -> UpdateTransportResponse
}

public enum UpdateTransportError: Error, Equatable, Sendable {
    case invalidRequest
    case requestFailed
    case redirectRejected
    case responseTooLarge
    case destinationRejected
}

public struct URLSessionUpdateTransport: UpdateTransport {
    public init() {}

    public func fetch(
        _ url: URL,
        to destination: URL,
        timeout: TimeInterval,
        maximumBytes: Int64
    ) async throws -> UpdateTransportResponse {
        guard Self.isHTTPS(url), destination.isFileURL, timeout > 0, timeout <= 300,
              maximumBytes > 0 else { throw UpdateTransportError.invalidRequest }
        let loader = UpdateDownloadLoader(
            requestURL: url,
            destination: destination,
            timeout: timeout,
            maximumBytes: maximumBytes
        )
        return try await loader.start()
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard isHTTPS(first), isHTTPS(second) else { return false }
        return first.host?.lowercased() == second.host?.lowercased()
            && (first.port ?? 443) == (second.port ?? 443)
    }
}

private final class UpdateDownloadLoader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let requestURL: URL
    private let destination: URL
    private let timeout: TimeInterval
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UpdateTransportResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var redirects: [URL] = []
    private var callerCancelled = false
    private var redirectRejected = false
    private var responseTooLarge = false
    private var destinationReady = false
    private var destinationRejected = false

    init(requestURL: URL, destination: URL, timeout: TimeInterval, maximumBytes: Int64) {
        self.requestURL = requestURL
        self.destination = destination
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }

    func start() async throws -> UpdateTransportResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.waitsForConnectivity = false
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
                request.httpMethod = "GET"
                request.setValue("application/json, application/zip", forHTTPHeaderField: "Accept")
                let task = session.downloadTask(with: request)

                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                let cancelled = callerCancelled
                lock.unlock()
                cancelled ? task.cancel() : task.resume()
            }
        } onCancel: {
            lock.lock()
            callerCancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let target = request.url else {
            lock.lock()
            redirectRejected = true
            lock.unlock()
            completionHandler(nil)
            return
        }
        lock.lock()
        let allowed = redirects.count < 3 && URLSessionUpdateTransport.sameOrigin(requestURL, target)
        if allowed { redirects.append(target) } else { redirectRejected = true }
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            lock.lock()
            responseTooLarge = true
            lock.unlock()
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            var metadata = stat()
            guard location.path.withCString({ lstat($0, &metadata) }) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size >= 0,
                  metadata.st_size <= maximumBytes else {
                throw UpdateTransportError.responseTooLarge
            }
            try FileManager.default.moveItem(at: location, to: destination)
            guard chmod(destination.path, 0o600) == 0 else {
                throw UpdateTransportError.destinationRejected
            }
            lock.lock()
            destinationReady = true
            lock.unlock()
        } catch let error as UpdateTransportError {
            lock.lock()
            if error == .responseTooLarge { responseTooLarge = true } else { destinationRejected = true }
            lock.unlock()
        } catch {
            lock.lock()
            destinationRejected = true
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let callerCancelled = callerCancelled
        let redirectRejected = redirectRejected
        let responseTooLarge = responseTooLarge
        let destinationReady = destinationReady
        let destinationRejected = destinationRejected
        let redirects = redirects
        let response = task.response as? HTTPURLResponse
        self.session = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()

        guard let continuation else { return }
        if callerCancelled {
            continuation.resume(throwing: CancellationError())
        } else if responseTooLarge {
            continuation.resume(throwing: UpdateTransportError.responseTooLarge)
        } else if redirectRejected {
            continuation.resume(throwing: UpdateTransportError.redirectRejected)
        } else if destinationRejected || !destinationReady {
            continuation.resume(throwing: UpdateTransportError.destinationRejected)
        } else if error != nil {
            continuation.resume(throwing: UpdateTransportError.requestFailed)
        } else if let response, let finalURL = response.url {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? -1
            continuation.resume(returning: UpdateTransportResponse(
                statusCode: response.statusCode,
                finalURL: finalURL,
                redirects: redirects,
                bytesWritten: bytes
            ))
        } else {
            continuation.resume(throwing: UpdateTransportError.requestFailed)
        }
    }
}

public protocol ReleaseArtifactVerifying: Sendable {
    func verify(artifactURL: URL, release: UpdateRelease) async throws
}

enum UpdaterNativeProcess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var overflow: Bool
    }

    private static var allowedExecutables: Set<String> {
        var values: Set<String> = [
            "/usr/bin/codesign",
            "/usr/bin/ditto",
            "/usr/bin/unzip",
            "/usr/bin/xcrun",
            "/usr/bin/zipinfo",
            "/usr/sbin/spctl",
        ]
        #if DEBUG
        values.insert("/bin/sleep")
        #endif
        return values
    }
    private static let outputLimit = 1024 * 1024

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> Result {
        let worker = Task.detached(priority: .utility) {
            try runSynchronously(
                executable,
                arguments,
                timeoutSeconds: timeoutSeconds,
                onLaunch: onLaunch
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func runSynchronously(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) throws -> Result {
        guard allowedExecutables.contains(executable),
              timeoutSeconds > 0, timeoutSeconds <= 300 else {
            throw UpdaterError.artifactVerificationFailed
        }
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let capture = UpdaterProcessCapture(limit: outputLimit)
        let drainGroup = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        onLaunch?(process.processIdentifier)
        drain(output.fileHandleForReading, stdout: true, capture: capture, group: drainGroup)
        drain(error.fileHandleForReading, stdout: false, capture: capture, group: drainGroup)

        let deadline = DispatchTime.now() + timeoutSeconds
        var cancellation = false
        var timedOut = false
        var failedToReap = false
        while exited.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if Task.isCancelled {
                cancellation = true
                break
            }
            if DispatchTime.now() >= deadline {
                timedOut = true
                break
            }
        }
        if cancellation || timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                failedToReap = exited.wait(timeout: .now() + .seconds(1)) == .timedOut
            }
        }
        if failedToReap || cancellation || timedOut {
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        guard drainGroup.wait(timeout: .now() + .seconds(1)) == .success else {
            throw UpdaterError.artifactVerificationFailed
        }
        if failedToReap { throw UpdaterError.artifactVerificationFailed }
        if cancellation { throw CancellationError() }
        try Task.checkCancellation()
        if timedOut { throw UpdaterError.artifactVerificationFailed }
        let result = capture.result()
        return Result(status: process.terminationStatus, stdout: result.stdout, overflow: result.overflow)
    }

    private static func drain(
        _ handle: FileHandle,
        stdout: Bool,
        capture: UpdaterProcessCapture,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            while true {
                let data = handle.readData(ofLength: 4_096)
                if data.isEmpty { return }
                capture.append(data, stdout: stdout)
            }
        }
    }
}

private final class UpdaterProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var stdout = Data()
    private var total = 0
    private var overflow = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data, stdout isStandardOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !overflow else { return }
        let next = total.addingReportingOverflow(data.count)
        guard !next.overflow, next.partialValue <= limit else {
            overflow = true
            return
        }
        total = next.partialValue
        if isStandardOutput { stdout.append(data) }
    }

    func result() -> (stdout: Data, overflow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, overflow)
    }
}

struct UpdateContinuityState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schema = schemaVersion
    var entries: [Entry] = []

    struct Entry: Codable, Equatable, Sendable {
        var keyID: String
        var channel: UpdateChannel
        var highestGeneratedAt: Int64
        var generationFingerprint: String
        var releases: [ReleaseFingerprint]
    }

    struct ReleaseFingerprint: Codable, Equatable, Sendable {
        var version: SemanticVersion
        var fingerprint: String
    }
}

protocol UpdateContinuityStoring: Sendable {
    func update(
        _ body: @Sendable (UpdateContinuityState) throws -> UpdateContinuityState
    ) throws -> UpdateContinuityState
}

struct UpdaterContinuityFileStore: UpdateContinuityStoring {
    static let filename = "update-continuity-v1.json"
    static let lockFilename = ".update-continuity.lock"
    static let maximumBytes = 256 * 1024
    static let maximumEntries = 16
    static let maximumReleasesPerEntry = 1_000

    let root: URL

    func load() throws -> UpdateContinuityState {
        let rootHandle = try openRoot()
        defer {
            Darwin.close(rootHandle.root)
            Darwin.close(rootHandle.parent)
        }
        let rootDescriptor = rootHandle.root
        let lockDescriptor = try lock(rootDescriptor)
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        return try loadUnlocked(rootDescriptor)
    }

    func update(
        _ body: @Sendable (UpdateContinuityState) throws -> UpdateContinuityState
    ) throws -> UpdateContinuityState {
        let rootHandle = try openRoot()
        defer {
            Darwin.close(rootHandle.root)
            Darwin.close(rootHandle.parent)
        }
        let rootDescriptor = rootHandle.root
        let lockDescriptor = try lock(rootDescriptor)
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        let current = try loadUnlocked(rootDescriptor)
        let next = try body(current)
        try saveUnlocked(next, rootDescriptor: rootDescriptor)
        return next
    }

    private func loadUnlocked(_ rootDescriptor: Int32) throws -> UpdateContinuityState {
        let descriptor = Self.filename.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT { return UpdateContinuityState() }
        guard descriptor >= 0 else { throw UpdaterError.releaseMetadataRejected }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumBytes else {
            throw UpdaterError.releaseMetadataRejected
        }
        let data = try readAll(descriptor, expectedBytes: Int(metadata.st_size))
        guard let state = try? JSONDecoder().decode(UpdateContinuityState.self, from: data) else {
            throw UpdaterError.releaseMetadataRejected
        }
        try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(state) == data else { throw UpdaterError.releaseMetadataRejected }
        return state
    }

    private func saveUnlocked(_ state: UpdateContinuityState, rootDescriptor: Int32) throws {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumBytes else { throw UpdaterError.releaseMetadataRejected }
        let temporary = ".update-continuity-\(UUID().uuidString).tmp"
        let descriptor = temporary.withCString {
            openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw UpdaterError.releaseMetadataRejected }
        var keepTemporary = true
        defer {
            Darwin.close(descriptor)
            if keepTemporary {
                _ = temporary.withCString { unlinkat(rootDescriptor, $0, 0) }
            }
        }
        try writeAll(descriptor, data: data)
        guard fchmod(descriptor, mode_t(0o600)) == 0,
              fsync(descriptor) == 0 else {
            throw UpdaterError.releaseMetadataRejected
        }
        let renameStatus = temporary.withCString { source in
            Self.filename.withCString { destination in
                renameat(rootDescriptor, source, rootDescriptor, destination)
            }
        }
        guard renameStatus == 0 else { throw UpdaterError.releaseMetadataRejected }
        keepTemporary = false
        _ = fsync(rootDescriptor)
    }

    private func lock(_ rootDescriptor: Int32) throws -> Int32 {
        let descriptor = Self.lockFilename.withCString {
            openat(
                rootDescriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw UpdaterError.releaseMetadataRejected }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_size == 0,
              fchmod(descriptor, mode_t(0o600)) == 0,
              fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
            Darwin.close(descriptor)
            throw UpdaterError.releaseMetadataRejected
        }
        let deadline = DispatchTime.now() + .seconds(2)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                Darwin.close(descriptor)
                throw UpdaterError.releaseMetadataRejected
            }
            guard DispatchTime.now() < deadline else {
                Darwin.close(descriptor)
                throw UpdaterError.releaseMetadataRejected
            }
            try Task.checkCancellation()
            usleep(10_000)
        }
        var linkedMetadata = stat()
        let linkedStatus = Self.lockFilename.withCString {
            fstatat(rootDescriptor, $0, &linkedMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard linkedStatus == 0,
              metadata.st_dev == linkedMetadata.st_dev,
              metadata.st_ino == linkedMetadata.st_ino else {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw UpdaterError.releaseMetadataRejected
        }
        return descriptor
    }

    private struct RootHandle {
        var parent: Int32
        var root: Int32
    }

    private func openRoot() throws -> RootHandle {
        let root = root.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        let component = root.lastPathComponent
        guard parent != root, safeFilename(component) else {
            throw UpdaterError.releaseMetadataRejected
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let parentDescriptor = parent.path.withCString { Darwin.open($0, flags) }
        guard parentDescriptor >= 0 else { throw UpdaterError.releaseMetadataRejected }
        let descriptor = component.withCString { openat(parentDescriptor, $0, flags) }
        guard descriptor >= 0 else {
            Darwin.close(parentDescriptor)
            throw UpdaterError.releaseMetadataRejected
        }
        var metadata = stat()
        var linkedMetadata = stat()
        let linkedStatus = component.withCString {
            fstatat(parentDescriptor, $0, &linkedMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &metadata) == 0,
              linkedStatus == 0,
              metadata.st_dev == linkedMetadata.st_dev,
              metadata.st_ino == linkedMetadata.st_ino,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
            throw UpdaterError.releaseMetadataRejected
        }
        return RootHandle(parent: parentDescriptor, root: descriptor)
    }

    private func readAll(_ descriptor: Int32, expectedBytes: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < expectedBytes {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, expectedBytes - data.count))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw UpdaterError.releaseMetadataRejected }
            data.append(buffer, count: count)
        }
        var trailing: UInt8 = 0
        guard Darwin.read(descriptor, &trailing, 1) == 0 else {
            throw UpdaterError.releaseMetadataRejected
        }
        return data
    }

    private func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw UpdaterError.releaseMetadataRejected }
                offset += count
            }
        }
    }

    private func validate(_ state: UpdateContinuityState) throws {
        guard state.schema == UpdateContinuityState.schemaVersion,
              state.entries.count <= Self.maximumEntries else {
            throw UpdaterError.releaseMetadataRejected
        }
        var keys = Set<String>()
        for entry in state.entries {
            let key = "\(entry.keyID):\(entry.channel.rawValue)"
            guard !entry.keyID.isEmpty, entry.keyID.utf8.count <= 128,
                  entry.keyID.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }),
                  entry.channel != .tip,
                  entry.highestGeneratedAt >= 0,
                  lowerHex(entry.generationFingerprint, count: 64),
                  entry.releases.count <= Self.maximumReleasesPerEntry,
                  keys.insert(key).inserted else {
                throw UpdaterError.releaseMetadataRejected
            }
            var versions = Set<SemanticVersion>()
            for release in entry.releases {
                guard release.version.isRelease,
                      lowerHex(release.fingerprint, count: 64),
                      versions.insert(release.version).inserted else {
                    throw UpdaterError.releaseMetadataRejected
                }
            }
        }
    }
}

public struct MacOSReleaseArtifactVerifier: ReleaseArtifactVerifying {
    static let maximumArchiveEntries = 256
    static let maximumExpandedFileBytes: Int64 = 512 * 1024 * 1024
    static let maximumExpandedTotalBytes: Int64 = 1024 * 1024 * 1024
    static let compressionRatioThresholdBytes: Int64 = 1024 * 1024
    static let maximumCompressionRatio: Int64 = 200
    static let maximumInfoPlistBytes: UInt64 = 1024 * 1024

    public init() {}

    public func verify(artifactURL: URL, release: UpdateRelease) async throws {
        let worker = Task.detached(priority: .utility) {
            try Self.verifySynchronously(artifactURL: artifactURL, release: release)
        }
        do {
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdaterError.artifactVerificationFailed
        }
    }

    private static func verifySynchronously(artifactURL: URL, release: UpdateRelease) throws {
        try Task.checkCancellation()
        let artifactIdentity = try fileIdentity(artifactURL, expectedSize: release.artifactSize)
        guard artifactIdentity.sha256 == release.artifactSHA256,
              artifactIdentity.permissions == 0o600 else {
            throw UpdaterError.artifactVerificationFailed
        }
        _ = try preflightArchive(artifactURL, expectedArchiveBytes: release.artifactSize)
        try Task.checkCancellation()
        let root = artifactURL.deletingLastPathComponent()
            .appendingPathComponent("verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        guard try run("/usr/bin/ditto", ["-x", "-k", artifactURL.path, root.path]) == 0 else {
            throw UpdaterError.artifactVerificationFailed
        }
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard children.count == 1, children[0].lastPathComponent == "ICloudGuard.app" else {
            throw UpdaterError.artifactVerificationFailed
        }
        let app = children[0]
        let appValues = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard appValues.isDirectory == true, appValues.isSymbolicLink != true else {
            throw UpdaterError.artifactVerificationFailed
        }
        try validateExtractedTree(app)

        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let info = try readInfoPlist(infoURL)
        guard
              info["CFBundleIdentifier"] as? String == "dev.rexliu.ICloudGuard",
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleShortVersionString"] as? String == release.version.description,
              info["LSMinimumSystemVersion"] as? String == release.minimumMacOS,
              let executableName = info["CFBundleExecutable"] as? String,
              executableName == "ICloudGuard", safeComponent(executableName) else {
            throw UpdaterError.artifactVerificationFailed
        }
        let executable = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        let executableIdentity = try fileIdentity(executable, expectedSize: nil)
        guard executableIdentity.sha256 == release.executableSHA256 else {
            throw UpdaterError.artifactVerificationFailed
        }

        let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(release.teamID)\" and certificate leaf[subject.CN] = \"\(release.signingIdentity)\""
        guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, app.path]) == 0,
              try run("/usr/bin/xcrun", ["stapler", "validate", app.path]) == 0,
              try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw UpdaterError.artifactVerificationFailed
        }
        let uuidOutput = try captureStrict(
            "/usr/bin/xcrun", ["dwarfdump", "--uuid", executable.path], timeoutSeconds: 15
        )
        let uuidFields = uuidOutput.split(whereSeparator: \.isWhitespace)
        guard uuidFields.count >= 2, uuidFields[0] == "UUID:", uuidFields[1] == Substring(release.executableUUID) else {
            throw UpdaterError.artifactVerificationFailed
        }
    }

    static func readInfoPlist(_ infoURL: URL) throws -> [String: Any] {
        let snapshot = try SecureRegularFile.read(infoURL, maximumBytes: maximumInfoPlistBytes)
        guard let info = try PropertyListSerialization.propertyList(
            from: snapshot.data,
            format: nil
        ) as? [String: Any] else {
            throw UpdaterError.artifactVerificationFailed
        }
        return info
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        try UpdaterNativeProcess.runSynchronously(executable, arguments, timeoutSeconds: 30).status
    }

    @discardableResult
    static func preflightArchive(_ archiveURL: URL, expectedArchiveBytes: Int64) throws -> Int {
        do {
            let namesOutput = try captureStrict("/usr/bin/unzip", ["-Z1", archiveURL.path])
            let names = namesOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !names.isEmpty, names.count <= maximumArchiveEntries,
                  Set(names).count == names.count else {
                throw UpdaterError.artifactVerificationFailed
            }
            var collisionKeys = Set<String>()
            for name in names {
                try validateArchivePath(name)
                let collisionPath = name.hasSuffix("/") ? String(name.dropLast()) : name
                let collisionKey = collisionPath.precomposedStringWithCanonicalMapping.folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                guard collisionKeys.insert(collisionKey).inserted else {
                    throw UpdaterError.artifactVerificationFailed
                }
            }

            let listing = try captureStrict("/usr/bin/zipinfo", ["-l", archiveURL.path])
            let nameSet = Set(names)
            var directoryKindsByName: [String: Bool] = [:]
            var totalUncompressed: Int64 = 0
            var totalCompressed: Int64 = 0
            for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
                guard fields.count == 10, let mode = fields.first else { continue }
                let path = String(fields[9])
                guard nameSet.contains(path) else { continue }
                guard directoryKindsByName[path] == nil,
                      let uncompressed = Int64(fields[3]), uncompressed >= 0,
                      let compressed = Int64(fields[5]), compressed >= 0 else {
                    throw UpdaterError.artifactVerificationFailed
                }
                let isDirectory = path.hasSuffix("/")
                guard mode.first == (isDirectory ? "d" : "-") else {
                    throw UpdaterError.artifactVerificationFailed
                }
                guard uncompressed <= maximumExpandedFileBytes,
                      compressed <= expectedArchiveBytes else {
                    throw UpdaterError.artifactVerificationFailed
                }
                if uncompressed >= compressionRatioThresholdBytes {
                    let ratioLimit = compressed.multipliedReportingOverflow(by: maximumCompressionRatio)
                    guard compressed > 0, !ratioLimit.overflow,
                          uncompressed <= ratioLimit.partialValue else {
                        throw UpdaterError.artifactVerificationFailed
                    }
                }
                guard let nextUncompressed = adding(totalUncompressed, uncompressed),
                      nextUncompressed <= maximumExpandedTotalBytes,
                      let nextCompressed = adding(totalCompressed, compressed),
                      nextCompressed <= expectedArchiveBytes else {
                    throw UpdaterError.artifactVerificationFailed
                }
                totalUncompressed = nextUncompressed
                totalCompressed = nextCompressed
                directoryKindsByName[path] = isDirectory
            }
            if totalUncompressed >= compressionRatioThresholdBytes {
                let totalRatioLimit = totalCompressed.multipliedReportingOverflow(
                    by: maximumCompressionRatio
                )
                guard totalCompressed > 0, !totalRatioLimit.overflow,
                      totalUncompressed <= totalRatioLimit.partialValue else {
                    throw UpdaterError.artifactVerificationFailed
                }
            }
            guard Set(directoryKindsByName.keys) == nameSet,
                  directoryKindsByName["ICloudGuard.app/"] == true,
                  try run("/usr/bin/unzip", ["-tqq", archiveURL.path]) == 0 else {
                throw UpdaterError.artifactVerificationFailed
            }
            return directoryKindsByName.count
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdaterError.artifactVerificationFailed
        }
    }

    static func validateExtractedTree(_ appURL: URL) throws {
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { throw UpdaterError.artifactVerificationFailed }
        var entryCount = 1
        var totalBytes: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= maximumArchiveEntries else {
                throw UpdaterError.artifactVerificationFailed
            }
            var metadata = stat()
            guard item.path.withCString({ lstat($0, &metadata) }) == 0 else {
                throw UpdaterError.artifactVerificationFailed
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG:
                guard metadata.st_size >= 0,
                      metadata.st_size <= maximumExpandedFileBytes,
                      let next = adding(totalBytes, metadata.st_size),
                      next <= maximumExpandedTotalBytes else {
                    throw UpdaterError.artifactVerificationFailed
                }
                totalBytes = next
            default:
                throw UpdaterError.artifactVerificationFailed
            }
        }
        guard !enumerationFailed else { throw UpdaterError.artifactVerificationFailed }
    }

    private static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4_096,
              !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw UpdaterError.artifactVerificationFailed
        }
        let candidate = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "ICloudGuard.app",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw UpdaterError.artifactVerificationFailed
        }
    }

    private static func captureStrict(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 15
    ) throws -> String {
        let result = try UpdaterNativeProcess.runSynchronously(
            executable, arguments, timeoutSeconds: timeoutSeconds
        )
        guard result.status == 0, !result.overflow,
              let output = String(data: result.stdout, encoding: .utf8) else {
            throw UpdaterError.artifactVerificationFailed
        }
        return output
    }

    private static func adding(_ first: Int64, _ second: Int64) -> Int64? {
        let result = first.addingReportingOverflow(second)
        return result.overflow ? nil : result.partialValue
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}

public struct VerifiedUpdaterConfiguration: Sendable {
    public var feedURL: URL
    public var channel: UpdateChannel
    public var currentVersion: SemanticVersion
    public var expectedKeyID: String
    public var publicKeyX963: Data
    public var expectedTeamID: String
    public var temporaryRoot: URL
    public var maximumFeedBytes: Int64
    public var maximumArtifactBytes: Int64
    public var feedTimeout: TimeInterval
    public var artifactTimeout: TimeInterval
    public var cacheLifetime: TimeInterval
    public var initialBackoff: TimeInterval
    public var maximumBackoff: TimeInterval

    public init(
        feedURL: URL,
        channel: UpdateChannel,
        currentVersion: SemanticVersion,
        expectedKeyID: String,
        publicKeyX963: Data,
        expectedTeamID: String,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        maximumFeedBytes: Int64 = 256 * 1024,
        maximumArtifactBytes: Int64 = 512 * 1024 * 1024,
        feedTimeout: TimeInterval = 15,
        artifactTimeout: TimeInterval = 120,
        cacheLifetime: TimeInterval = 15 * 60,
        initialBackoff: TimeInterval = 30,
        maximumBackoff: TimeInterval = 60 * 60
    ) {
        self.feedURL = feedURL
        self.channel = channel
        self.currentVersion = currentVersion
        self.expectedKeyID = expectedKeyID
        self.publicKeyX963 = publicKeyX963
        self.expectedTeamID = expectedTeamID
        self.temporaryRoot = temporaryRoot
        self.maximumFeedBytes = maximumFeedBytes
        self.maximumArtifactBytes = maximumArtifactBytes
        self.feedTimeout = feedTimeout
        self.artifactTimeout = artifactTimeout
        self.cacheLifetime = cacheLifetime
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
    }
}

public enum UpdateCheckSource: String, Sendable {
    case network
    case cache
}

public enum UnsupportedUpdateReason: String, Sendable {
    case tipRequiresIndependentAuthentication = "tip-requires-independent-authentication"
}

public struct UpdateCandidate: Sendable, Equatable {
    public let release: UpdateRelease
    fileprivate let feedExpiresAt: Date
    fileprivate let monotonicExpiresAt: TimeInterval
}

public enum UpdateAvailability: Sendable, Equatable {
    case upToDate(currentVersion: SemanticVersion)
    case available(UpdateCandidate)
    case unsupported(channel: UpdateChannel, reason: UnsupportedUpdateReason)
}

public struct UpdateCheckResult: Sendable, Equatable {
    public var availability: UpdateAvailability
    public var source: UpdateCheckSource
    public var checkedAt: Date

    fileprivate func with(source: UpdateCheckSource) -> Self {
        var copy = self
        copy.source = source
        return copy
    }
}

public struct ManualUpdateHandoff: Sendable, Equatable {
    public let release: UpdateRelease
    public let verifiedArchiveURL: URL
    public let instructions: String
}

public enum UpdaterError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case operationInProgress
    case backoffActive(retryAfterSeconds: Int)
    case temporaryStorageUnavailable
    case transportFailed
    case responseRejected
    case feedMalformed
    case feedAuthenticationFailed
    case feedExpired
    case releaseMetadataRejected
    case candidateExpired
    case artifactIntegrityFailed
    case artifactVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The updater configuration is invalid."
        case .operationInProgress: return "An update operation is already in progress."
        case .backoffActive(let seconds): return "Update checks are paused for \(seconds) seconds."
        case .temporaryStorageUnavailable: return "Private temporary storage is unavailable."
        case .transportFailed: return "The update service is unavailable."
        case .responseRejected: return "The update service response was rejected."
        case .feedMalformed: return "The update feed format is invalid."
        case .feedAuthenticationFailed: return "The update feed signature is invalid."
        case .feedExpired: return "The update feed is expired."
        case .releaseMetadataRejected: return "The release metadata is invalid."
        case .candidateExpired: return "Check for updates again before downloading."
        case .artifactIntegrityFailed: return "The downloaded update failed its integrity check."
        case .artifactVerificationFailed: return "The downloaded update failed platform verification."
        }
    }
}

public actor VerifiedReleaseUpdater {
    private static let staleTemporaryAge: TimeInterval = 24 * 60 * 60
    private static let maximumStaleScanEntries = 64
    private static let maximumStaleCleanupEntries = 16

    private struct CacheEntry {
        var result: UpdateCheckResult
        var monotonicExpiresAt: TimeInterval
    }

    private let configuration: VerifiedUpdaterConfiguration
    private let transport: any UpdateTransport
    private let artifactVerifier: any ReleaseArtifactVerifying
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> TimeInterval
    private var continuityStore: any UpdateContinuityStoring
    private var cache: CacheEntry?
    private var consecutiveFailures = 0
    private var backoffUntil: TimeInterval?
    private var operationActive = false
    private var lastObservedWallClock: Date?
    private var beforeDirectoryUnlinkForTesting: (@Sendable (URL) -> Void)?

    public init(
        configuration: VerifiedUpdaterConfiguration,
        transport: any UpdateTransport = URLSessionUpdateTransport(),
        artifactVerifier: any ReleaseArtifactVerifying = MacOSReleaseArtifactVerifier(),
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        guard URLSessionUpdateTransport.isHTTPS(configuration.feedURL),
              configuration.currentVersion.isRelease,
              !configuration.expectedKeyID.isEmpty,
              configuration.expectedKeyID.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }),
              validTeamID(configuration.expectedTeamID),
              configuration.temporaryRoot.isFileURL,
              configuration.maximumFeedBytes > 0,
              configuration.maximumArtifactBytes > 0,
              configuration.feedTimeout > 0, configuration.feedTimeout <= 300,
              configuration.artifactTimeout > 0, configuration.artifactTimeout <= 300,
              configuration.cacheLifetime > 0,
              configuration.initialBackoff > 0,
              configuration.maximumBackoff >= configuration.initialBackoff,
              (try? P256.Signing.PublicKey(x963Representation: configuration.publicKeyX963)) != nil else {
            throw UpdaterError.invalidConfiguration
        }
        self.configuration = configuration
        self.transport = transport
        self.artifactVerifier = artifactVerifier
        self.now = now
        self.monotonicNow = monotonicNow
        self.continuityStore = UpdaterContinuityFileStore(root: configuration.temporaryRoot)
    }

    /// Checks metadata only. This method never downloads or installs an artifact.
    public func check() async throws -> UpdateCheckResult {
        try Task.checkCancellation()
        let checkedAt = now()
        guard observeWallClock(checkedAt) else { throw UpdaterError.feedExpired }
        let checkedMonotonic = try monotonicTimestamp()
        if configuration.channel == .tip {
            return UpdateCheckResult(
                availability: .unsupported(
                    channel: .tip,
                    reason: .tipRequiresIndependentAuthentication
                ),
                source: .network,
                checkedAt: checkedAt
            )
        }
        if let backoffUntil, backoffUntil > checkedMonotonic {
            throw UpdaterError.backoffActive(
                retryAfterSeconds: max(1, Int(ceil(backoffUntil - checkedMonotonic)))
            )
        }
        if let cache, cache.monotonicExpiresAt > checkedMonotonic {
            return cache.result.with(source: .cache)
        }
        guard !operationActive else { throw UpdaterError.operationInProgress }
        operationActive = true
        defer { operationActive = false }

        let directory = try privateTemporaryDirectory()
        defer { try? removePrivateTemporaryDirectory(directory, expectedFileName: "feed.json") }
        let feedFile = directory.appendingPathComponent("feed.json")
        do {
            try Task.checkCancellation()
            let response = try await transport.fetch(
                configuration.feedURL,
                to: feedFile,
                timeout: configuration.feedTimeout,
                maximumBytes: configuration.maximumFeedBytes
            )
            try Task.checkCancellation()
            try validateResponse(response, requestURL: configuration.feedURL)
            let snapshot = try SecureRegularFile.read(
                feedFile,
                maximumBytes: UInt64(configuration.maximumFeedBytes)
            )
            guard snapshot.permissions == 0o600, Int64(snapshot.data.count) == response.bytesWritten else {
                throw UpdaterError.responseRejected
            }
            let payload = try UpdateFeedCodec.authenticatedPayload(
                from: snapshot.data,
                expectedKeyID: configuration.expectedKeyID,
                publicKeyX963: configuration.publicKeyX963
            )
            let validatedAt = now()
            guard observeWallClock(validatedAt) else { throw UpdaterError.feedExpired }
            let validatedMonotonic = try monotonicTimestamp()
            let expiresAt = try validate(payload: payload, checkedAt: validatedAt)
            let signedLifetime = expiresAt.timeIntervalSince(validatedAt)
            guard signedLifetime > 0, signedLifetime.isFinite else { throw UpdaterError.feedExpired }
            let signedMonotonicExpiry = validatedMonotonic + signedLifetime
            guard signedMonotonicExpiry.isFinite else { throw UpdaterError.feedExpired }
            let releases = payload.releases.filter { $0.channel == configuration.channel }
            guard !releases.isEmpty else { throw UpdaterError.releaseMetadataRejected }
            let latest = releases.max { $0.version < $1.version }
            let availability: UpdateAvailability
            if let latest, latest.version > configuration.currentVersion {
                availability = .available(UpdateCandidate(
                    release: latest,
                    feedExpiresAt: expiresAt,
                    monotonicExpiresAt: signedMonotonicExpiry
                ))
            } else {
                availability = .upToDate(currentVersion: configuration.currentVersion)
            }
            let result = UpdateCheckResult(availability: availability, source: .network, checkedAt: checkedAt)
            try Task.checkCancellation()
            let keyID = configuration.expectedKeyID
            _ = try continuityStore.update { state in
                try Self.updatedContinuityState(state, for: payload, keyID: keyID)
            }
            cache = CacheEntry(
                result: result,
                monotonicExpiresAt: min(
                    signedMonotonicExpiry,
                    validatedMonotonic + configuration.cacheLifetime
                )
            )
            consecutiveFailures = 0
            backoffUntil = nil
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UpdaterError {
            recordFailure()
            throw error
        } catch {
            recordFailure()
            throw UpdaterError.transportFailed
        }
    }

    /// Downloads and verifies one candidate from the current authenticated cache.
    /// The method returns a manual handoff and never replaces the installed app.
    public func download(_ candidate: UpdateCandidate) async throws -> ManualUpdateHandoff {
        try Task.checkCancellation()
        let startedAt = now()
        guard observeWallClock(startedAt) else { throw UpdaterError.candidateExpired }
        let startedMonotonic = try monotonicTimestamp()
        guard !operationActive else { throw UpdaterError.operationInProgress }
        guard let cache, cache.monotonicExpiresAt > startedMonotonic,
              case .available(let authenticatedCandidate) = cache.result.availability,
              authenticatedCandidate == candidate,
              candidate.monotonicExpiresAt > startedMonotonic,
              candidate.feedExpiresAt > startedAt else {
            throw UpdaterError.candidateExpired
        }
        if let backoffUntil, backoffUntil > startedMonotonic {
            throw UpdaterError.backoffActive(
                retryAfterSeconds: max(1, Int(ceil(backoffUntil - startedMonotonic)))
            )
        }
        operationActive = true
        defer { operationActive = false }

        let directory = try privateTemporaryDirectory()
        let artifact = directory.appendingPathComponent(candidate.release.artifactFilename)
        do {
            try Task.checkCancellation()
            let response = try await transport.fetch(
                candidate.release.artifactURL,
                to: artifact,
                timeout: configuration.artifactTimeout,
                maximumBytes: min(configuration.maximumArtifactBytes, candidate.release.artifactSize)
            )
            try Task.checkCancellation()
            try validateResponse(response, requestURL: candidate.release.artifactURL)
            guard response.bytesWritten == candidate.release.artifactSize else {
                throw UpdaterError.artifactIntegrityFailed
            }
            let identity = try fileIdentity(artifact, expectedSize: candidate.release.artifactSize)
            guard identity.sha256 == candidate.release.artifactSHA256,
                  identity.permissions == 0o600 else {
                throw UpdaterError.artifactIntegrityFailed
            }
            try Task.checkCancellation()
            do {
                try await artifactVerifier.verify(artifactURL: artifact, release: candidate.release)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UpdaterError.artifactVerificationFailed
            }
            try Task.checkCancellation()
            let verifiedIdentity = try fileIdentity(artifact, expectedSize: candidate.release.artifactSize)
            guard verifiedIdentity.sha256 == candidate.release.artifactSHA256,
                  verifiedIdentity.permissions == 0o600 else {
                throw UpdaterError.artifactIntegrityFailed
            }
            let completedAt = now()
            guard observeWallClock(completedAt),
                  candidate.feedExpiresAt > completedAt,
                  candidate.monotonicExpiresAt > (try monotonicTimestamp()) else {
                throw UpdaterError.candidateExpired
            }
            consecutiveFailures = 0
            backoffUntil = nil
            return ManualUpdateHandoff(
                release: candidate.release,
                verifiedArchiveURL: artifact,
                instructions: "Quit iCloud Guard. Open the verified archive. Replace the existing app manually. Relaunch and confirm version \(candidate.release.version)."
            )
        } catch is CancellationError {
            try? removePrivateTemporaryDirectory(
                directory,
                expectedFileName: candidate.release.artifactFilename
            )
            throw CancellationError()
        } catch let error as UpdaterError {
            try? removePrivateTemporaryDirectory(
                directory,
                expectedFileName: candidate.release.artifactFilename
            )
            recordFailure()
            throw error
        } catch {
            try? removePrivateTemporaryDirectory(
                directory,
                expectedFileName: candidate.release.artifactFilename
            )
            recordFailure()
            throw UpdaterError.transportFailed
        }
    }

    public func discard(_ handoff: ManualUpdateHandoff) throws {
        let directory = handoff.verifiedArchiveURL.deletingLastPathComponent().standardizedFileURL
        let root = configuration.temporaryRoot.standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              handoff.verifiedArchiveURL.lastPathComponent == handoff.release.artifactFilename else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        try removePrivateTemporaryDirectory(
            directory,
            expectedFileName: handoff.release.artifactFilename
        )
    }

    func setBeforeDirectoryUnlinkForTesting(_ hook: (@Sendable (URL) -> Void)?) {
        beforeDirectoryUnlinkForTesting = hook
    }

    func setContinuityStoreForTesting(_ store: any UpdateContinuityStoring) {
        continuityStore = store
        cache = nil
    }

    private func removePrivateTemporaryDirectory(
        _ directory: URL,
        expectedFileName: String
    ) throws {
        let root = configuration.temporaryRoot.standardizedFileURL
        let directory = directory.standardizedFileURL
        let prefix = "icloud-guard-update-"
        let childComponent = directory.lastPathComponent
        guard directory.deletingLastPathComponent() == root,
              childComponent.hasPrefix(prefix),
              UUID(uuidString: String(childComponent.dropFirst(prefix.count))) != nil,
              safePathComponent(expectedFileName) else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        let parent = root.deletingLastPathComponent()
        let rootComponent = root.lastPathComponent
        guard parent != root, safePathComponent(rootComponent) else {
            throw UpdaterError.temporaryStorageUnavailable
        }

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let parentDescriptor = parent.path.withCString { Darwin.open($0, flags) }
        guard parentDescriptor >= 0 else { throw UpdaterError.temporaryStorageUnavailable }
        defer { Darwin.close(parentDescriptor) }
        let rootDescriptor = rootComponent.withCString { openat(parentDescriptor, $0, flags) }
        guard rootDescriptor >= 0 else { throw UpdaterError.temporaryStorageUnavailable }
        defer { Darwin.close(rootDescriptor) }
        guard validateOwnedPrivateDirectory(rootDescriptor) else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        let childDescriptor = childComponent.withCString { openat(rootDescriptor, $0, flags) }
        guard childDescriptor >= 0 else { throw UpdaterError.temporaryStorageUnavailable }
        defer { Darwin.close(childDescriptor) }
        var openedChildMetadata = stat()
        guard fstat(childDescriptor, &openedChildMetadata) == 0,
              validateOwnedPrivateDirectory(childDescriptor),
              let names = directoryEntryNames(childDescriptor, limit: 2),
              names.isEmpty || names == [expectedFileName] else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        if names == [expectedFileName] {
            let fileDescriptor = expectedFileName.withCString {
                openat(childDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard fileDescriptor >= 0 else { throw UpdaterError.temporaryStorageUnavailable }
            defer { Darwin.close(fileDescriptor) }
            var openedFileMetadata = stat()
            var linkedFileMetadata = stat()
            let linkedStatus = expectedFileName.withCString {
                fstatat(childDescriptor, $0, &linkedFileMetadata, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(fileDescriptor, &openedFileMetadata) == 0,
                  linkedStatus == 0,
                  sameFileIdentity(openedFileMetadata, linkedFileMetadata),
                  openedFileMetadata.st_mode & S_IFMT == S_IFREG,
                  openedFileMetadata.st_uid == geteuid(),
                  openedFileMetadata.st_mode & mode_t(0o777) == mode_t(0o600),
                  expectedFileName.withCString({ unlinkat(childDescriptor, $0, 0) }) == 0 else {
                throw UpdaterError.temporaryStorageUnavailable
            }
        }
        beforeDirectoryUnlinkForTesting?(directory)
        var linkedChildMetadata = stat()
        let linkedStatus = childComponent.withCString {
            fstatat(rootDescriptor, $0, &linkedChildMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard linkedStatus == 0,
              sameFileIdentity(openedChildMetadata, linkedChildMetadata),
              childComponent.withCString({ unlinkat(rootDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
            throw UpdaterError.temporaryStorageUnavailable
        }
    }

    private func validateOwnedPrivateDirectory(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_uid == geteuid()
            && metadata.st_mode & mode_t(0o777) == mode_t(0o700)
    }

    private func sameFileIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private func directoryEntryNames(_ descriptor: Int32, limit: Int) -> [String]? {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { return nil }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            return nil
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? names.sorted() : nil }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
                if names.count > limit { return nil }
            }
        }
    }

    private func safePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = configuration.temporaryRoot.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        let rootComponent = root.lastPathComponent
        guard parent != root,
              !rootComponent.isEmpty,
              rootComponent != ".",
              rootComponent != "..",
              !rootComponent.contains("/"),
              !rootComponent.contains("\0") else {
            throw UpdaterError.temporaryStorageUnavailable
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let parentDescriptor = parent.path.withCString { Darwin.open($0, directoryFlags) }
        guard parentDescriptor >= 0 else { throw UpdaterError.temporaryStorageUnavailable }
        defer { Darwin.close(parentDescriptor) }

        var parentMetadata = stat()
        guard fstat(parentDescriptor, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw UpdaterError.temporaryStorageUnavailable
        }

        let createRootResult = rootComponent.withCString {
            mkdirat(parentDescriptor, $0, mode_t(0o700))
        }
        guard createRootResult == 0 || errno == EEXIST else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        let rootDescriptor = rootComponent.withCString {
            openat(parentDescriptor, $0, directoryFlags)
        }
        guard rootDescriptor >= 0 else { throw UpdaterError.temporaryStorageUnavailable }
        defer { Darwin.close(rootDescriptor) }
        guard hardenOwnedDirectory(rootDescriptor) else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        cleanupStaleTemporaryDirectories(rootDescriptor, wallClock: now())

        let childComponent = "icloud-guard-update-\(UUID().uuidString)"
        guard childComponent.withCString({ mkdirat(rootDescriptor, $0, mode_t(0o700)) }) == 0 else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        var keepChild = false
        defer {
            if !keepChild {
                _ = childComponent.withCString { unlinkat(rootDescriptor, $0, AT_REMOVEDIR) }
            }
        }
        let childDescriptor = childComponent.withCString {
            openat(rootDescriptor, $0, directoryFlags)
        }
        guard childDescriptor >= 0 else { throw UpdaterError.temporaryStorageUnavailable }
        defer { Darwin.close(childDescriptor) }
        guard hardenOwnedDirectory(childDescriptor) else {
            throw UpdaterError.temporaryStorageUnavailable
        }
        keepChild = true
        return root.appendingPathComponent(childComponent, isDirectory: true)
    }

    private func cleanupStaleTemporaryDirectories(_ rootDescriptor: Int32, wallClock: Date) {
        guard wallClock.timeIntervalSince1970.isFinite,
              let names = directoryEntryNames(
                rootDescriptor,
                limit: Self.maximumStaleScanEntries
              ) else { return }
        let prefix = "icloud-guard-update-"
        var removed = 0
        for name in names where removed < Self.maximumStaleCleanupEntries {
            guard name.hasPrefix(prefix),
                  UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            var metadata = stat()
            let status = name.withCString {
                fstatat(rootDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            let age = wallClock.timeIntervalSince1970 - TimeInterval(metadata.st_mtimespec.tv_sec)
            guard status == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & mode_t(0o777) == mode_t(0o700),
                  age.isFinite, age >= Self.staleTemporaryAge else { continue }
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let childDescriptor = name.withCString { openat(rootDescriptor, $0, flags) }
            guard childDescriptor >= 0 else { continue }
            defer { Darwin.close(childDescriptor) }
            var openedChildMetadata = stat()
            guard fstat(childDescriptor, &openedChildMetadata) == 0,
                  validateOwnedPrivateDirectory(childDescriptor),
                  let childNames = directoryEntryNames(childDescriptor, limit: 1),
                  childNames.count <= 1 else { continue }
            if let fileName = childNames.first {
                guard isUpdaterTemporaryFileName(fileName) else { continue }
                let fileDescriptor = fileName.withCString {
                    openat(childDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard fileDescriptor >= 0 else { continue }
                defer { Darwin.close(fileDescriptor) }
                var openedFileMetadata = stat()
                var linkedFileMetadata = stat()
                let linkedStatus = fileName.withCString {
                    fstatat(childDescriptor, $0, &linkedFileMetadata, AT_SYMLINK_NOFOLLOW)
                }
                guard fstat(fileDescriptor, &openedFileMetadata) == 0,
                      linkedStatus == 0,
                      sameFileIdentity(openedFileMetadata, linkedFileMetadata),
                      openedFileMetadata.st_mode & S_IFMT == S_IFREG,
                      openedFileMetadata.st_uid == geteuid(),
                      openedFileMetadata.st_mode & mode_t(0o777) == mode_t(0o600),
                      fileName.withCString({ unlinkat(childDescriptor, $0, 0) }) == 0 else {
                    continue
                }
            }
            var linkedChildMetadata = stat()
            let linkedStatus = name.withCString {
                fstatat(rootDescriptor, $0, &linkedChildMetadata, AT_SYMLINK_NOFOLLOW)
            }
            if linkedStatus == 0,
               sameFileIdentity(openedChildMetadata, linkedChildMetadata),
               name.withCString({ unlinkat(rootDescriptor, $0, AT_REMOVEDIR) }) == 0 {
                removed += 1
            }
        }
    }

    private func hardenOwnedDirectory(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, mode_t(0o700)) == 0,
              fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
            return false
        }
        return true
    }

    private func isUpdaterTemporaryFileName(_ value: String) -> Bool {
        value == "feed.json" || (safeFilename(value) && value.hasPrefix("ICloudGuard-") && value.hasSuffix(".zip"))
    }

    private func validateResponse(_ response: UpdateTransportResponse, requestURL: URL) throws {
        guard response.statusCode == 200,
              response.bytesWritten >= 0,
              URLSessionUpdateTransport.sameOrigin(requestURL, response.finalURL),
              response.redirects.count <= 3,
              response.redirects.allSatisfy({ URLSessionUpdateTransport.sameOrigin(requestURL, $0) }) else {
            throw UpdaterError.responseRejected
        }
    }

    private func validate(payload: UpdateFeedPayload, checkedAt: Date) throws -> Date {
        let generatedAt = Date(timeIntervalSince1970: TimeInterval(payload.generatedAtEpoch))
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(payload.expiresAtEpoch))
        guard payload.schema == UpdateFeedPayload.schemaVersion,
              payload.releases.count <= 100,
              generatedAt <= checkedAt.addingTimeInterval(5 * 60),
              expiresAt > checkedAt,
              expiresAt > generatedAt,
              expiresAt.timeIntervalSince(generatedAt) <= 7 * 24 * 60 * 60 else {
            throw UpdaterError.feedExpired
        }
        var identities = Set<String>()
        for release in payload.releases {
            try validate(release: release)
            guard identities.insert("\(release.channel.rawValue):\(release.version)").inserted else {
                throw UpdaterError.releaseMetadataRejected
            }
        }
        return expiresAt
    }

    private static func updatedContinuityState(
        _ existingState: UpdateContinuityState,
        for payload: UpdateFeedPayload,
        keyID: String
    ) throws -> UpdateContinuityState {
        var state = existingState
        let authenticatedChannels = Set(payload.releases.map(\.channel)).subtracting([.tip])
        for channel in authenticatedChannels {
            let channelReleases = payload.releases.filter { $0.channel == channel }
            let generationFingerprint = try channelGenerationFingerprint(
                channel: channel,
                payload: payload,
                releases: channelReleases
            )
            let entryIndex = state.entries.firstIndex {
                $0.keyID == keyID && $0.channel == channel
            }
            var entry = entryIndex.map { state.entries[$0] } ?? UpdateContinuityState.Entry(
                keyID: keyID,
                channel: channel,
                highestGeneratedAt: payload.generatedAtEpoch,
                generationFingerprint: generationFingerprint,
                releases: []
            )
            guard payload.generatedAtEpoch >= entry.highestGeneratedAt else {
                throw UpdaterError.releaseMetadataRejected
            }
            if payload.generatedAtEpoch == entry.highestGeneratedAt,
               generationFingerprint != entry.generationFingerprint {
                throw UpdaterError.releaseMetadataRejected
            }
            var releasesByVersion = Dictionary(
                uniqueKeysWithValues: entry.releases.map { ($0.version, $0.fingerprint) }
            )
            for release in channelReleases {
                let fingerprint = try releaseFingerprint(release)
                if let existing = releasesByVersion[release.version], existing != fingerprint {
                    throw UpdaterError.releaseMetadataRejected
                }
                releasesByVersion[release.version] = fingerprint
            }
            if payload.generatedAtEpoch > entry.highestGeneratedAt {
                entry.highestGeneratedAt = payload.generatedAtEpoch
                entry.generationFingerprint = generationFingerprint
            }
            entry.releases = releasesByVersion.map {
                UpdateContinuityState.ReleaseFingerprint(version: $0.key, fingerprint: $0.value)
            }.sorted { $0.version < $1.version }
            if let entryIndex {
                state.entries[entryIndex] = entry
            } else {
                state.entries.append(entry)
            }
        }
        state.entries.sort {
            $0.keyID == $1.keyID ? $0.channel.rawValue < $1.channel.rawValue : $0.keyID < $1.keyID
        }
        return state
    }

    private struct ChannelGeneration: Codable {
        var channel: UpdateChannel
        var generatedAtEpoch: Int64
        var expiresAtEpoch: Int64
        var releases: [UpdateRelease]
    }

    private static func channelGenerationFingerprint(
        channel: UpdateChannel,
        payload: UpdateFeedPayload,
        releases: [UpdateRelease]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ChannelGeneration(
            channel: channel,
            generatedAtEpoch: payload.generatedAtEpoch,
            expiresAtEpoch: payload.expiresAtEpoch,
            releases: releases.sorted { $0.version < $1.version }
        ))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func releaseFingerprint(_ release: UpdateRelease) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(release)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(release: UpdateRelease) throws {
        let shortCommit = String(release.commit.prefix(12))
        guard release.releaseManifestSchemaVersion == 2,
              release.version.isRelease,
              release.sourceTreeClean,
              lowerHex(release.commit, count: 40),
              lowerHex(release.artifactSHA256, count: 64),
              lowerHex(release.executableSHA256, count: 64),
              validUUID(release.executableUUID),
              release.artifactSize > 0,
              release.artifactSize <= configuration.maximumArtifactBytes,
              release.sourceEpoch >= 0,
              release.minimumMacOS == "14.0",
              !release.buildToolchain.isEmpty,
              release.buildToolchain.utf8.count <= 256,
              URLSessionUpdateTransport.isHTTPS(release.artifactURL),
              URLSessionUpdateTransport.sameOrigin(configuration.feedURL, release.artifactURL),
              release.artifactURL.lastPathComponent == release.artifactFilename,
              safeFilename(release.artifactFilename) else {
            throw UpdaterError.releaseMetadataRejected
        }
        switch release.channel {
        case .stable:
            guard release.tag == "v\(release.version)",
                  release.artifactFilename == "ICloudGuard-\(release.version).zip",
                  release.signingType == "developer-id",
                  validSigningIdentity(release.signingIdentity),
                  release.teamID == configuration.expectedTeamID,
                  release.notarized, release.stapled,
                  release.provenance == .trustedCI else {
                throw UpdaterError.releaseMetadataRejected
            }
        case .beta:
            guard release.tag == "beta-\(release.version)",
                  release.artifactFilename == "ICloudGuard-beta-\(release.version).zip",
                  release.signingType == "developer-id",
                  validSigningIdentity(release.signingIdentity),
                  release.teamID == configuration.expectedTeamID,
                  release.notarized, release.stapled,
                  release.provenance == .trustedCI else {
                throw UpdaterError.releaseMetadataRejected
            }
        case .tip:
            guard release.tag == "tip-\(shortCommit)",
                  release.artifactFilename == "ICloudGuard-tip-\(release.version)-\(shortCommit).zip",
                  release.signingType == "adhoc", release.signingIdentity == "-",
                  release.teamID.isEmpty, !release.notarized, !release.stapled,
                  release.provenance == .unauthenticatedTip else {
                throw UpdaterError.releaseMetadataRejected
            }
        }
    }

    private func monotonicTimestamp() throws -> TimeInterval {
        let value = monotonicNow()
        guard value.isFinite, value >= 0 else { throw UpdaterError.feedExpired }
        return value
    }

    private func observeWallClock(_ value: Date) -> Bool {
        guard value.timeIntervalSince1970.isFinite else {
            cache = nil
            return false
        }
        if let lastObservedWallClock, value < lastObservedWallClock {
            cache = nil
            return false
        }
        lastObservedWallClock = value
        return true
    }

    private func recordFailure() {
        consecutiveFailures = min(consecutiveFailures + 1, 20)
        let multiplier = pow(2.0, Double(consecutiveFailures - 1))
        let delay = min(configuration.maximumBackoff, configuration.initialBackoff * multiplier)
        let current = monotonicNow()
        backoffUntil = current.isFinite && current >= 0 ? current + delay : nil
    }
}

private func validTeamID(_ value: String) -> Bool {
    value.count == 10 && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
    }
}

private func validSigningIdentity(_ value: String) -> Bool {
    value.hasPrefix("Developer ID Application:") && value.utf8.count <= 256
        && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value >= 32 && scalar.value != 34 && scalar.value != 92
        }
}

private func safeFilename(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains(where: { $0.value < 32 })
}

private func lowerHex(_ value: String, count: Int) -> Bool {
    value.count == count && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
    }
}

private func validUUID(_ value: String) -> Bool {
    let characters = Array(value.unicodeScalars)
    guard characters.count == 36 else { return false }
    for (index, scalar) in characters.enumerated() {
        if [8, 13, 18, 23].contains(index) {
            guard scalar.value == 45 else { return false }
        } else {
            guard (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 70) else {
                return false
            }
        }
    }
    return true
}

private struct UpdateFileIdentity {
    var size: Int64
    var permissions: Int
    var sha256: String
}

private func fileIdentity(_ url: URL, expectedSize: Int64?) throws -> UpdateFileIdentity {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw UpdaterError.artifactIntegrityFailed }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_size >= 0,
          expectedSize == nil || metadata.st_size == expectedSize else {
        throw UpdaterError.artifactIntegrityFailed
    }
    var hasher = SHA256()
    var total: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw UpdaterError.artifactIntegrityFailed
        }
        if count == 0 { break }
        total += Int64(count)
        if let expectedSize, total > expectedSize { throw UpdaterError.artifactIntegrityFailed }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    guard total == metadata.st_size else { throw UpdaterError.artifactIntegrityFailed }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return UpdateFileIdentity(
        size: total,
        permissions: Int(metadata.st_mode & 0o777),
        sha256: digest
    )
}

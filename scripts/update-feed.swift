import CryptoKit
import Darwin
import Foundation

private enum ToolError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

private enum Channel: String, Codable {
    case stable
    case beta
}

private enum Provenance: String, Codable {
    case trustedCI = "trusted-ci"
}

private struct SemanticVersion: Codable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        guard value.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let numbers = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.allSatisfy(\.isNumber),
                  field == "0" || field.first != "0" else { return nil }
            return Int(field)
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = Self(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid semantic version.")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

private struct ReleaseManifest: Decodable {
    let schemaVersion: Int
    let channel: Channel
    let version: String
    let tag: String
    let commit: String
    let sourceTreeClean: Bool
    let artifactFilename: String
    let artifactSHA256: String
    let artifactSize: Int64
    let executableSHA256: String
    let executableUUID: String
    let signingIdentity: String
    let signingType: String
    let notarized: Bool
    let stapled: Bool
    let buildToolchain: String
    let minimumMacOS: String
    let sourceEpoch: Int64

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case channel
        case version
        case tag
        case commit
        case sourceTreeClean = "source_tree_clean"
        case artifactFilename = "artifact_filename"
        case artifactSHA256 = "artifact_sha256"
        case artifactSize = "artifact_size"
        case executableSHA256 = "executable_sha256"
        case executableUUID = "executable_uuid"
        case signingIdentity = "signing_identity"
        case signingType = "signing_type"
        case notarized
        case stapled
        case buildToolchain = "build_toolchain"
        case minimumMacOS = "minimum_macos"
        case sourceEpoch = "source_epoch"
    }
}

private struct FeedRelease: Codable {
    let releaseManifestSchemaVersion: Int
    let channel: Channel
    let version: SemanticVersion
    let tag: String
    let commit: String
    let sourceTreeClean: Bool
    let artifactURL: URL
    let artifactFilename: String
    let artifactSHA256: String
    let artifactSize: Int64
    let executableSHA256: String
    let executableUUID: String
    let signingIdentity: String
    let signingType: String
    let teamID: String
    let notarized: Bool
    let stapled: Bool
    let buildToolchain: String
    let minimumMacOS: String
    let sourceEpoch: Int64
    let provenance: Provenance
}

private struct FeedPayload: Codable {
    let schema: Int
    let generatedAtEpoch: Int64
    let expiresAtEpoch: Int64
    let releases: [FeedRelease]
}

private struct Envelope: Codable {
    let schema: Int
    let keyID: String
    let payload: String
    let signature: String
}

private struct Options {
    private let values: [String: String]

    init(_ arguments: ArraySlice<String>, allowed: Set<String>) throws {
        var result: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let name = arguments[index]
            guard name.hasPrefix("--"), allowed.contains(name), result[name] == nil else {
                throw ToolError.invalid("unknown or duplicate option: \(name)")
            }
            index = arguments.index(after: index)
            guard index < arguments.endIndex else {
                throw ToolError.invalid("\(name) requires a value")
            }
            result[name] = arguments[index]
            index = arguments.index(after: index)
        }
        values = result
    }

    func require(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw ToolError.invalid("\(name) is required")
        }
        return value
    }

    func optional(_ name: String) -> String? { values[name] }
}

private let usage = """
Usage:
  scripts/update-feed.sh keygen --private-key FILE --public-key FILE
  scripts/update-feed.sh create --manifest FILE --artifact FILE --update-origin HTTPS_URL --channel stable|beta --team-id TEAM_ID --key-id KEY_ID --private-key FILE --generated-at EPOCH --expires-at EPOCH --output FILE
  scripts/update-feed.sh verify --feed FILE --update-origin HTTPS_URL --channel stable|beta --team-id TEAM_ID --key-id KEY_ID --public-key-x963-base64 BASE64 [--checked-at EPOCH]
"""

private let feedOptions: Set<String> = [
    "--manifest", "--artifact", "--update-origin", "--channel", "--team-id", "--key-id",
    "--private-key", "--generated-at", "--expires-at", "--output",
]
private let verifyOptions: Set<String> = [
    "--feed", "--update-origin", "--channel", "--team-id", "--key-id",
    "--public-key-x963-base64", "--checked-at",
]

private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func readRegularFile(_ path: String, maximumBytes: Int, privateInput: Bool = false) throws -> Data {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw ToolError.invalid("cannot open a regular input file: \(path)") }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
        throw ToolError.invalid("input is not a bounded regular file: \(path)")
    }
    if privateInput && metadata.st_mode & 0o077 != 0 {
        throw ToolError.invalid("private key permissions must deny group and other access")
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw ToolError.invalid("cannot read input file: \(path)")
        }
        if count == 0 { break }
        guard result.count + count <= maximumBytes else {
            throw ToolError.invalid("input exceeds \(maximumBytes) bytes: \(path)")
        }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

private func verifyArtifact(_ path: String, manifest: ReleaseManifest) throws {
    guard URL(fileURLWithPath: path).lastPathComponent == manifest.artifactFilename else {
        throw ToolError.invalid("artifact filename does not match the release manifest")
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw ToolError.invalid("cannot open a regular artifact file") }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_size == manifest.artifactSize,
          metadata.st_size > 0, metadata.st_size <= 512 * 1024 * 1024 else {
        throw ToolError.invalid("artifact size does not match the release manifest")
    }
    var hasher = SHA256()
    var total: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw ToolError.invalid("cannot read artifact")
        }
        if count == 0 { break }
        total += Int64(count)
        guard total <= manifest.artifactSize else { throw ToolError.invalid("artifact grew while hashing") }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard total == manifest.artifactSize, digest == manifest.artifactSHA256 else {
        throw ToolError.invalid("artifact SHA-256 does not match the release manifest")
    }
}

private func safeOutputFilename(_ filename: String) -> Bool {
    !filename.isEmpty && filename != "." && filename != ".." &&
        filename.utf8.count <= 255 &&
        !filename.contains("/") && !filename.contains("\\") &&
        !filename.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
}

private func writeNewFile(_ data: Data, to path: String, mode: mode_t) throws {
    guard !path.isEmpty, path.hasPrefix("/") else {
        throw ToolError.invalid("output path must be absolute and normalized")
    }
    let output = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    let filename = output.lastPathComponent
    guard output.path == path, safeOutputFilename(filename) else {
        throw ToolError.invalid("output path must be absolute and normalized with a safe filename")
    }

    let parent = output.deletingLastPathComponent()
    let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentDescriptor >= 0 else {
        throw ToolError.invalid("output parent must be a real directory")
    }
    defer { Darwin.close(parentDescriptor) }

    var parentMetadata = stat()
    guard fstat(parentDescriptor, &parentMetadata) == 0,
          parentMetadata.st_mode & S_IFMT == S_IFDIR else {
        throw ToolError.invalid("output parent must be a real directory")
    }

    let temporaryFilename = ".icloud-guard-feed-\(UUID().uuidString).tmp"
    let descriptor = temporaryFilename.withCString {
        Darwin.openat(
            parentDescriptor,
            $0,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
    }
    guard descriptor >= 0 else { throw ToolError.invalid("cannot create output") }
    var temporaryExists = true
    defer {
        Darwin.close(descriptor)
        if temporaryExists {
            _ = temporaryFilename.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
        }
    }
    try data.withUnsafeBytes { rawBuffer in
        var offset = 0
        while offset < rawBuffer.count {
            let count = Darwin.write(descriptor, rawBuffer.baseAddress?.advanced(by: offset), rawBuffer.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw ToolError.invalid("cannot write output")
            }
            guard count > 0 else { throw ToolError.invalid("cannot write output") }
            offset += count
        }
    }

    guard fsync(descriptor) == 0 else { throw ToolError.invalid("cannot sync output") }
    let publishResult = temporaryFilename.withCString { temporaryPointer in
        filename.withCString { outputPointer in
            Darwin.linkat(parentDescriptor, temporaryPointer, parentDescriptor, outputPointer, 0)
        }
    }
    guard publishResult == 0 else {
        throw ToolError.invalid(errno == EEXIST ? "output already exists" : "cannot publish output")
    }
    let removeTemporaryResult = temporaryFilename.withCString {
        Darwin.unlinkat(parentDescriptor, $0, 0)
    }
    guard removeTemporaryResult == 0 else {
        throw ToolError.invalid("cannot remove temporary output link")
    }
    temporaryExists = false
}

private func strictURL(_ value: String) throws -> URL {
    guard value.utf8.count <= 2_048,
          let components = URLComponents(string: value),
          components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          let url = components.url else {
        throw ToolError.invalid("URL must use HTTPS without credentials, query, or fragment")
    }
    return url
}

private func sameOrigin(_ first: URL, _ second: URL) -> Bool {
    first.host?.lowercased() == second.host?.lowercased()
        && (first.port ?? 443) == (second.port ?? 443)
}

private func updateURLs(origin: URL, channel: Channel, artifactFilename: String? = nil) -> (feed: URL, artifact: URL?) {
    let channelRoot = origin.appendingPathComponent(channel.rawValue, isDirectory: true)
    return (
        channelRoot.appendingPathComponent("feed-v1.json", isDirectory: false),
        artifactFilename.map { channelRoot.appendingPathComponent($0, isDirectory: false) }
    )
}

private func lowerHex(_ value: String, count: Int) -> Bool {
    value.count == count && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
    }
}

private func validTeamID(_ value: String) -> Bool {
    value.count == 10 && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
    }
}

private func validKeyID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
            || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_" || $0 == "."
    }
}

private func validUUID(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard scalars.count == 36 else { return false }
    for (index, scalar) in scalars.enumerated() {
        if [8, 13, 18, 23].contains(index) {
            guard scalar.value == 45 else { return false }
        } else if !((scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 70)) {
            return false
        }
    }
    return true
}

private func validSigningIdentity(_ value: String) -> Bool {
    value.hasPrefix("Developer ID Application:") && value.utf8.count <= 256
        && value.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value != 34 && $0.value != 92 }
}

private func validate(_ release: FeedRelease, expectedChannel: Channel, teamID: String, feedURL: URL) throws {
    let expectedTag = release.channel == .stable ? "v\(release.version)" : "beta-\(release.version)"
    let expectedFilename = release.channel == .stable
        ? "ICloudGuard-\(release.version).zip"
        : "ICloudGuard-beta-\(release.version).zip"
    guard release.releaseManifestSchemaVersion == 2,
          release.channel == expectedChannel,
          release.sourceTreeClean,
          release.tag == expectedTag,
          release.artifactFilename == expectedFilename,
          release.artifactURL.lastPathComponent == expectedFilename,
          sameOrigin(feedURL, release.artifactURL),
          lowerHex(release.commit, count: 40),
          lowerHex(release.artifactSHA256, count: 64),
          lowerHex(release.executableSHA256, count: 64),
          validUUID(release.executableUUID),
          release.artifactSize > 0, release.artifactSize <= 512 * 1024 * 1024,
          release.sourceEpoch >= 0,
          release.signingType == "developer-id", validSigningIdentity(release.signingIdentity),
          release.teamID == teamID, validTeamID(release.teamID),
          release.notarized, release.stapled,
          release.minimumMacOS == "15.0",
          !release.buildToolchain.isEmpty, release.buildToolchain.utf8.count <= 256,
          release.provenance == .trustedCI else {
        throw ToolError.invalid("release metadata does not satisfy the installed updater contract")
    }
}

private func readManifest(_ manifestPath: String) throws -> ReleaseManifest {
    let data = try readRegularFile(manifestPath, maximumBytes: 64 * 1024)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == Set(ReleaseManifest.CodingKeys.allCases.map(\.rawValue)) else {
        throw ToolError.invalid("release manifest keys do not match schema 2")
    }
    let manifest: ReleaseManifest
    do { manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data) }
    catch { throw ToolError.invalid("release manifest is malformed") }
    return manifest
}

private func makeRelease(manifest: ReleaseManifest, artifactURL: URL, feedURL: URL, channel: Channel, teamID: String) throws -> FeedRelease {
    guard let version = SemanticVersion(manifest.version) else {
        throw ToolError.invalid("release version is not a release semantic version")
    }
    let release = FeedRelease(
        releaseManifestSchemaVersion: manifest.schemaVersion,
        channel: manifest.channel,
        version: version,
        tag: manifest.tag,
        commit: manifest.commit,
        sourceTreeClean: manifest.sourceTreeClean,
        artifactURL: artifactURL,
        artifactFilename: manifest.artifactFilename,
        artifactSHA256: manifest.artifactSHA256,
        artifactSize: manifest.artifactSize,
        executableSHA256: manifest.executableSHA256,
        executableUUID: manifest.executableUUID,
        signingIdentity: manifest.signingIdentity,
        signingType: manifest.signingType,
        teamID: teamID,
        notarized: manifest.notarized,
        stapled: manifest.stapled,
        buildToolchain: manifest.buildToolchain,
        minimumMacOS: manifest.minimumMacOS,
        sourceEpoch: manifest.sourceEpoch,
        provenance: .trustedCI
    )
    try validate(release, expectedChannel: channel, teamID: teamID, feedURL: feedURL)
    return release
}

private func validateTimes(generated: Int64, expires: Int64, checked: Int64) throws {
    guard generated >= 0, generated <= checked + 300,
          expires > checked, expires > generated, expires - generated <= 7 * 24 * 60 * 60 else {
        throw ToolError.invalid("feed timestamps must be current and expire within seven days")
    }
}

private func keygen(_ arguments: ArraySlice<String>) throws {
    let options = try Options(arguments, allowed: ["--private-key", "--public-key"])
    let privatePath = try options.require("--private-key")
    let publicPath = try options.require("--public-key")
    let key = P256.Signing.PrivateKey()
    try writeNewFile(Data(key.pemRepresentation.utf8), to: privatePath, mode: 0o600)
    do {
        try writeNewFile(Data((key.publicKey.x963Representation.base64EncodedString() + "\n").utf8), to: publicPath, mode: 0o644)
    } catch {
        Darwin.unlink(privatePath)
        throw error
    }
}

private func create(_ arguments: ArraySlice<String>) throws {
    let options = try Options(arguments, allowed: feedOptions)
    guard let channel = Channel(rawValue: try options.require("--channel")) else {
        throw ToolError.invalid("channel must be stable or beta")
    }
    let teamID = try options.require("--team-id")
    let keyID = try options.require("--key-id")
    guard validTeamID(teamID), validKeyID(keyID) else { throw ToolError.invalid("team ID or key ID is invalid") }
    let updateOrigin = try strictURL(try options.require("--update-origin"))
    let generated = Int64(try options.require("--generated-at"))
    let expires = Int64(try options.require("--expires-at"))
    guard let generated, let expires else { throw ToolError.invalid("feed timestamps must be integers") }
    let now = Int64(Date().timeIntervalSince1970)
    try validateTimes(generated: generated, expires: expires, checked: now)
    let manifest = try readManifest(try options.require("--manifest"))
    try verifyArtifact(try options.require("--artifact"), manifest: manifest)
    let urls = updateURLs(origin: updateOrigin, channel: channel, artifactFilename: manifest.artifactFilename)
    guard let artifactURL = urls.artifact else { throw ToolError.invalid("artifact URL is unavailable") }
    let release = try makeRelease(
        manifest: manifest,
        artifactURL: artifactURL,
        feedURL: urls.feed,
        channel: channel,
        teamID: teamID
    )
    let payload = FeedPayload(schema: 1, generatedAtEpoch: generated, expiresAtEpoch: expires, releases: [release])
    let payloadData = try canonicalData(payload)
    let keyData = try readRegularFile(try options.require("--private-key"), maximumBytes: 16 * 1024, privateInput: true)
    guard let keyPEM = String(data: keyData, encoding: .utf8) else { throw ToolError.invalid("private key is not UTF-8 PEM") }
    let key: P256.Signing.PrivateKey
    do { key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM) }
    catch { throw ToolError.invalid("private key is not a P-256 signing key") }
    let signature = try key.signature(for: payloadData).derRepresentation
    let envelope = Envelope(
        schema: 1,
        keyID: keyID,
        payload: payloadData.base64EncodedString(),
        signature: signature.base64EncodedString()
    )
    try writeNewFile(try canonicalData(envelope), to: try options.require("--output"), mode: 0o644)
}

private func verify(_ arguments: ArraySlice<String>) throws {
    let options = try Options(arguments, allowed: verifyOptions)
    guard let channel = Channel(rawValue: try options.require("--channel")) else {
        throw ToolError.invalid("channel must be stable or beta")
    }
    let teamID = try options.require("--team-id")
    let keyID = try options.require("--key-id")
    guard validTeamID(teamID), validKeyID(keyID) else { throw ToolError.invalid("team ID or key ID is invalid") }
    let updateOrigin = try strictURL(try options.require("--update-origin"))
    let feedURL = updateURLs(origin: updateOrigin, channel: channel).feed
    let publicBase64 = try options.require("--public-key-x963-base64")
    guard let publicData = Data(base64Encoded: publicBase64),
          publicData.base64EncodedString() == publicBase64 else {
        throw ToolError.invalid("public key must be canonical base64")
    }
    let publicKey: P256.Signing.PublicKey
    do { publicKey = try P256.Signing.PublicKey(x963Representation: publicData) }
    catch { throw ToolError.invalid("public key is not an uncompressed P-256 key") }

    let data = try readRegularFile(try options.require("--feed"), maximumBytes: 256 * 1024)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == Set(["schema", "keyID", "payload", "signature"]),
          let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
          envelope.schema == 1, envelope.keyID == keyID,
          let payloadData = Data(base64Encoded: envelope.payload),
          payloadData.base64EncodedString() == envelope.payload,
          let signatureData = Data(base64Encoded: envelope.signature),
          signatureData.base64EncodedString() == envelope.signature,
          let payload = try? JSONDecoder().decode(FeedPayload.self, from: payloadData),
          let canonical = try? canonicalData(payload), canonical == payloadData,
          let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
          publicKey.isValidSignature(signature, for: payloadData) else {
        throw ToolError.invalid("feed is malformed or its signature is invalid")
    }
    let checkedAt: Int64
    if let checked = options.optional("--checked-at") {
        guard let parsed = Int64(checked) else { throw ToolError.invalid("checked-at must be an integer") }
        checkedAt = parsed
    } else {
        checkedAt = Int64(Date().timeIntervalSince1970)
    }
    try validateTimes(generated: payload.generatedAtEpoch, expires: payload.expiresAtEpoch, checked: checkedAt)
    guard payload.schema == 1, !payload.releases.isEmpty, payload.releases.count <= 100 else {
        throw ToolError.invalid("feed payload schema or release count is invalid")
    }
    var identities = Set<String>()
    for release in payload.releases {
        try validate(release, expectedChannel: channel, teamID: teamID, feedURL: feedURL)
        guard identities.insert("\(release.channel.rawValue):\(release.version)").inserted else {
            throw ToolError.invalid("feed contains a duplicate channel and version")
        }
    }
}

do {
    guard CommandLine.arguments.count >= 2 else { throw ToolError.invalid(usage) }
    let arguments = CommandLine.arguments.dropFirst(2)
    switch CommandLine.arguments[1] {
    case "keygen": try keygen(arguments)
    case "create": try create(arguments)
    case "verify": try verify(arguments)
    case "--help", "-h": print(usage)
    default: throw ToolError.invalid(usage)
    }
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(64)
}

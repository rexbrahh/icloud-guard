import Darwin
import Foundation

public enum MultiScopeError: LocalizedError, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidName(String)
    case invalidDefinition(String)
    case duplicateIdentifier(String)
    case duplicateName(String)
    case ambiguousSelector(String, String)
    case invalidPath(scopeID: String, reason: String)
    case overlappingPaths(String, String)
    case symlinkAmbiguity(String)
    case unknownScope(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            return "invalid scope identifier \(value)"
        case .invalidName(let value):
            return "invalid scope name \(value)"
        case .invalidDefinition(let reason):
            return "invalid scope definition: \(reason)"
        case .duplicateIdentifier(let value):
            return "duplicate scope identifier \(value)"
        case .duplicateName(let value):
            return "duplicate scope name \(value)"
        case .ambiguousSelector(let identifier, let name):
            return "scope identifier \(identifier) conflicts with scope name \(name)"
        case .invalidPath(let scopeID, let reason):
            return "scope \(scopeID) has an invalid path: \(reason)"
        case .overlappingPaths(let first, let second):
            return "scope paths overlap: \(first) and \(second)"
        case .symlinkAmbiguity(let scopeID):
            return "scope \(scopeID) contains a symbolic-link path component"
        case .unknownScope(let selector):
            return "unknown scope \(selector)"
        }
    }
}

/// One independently configured scope. Definitions are stored as quoted,
/// versioned payloads in the existing fixed-schema TOML file.
public struct ManagedScopeConfig: Codable, Equatable, Sendable {
    public static let definitionVersion = 2

    public var id: String
    public var name: String
    public var automaticEnabled: Bool
    public var scope: AppConfig.ScopeConfig
    public var watcher: AppConfig.WatcherConfig
    public var policy: AppConfig.PolicyConfig
    public var eviction: AppConfig.EvictionConfig

    public init(
        id: String,
        name: String,
        automaticEnabled: Bool = true,
        scope: AppConfig.ScopeConfig,
        watcher: AppConfig.WatcherConfig = .init(),
        policy: AppConfig.PolicyConfig = .init(),
        eviction: AppConfig.EvictionConfig = .init()
    ) {
        self.id = id
        self.name = name
        self.automaticEnabled = automaticEnabled
        self.scope = scope
        self.watcher = watcher
        self.policy = policy.normalized()
        self.eviction = eviction
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case name
        case automaticEnabled = "automatic_enabled"
        case scope
        case watcher
        case policy
        case eviction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.definitionVersion
        guard version == Self.definitionVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "unsupported definition version \(version)"
            )
        }
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        automaticEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticEnabled) ?? true
        scope = try container.decode(AppConfig.ScopeConfig.self, forKey: .scope)
        watcher = try container.decodeIfPresent(AppConfig.WatcherConfig.self, forKey: .watcher) ?? .init()
        policy = try container.decodeIfPresent(AppConfig.PolicyConfig.self, forKey: .policy) ?? .init()
        eviction = try container.decodeIfPresent(AppConfig.EvictionConfig.self, forKey: .eviction) ?? .init()
        policy = policy.normalized()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.definitionVersion, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(automaticEnabled, forKey: .automaticEnabled)
        try container.encode(scope, forKey: .scope)
        try container.encode(watcher, forKey: .watcher)
        try container.encode(policy.normalized(), forKey: .policy)
        try container.encode(eviction, forKey: .eviction)
    }

    func encodedDefinition() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let definition = String(data: data, encoding: .utf8) else {
            throw MultiScopeError.invalidDefinition("definition is not UTF-8")
        }
        return definition
    }

    static func decodeDefinition(_ definition: String) throws -> ManagedScopeConfig {
        guard !definition.isEmpty, definition.utf8.count <= 65_536,
              let data = definition.data(using: .utf8) else {
            throw MultiScopeError.invalidDefinition("definition must be 1...65536 UTF-8 bytes")
        }
        do {
            let version = try JSONDecoder().decode(DefinitionVersion.self, from: data).version
            switch version {
            case 1:
                let legacy = try JSONDecoder().decode(LegacyDefinitionV1.self, from: data)
                guard try legacy.encodedDefinition() == definition else {
                    throw MultiScopeError.invalidDefinition("definition is not canonical")
                }
                return ManagedScopeConfig(
                    id: legacy.id,
                    name: legacy.name,
                    automaticEnabled: legacy.automaticEnabled,
                    scope: legacy.scope,
                    watcher: .init(),
                    policy: legacy.policy,
                    eviction: legacy.eviction
                )
            case Self.definitionVersion:
                let decoded = try JSONDecoder().decode(ManagedScopeConfig.self, from: data)
                guard try decoded.encodedDefinition() == definition else {
                    throw MultiScopeError.invalidDefinition("definition is not canonical")
                }
                return decoded
            default:
                throw MultiScopeError.invalidDefinition("unsupported definition version \(version)")
            }
        } catch let error as MultiScopeError {
            throw error
        } catch {
            throw MultiScopeError.invalidDefinition(error.localizedDescription)
        }
    }

    private struct DefinitionVersion: Decodable {
        var version: Int
    }

    private struct LegacyDefinitionV1: Codable {
        var version: Int
        var id: String
        var name: String
        var automaticEnabled: Bool
        var scope: AppConfig.ScopeConfig
        var policy: AppConfig.PolicyConfig
        var eviction: AppConfig.EvictionConfig

        private enum CodingKeys: String, CodingKey {
            case version
            case id
            case name
            case automaticEnabled = "automatic_enabled"
            case scope
            case policy
            case eviction
        }

        func encodedDefinition() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(self)
            guard let definition = String(data: data, encoding: .utf8) else {
                throw MultiScopeError.invalidDefinition("definition is not UTF-8")
            }
            return definition
        }
    }
}

public enum MultiScopeValidator {
    public static func validate(_ scopes: [ManagedScopeConfig]) throws {
        guard 1...64 ~= scopes.count else {
            throw MultiScopeError.invalidDefinition("scope count must be in 1...64")
        }

        var identifiers = Set<String>()
        var names = Set<String>()
        var canonical: [(id: String, path: String)] = []

        for scope in scopes {
            try validateIdentifier(scope.id)
            try validateName(scope.name)
            guard identifiers.insert(scope.id).inserted else {
                throw MultiScopeError.duplicateIdentifier(scope.id)
            }
            let foldedName = normalizedName(scope.name)
            guard names.insert(foldedName).inserted else {
                throw MultiScopeError.duplicateName(scope.name)
            }
            if let duplicate = FolderPolicySet.duplicatePath(in: scope.scope.folderPolicies) {
                throw MultiScopeError.invalidDefinition(
                    "scope \(scope.id) contains duplicate folder policy path \(duplicate)"
                )
            }
            guard scope.scope.keepDownloadedPaths.allSatisfy({ KeepDownloadedRule(pattern: $0) != nil }) else {
                throw MultiScopeError.invalidDefinition(
                    "scope \(scope.id) contains an unsafe keep-downloaded path"
                )
            }
            guard scope.scope.protectedPaths.allSatisfy({
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed == $0 && $0.utf8.count <= 4_096
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }) else {
                throw MultiScopeError.invalidDefinition(
                    "scope \(scope.id) contains an invalid protected path"
                )
            }
            guard 1...1_000_000 ~= scope.eviction.batchLimit,
                  1...1_000_000 ~= scope.eviction.panicLimit,
                  policyValues(scope.policy).allSatisfy({ 0...1_000_000 ~= $0 }),
                  1...1_000_000 ~= scope.policy.growthWindowMinutes else {
                throw MultiScopeError.invalidDefinition("scope \(scope.id) contains an out-of-range policy value")
            }
            guard watcherIsValid(scope.watcher) else {
                throw MultiScopeError.invalidDefinition("scope \(scope.id) contains an out-of-range watcher value")
            }
            canonical.append((scope.id, try canonicalPath(for: scope)))
        }

        for identifierScope in scopes {
            let foldedIdentifier = normalizedName(identifierScope.id)
            for namedScope in scopes where namedScope.id != identifierScope.id {
                if normalizedName(namedScope.name) == foldedIdentifier {
                    throw MultiScopeError.ambiguousSelector(identifierScope.id, namedScope.name)
                }
            }
        }

        for firstIndex in canonical.indices {
            for secondIndex in canonical.indices where secondIndex > firstIndex {
                let first = canonical[firstIndex]
                let second = canonical[secondIndex]
                if contains(first.path, second.path) || contains(second.path, first.path) {
                    throw MultiScopeError.overlappingPaths(first.id, second.id)
                }
            }
        }
    }

    public static func validateIdentifier(_ identifier: String) throws {
        let scalars = identifier.unicodeScalars
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !identifier.isEmpty,
              identifier.utf8.count <= 64,
              identifier.first?.isASCII == true,
              identifier.first?.isLetter == true || identifier.first?.isNumber == true,
              scalars.allSatisfy(allowed.contains),
              !identifier.hasSuffix("-") else {
            throw MultiScopeError.invalidIdentifier(identifier)
        }
    }

    public static func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name,
              !name.isEmpty,
              name.utf8.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !name.contains("/"), !name.contains("\\") else {
            throw MultiScopeError.invalidName(name)
        }
    }

    public static func canonicalPath(for scope: ManagedScopeConfig) throws -> String {
        let expanded = NSString(string: scope.scope.path).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded.utf8.count <= 4_096 else {
            throw MultiScopeError.invalidPath(scopeID: scope.id, reason: "path must be an absolute path of at most 4096 bytes")
        }
        let standardized = try lexicallyNormalizedAbsolutePath(expanded, scopeID: scope.id)
        guard standardized != "/" else {
            throw MultiScopeError.invalidPath(scopeID: scope.id, reason: "filesystem root is not a valid scope")
        }
        if containsSymbolicLink(in: standardized) {
            throw MultiScopeError.symlinkAmbiguity(scope.id)
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if standardized.withCString({ Darwin.realpath($0, &buffer) }) != nil {
            return String(cString: buffer)
        }
        return standardized
    }

    private static func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        parent == child || child.hasPrefix(parent + "/")
    }

    private static func policyValues(_ policy: AppConfig.PolicyConfig) -> [Int] {
        [
            policy.targetLocalGiB, policy.trimLocalGiB, policy.warnFreeGiB,
            policy.remediateFreeGiB, policy.panicFreeGiB, policy.cooldownMinutes,
            policy.growthTriggerGiB,
        ]
    }

    private static func watcherIsValid(_ watcher: AppConfig.WatcherConfig) -> Bool {
        (1...604_800).contains(watcher.backoffMaxSeconds)
            && (1...604_800).contains(watcher.pollutionCheckIntervalSeconds)
            && (1...604_800).contains(watcher.watchlistPollSeconds)
            && (1...100_000).contains(watcher.watchlistMaxEntries)
            && (1...87_600).contains(watcher.verifiedRetentionHours)
            && (1...3_600).contains(watcher.pendingVerificationGraceSeconds)
            && (1...100).contains(watcher.pendingRetryLimit)
            && (1...100).contains(watcher.maxFights)
    }

    private static func containsSymbolicLink(in path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        var current = ""
        for component in components {
            current = component == "/" ? "/" : URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(component, isDirectory: true).path
            var metadata = stat()
            if current.withCString({ lstat($0, &metadata) }) == 0,
               metadata.st_mode & S_IFMT == S_IFLNK {
                return true
            }
        }
        return false
    }

    private static func lexicallyNormalizedAbsolutePath(_ path: String, scopeID: String) throws -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw MultiScopeError.invalidPath(scopeID: scopeID, reason: "path escapes filesystem root")
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}

public struct ScopeSelector: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty, value.utf8.count <= 80,
              !value.contains("/"), !value.contains("\\"), !value.hasPrefix("~"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MultiScopeError.unknownScope("invalid-selector")
        }
        self.value = value
    }
}

/// Safe for CLI, IPC, logs, and support diagnostics: it never carries a raw path.
public struct ScopeSelectionResult: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var scopeIdentifier: String

    public init(scope: ManagedScopeConfig) {
        id = scope.id
        name = scope.name
        scopeIdentifier = PrivacyIdentifier.scope(scope.scope.path)
    }
}

public struct ManagedScopeContext: Equatable, Sendable {
    public var config: ManagedScopeConfig
    public var paths: AppPaths.ScopePaths
    public var usesLegacyStorage: Bool

    public init(config: ManagedScopeConfig, paths: AppPaths.ScopePaths, usesLegacyStorage: Bool) {
        self.config = config
        self.paths = paths
        self.usesLegacyStorage = usesLegacyStorage
    }

    public var selectionResult: ScopeSelectionResult { ScopeSelectionResult(scope: config) }
}

public struct MultiScopeCatalog: Sendable {
    public let contexts: [ManagedScopeContext]

    public init(config: AppConfig) throws {
        if let scopes = config.scopes {
            try MultiScopeValidator.validate(scopes)
            contexts = try scopes.map {
                ManagedScopeContext(config: $0, paths: try AppPaths.paths(forManagedScope: $0), usesLegacyStorage: false)
            }
        } else {
            let legacy = ManagedScopeConfig(
                id: "default",
                name: "iCloud Drive",
                scope: config.scope,
                watcher: config.watcher,
                policy: config.policy,
                eviction: config.eviction
            )
            contexts = [ManagedScopeContext(config: legacy, paths: AppPaths.legacyScopePaths, usesLegacyStorage: true)]
        }
    }

    public func context(for selector: ScopeSelector) throws -> ManagedScopeContext {
        let folded = selector.value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let matches = contexts.filter {
            $0.config.id == selector.value || $0.config.name.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ) == folded
        }
        let uniqueMatches = Dictionary(grouping: matches, by: { $0.config.id }).values.compactMap(\.first)
        guard uniqueMatches.count == 1, let match = uniqueMatches.first else {
            throw MultiScopeError.unknownScope(selector.value)
        }
        return match
    }

    public var selections: [ScopeSelectionResult] { contexts.map(\.selectionResult) }
}

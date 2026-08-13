import Foundation

public enum FolderPolicyMode: String, Codable, CaseIterable, Sendable {
    case protect
    case evictFirst = "evict-first"
    case evictLast = "evict-last"
}

public struct FolderPolicyRule: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: LocalizedError, Equatable, Sendable {
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    public var path: String
    public var mode: FolderPolicyMode

    public init(path: String, mode: FolderPolicyMode) throws {
        self.path = try Self.validatedPath(path)
        self.mode = mode
    }

    public init(serialized: String) throws {
        guard let separator = serialized.firstIndex(of: ":"),
              let mode = FolderPolicyMode(rawValue: String(serialized[..<separator])) else {
            throw ValidationError.invalid("folder policy must use mode:path with protect, evict-first, or evict-last")
        }
        try self.init(path: String(serialized[serialized.index(after: separator)...]), mode: mode)
    }

    public var serialized: String { "\(mode.rawValue):\(path)" }

    public func matches(relativePath: String) -> Bool {
        let candidate = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return candidate == path || candidate.hasPrefix(path + "/")
    }

    private static func validatedPath(_ input: String) throws -> String {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !input.hasPrefix("/"),
              !input.hasPrefix("~"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ValidationError.invalid("folder policy path must be a safe scope-relative path")
        }
        return path
    }
}

public struct FolderPolicySet: Sendable {
    public let rules: [FolderPolicyRule]

    public init(_ rules: [FolderPolicyRule]) {
        self.rules = rules
    }

    public static func duplicatePath(in rules: [FolderPolicyRule]) -> String? {
        var paths = Set<String>()
        for rule in rules where !paths.insert(rule.path).inserted { return rule.path }
        return nil
    }

    public func effectiveMode(relativePath: String) -> FolderPolicyMode? {
        rules
            .filter { $0.matches(relativePath: relativePath) }
            .max { lhs, rhs in lhs.path.count < rhs.path.count }?
            .mode
    }

    public func prioritized(_ candidates: [EvictionCandidate]) -> [EvictionCandidate] {
        candidates.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(for: lhs.element.relativePath)
            let rhsRank = rank(for: rhs.element.relativePath)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
    }

    public func rank(for relativePath: String) -> Int {
        switch effectiveMode(relativePath: relativePath) {
        case .evictFirst: return 0
        case .evictLast: return 2
        case .protect, .none: return 1
        }
    }
}

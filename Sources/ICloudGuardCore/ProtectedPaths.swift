import Foundation

/// Unified protected-path matching for eviction eligibility.
///
/// Supports:
/// - relative prefix from the iCloud scope root ("Documents/work" matches "Documents/work/…")
/// - absolute path prefix ("~/Library/Mobile Documents/…" or full path)
/// - glob patterns containing `*` or `?` matched against the full path and the file name
public struct ProtectedPathsMatcher: Sendable {
    public let patterns: [String]
    public let keepDownloaded: KeepDownloadedMatcher
    public let folderPolicies: FolderPolicySet

    public init(patterns: [String]) {
        self.init(protectedPaths: patterns, keepDownloadedPatterns: [], folderPolicies: [])
    }

    public init(
        protectedPaths: [String],
        keepDownloadedPatterns: [String],
        folderPolicies: [FolderPolicyRule]
    ) {
        self.patterns = protectedPaths
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.keepDownloaded = KeepDownloadedMatcher(patterns: keepDownloadedPatterns)
        self.folderPolicies = FolderPolicySet(folderPolicies)
    }

    public var isEmpty: Bool { patterns.isEmpty && keepDownloaded.isEmpty && folderPolicies.rules.isEmpty }

    public func folderMode(relativePath: String) -> FolderPolicyMode? {
        folderPolicies.effectiveMode(relativePath: relativePath)
    }

    public func priorityRank(relativePath: String) -> Int {
        folderPolicies.rank(for: relativePath)
    }

    public func isKeptDownloaded(relativePath: String) -> Bool {
        keepDownloaded.matches(relativePath: relativePath)
    }

    public func isProtected(path: String, relativePath: String) -> Bool {
        if patternsMatch(path: path, relativePath: relativePath) { return true }
        let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if keepDownloaded.matches(relativePath: relative) { return true }
        return folderPolicies.effectiveMode(relativePath: relative) == .protect
    }

    public func patternsMatch(path: String, relativePath: String) -> Bool {
        let expanded = path
        let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        for pattern in patterns {
            let expandedPattern = NSString(string: pattern).expandingTildeInPath
            let trimmedPattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // Relative prefix match
            if !trimmedPattern.isEmpty
                && (relative == trimmedPattern || relative.hasPrefix(trimmedPattern + "/")) {
                return true
            }

            // Absolute prefix match
            if expandedPattern.hasPrefix("/")
                && (expanded == expandedPattern || expanded.hasPrefix(expandedPattern + "/")) {
                return true
            }

            // Glob match — against the full path, the relative path, the
            // file name, and every ancestor (so "*.photoslibrary" also
            // protects files inside the package).
            if expandedPattern.contains("*") || expandedPattern.contains("?") {
                if fnmatch(expandedPattern, expanded, 0) == 0 { return true }
                if fnmatch(expandedPattern, relative, 0) == 0 { return true }
                let name = URL(fileURLWithPath: expanded).lastPathComponent
                if fnmatch(expandedPattern, name, 0) == 0 { return true }

                var ancestor = URL(fileURLWithPath: expanded).deletingLastPathComponent()
                while ancestor.pathComponents.count > 1 {
                    if fnmatch(expandedPattern, ancestor.path, 0) == 0 { return true }
                    if fnmatch(expandedPattern, ancestor.lastPathComponent, 0) == 0 { return true }
                    let parent = ancestor.deletingLastPathComponent()
                    if parent.path == ancestor.path { break }
                    ancestor = parent
                }

                let parts = relative.split(separator: "/").map(String.init)
                if parts.count > 1 {
                    for end in 1..<parts.count {
                        let prefix = parts.prefix(end).joined(separator: "/")
                        if fnmatch(expandedPattern, prefix, 0) == 0 { return true }
                    }
                }
            }
        }

        return false
    }
}

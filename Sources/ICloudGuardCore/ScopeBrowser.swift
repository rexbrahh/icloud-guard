import AppKit
import Foundation

public enum ScopeBrowserItemKind: String, Codable, Sendable {
    case file
    case folder
    case package
}

public enum ScopeBrowserResidency: String, Codable, Sendable {
    case local
    case cloudOnly = "cloud-only"
    case notApplicable = "not-applicable"
    case unknown
}

public enum ScopeBrowserPolicy: String, Codable, Sendable {
    case protected
    case keepDownloaded = "keep-downloaded"
    case evictFirst = "evict-first"
    case evictLast = "evict-last"
    case standard
}

public struct ScopeBrowserRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String { pathIdentifier }
    public var pathIdentifier: String
    public var displayPath: String
    public var kind: ScopeBrowserItemKind
    public var residency: ScopeBrowserResidency
    public var allocatedBytes: Int64
    public var policy: ScopeBrowserPolicy
}

public struct ScopeBrowserReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schema = schemaVersion
    public var scopeIdentifier: String
    public var rows: [ScopeBrowserRow]
    public var scanComplete: Bool
    public var truncated: Bool
    public var skippedDirectories: Int
    public var readErrors: Int
}

public final class ScopeBrowserService: Sendable {
    public typealias Scan = @Sendable (
        _ rootPath: String,
        _ shouldStop: @escaping () -> Bool,
        _ onEntry: @escaping (BulkScanEntry) -> Void
    ) throws -> BulkScanSummary

    private let scan: Scan
    private let isFilePackage: @Sendable (String) -> Bool

    public init(
        scan: @escaping Scan = { root, shouldStop, onEntry in
            try BulkScanner.scan(rootPath: root, shouldStop: shouldStop, onEntry: onEntry)
        },
        isFilePackage: @escaping @Sendable (String) -> Bool = { NSWorkspace.shared.isFilePackage(atPath: $0) }
    ) {
        self.scan = scan
        self.isFilePackage = isFilePackage
    }

    public func browse(
        configURL: URL = AppPaths.config,
        revealPaths: Bool = false,
        limit: Int = 2_000
    ) throws -> ScopeBrowserReport {
        let config = try ConfigStore(configURL: configURL).loadValidated()
        return try browse(config: config, revealPaths: revealPaths, limit: limit)
    }

    public func browse(
        config: AppConfig,
        revealPaths: Bool = false,
        limit: Int = 2_000
    ) throws -> ScopeBrowserReport {
        let boundedLimit = max(1, min(limit, 10_000))
        let policyMatcher = config.scope.evictionPolicyMatcher
        var rows: [ScopeBrowserRow] = []

        let summary = try scan(
            config.scope.path,
            { rows.count >= boundedLimit },
            { entry in
                guard rows.count < boundedLimit else { return }
                let folderMode = policyMatcher.folderMode(relativePath: entry.relativePath)
                let policy: ScopeBrowserPolicy
                if policyMatcher.patternsMatch(path: entry.path, relativePath: entry.relativePath)
                    || folderMode == .protect {
                    policy = .protected
                } else if policyMatcher.isKeptDownloaded(relativePath: entry.relativePath) {
                    policy = .keepDownloaded
                } else if folderMode == .evictFirst {
                    policy = .evictFirst
                } else if folderMode == .evictLast {
                    policy = .evictLast
                } else {
                    policy = .standard
                }
                let kind: ScopeBrowserItemKind = entry.isDirectory
                    ? (self.isFilePackage(entry.path) ? .package : .folder)
                    : .file
                let residency: ScopeBrowserResidency
                if entry.isDirectory {
                    residency = .notApplicable
                } else if entry.isDataless {
                    residency = .cloudOnly
                } else if entry.allocatedBytes > 0 {
                    residency = .local
                } else {
                    residency = .unknown
                }
                let identifier = String(PrivacyIdentifier.hash(entry.path).prefix(24))
                rows.append(ScopeBrowserRow(
                    pathIdentifier: identifier,
                    displayPath: revealPaths ? entry.relativePath : "path:\(identifier)",
                    kind: kind,
                    residency: residency,
                    allocatedBytes: max(0, entry.allocatedBytes),
                    policy: policy
                ))
            }
        )
        rows.sort { $0.displayPath < $1.displayPath }
        return ScopeBrowserReport(
            scopeIdentifier: PrivacyIdentifier.scope(config.scope.path),
            rows: rows,
            scanComplete: summary.isComplete,
            truncated: summary.stoppedEarly || rows.count == boundedLimit,
            skippedDirectories: summary.skippedDirectories,
            readErrors: summary.readErrors
        )
    }
}

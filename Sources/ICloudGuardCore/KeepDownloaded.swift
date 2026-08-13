import Darwin
import Foundation

public struct KeepDownloadedRule: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case prefix
        case glob
    }

    public let pattern: String
    public let kind: Kind
    /// Relative directory or file used as the narrowest safe scan root.
    public let scanAnchor: String

    public init?(pattern rawPattern: String) {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        while pattern.hasSuffix("/") { pattern.removeLast() }
        guard !pattern.isEmpty,
              !pattern.hasPrefix("/"),
              !pattern.hasPrefix("~"),
              !pattern.contains("\0") else {
            return nil
        }

        let components = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        self.pattern = pattern
        if let wildcardIndex = components.firstIndex(where: Self.hasGlob) {
            kind = .glob
            scanAnchor = components.prefix(wildcardIndex).joined(separator: "/")
        } else {
            kind = .prefix
            scanAnchor = pattern
        }
    }

    public func matches(relativePath rawPath: String) -> Bool {
        guard let relativePath = Self.normalizedRelativePath(rawPath) else { return false }
        switch kind {
        case .prefix:
            return relativePath == pattern || relativePath.hasPrefix(pattern + "/")
        case .glob:
            if Self.glob(pattern, matches: relativePath) { return true }

            let components = relativePath.split(separator: "/").map(String.init)
            if !pattern.contains("/") && components.contains(where: { Self.glob(pattern, matches: $0) }) {
                return true
            }
            guard components.count > 1 else { return false }
            return (1..<components.count).contains { end in
                Self.glob(pattern, matches: components.prefix(end).joined(separator: "/"))
            }
        }
    }

    static func normalizedRelativePath(_ rawPath: String) -> String? {
        let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, !rawPath.hasPrefix("/"), !path.contains("\0") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    private static func hasGlob(_ component: String) -> Bool {
        component.contains("*") || component.contains("?") || component.contains("[")
    }

    private static func glob(_ pattern: String, matches path: String) -> Bool {
        fnmatch(pattern, path, FNM_PATHNAME) == 0
    }
}

public struct KeepDownloadedMatcher: Equatable, Sendable {
    public let rules: [KeepDownloadedRule]
    public let invalidPatternCount: Int

    public init(patterns: [String]) {
        var seen: Set<String> = []
        var rules: [KeepDownloadedRule] = []
        var invalidPatternCount = 0
        for pattern in patterns {
            guard let rule = KeepDownloadedRule(pattern: pattern) else {
                invalidPatternCount += 1
                continue
            }
            if seen.insert(rule.pattern).inserted { rules.append(rule) }
        }
        self.rules = rules
        self.invalidPatternCount = invalidPatternCount
    }

    private init(rules: [KeepDownloadedRule], invalidPatternCount: Int) {
        self.rules = rules
        self.invalidPatternCount = invalidPatternCount
    }

    public var isEmpty: Bool { rules.isEmpty }

    public func matches(relativePath: String) -> Bool {
        rules.contains { $0.matches(relativePath: relativePath) }
    }

    fileprivate func limited(to count: Int) -> KeepDownloadedMatcher {
        KeepDownloadedMatcher(
            rules: Array(rules.prefix(max(0, count))),
            invalidPatternCount: invalidPatternCount
        )
    }
}

public struct KeepDownloadedMetadata: Equatable, Sendable {
    public let identity: EvictionFileIdentity?
    public let isDataless: Bool

    public init(identity: EvictionFileIdentity?, isDataless: Bool) {
        self.identity = identity
        self.isDataless = isDataless
    }
}

public enum KeepDownloadedMetadataResult: Equatable, Sendable {
    case found(KeepDownloadedMetadata)
    case vanished
    case unavailable
}

public enum KeepDownloadedStatus: String, Codable, Equatable, Sendable {
    case verified
    case pending
    case failed
    case skipped
}

public enum KeepDownloadedReasonCode: String, Codable, Error, Equatable, Hashable, Sendable {
    case downloadVerified = "download-verified"
    case alreadyDownloaded = "already-downloaded"
    case verificationPending = "verification-pending"
    case verificationUnavailable = "verification-unavailable"
    case verificationIdentityChanged = "verification-identity-changed"
    case verificationVanished = "verification-vanished"
    case requestFailed = "request-failed"
    case requestVanished = "request-vanished"
    case requestPermission = "request-permission"
    case requestBusy = "request-busy"
    case requestNotUbiquitous = "request-not-ubiquitous"
    case requestCapReached = "request-cap-reached"
    case cancelled = "cancelled"
    case cancelledAfterRequest = "cancelled-after-request"
    case invalidPattern = "invalid-pattern"
    case ruleCapReached = "rule-cap-reached"
    case scanCapReached = "scan-cap-reached"
    case scanFailed = "scan-failed"
    case scanIncomplete = "scan-incomplete"
    case metadataUnavailable = "metadata-unavailable"
    case vanished = "vanished"
    case outsideScope = "outside-scope"
    case unsafeScope = "unsafe-scope"
    case unsafeAncestor = "unsafe-ancestor"
    case symlink = "symlink"
    case staleType = "stale-type"
    case missingIdentity = "missing-identity"
    case staleIdentity = "stale-identity"
}

public struct KeepDownloadedItemResult: Codable, Equatable, Sendable {
    public let path: String
    public let relativePath: String
    public let status: KeepDownloadedStatus
    public let reason: KeepDownloadedReasonCode
    public let requestAttempts: Int

    public init(
        path: String,
        relativePath: String,
        status: KeepDownloadedStatus,
        reason: KeepDownloadedReasonCode,
        requestAttempts: Int
    ) {
        self.path = path
        self.relativePath = relativePath
        self.status = status
        self.reason = reason
        self.requestAttempts = requestAttempts
    }
}

public struct KeepDownloadedOutcome: Equatable, Sendable {
    public let items: [KeepDownloadedItemResult]
    public let scannedEntries: Int
    public let requestsAttempted: Int
    public let cancelled: Bool
    public let reasonCounts: [KeepDownloadedReasonCode: Int]

    public init(
        items: [KeepDownloadedItemResult],
        scannedEntries: Int,
        requestsAttempted: Int,
        cancelled: Bool,
        reasonCounts: [KeepDownloadedReasonCode: Int]
    ) {
        self.items = items
        self.scannedEntries = scannedEntries
        self.requestsAttempted = requestsAttempted
        self.cancelled = cancelled
        self.reasonCounts = reasonCounts
    }

    public var verifiedCount: Int { items.count { $0.status == .verified } }
    public var pendingCount: Int { items.count { $0.status == .pending } }
    public var failedCount: Int { items.count { $0.status == .failed } }
    public var skippedCount: Int { items.count { $0.status == .skipped } }
}

public struct KeepDownloadedExecution: Equatable, Sendable {
    public var outcome: KeepDownloadedOutcome
    public var receipt: GuardRunReceipt

    public init(outcome: KeepDownloadedOutcome, receipt: GuardRunReceipt) {
        self.outcome = outcome
        self.receipt = receipt
    }
}

public enum KeepDownloadedOperationError: LocalizedError, Equatable, Sendable {
    case contention
    case lockFailed

    public var errorDescription: String? {
        switch self {
        case .contention: return "another mutation owner is active"
        case .lockFailed: return "cannot acquire keep-downloaded mutation lock"
        }
    }
}

public enum KeepDownloadedOperations {
    public static func enforce(
        appHomeURL: URL = AppPaths.homeDir,
        scopePath: String,
        patterns: [String],
        trigger: GuardRunTrigger,
        cancellation: EvictionCancellation? = nil,
        materializer: KeepDownloadedMaterializer = KeepDownloadedMaterializer()
    ) throws -> KeepDownloadedExecution {
        let lock: AdvisoryFileLock
        do {
            lock = try AdvisoryFileLock(path: appHomeURL.appendingPathComponent("run.lock").path)
            try lock.writeOwnerPID()
        } catch AdvisoryFileLock.LockError.unavailable {
            throw KeepDownloadedOperationError.contention
        } catch {
            throw KeepDownloadedOperationError.lockFailed
        }
        defer { withExtendedLifetime(lock) {} }

        let startedAt = Date()
        let outcome = materializer.materialize(
            scopePath: scopePath,
            patterns: patterns,
            cancellation: cancellation
        )
        let receipt = makeReceipt(
            outcome: outcome,
            scopePath: scopePath,
            trigger: trigger,
            startedAt: startedAt
        )
        _ = try RunHistoryStore(url: appHomeURL.appendingPathComponent("history.json")).append(receipt)
        return KeepDownloadedExecution(outcome: outcome, receipt: receipt)
    }

    static func makeReceipt(
        outcome: KeepDownloadedOutcome,
        scopePath: String,
        trigger: GuardRunTrigger,
        startedAt: Date = Date()
    ) -> GuardRunReceipt {
        let adverseItemCount = outcome.items.count {
            $0.status == .failed || ($0.status == .skipped && $0.reason != .alreadyDownloaded)
        }
        let itemReasonCounts = Dictionary(grouping: outcome.items, by: \.reason).mapValues(\.count)
        let reasonOnlyResidualCount = outcome.reasonCounts.reduce(into: 0) { total, pair in
            guard pair.key.isResidualFailure else { return }
            total += max(0, pair.value - (itemReasonCounts[pair.key] ?? 0))
        }
        let receiptFailedCount = adverseItemCount + reasonOnlyResidualCount
        let exitCode: Int32
        let status: GuardRunStatus
        let reason: String
        if outcome.cancelled {
            exitCode = 130
            status = .cancelled
            reason = "keep-downloaded enforcement cancelled"
        } else if receiptFailedCount > 0 || (outcome.pendingCount > 0 && outcome.verifiedCount > 0) {
            exitCode = 1
            status = .partial
            reason = "keep-downloaded enforcement completed with residual items"
        } else if outcome.pendingCount > 0 {
            exitCode = 1
            status = .pending
            reason = "keep-downloaded requests are pending verification"
        } else if outcome.verifiedCount > 0 {
            exitCode = 0
            status = .succeeded
            reason = "keep-downloaded items verified locally"
        } else {
            exitCode = 0
            status = .noAction
            reason = "keep-downloaded items already local or no rules matched"
        }
        let plannedCount = max(
            outcome.items.count + reasonOnlyResidualCount,
            outcome.verifiedCount + outcome.pendingCount + receiptFailedCount
        )
        let residualReasons = outcome.reasonCounts
            .filter { $0.key.isResidualFailure && $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: ",")
        var receiptMetadata = ["requests_attempted": String(outcome.requestsAttempted)]
        if !residualReasons.isEmpty { receiptMetadata["residual_reasons"] = residualReasons }
        return GuardRunReceipt(
            startedAt: startedAt,
            trigger: trigger,
            command: "keep-downloaded",
            requestedAction: "keep-downloaded",
            action: .none,
            dryRun: false,
            reason: reason,
            reasonMetadata: receiptMetadata,
            sourceScopeIdentifier: PrivacyIdentifier.scope(scopePath),
            privacyScopePath: scopePath,
            plannedCount: plannedCount,
            verifiedCount: outcome.verifiedCount,
            pendingCount: outcome.pendingCount,
            failedCount: receiptFailedCount,
            cancelled: outcome.cancelled,
            exitCode: exitCode,
            status: status,
            statePersisted: true,
            watchlistPersisted: true
        )
    }
}

private extension KeepDownloadedReasonCode {
    var isResidualFailure: Bool {
        switch self {
        case .downloadVerified, .alreadyDownloaded, .verificationPending,
             .verificationUnavailable, .verificationIdentityChanged, .verificationVanished,
             .cancelled, .cancelledAfterRequest:
            return false
        case .requestFailed, .requestVanished, .requestPermission, .requestBusy,
             .requestNotUbiquitous, .requestCapReached, .invalidPattern, .ruleCapReached,
             .scanCapReached, .scanFailed, .scanIncomplete, .metadataUnavailable, .vanished,
             .outsideScope, .unsafeScope, .unsafeAncestor, .symlink, .staleType,
             .missingIdentity, .staleIdentity:
            return true
        }
    }
}

public struct KeepDownloadedLimits: Equatable, Sendable {
    public var maxRules: Int
    public var maxScanEntries: Int
    /// Maximum number of FileProvider API calls, including retries.
    public var maxRequests: Int
    public var requestAttempts: Int
    public var verificationAttempts: Int

    public init(
        maxRules: Int = 128,
        maxScanEntries: Int = 25_000,
        maxRequests: Int = 128,
        requestAttempts: Int = 2,
        verificationAttempts: Int = 5
    ) {
        self.maxRules = max(0, maxRules)
        self.maxScanEntries = max(0, maxScanEntries)
        self.maxRequests = max(0, maxRequests)
        self.requestAttempts = max(1, requestAttempts)
        self.verificationAttempts = max(1, verificationAttempts)
    }
}

public typealias KeepDownloadedScanProvider = @Sendable (
    _ rootPath: String,
    _ shouldStop: () -> Bool,
    _ onEntry: (BulkScanEntry) -> Void
) throws -> BulkScanSummary
public typealias KeepDownloadedMetadataProvider = @Sendable (String) -> KeepDownloadedMetadataResult
public typealias KeepDownloadedRequestProvider = @Sendable (URL) throws -> Void
public typealias KeepDownloadedDelayProvider = @Sendable () -> Void

public struct KeepDownloadedProviders: Sendable {
    public let scan: KeepDownloadedScanProvider
    public let metadata: KeepDownloadedMetadataProvider
    public let requestDownload: KeepDownloadedRequestProvider
    public let delay: KeepDownloadedDelayProvider

    public init(
        scan: @escaping KeepDownloadedScanProvider,
        metadata: @escaping KeepDownloadedMetadataProvider,
        requestDownload: @escaping KeepDownloadedRequestProvider,
        delay: @escaping KeepDownloadedDelayProvider
    ) {
        self.scan = scan
        self.metadata = metadata
        self.requestDownload = requestDownload
        self.delay = delay
    }

    public static let live = KeepDownloadedProviders(
        scan: { rootPath, shouldStop, onEntry in
            try BulkScanner.scan(rootPath: rootPath, shouldStop: shouldStop, onEntry: onEntry)
        },
        metadata: { path in
            errno = 0
            guard let info = BulkScanner.lstatPath(path) else {
                return errno == ENOENT ? .vanished : .unavailable
            }
            return .found(KeepDownloadedMetadata(
                identity: EvictionFileIdentity.from(info),
                isDataless: (info.st_flags & SF_DATALESS) != 0
            ))
        },
        requestDownload: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
        delay: { usleep(100_000) }
    )
}

/// Download-only maintenance for user-configured relative paths. This type
/// never invokes eviction and does not alter protected-path policy.
public final class KeepDownloadedMaterializer: Sendable {
    private struct Candidate: Sendable {
        let path: String
        let relativePath: String
        let identity: EvictionFileIdentity?
    }

    private let limits: KeepDownloadedLimits
    private let providers: KeepDownloadedProviders

    public init(
        limits: KeepDownloadedLimits = KeepDownloadedLimits(),
        providers: KeepDownloadedProviders = .live
    ) {
        self.limits = limits
        self.providers = providers
    }

    public func materialize(
        scopePath: String,
        patterns: [String],
        cancellation: EvictionCancellation? = nil
    ) -> KeepDownloadedOutcome {
        materialize(
            scopePath: scopePath,
            matcher: KeepDownloadedMatcher(patterns: patterns),
            cancellation: cancellation
        )
    }

    public func materialize(
        scopePath: String,
        matcher suppliedMatcher: KeepDownloadedMatcher,
        cancellation: EvictionCancellation? = nil
    ) -> KeepDownloadedOutcome {
        let canonicalScope = URL(
            fileURLWithPath: NSString(string: scopePath).expandingTildeInPath,
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL.path
        let matcher = suppliedMatcher.limited(to: limits.maxRules)
        var reasons: [KeepDownloadedReasonCode: Int] = [:]
        reasons[.invalidPattern] = suppliedMatcher.invalidPatternCount
        let ignoredRules = max(0, suppliedMatcher.rules.count - matcher.rules.count)
        reasons[.ruleCapReached] = ignoredRules

        guard case .found(let scopeMetadata) = providers.metadata(canonicalScope),
              let scopeIdentity = scopeMetadata.identity,
              scopeIdentity.kind == .directory else {
            reasons[.unsafeScope, default: 0] += 1
            return outcome(items: [], scannedEntries: 0, requests: 0, cancelled: false, reasons: reasons)
        }
        guard !matcher.isEmpty else {
            return outcome(items: [], scannedEntries: 0, requests: 0, cancelled: false, reasons: reasons)
        }

        var candidates: [String: Candidate] = [:]
        var scanResults: [KeepDownloadedItemResult] = []
        var scannedEntries = 0
        var scanCapReported = false
        let anchors = minimalAnchors(matcher.rules.map(\.scanAnchor))

        for anchor in anchors {
            if cancellation?.isCancelled == true {
                reasons[.cancelled, default: 0] += 1
                break
            }
            let anchorPath = Self.path(in: canonicalScope, relativePath: anchor)
            switch providers.metadata(anchorPath) {
            case .vanished:
                reasons[.vanished, default: 0] += 1
            case .unavailable:
                reasons[.metadataUnavailable, default: 0] += 1
            case .found(let metadata):
                if metadata.identity?.kind == .regular {
                    if matcher.matches(relativePath: anchor) {
                        candidates[anchorPath] = Candidate(
                            path: anchorPath,
                            relativePath: anchor,
                            identity: metadata.identity
                        )
                    }
                    continue
                }
                guard metadata.identity?.kind == .directory else {
                    reasons[metadata.identity?.kind == .symbolicLink ? .symlink : .staleType, default: 0] += 1
                    continue
                }
                let anchorValidation = validate(
                    path: anchorPath,
                    relativePath: anchor,
                    scope: canonicalScope,
                    scopeIdentity: scopeIdentity,
                    expectedIdentity: metadata.identity,
                    expectedKind: .directory
                )
                guard case .success = anchorValidation else {
                    if case .failure(let reason) = anchorValidation { reasons[reason, default: 0] += 1 }
                    continue
                }
                guard scannedEntries < limits.maxScanEntries else {
                    if !scanCapReported { reasons[.scanCapReached, default: 0] += 1 }
                    scanCapReported = true
                    continue
                }

                do {
                    let summary = try providers.scan(
                        anchorPath,
                        { cancellation?.isCancelled == true || scannedEntries >= self.limits.maxScanEntries },
                        { entry in
                            guard scannedEntries < self.limits.maxScanEntries else {
                                scanCapReported = true
                                return
                            }
                            scannedEntries += 1
                            let relativePath = anchor.isEmpty
                                ? entry.relativePath
                                : anchor + "/" + entry.relativePath
                            guard entry.isRegularFile,
                                  matcher.matches(relativePath: relativePath),
                                  let normalized = KeepDownloadedRule.normalizedRelativePath(relativePath) else {
                                return
                            }
                            let expectedPath = Self.path(in: canonicalScope, relativePath: normalized)
                            let entryPath = URL(fileURLWithPath: entry.path).standardizedFileURL.path
                            guard entryPath == expectedPath else {
                                let result = Self.item(
                                    path: entry.path,
                                    relativePath: relativePath,
                                    status: .skipped,
                                    reason: .outsideScope
                                )
                                scanResults.append(result)
                                reasons[result.reason, default: 0] += 1
                                return
                            }
                            candidates[expectedPath] = Candidate(
                                path: expectedPath,
                                relativePath: normalized,
                                identity: entry.identity
                            )
                        }
                    )
                    if scanCapReported {
                        reasons[.scanCapReached, default: 0] += 1
                    } else if !summary.isComplete {
                        reasons[.scanIncomplete, default: 0] += 1
                    }
                } catch {
                    reasons[.scanFailed, default: 0] += 1
                }
            }
        }

        var items = scanResults
        var requestCount = 0
        var wasCancelled = cancellation?.isCancelled == true
        for candidate in candidates.values.sorted(by: { $0.relativePath < $1.relativePath }) {
            if cancellation?.isCancelled == true {
                wasCancelled = true
                reasons[.cancelled, default: 0] += 1
                break
            }
            let result = materialize(
                candidate,
                scope: canonicalScope,
                scopeIdentity: scopeIdentity,
                requestCount: &requestCount,
                cancellation: cancellation
            )
            items.append(result)
            reasons[result.reason, default: 0] += 1
            if result.reason == .cancelled || result.reason == .cancelledAfterRequest { wasCancelled = true }
        }
        return outcome(
            items: items,
            scannedEntries: scannedEntries,
            requests: requestCount,
            cancelled: wasCancelled,
            reasons: reasons
        )
    }

    private func materialize(
        _ candidate: Candidate,
        scope: String,
        scopeIdentity: EvictionFileIdentity,
        requestCount: inout Int,
        cancellation: EvictionCancellation?
    ) -> KeepDownloadedItemResult {
        var attempts = 0
        var lastFailure: KeepDownloadedReasonCode = .requestFailed

        while attempts < limits.requestAttempts {
            guard cancellation?.isCancelled != true else {
                return Self.item(candidate, status: .skipped, reason: .cancelled, attempts: attempts)
            }
            guard requestCount < limits.maxRequests else {
                return attempts == 0
                    ? Self.item(candidate, status: .skipped, reason: .requestCapReached)
                    : Self.item(candidate, status: .failed, reason: lastFailure, attempts: attempts)
            }
            switch validate(
                path: candidate.path,
                relativePath: candidate.relativePath,
                scope: scope,
                scopeIdentity: scopeIdentity,
                expectedIdentity: candidate.identity,
                expectedKind: .regular
            ) {
            case .failure(let reason):
                return Self.item(candidate, status: .skipped, reason: reason, attempts: attempts)
            case .success(let metadata):
                if !metadata.isDataless {
                    return Self.item(candidate, status: .skipped, reason: .alreadyDownloaded, attempts: attempts)
                }
            }

            attempts += 1
            requestCount += 1
            do {
                try providers.requestDownload(URL(fileURLWithPath: candidate.path))
                return verify(candidate, attempts: attempts, cancellation: cancellation)
            } catch {
                lastFailure = Self.requestFailure(error)
                if attempts < limits.requestAttempts && requestCount < limits.maxRequests {
                    providers.delay()
                }
            }
        }
        return Self.item(candidate, status: .failed, reason: lastFailure, attempts: attempts)
    }

    private func verify(
        _ candidate: Candidate,
        attempts: Int,
        cancellation: EvictionCancellation?
    ) -> KeepDownloadedItemResult {
        var finalReason: KeepDownloadedReasonCode = .verificationPending
        for verificationAttempt in 0..<limits.verificationAttempts {
            if cancellation?.isCancelled == true {
                return Self.item(candidate, status: .pending, reason: .cancelledAfterRequest, attempts: attempts)
            }
            switch providers.metadata(candidate.path) {
            case .found(let metadata):
                guard metadata.identity == candidate.identity else {
                    return Self.item(
                        candidate,
                        status: .pending,
                        reason: .verificationIdentityChanged,
                        attempts: attempts
                    )
                }
                guard metadata.identity?.kind == .regular else {
                    return Self.item(candidate, status: .pending, reason: .verificationIdentityChanged, attempts: attempts)
                }
                if !metadata.isDataless {
                    return Self.item(candidate, status: .verified, reason: .downloadVerified, attempts: attempts)
                }
                finalReason = .verificationPending
            case .vanished:
                finalReason = .verificationVanished
            case .unavailable:
                finalReason = .verificationUnavailable
            }
            if verificationAttempt + 1 < limits.verificationAttempts { providers.delay() }
        }
        return Self.item(candidate, status: .pending, reason: finalReason, attempts: attempts)
    }

    private func validate(
        path: String,
        relativePath: String,
        scope: String,
        scopeIdentity: EvictionFileIdentity,
        expectedIdentity: EvictionFileIdentity?,
        expectedKind: EvictionFileIdentity.Kind
    ) -> Result<KeepDownloadedMetadata, KeepDownloadedReasonCode> {
        guard let normalized = KeepDownloadedRule.normalizedRelativePath(relativePath),
              Self.path(in: scope, relativePath: normalized) == URL(fileURLWithPath: path).standardizedFileURL.path else {
            return .failure(.outsideScope)
        }
        guard let expectedIdentity else { return .failure(.missingIdentity) }
        guard case .found(let scopeMetadata) = providers.metadata(scope),
              scopeMetadata.identity == scopeIdentity else {
            return .failure(.unsafeScope)
        }

        var current = scope
        let components = normalized.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current += "/" + component
            let isTarget = index + 1 == components.count
            switch providers.metadata(current) {
            case .vanished:
                return .failure(.vanished)
            case .unavailable:
                return .failure(.metadataUnavailable)
            case .found(let metadata):
                if !isTarget {
                    guard metadata.identity?.kind == .directory else {
                        return .failure(metadata.identity?.kind == .symbolicLink ? .unsafeAncestor : .staleType)
                    }
                    continue
                }
                guard metadata.identity?.kind == expectedKind else {
                    return .failure(metadata.identity?.kind == .symbolicLink ? .symlink : .staleType)
                }
                guard metadata.identity == expectedIdentity else { return .failure(.staleIdentity) }
                return .success(metadata)
            }
        }
        return .failure(.outsideScope)
    }

    private func minimalAnchors(_ anchors: [String]) -> [String] {
        var result: [String] = []
        for anchor in Set(anchors).sorted(by: {
            let lhs = $0.split(separator: "/").count
            let rhs = $1.split(separator: "/").count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }) {
            if result.contains(where: { $0.isEmpty || anchor == $0 || anchor.hasPrefix($0 + "/") }) { continue }
            result.append(anchor)
        }
        return result
    }

    private func outcome(
        items: [KeepDownloadedItemResult],
        scannedEntries: Int,
        requests: Int,
        cancelled: Bool,
        reasons: [KeepDownloadedReasonCode: Int]
    ) -> KeepDownloadedOutcome {
        KeepDownloadedOutcome(
            items: items,
            scannedEntries: scannedEntries,
            requestsAttempted: requests,
            cancelled: cancelled,
            reasonCounts: reasons.filter { $0.value > 0 }
        )
    }

    private static func path(in scope: String, relativePath: String) -> String {
        guard !relativePath.isEmpty else { return scope }
        return URL(fileURLWithPath: scope, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL.path
    }

    private static func item(
        _ candidate: Candidate,
        status: KeepDownloadedStatus,
        reason: KeepDownloadedReasonCode,
        attempts: Int = 0
    ) -> KeepDownloadedItemResult {
        item(
            path: candidate.path,
            relativePath: candidate.relativePath,
            status: status,
            reason: reason,
            attempts: attempts
        )
    }

    private static func item(
        path: String,
        relativePath: String,
        status: KeepDownloadedStatus,
        reason: KeepDownloadedReasonCode,
        attempts: Int = 0
    ) -> KeepDownloadedItemResult {
        KeepDownloadedItemResult(
            path: path,
            relativePath: relativePath,
            status: status,
            reason: reason,
            requestAttempts: attempts
        )
    }

    private static func requestFailure(_ error: Error) -> KeepDownloadedReasonCode {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .requestVanished
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .requestPermission
            case NSFileReadInvalidFileNameError: return .requestNotUbiquitous
            case 255: return .requestBusy
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOENT): return .requestVanished
            case Int(EPERM), Int(EACCES): return .requestPermission
            case Int(EBUSY): return .requestBusy
            default: break
            }
        }
        return .requestFailed
    }
}

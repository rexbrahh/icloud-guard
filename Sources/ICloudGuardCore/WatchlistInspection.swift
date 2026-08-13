import Foundation

public enum WatchlistInspectionState: String, Codable, Sendable {
    case pending
    case retrying
    case fighting
    case suspended
    case identityMismatch = "identity-mismatch"
    case verified
    case rejected
}

public struct WatchlistInspection: Codable, Equatable, Identifiable, Sendable {
    public var id: String { pathIdentifier }
    public var pathIdentifier: String
    public var displayPath: String
    public var state: WatchlistInspectionState
    public var fightCount: Int
    public var retryCount: Int
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var nextRetryAt: Date?
    public var suspensionReason: String?
    public var identityMismatch: Bool
    public var rejectionReason: String?

    public init(entry: WatchlistEntry, scopePath: String, revealPaths: Bool, maxFights: Int) {
        pathIdentifier = String(PrivacyIdentifier.hash(entry.path).prefix(24))
        let normalized = WatchlistSemanticValidator.validate(entry, scopePath: scopePath)
        if revealPaths {
            let canonicalScope = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath)
                .resolvingSymlinksInPath().standardizedFileURL.path
            displayPath = normalized.entry.map { String($0.path.dropFirst(canonicalScope.count + 1)) }
                ?? "path:\(pathIdentifier)"
        } else {
            displayPath = "path:\(pathIdentifier)"
        }
        fightCount = entry.reEvictCount
        retryCount = entry.pendingRetryCount
        lastAttemptAt = entry.lastAttemptAt ?? entry.pendingSince
        lastError = entry.lastError.map(Self.privacySafeError)
        nextRetryAt = entry.nextCheckAt == .distantFuture ? nil : entry.nextCheckAt
        suspensionReason = entry.suspensionReason
        identityMismatch = entry.identityMismatch
        rejectionReason = normalized.rejectionReason
        if normalized.entry == nil {
            state = .rejected
            lastError = nil
            suspensionReason = normalized.rejectionReason
        } else if entry.identityMismatch {
            state = .identityMismatch
        } else if entry.suspended {
            state = .suspended
        } else if entry.pendingVerification, entry.pendingRetryCount > 0 {
            state = .retrying
        } else if entry.pendingVerification {
            state = .pending
        } else if WatchlistFightPolicy.isFighting(count: entry.reEvictCount, maxFights: maxFights) {
            state = .fighting
        } else {
            state = .verified
        }
    }

    private static func privacySafeError(_ error: String) -> String {
        let hasPathSyntax = error.contains("/") || error.contains("~") || error.contains("\\")
        let hasControl = error.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !hasPathSyntax, !hasControl, error.utf8.count <= 128 else {
            return "redacted-error:\(PrivacyIdentifier.hash(error).prefix(16))"
        }
        return error
    }
}

public enum WatchlistInspectionService {
    public enum InspectionError: LocalizedError, Sendable {
        case unreadable(String)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let message): return "cannot read watchlist: \(message)"
            case .corrupt(let message): return "watchlist is corrupt: \(message)"
            }
        }
    }

    public static func load(
        storageURL: URL = AppPaths.watchlist,
        scopePath: String,
        revealPaths: Bool = false,
        maxFights: Int = WatchlistWatcher.defaultMaxFights
    ) throws -> [WatchlistInspection] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let entries = try decodeEntries(storageURL: storageURL)
        return entries.map {
            WatchlistInspection(entry: $0, scopePath: scopePath, revealPaths: revealPaths, maxFights: maxFights)
        }
            .sorted {
                if $0.state != $1.state { return $0.state.rawValue < $1.state.rawValue }
                return $0.pathIdentifier < $1.pathIdentifier
            }
    }

    public static func loadEntries(
        storageURL: URL = AppPaths.watchlist,
        scopePath: String
    ) throws -> [WatchlistEntry] {
        let entries = try decodeEntries(storageURL: storageURL)
        var validated: [WatchlistEntry] = []
        validated.reserveCapacity(entries.count)
        for entry in entries {
            let result = WatchlistSemanticValidator.validate(entry, scopePath: scopePath)
            guard let normalized = result.entry else {
                throw InspectionError.corrupt(result.rejectionReason ?? "invalid entry")
            }
            validated.append(normalized)
        }
        return validated
    }

    private static func decodeEntries(storageURL: URL) throws -> [WatchlistEntry] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let data: Data
        do { data = try WatchlistStorage.readData(at: storageURL) }
        catch { throw InspectionError.unreadable(error.localizedDescription) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let entries = try decoder.decode([WatchlistEntry].self, from: data)
            guard entries.count <= WatchlistSemanticValidator.absoluteMaximumEntries else {
                throw InspectionError.corrupt("entry count exceeds safety limit")
            }
            return entries
        }
        catch let error as InspectionError { throw error }
        catch { throw InspectionError.corrupt(error.localizedDescription) }
    }
}

enum WatchlistStorage {
    static let maximumBytes: UInt64 = 8 * 1024 * 1024

    static func readData(at url: URL) throws -> Data {
        do {
            return try SecureRegularFile.read(url, maximumBytes: maximumBytes).data
        } catch SecureRegularFile.ReadError.open(let errorNumber) where errorNumber == ENOENT {
            throw SecureRegularFile.ReadError.open(errorNumber)
        } catch let SecureRegularFile.ReadError.tooLarge(size) {
            throw WatchlistStorageError.tooLarge(path: url.path, size: size, limit: maximumBytes)
        } catch {
            throw WatchlistStorageError.notRegular
        }
    }
}

enum WatchlistStorageError: Error, CustomStringConvertible, LocalizedError {
    case notRegular
    case tooLarge(path: String, size: UInt64, limit: UInt64)

    var description: String {
        switch self {
        case .notRegular:
            return "watchlist is not a readable regular file"
        case .tooLarge(let path, let size, let limit):
            return "watchlist-too-large path=\(path) size=\(size) limit=\(limit)"
        }
    }

    var errorDescription: String? { description }
}

public enum WatchlistFightPolicy {
    public static func isFighting(count: Int, maxFights: Int) -> Bool {
        count > max(1, maxFights)
    }
}

public enum WatchlistSemanticValidator {
    public static let absoluteMaximumEntries = 100_000
    private static let maximumCounter = 1_000_000

    public struct Result: Sendable {
        public var entry: WatchlistEntry?
        public var rejectionReason: String?
    }

    public static func validate(
        _ entry: WatchlistEntry,
        scopePath: String,
        now: Date = Date()
    ) -> Result {
        guard entry.reEvictCount >= 0, entry.reEvictCount <= maximumCounter,
              entry.stableDatalessChecks >= 0, entry.stableDatalessChecks <= maximumCounter,
              entry.pendingRetryCount >= 0, entry.pendingRetryCount <= maximumCounter else {
            return Result(entry: nil, rejectionReason: "counter-out-of-range")
        }
        let eventDates = [entry.addedAt, entry.pendingSince, entry.requestTimestamp, entry.lastAttemptAt, entry.verifiedAt]
            .compactMap { $0 }
        guard entry.nextCheckAt.timeIntervalSinceReferenceDate.isFinite,
              eventDates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            return Result(entry: nil, rejectionReason: "invalid-date")
        }
        let futureEventDate = eventDates.filter { $0 > now }.max()
        if let identity = entry.identity {
            guard identity.inode > 0, identity.kind == .regular || identity.kind == .directory else {
                return Result(entry: nil, rejectionReason: "invalid-identity")
            }
        }
        let canonicalScope = URL(fileURLWithPath: NSString(string: scopePath).expandingTildeInPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalPath = URL(fileURLWithPath: NSString(string: entry.path).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard !canonicalScope.isEmpty, canonicalPath.hasPrefix(canonicalScope + "/") else {
            return Result(entry: nil, rejectionReason: "outside-scope")
        }
        var normalized = entry
        normalized.path = canonicalPath
        if let futureEventDate {
            // Clock rollback: keep durable entries, but do not check or prune them until their own timeline catches up.
            normalized.nextCheckAt = max(normalized.nextCheckAt, futureEventDate)
        }
        return Result(entry: normalized, rejectionReason: nil)
    }
}

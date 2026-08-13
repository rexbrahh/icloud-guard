import CryptoKit
import Darwin
import Foundation

/// TOML-based application configuration.
///
/// Lives at ~/.icloud-guard/config.toml
/// Runtime state uses private JSON files. The TOML is hand-writable and human-readable.
///
/// Example config.toml:
/// ```toml
/// [suppression]
/// spotlight = true
/// quicklook = true
/// materialize_dataless = false
///
/// [eviction]
/// batch_limit = 500
/// panic_limit = 2000
///
/// [watcher]
/// backoff_max_seconds = 60
/// pollution_check_interval_seconds = 300
/// watchlist_poll_seconds = 10
///
/// [scope]
/// path = "~/Library/Mobile Documents/com~apple~CloudDocs"
/// ```
public struct AppConfig: Equatable, Sendable {
    public var suppression: SuppressionConfig
    public var eviction: EvictionConfig
    public var watcher: WatcherConfig
    public var scope: ScopeConfig
    public var policy: PolicyConfig
    public var notifications: NotificationsConfig
    public var energy: EnergySchedulingPolicy
    public var updates: UpdatesConfig
    /// Optional explicit scope set. `nil` preserves the legacy single-scope
    /// configuration and its established storage paths.
    public var scopes: [ManagedScopeConfig]?

    public init(
        suppression: SuppressionConfig = .init(),
        eviction: EvictionConfig = .init(),
        watcher: WatcherConfig = .init(),
        scope: ScopeConfig = .init(),
        policy: PolicyConfig = .init(),
        notifications: NotificationsConfig = .init(),
        energy: EnergySchedulingPolicy = .init(),
        updates: UpdatesConfig = .init(),
        scopes: [ManagedScopeConfig]? = nil
    ) {
        self.suppression = suppression
        self.eviction = eviction
        self.watcher = watcher
        self.scope = scope
        self.policy = policy.normalized()
        self.notifications = notifications
        self.energy = energy
        self.updates = updates
        self.scopes = scopes?.map {
            ManagedScopeConfig(
                id: $0.id,
                name: $0.name,
                automaticEnabled: $0.automaticEnabled,
                scope: $0.scope,
                watcher: $0.watcher,
                policy: $0.policy.normalized(),
                eviction: $0.eviction
            )
        }
    }

    public func normalized() -> AppConfig {
        AppConfig(
            suppression: suppression,
            eviction: eviction,
            watcher: watcher,
            scope: scope,
            policy: policy.normalized(),
            notifications: notifications,
            energy: energy,
            updates: updates,
            scopes: scopes
        )
    }

    public struct SuppressionConfig: Equatable, Sendable, Codable {
        public var spotlight: Bool
        public var quicklook: Bool
        public var materializeDataless: Bool

        public init(spotlight: Bool = true, quicklook: Bool = true, materializeDataless: Bool = false) {
            self.spotlight = spotlight
            self.quicklook = quicklook
            self.materializeDataless = materializeDataless
        }

        public var nonMaterializingIOPolicyEnabled: Bool {
            get { !materializeDataless }
            set { materializeDataless = !newValue }
        }
    }

    public struct EvictionConfig: Equatable, Sendable, Codable {
        public var batchLimit: Int
        public var panicLimit: Int
        public var protectBusyPackages: Bool

        public init(batchLimit: Int = 500, panicLimit: Int = 2000, protectBusyPackages: Bool = true) {
            self.batchLimit = batchLimit
            self.panicLimit = panicLimit
            self.protectBusyPackages = protectBusyPackages
        }
    }

    public struct WatcherConfig: Equatable, Sendable, Codable {
        public var backoffMaxSeconds: Int
        public var pollutionCheckIntervalSeconds: Int
        public var watchlistPollSeconds: Int
        public var watchlistMaxEntries: Int
        public var verifiedRetentionHours: Int
        public var pendingVerificationGraceSeconds: Int
        public var pendingRetryLimit: Int
        public var maxFights: Int

        public init(
            backoffMaxSeconds: Int = 60,
            pollutionCheckIntervalSeconds: Int = 300,
            watchlistPollSeconds: Int = 10,
            watchlistMaxEntries: Int = 5000,
            verifiedRetentionHours: Int = 168,
            pendingVerificationGraceSeconds: Int = 30,
            pendingRetryLimit: Int = 10,
            maxFights: Int = 10
        ) {
            self.backoffMaxSeconds = backoffMaxSeconds
            self.pollutionCheckIntervalSeconds = pollutionCheckIntervalSeconds
            self.watchlistPollSeconds = watchlistPollSeconds
            self.watchlistMaxEntries = watchlistMaxEntries
            self.verifiedRetentionHours = verifiedRetentionHours
            self.pendingVerificationGraceSeconds = pendingVerificationGraceSeconds
            self.pendingRetryLimit = pendingRetryLimit
            self.maxFights = maxFights
        }
    }

    public struct ScopeConfig: Equatable, Sendable, Codable {
        public var path: String
        public var protectedPaths: [String]
        public var keepDownloadedPaths: [String]
        public var folderPolicies: [FolderPolicyRule]

        public init(
            path: String = "~/Library/Mobile Documents/com~apple~CloudDocs",
            protectedPaths: [String] = [],
            keepDownloadedPaths: [String] = [],
            folderPolicies: [FolderPolicyRule] = []
        ) {
            self.path = path
            self.protectedPaths = protectedPaths
            self.keepDownloadedPaths = keepDownloadedPaths
            self.folderPolicies = folderPolicies
        }

        /// All eviction exclusions. Keep-downloaded remains semantically
        /// distinct, but it must block every eviction path just like explicit
        /// protection. Folder policies are deliberately not flattened here:
        /// their most-specific child rule can override a protected parent.
        public var evictionExcludedPaths: [String] {
            protectedPaths + keepDownloadedPaths
        }

        public var evictionPolicyMatcher: ProtectedPathsMatcher {
            ProtectedPathsMatcher(
                protectedPaths: protectedPaths,
                keepDownloadedPatterns: keepDownloadedPaths,
                folderPolicies: folderPolicies
            )
        }
    }

    public struct NotificationsConfig: Equatable, Sendable, Codable {
        public var evictionCompleted: Bool
        public var partialFailure: Bool
        public var fightingFiles: Bool
        public var restoreCompleted: Bool
        public var keepDownloaded: Bool
        public var actionsEnabled: Bool

        public init(
            evictionCompleted: Bool = true,
            partialFailure: Bool = true,
            fightingFiles: Bool = true,
            restoreCompleted: Bool = true,
            keepDownloaded: Bool = true,
            actionsEnabled: Bool = true
        ) {
            self.evictionCompleted = evictionCompleted
            self.partialFailure = partialFailure
            self.fightingFiles = fightingFiles
            self.restoreCompleted = restoreCompleted
            self.keepDownloaded = keepDownloaded
            self.actionsEnabled = actionsEnabled
        }
    }

    public struct UpdatesConfig: Equatable, Sendable, Codable {
        public enum ValidationError: LocalizedError, Equatable, Sendable {
            case invalid(String)

            public var errorDescription: String? {
                switch self {
                case .invalid(let message): return message
                }
            }
        }

        public var enabled: Bool
        public var channel: UpdateChannel
        public var feedURL: String
        public var keyID: String
        public var publicKeyX963Base64: String
        public var teamID: String

        public init(
            enabled: Bool = false,
            channel: UpdateChannel = .stable,
            feedURL: String = "",
            keyID: String = "",
            publicKeyX963Base64: String = "",
            teamID: String = ""
        ) {
            self.enabled = enabled
            self.channel = channel
            self.feedURL = feedURL
            self.keyID = keyID
            self.publicKeyX963Base64 = publicKeyX963Base64
            self.teamID = teamID
        }

        /// Builds updater inputs without performing filesystem or network I/O.
        /// A disabled updater intentionally needs no trust material.
        public func verifiedUpdaterConfiguration(
            temporaryRoot: URL = AppPaths.cache
        ) throws -> VerifiedUpdaterConfiguration? {
            try validateStoredFields()
            guard enabled else { return nil }
            guard channel != .tip else {
                throw ValidationError.invalid("updates.channel tip is unsupported")
            }
            guard let components = URLComponents(string: feedURL),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  let resolvedFeedURL = components.url else {
                throw ValidationError.invalid("updates.feed_url must be an HTTPS URL without credentials, query, or fragment")
            }
            guard !keyID.isEmpty,
                  keyID.unicodeScalars.allSatisfy({ scalar in
                      (scalar.value >= 48 && scalar.value <= 57)
                          || (scalar.value >= 65 && scalar.value <= 90)
                          || (scalar.value >= 97 && scalar.value <= 122)
                          || scalar == "-" || scalar == "_" || scalar == "."
                  }) else {
                throw ValidationError.invalid("updates.key_id must use 1...128 ASCII letters, digits, dot, dash, or underscore")
            }
            guard let publicKey = Data(base64Encoded: publicKeyX963Base64),
                  publicKey.base64EncodedString() == publicKeyX963Base64,
                  publicKey.count == 65,
                  publicKey.first == 0x04,
                  (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else {
                throw ValidationError.invalid("updates.public_key_x963_base64 must encode a valid uncompressed P-256 public key")
            }
            guard Self.validTeamID(teamID) else {
                throw ValidationError.invalid("updates.team_id must be 10 uppercase ASCII letters or digits")
            }
            guard let currentVersion = SemanticVersion(ICloudGuardProduct.version), currentVersion.isRelease else {
                throw ValidationError.invalid("the current product version is not a release semantic version")
            }
            return VerifiedUpdaterConfiguration(
                feedURL: resolvedFeedURL,
                channel: channel,
                currentVersion: currentVersion,
                expectedKeyID: keyID,
                publicKeyX963: publicKey,
                expectedTeamID: teamID,
                temporaryRoot: temporaryRoot
            )
        }

        fileprivate func validateStoredFields() throws {
            guard feedURL.utf8.count <= 2_048 else {
                throw ValidationError.invalid("updates.feed_url exceeds 2048 UTF-8 bytes")
            }
            guard keyID.utf8.count <= 128 else {
                throw ValidationError.invalid("updates.key_id exceeds 128 UTF-8 bytes")
            }
            guard publicKeyX963Base64.utf8.count <= 256 else {
                throw ValidationError.invalid("updates.public_key_x963_base64 exceeds 256 UTF-8 bytes")
            }
            guard teamID.utf8.count <= 64 else {
                throw ValidationError.invalid("updates.team_id exceeds 64 UTF-8 bytes")
            }
        }

        private static func validTeamID(_ value: String) -> Bool {
            value.count == 10 && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
            }
        }
    }

    public struct PolicyConfig: Equatable, Sendable, Codable {
        public var targetLocalGiB: Int
        public var trimLocalGiB: Int
        public var warnFreeGiB: Int
        public var remediateFreeGiB: Int
        public var panicFreeGiB: Int
        public var cooldownMinutes: Int
        public var growthTriggerGiB: Int
        public var growthWindowMinutes: Int

        public init(
            targetLocalGiB: Int = 5,
            trimLocalGiB: Int = 8,
            warnFreeGiB: Int = 80,
            remediateFreeGiB: Int = 50,
            panicFreeGiB: Int = 25,
            cooldownMinutes: Int = 30,
            growthTriggerGiB: Int = 20,
            growthWindowMinutes: Int = 10
        ) {
            self.targetLocalGiB = targetLocalGiB
            self.trimLocalGiB = trimLocalGiB
            self.warnFreeGiB = warnFreeGiB
            self.remediateFreeGiB = remediateFreeGiB
            self.panicFreeGiB = panicFreeGiB
            self.cooldownMinutes = cooldownMinutes
            self.growthTriggerGiB = growthTriggerGiB
            self.growthWindowMinutes = growthWindowMinutes
        }

        public func normalized() -> PolicyConfig {
            let target = max(targetLocalGiB, 0)
            let trim = target == 0 && trimLocalGiB == 0 ? 0 : max(trimLocalGiB, target + 1)
            let panic = max(panicFreeGiB, 0)
            let remediate = max(remediateFreeGiB, panic)
            let warn = max(warnFreeGiB, remediate)
            return PolicyConfig(
                targetLocalGiB: target,
                trimLocalGiB: trim,
                warnFreeGiB: warn,
                remediateFreeGiB: remediate,
                panicFreeGiB: panic,
                cooldownMinutes: max(cooldownMinutes, 0),
                growthTriggerGiB: max(growthTriggerGiB, 0),
                growthWindowMinutes: max(growthWindowMinutes, 1)
            )
        }
    }
}

/// Small TOML reader/writer for the application's fixed schema.
/// Unknown sections and keys are retained when known values are saved.
public final class ConfigStore: Sendable {
    public struct Inspection: Equatable, Sendable {
        public var exists: Bool
        public var valid: Bool
        public var migrationNeeded: Bool
        public var config: AppConfig?
        public var error: String?
        public var source: String?

        public init(
            exists: Bool,
            valid: Bool,
            migrationNeeded: Bool,
            config: AppConfig?,
            error: String?,
            source: String? = nil
        ) {
            self.exists = exists
            self.valid = valid
            self.migrationNeeded = migrationNeeded
            self.config = config
            self.error = error
            self.source = source
        }
    }
    public struct ConfigError: LocalizedError, Equatable, Sendable {
        public let line: Int?
        public let message: String

        public init(line: Int? = nil, message: String) {
            self.line = line
            self.message = message
        }

        public var errorDescription: String? {
            if let line { return "config.toml line \(line): \(message)" }
            return "config.toml: \(message)"
        }
    }

    private let configURL: URL
    private let atomicWriter: @Sendable (Data, URL) throws -> Void
    public static let maximumConfigBytes: UInt64 = 1024 * 1024

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? AppPaths.config
        self.atomicWriter = { data, url in try Self.writeAtomically(data, to: url) }
    }

    init(
        configURL: URL,
        atomicWriter: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        self.configURL = configURL
        self.atomicWriter = atomicWriter
    }

    public var configURLPath: String { configURL.path }

    /// Read-only parse and migration assessment. This method never creates or
    /// rewrites the configuration file.
    public func inspect() -> Inspection {
        do {
            guard let content = try readContentIfExists() else {
                return Inspection(exists: false, valid: true, migrationNeeded: true, config: AppConfig(), error: nil)
            }
            let parsed = try parseToml(content)
            return Inspection(
                exists: true,
                valid: true,
                migrationNeeded: parsed.seenKeys != Self.knownKeys || parsed.normalizationChangedValues,
                config: parsed.config,
                error: nil,
                source: content
            )
        } catch {
            return Inspection(exists: true, valid: false, migrationNeeded: false, config: nil, error: error.localizedDescription)
        }
    }

    /// Compatibility helper for presentation-only callers. Runtime operations
    /// use `loadValidated()` so malformed input cannot silently become defaults.
    public func load() -> AppConfig {
        (try? loadValidated()) ?? AppConfig()
    }

    public func loadValidated() throws -> AppConfig {
        guard let content = try readContentIfExists() else { return AppConfig() }
        return try parseToml(content).config
    }

    /// Load the config, and if any known keys are missing from the file (e.g.
    /// configs written by older versions) or normalization changed effective
    /// values, persist the completed/normalized config back to disk. This is
    /// what keeps old installs working as new keys are introduced — a missing
    /// key must never silently disable a feature.
    @discardableResult
    public func loadMigrating() -> AppConfig {
        (try? loadMigratingValidated()) ?? AppConfig()
    }

    /// Strict runtime load. Migration patches only known values and missing
    /// keys; comments, unknown keys, and legacy fields remain byte-for-byte.
    @discardableResult
    public func loadMigratingValidated() throws -> AppConfig {
        guard let content = try readContentIfExists() else {
            let fresh = AppConfig()
            try save(fresh)
            return fresh
        }
        let parsed = try parseToml(content)
        if parsed.seenKeys != Self.knownKeys || parsed.normalizationChangedValues {
            try write(config: parsed.config, preserving: content)
        }
        return parsed.config
    }

    /// Every "section.key" the current version understands.
    static let knownKeys: Set<String> = [
        "suppression.spotlight", "suppression.quicklook", "suppression.materialize_dataless",
        "eviction.batch_limit", "eviction.panic_limit", "eviction.protect_busy_packages",
        "watcher.backoff_max_seconds", "watcher.pollution_check_interval_seconds", "watcher.watchlist_poll_seconds",
        "watcher.watchlist_max_entries", "watcher.verified_retention_hours",
        "watcher.pending_verification_grace_seconds", "watcher.pending_retry_limit", "watcher.max_fights",
        "scope.path", "scope.protected_paths", "scope.keep_downloaded_paths", "scope.folder_policies",
        "policy.target_local_gib", "policy.trim_local_gib", "policy.warn_free_gib",
        "policy.remediate_free_gib", "policy.panic_free_gib", "policy.cooldown_minutes",
        "policy.growth_trigger_gib", "policy.growth_window_minutes",
        "notifications.eviction_completed", "notifications.partial_failure", "notifications.fighting_files",
        "notifications.restore_completed", "notifications.keep_downloaded", "notifications.actions_enabled",
        "energy.enabled", "energy.defer_on_low_power_mode", "energy.defer_on_serious_thermal_state",
        "energy.defer_on_battery_power",
        "updates.enabled", "updates.channel", "updates.feed_url", "updates.key_id",
        "updates.public_key_x963_base64", "updates.team_id",
    ]

    private static let keysBySection: [(String, [String])] = [
        ("suppression", ["spotlight", "quicklook", "materialize_dataless"]),
        ("eviction", ["batch_limit", "panic_limit", "protect_busy_packages"]),
        ("watcher", [
            "backoff_max_seconds", "pollution_check_interval_seconds", "watchlist_poll_seconds",
            "watchlist_max_entries", "verified_retention_hours", "pending_verification_grace_seconds",
            "pending_retry_limit", "max_fights",
        ]),
        ("scope", ["path", "protected_paths", "keep_downloaded_paths", "folder_policies"]),
        ("policy", [
            "target_local_gib", "trim_local_gib", "warn_free_gib", "remediate_free_gib",
            "panic_free_gib", "cooldown_minutes", "growth_trigger_gib", "growth_window_minutes",
        ]),
        ("notifications", [
            "eviction_completed", "partial_failure", "fighting_files", "restore_completed",
            "keep_downloaded", "actions_enabled",
        ]),
        ("energy", [
            "enabled", "defer_on_low_power_mode", "defer_on_serious_thermal_state", "defer_on_battery_power",
        ]),
        ("updates", ["enabled", "channel", "feed_url", "key_id", "public_key_x963_base64", "team_id"]),
        ("scopes", ["definitions"]),
    ]

    public func save(_ config: AppConfig) throws {
        if let duplicate = FolderPolicySet.duplicatePath(in: config.scope.folderPolicies) {
            throw ConfigError(message: "scope.folder_policies contains duplicate normalized path \(duplicate)")
        }
        if let scopes = config.scopes {
            do { try MultiScopeValidator.validate(scopes) }
            catch { throw ConfigError(message: error.localizedDescription) }
        }
        do { _ = try config.updates.verifiedUpdaterConfiguration() }
        catch { throw ConfigError(message: error.localizedDescription) }
        let existing: String?
        do {
            if let content = try readContentIfExists() {
                existing = content
                _ = try parseToml(existing!)
            } else {
                existing = nil
            }
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError(message: "cannot read \(configURL.path): \(error.localizedDescription)")
        }
        try write(config: config.normalized(), preserving: existing)
    }

    private func readContentIfExists() throws -> String? {
        let snapshot: SecureRegularFile.Snapshot
        do {
            snapshot = try SecureRegularFile.read(configURL, maximumBytes: Self.maximumConfigBytes)
        } catch SecureRegularFile.ReadError.open(let errorNumber) where errorNumber == ENOENT {
            return nil
        } catch SecureRegularFile.ReadError.tooLarge(let size) {
            throw ConfigError(message: "configuration exceeds \(Self.maximumConfigBytes) bytes (found \(size))")
        } catch {
            throw ConfigError(message: "configuration must be a bounded regular file")
        }
        guard let content = String(data: snapshot.data, encoding: .utf8) else {
            throw ConfigError(message: "configuration is not valid UTF-8")
        }
        return content
    }

    private func write(config: AppConfig, preserving content: String?) throws {
        let rendered: String
        if let content {
            rendered = try merge(config: config, into: content)
        } else {
            rendered = try serializeToml(config)
        }
        guard let data = rendered.data(using: .utf8) else {
            throw ConfigError(message: "cannot encode configuration as UTF-8")
        }
        do {
            try atomicWriter(data, configURL)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError(message: "cannot save \(configURL.path): \(error.localizedDescription)")
        }
    }

    // MARK: - TOML Parser

    private struct ParsedConfig {
        var config: AppConfig
        var seenKeys: Set<String>
        var normalizationChangedValues: Bool
    }

    private func parseToml(_ content: String) throws -> ParsedConfig {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigError(message: "file is empty or truncated")
        }
        var suppression = AppConfig.SuppressionConfig()
        var eviction = AppConfig.EvictionConfig()
        var watcher = AppConfig.WatcherConfig()
        var scope = AppConfig.ScopeConfig()
        var policy = AppConfig.PolicyConfig()
        var notifications = AppConfig.NotificationsConfig()
        var energy = EnergySchedulingPolicy()
        var updates = AppConfig.UpdatesConfig()
        var scopes: [ManagedScopeConfig]?
        var seenKeys: Set<String> = []
        var seenSyntacticKeys: Set<String> = []
        var seenSections: Set<String> = []

        var currentSection = ""

        for (offset, line) in content.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let trimmed = Self.withoutInlineComment(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]"), trimmed.filter({ $0 == "[" }).count == 1,
                      trimmed.filter({ $0 == "]" }).count == 1 else {
                    throw ConfigError(line: lineNumber, message: "malformed section header")
                }
                currentSection = String(trimmed.dropFirst().dropLast())
                guard !currentSection.isEmpty else {
                    throw ConfigError(line: lineNumber, message: "section name is empty")
                }
                guard seenSections.insert(currentSection).inserted else {
                    throw ConfigError(line: lineNumber, message: "duplicate section [\(currentSection)]")
                }
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw ConfigError(line: lineNumber, message: "expected key = value")
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let rawValue = parts[1].trimmingCharacters(in: .whitespaces)
            guard !currentSection.isEmpty else {
                throw ConfigError(line: lineNumber, message: "key \(key) appears before a section")
            }
            guard !key.isEmpty, !rawValue.isEmpty else {
                throw ConfigError(line: lineNumber, message: "key and value must not be empty")
            }
            let qualifiedKey = "\(currentSection).\(key)"
            guard seenSyntacticKeys.insert(qualifiedKey).inserted else {
                throw ConfigError(line: lineNumber, message: "duplicate key \(qualifiedKey)")
            }
            if Self.knownKeys.contains(qualifiedKey) { seenKeys.insert(qualifiedKey) }

            switch currentSection {
            case "suppression":
                switch key {
                case "spotlight": suppression.spotlight = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "quicklook": suppression.quicklook = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "materialize_dataless": suppression.materializeDataless = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                default: break
                }
            case "eviction":
                switch key {
                case "batch_limit": eviction.batchLimit = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...1_000_000)
                case "panic_limit": eviction.panicLimit = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...1_000_000)
                case "protect_busy_packages": eviction.protectBusyPackages = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                default: break
                }
            case "watcher":
                switch key {
                case "backoff_max_seconds": watcher.backoffMaxSeconds = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...604_800)
                case "pollution_check_interval_seconds": watcher.pollutionCheckIntervalSeconds = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...604_800)
                case "watchlist_poll_seconds": watcher.watchlistPollSeconds = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...604_800)
                case "watchlist_max_entries": watcher.watchlistMaxEntries = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...100_000)
                case "verified_retention_hours": watcher.verifiedRetentionHours = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...87_600)
                case "pending_verification_grace_seconds": watcher.pendingVerificationGraceSeconds = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...3_600)
                case "pending_retry_limit": watcher.pendingRetryLimit = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...100)
                case "max_fights": watcher.maxFights = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...100)
                default: break
                }
            case "scope":
                switch key {
                case "path":
                    scope.path = try parseString(rawValue, key: qualifiedKey, line: lineNumber)
                    guard !scope.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ConfigError(line: lineNumber, message: "\(qualifiedKey) must not be empty")
                    }
                case "protected_paths":
                    scope.protectedPaths = try parseStringArray(rawValue, key: qualifiedKey, line: lineNumber)
                case "keep_downloaded_paths":
                    let values = try parseStringArray(rawValue, key: qualifiedKey, line: lineNumber)
                    guard values.allSatisfy({ KeepDownloadedRule(pattern: $0) != nil }) else {
                        throw ConfigError(line: lineNumber, message: "\(qualifiedKey) must contain only safe scope-relative paths or globs")
                    }
                    scope.keepDownloadedPaths = values
                case "folder_policies":
                    let values = try parseStringArray(rawValue, key: qualifiedKey, line: lineNumber)
                    do {
                        scope.folderPolicies = try values.map(FolderPolicyRule.init(serialized:))
                        if let duplicate = FolderPolicySet.duplicatePath(in: scope.folderPolicies) {
                            throw ConfigError(
                                line: lineNumber,
                                message: "\(qualifiedKey) contains duplicate normalized path \(duplicate)"
                            )
                        }
                    }
                    catch { throw ConfigError(line: lineNumber, message: "\(qualifiedKey): \(error.localizedDescription)") }
                default: break
                }
            case "policy":
                switch key {
                case "target_local_gib": policy.targetLocalGiB = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 0...1_000_000)
                case "trim_local_gib": policy.trimLocalGiB = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 0...1_000_000)
                case "warn_free_gib": policy.warnFreeGiB = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 0...1_000_000)
                case "remediate_free_gib": policy.remediateFreeGiB = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 0...1_000_000)
                case "panic_free_gib": policy.panicFreeGiB = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 0...1_000_000)
                case "cooldown_minutes": policy.cooldownMinutes = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 0...1_000_000)
                case "growth_trigger_gib": policy.growthTriggerGiB = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 0...1_000_000)
                case "growth_window_minutes": policy.growthWindowMinutes = try parseInt(rawValue, key: qualifiedKey, line: lineNumber, range: 1...1_000_000)
                default: break
                }
            case "notifications":
                switch key {
                case "eviction_completed": notifications.evictionCompleted = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "partial_failure": notifications.partialFailure = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "fighting_files": notifications.fightingFiles = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "restore_completed": notifications.restoreCompleted = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "keep_downloaded": notifications.keepDownloaded = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "actions_enabled": notifications.actionsEnabled = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                default: break
                }
            case "energy":
                switch key {
                case "enabled": energy.enabled = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "defer_on_low_power_mode": energy.deferOnLowPowerMode = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "defer_on_serious_thermal_state": energy.deferOnSeriousThermalState = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "defer_on_battery_power": energy.deferOnBatteryPower = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                default: break
                }
            case "updates":
                switch key {
                case "enabled": updates.enabled = try parseBool(rawValue, key: qualifiedKey, line: lineNumber)
                case "channel":
                    let value = try parseString(rawValue, key: qualifiedKey, line: lineNumber)
                    guard let channel = UpdateChannel(rawValue: value) else {
                        throw ConfigError(line: lineNumber, message: "\(qualifiedKey) must be stable, beta, or tip")
                    }
                    updates.channel = channel
                case "feed_url": updates.feedURL = try parseBoundedString(rawValue, key: qualifiedKey, line: lineNumber, maximumBytes: 2_048)
                case "key_id": updates.keyID = try parseBoundedString(rawValue, key: qualifiedKey, line: lineNumber, maximumBytes: 128)
                case "public_key_x963_base64": updates.publicKeyX963Base64 = try parseBoundedString(rawValue, key: qualifiedKey, line: lineNumber, maximumBytes: 256)
                case "team_id": updates.teamID = try parseBoundedString(rawValue, key: qualifiedKey, line: lineNumber, maximumBytes: 64)
                default: break
                }
            case "scopes":
                switch key {
                case "definitions":
                    guard rawValue.utf8.count <= 4 * 1_024 * 1_024 else {
                        throw ConfigError(line: lineNumber, message: "\(qualifiedKey) exceeds 4 MiB")
                    }
                    let definitions = try parseStringArray(rawValue, key: qualifiedKey, line: lineNumber)
                    do {
                        scopes = try definitions.map(ManagedScopeConfig.decodeDefinition)
                        try MultiScopeValidator.validate(scopes!)
                    } catch {
                        throw ConfigError(line: lineNumber, message: "\(qualifiedKey): \(error.localizedDescription)")
                    }
                default: break
                }
            default: break
            }
        }

        if seenSections.contains("scopes"), scopes == nil {
            throw ConfigError(message: "scopes.definitions is required when [scopes] is present")
        }
        do { _ = try updates.verifiedUpdaterConfiguration() }
        catch { throw ConfigError(message: error.localizedDescription) }
        let normalizedPolicy = policy.normalized()
        return ParsedConfig(
            config: AppConfig(
                suppression: suppression, eviction: eviction, watcher: watcher,
                scope: scope, policy: normalizedPolicy, notifications: notifications,
                energy: energy, updates: updates, scopes: scopes
            ),
            seenKeys: seenKeys,
            normalizationChangedValues: policy != normalizedPolicy
        )
    }

    private func parseBool(_ value: String, key: String, line: Int) throws -> Bool {
        switch value {
        case "true": return true
        case "false": return false
        default: throw ConfigError(line: line, message: "\(key) must be true or false")
        }
    }

    private func parseInt(_ value: String, key: String, line: Int, range: ClosedRange<Int>) throws -> Int {
        guard let parsed = Int(value) else {
            throw ConfigError(line: line, message: "\(key) must be an integer")
        }
        guard range.contains(parsed) else {
            throw ConfigError(line: line, message: "\(key) must be in \(range.lowerBound)...\(range.upperBound)")
        }
        return parsed
    }

    private func parseString(_ value: String, key: String, line: Int) throws -> String {
        guard let data = value.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let string = parsed as? String else {
            throw ConfigError(line: line, message: "\(key) must be a quoted string")
        }
        return string
    }

    private func parseBoundedString(
        _ value: String,
        key: String,
        line: Int,
        maximumBytes: Int
    ) throws -> String {
        let string = try parseString(value, key: key, line: line)
        guard string.utf8.count <= maximumBytes else {
            throw ConfigError(line: line, message: "\(key) exceeds \(maximumBytes) UTF-8 bytes")
        }
        return string
    }

    private func parseStringArray(_ value: String, key: String, line: Int) throws -> [String] {
        guard let data = value.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let strings = parsed as? [String] else {
            throw ConfigError(line: line, message: "\(key) must be an array of quoted strings")
        }
        return strings
    }

    // MARK: - Minimal TOML Serializer

    private func serializeToml(_ config: AppConfig) throws -> String {
        var lines: [String] = []
        lines.append("# iCloud Guard configuration")
        lines.append("# Generated by iCloud Guard — do not edit while app is running")
        lines.append("")
        lines.append("[suppression]")
        lines.append("spotlight = \(config.suppression.spotlight)")
        lines.append("quicklook = \(config.suppression.quicklook)")
        lines.append("materialize_dataless = \(config.suppression.materializeDataless)")
        lines.append("")
        lines.append("[eviction]")
        lines.append("batch_limit = \(config.eviction.batchLimit)")
        lines.append("panic_limit = \(config.eviction.panicLimit)")
        lines.append("protect_busy_packages = \(config.eviction.protectBusyPackages)")
        lines.append("")
        lines.append("[watcher]")
        lines.append("backoff_max_seconds = \(config.watcher.backoffMaxSeconds)")
        lines.append("pollution_check_interval_seconds = \(config.watcher.pollutionCheckIntervalSeconds)")
        lines.append("watchlist_poll_seconds = \(config.watcher.watchlistPollSeconds)")
        lines.append("watchlist_max_entries = \(config.watcher.watchlistMaxEntries)")
        lines.append("verified_retention_hours = \(config.watcher.verifiedRetentionHours)")
        lines.append("pending_verification_grace_seconds = \(config.watcher.pendingVerificationGraceSeconds)")
        lines.append("pending_retry_limit = \(config.watcher.pendingRetryLimit)")
        lines.append("max_fights = \(config.watcher.maxFights)")
        lines.append("")
        lines.append("[scope]")
        lines.append("path = \(Self.quoted(config.scope.path))")
        let paths = config.scope.protectedPaths.map(Self.quoted).joined(separator: ", ")
        lines.append("protected_paths = [\(paths)]")
        lines.append("keep_downloaded_paths = [\(config.scope.keepDownloadedPaths.map(Self.quoted).joined(separator: ", "))]")
        lines.append("folder_policies = [\(config.scope.folderPolicies.map { Self.quoted($0.serialized) }.joined(separator: ", "))]")
        lines.append("")
        lines.append("[policy]")
        lines.append("target_local_gib = \(config.policy.targetLocalGiB)")
        lines.append("trim_local_gib = \(config.policy.trimLocalGiB)")
        lines.append("warn_free_gib = \(config.policy.warnFreeGiB)")
        lines.append("remediate_free_gib = \(config.policy.remediateFreeGiB)")
        lines.append("panic_free_gib = \(config.policy.panicFreeGiB)")
        lines.append("cooldown_minutes = \(config.policy.cooldownMinutes)")
        lines.append("growth_trigger_gib = \(config.policy.growthTriggerGiB)")
        lines.append("growth_window_minutes = \(config.policy.growthWindowMinutes)")
        lines.append("")
        lines.append("[notifications]")
        lines.append("eviction_completed = \(config.notifications.evictionCompleted)")
        lines.append("partial_failure = \(config.notifications.partialFailure)")
        lines.append("fighting_files = \(config.notifications.fightingFiles)")
        lines.append("restore_completed = \(config.notifications.restoreCompleted)")
        lines.append("keep_downloaded = \(config.notifications.keepDownloaded)")
        lines.append("actions_enabled = \(config.notifications.actionsEnabled)")
        lines.append("")
        lines.append("[energy]")
        lines.append("enabled = \(config.energy.enabled)")
        lines.append("defer_on_low_power_mode = \(config.energy.deferOnLowPowerMode)")
        lines.append("defer_on_serious_thermal_state = \(config.energy.deferOnSeriousThermalState)")
        lines.append("defer_on_battery_power = \(config.energy.deferOnBatteryPower)")
        lines.append("")
        lines.append("[updates]")
        lines.append("enabled = \(config.updates.enabled)")
        lines.append("channel = \(Self.quoted(config.updates.channel.rawValue))")
        lines.append("feed_url = \(Self.quoted(config.updates.feedURL))")
        lines.append("key_id = \(Self.quoted(config.updates.keyID))")
        lines.append("public_key_x963_base64 = \(Self.quoted(config.updates.publicKeyX963Base64))")
        lines.append("team_id = \(Self.quoted(config.updates.teamID))")
        lines.append("")
        if let scopes = config.scopes {
            lines.append("[scopes]")
            let definitions = try scopes.map { try $0.encodedDefinition() }
            lines.append("definitions = [\(definitions.map(Self.quoted).joined(separator: ", "))]")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func merge(config: AppConfig, into content: String) throws -> String {
        let values = try Self.values(for: config)
        let knownSections = Set(Self.keysBySection.map(\.0))
        var seen: Set<String> = []
        var output: [String] = []
        var currentSection: String?

        func appendMissing(for section: String, to lines: inout [String]) {
            guard let keys = Self.keysBySection.first(where: { $0.0 == section })?.1 else { return }
            for key in keys where !seen.contains("\(section).\(key)") {
                guard let value = values["\(section).\(key)"] else { continue }
                lines.append("\(key) = \(value)")
                seen.insert("\(section).\(key)")
            }
        }

        for line in content.components(separatedBy: .newlines) {
            let uncommented = Self.withoutInlineComment(line).trimmingCharacters(in: .whitespaces)
            if uncommented.hasPrefix("["), uncommented.hasSuffix("]") {
                if let currentSection, knownSections.contains(currentSection) {
                    appendMissing(for: currentSection, to: &output)
                }
                currentSection = String(uncommented.dropFirst().dropLast())
                output.append(line)
                continue
            }

            if let currentSection,
               let separator = uncommented.firstIndex(of: "=") {
                let key = uncommented[..<separator].trimmingCharacters(in: .whitespaces)
                let qualified = "\(currentSection).\(key)"
                if let value = values[qualified] {
                    let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
                    let comment = Self.inlineComment(in: line)
                    output.append("\(indentation)\(key) = \(value)\(comment)")
                    seen.insert(qualified)
                    continue
                }
            }
            output.append(line)
        }

        if let currentSection, knownSections.contains(currentSection) {
            appendMissing(for: currentSection, to: &output)
        }
        for (section, keys) in Self.keysBySection where keys.contains(where: {
            values["\(section).\($0)"] != nil && !seen.contains("\(section).\($0)")
        }) {
            if output.last?.isEmpty == false { output.append("") }
            output.append("[\(section)]")
            appendMissing(for: section, to: &output)
        }
        return output.joined(separator: "\n")
    }

    private static func values(for config: AppConfig) throws -> [String: String] {
        let protectedPaths = config.scope.protectedPaths.map(quoted).joined(separator: ", ")
        let keepDownloadedPaths = config.scope.keepDownloadedPaths.map(quoted).joined(separator: ", ")
        let folderPolicies = config.scope.folderPolicies.map { quoted($0.serialized) }.joined(separator: ", ")
        var values: [String: String] = [
            "suppression.spotlight": String(config.suppression.spotlight),
            "suppression.quicklook": String(config.suppression.quicklook),
            "suppression.materialize_dataless": String(config.suppression.materializeDataless),
            "eviction.batch_limit": String(config.eviction.batchLimit),
            "eviction.panic_limit": String(config.eviction.panicLimit),
            "eviction.protect_busy_packages": String(config.eviction.protectBusyPackages),
            "watcher.backoff_max_seconds": String(config.watcher.backoffMaxSeconds),
            "watcher.pollution_check_interval_seconds": String(config.watcher.pollutionCheckIntervalSeconds),
            "watcher.watchlist_poll_seconds": String(config.watcher.watchlistPollSeconds),
            "watcher.watchlist_max_entries": String(config.watcher.watchlistMaxEntries),
            "watcher.verified_retention_hours": String(config.watcher.verifiedRetentionHours),
            "watcher.pending_verification_grace_seconds": String(config.watcher.pendingVerificationGraceSeconds),
            "watcher.pending_retry_limit": String(config.watcher.pendingRetryLimit),
            "watcher.max_fights": String(config.watcher.maxFights),
            "scope.path": quoted(config.scope.path),
            "scope.protected_paths": "[\(protectedPaths)]",
            "scope.keep_downloaded_paths": "[\(keepDownloadedPaths)]",
            "scope.folder_policies": "[\(folderPolicies)]",
            "policy.target_local_gib": String(config.policy.targetLocalGiB),
            "policy.trim_local_gib": String(config.policy.trimLocalGiB),
            "policy.warn_free_gib": String(config.policy.warnFreeGiB),
            "policy.remediate_free_gib": String(config.policy.remediateFreeGiB),
            "policy.panic_free_gib": String(config.policy.panicFreeGiB),
            "policy.cooldown_minutes": String(config.policy.cooldownMinutes),
            "policy.growth_trigger_gib": String(config.policy.growthTriggerGiB),
            "policy.growth_window_minutes": String(config.policy.growthWindowMinutes),
            "notifications.eviction_completed": String(config.notifications.evictionCompleted),
            "notifications.partial_failure": String(config.notifications.partialFailure),
            "notifications.fighting_files": String(config.notifications.fightingFiles),
            "notifications.restore_completed": String(config.notifications.restoreCompleted),
            "notifications.keep_downloaded": String(config.notifications.keepDownloaded),
            "notifications.actions_enabled": String(config.notifications.actionsEnabled),
            "energy.enabled": String(config.energy.enabled),
            "energy.defer_on_low_power_mode": String(config.energy.deferOnLowPowerMode),
            "energy.defer_on_serious_thermal_state": String(config.energy.deferOnSeriousThermalState),
            "energy.defer_on_battery_power": String(config.energy.deferOnBatteryPower),
            "updates.enabled": String(config.updates.enabled),
            "updates.channel": quoted(config.updates.channel.rawValue),
            "updates.feed_url": quoted(config.updates.feedURL),
            "updates.key_id": quoted(config.updates.keyID),
            "updates.public_key_x963_base64": quoted(config.updates.publicKeyX963Base64),
            "updates.team_id": quoted(config.updates.teamID),
        ]
        if let scopes = config.scopes {
            let definitions = try scopes.map { try $0.encodedDefinition() }
            values["scopes.definitions"] = "[\(definitions.map(quoted).joined(separator: ", "))]"
        }
        return values
    }

    private static func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func withoutInlineComment(_ line: String) -> String {
        guard let index = commentIndex(in: line) else { return line }
        return String(line[..<index])
    }

    private static func inlineComment(in line: String) -> String {
        guard let index = commentIndex(in: line) else { return "" }
        let prefix = line[..<index]
        return (prefix.last?.isWhitespace == true ? "" : " ") + line[index...]
    }

    private static func commentIndex(in line: String) -> String.Index? {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == "#", !quoted { return index }
        }
        return nil
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConfigError(message: "cannot create \(directory.path): \(error.localizedDescription)")
        }

        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError("open configuration directory without following links") }
        defer { Darwin.close(directoryFD) }

        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create temporary file") }
        var descriptorOpen = true
        defer {
            if descriptorOpen { Darwin.close(fd) }
            unlinkat(directoryFD, temporaryName, 0)
        }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if result > 0 { written += result; continue }
                if result < 0, errno == EINTR { continue }
                throw posixError("write temporary file")
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw posixError("flush temporary file") }
        guard Darwin.close(fd) == 0 else { throw posixError("close temporary file") }
        descriptorOpen = false
        guard renameat(directoryFD, temporaryName, directoryFD, url.lastPathComponent) == 0 else {
            throw posixError("replace configuration")
        }
        guard Darwin.fsync(directoryFD) == 0 else { throw posixError("flush configuration directory") }
    }

    private static func posixError(_ operation: String) -> ConfigError {
        ConfigError(message: "\(operation) failed: \(String(cString: strerror(errno)))")
    }
}

import Foundation
import ICloudGuardCore
@preconcurrency import UserNotifications

/// Actor that manages local notifications with lazy authorization, throttling, and batching.
///
/// - Rematerialization notifications are throttled: only one per 60 seconds per category.
///   The path and count are batched into a single notification.
/// - Pollution threshold notifications are throttled to one per 5 minutes.
/// - Eviction completion notifications are always sent (user-initiated, low frequency).
actor Notifier {
    static let shared = Notifier()

    private var hasAuthorized = false
    private var policy = AppConfig.NotificationsConfig()
    private var notificationsEnabled = true
    private var systemCenterIsActive = false

    // Throttling state
    private var lastRematerializationNotify: Date?
    private var rematerializationBatchCount = 0
    private var lastPollutionNotify: Date?

    // Minimum interval between throttled notifications (seconds)
    private let rematerializationThrottleSeconds: TimeInterval = 60
    private let pollutionThrottleSeconds: TimeInterval = 300

    /// Updates in-memory policy without activating UserNotifications. The app lifecycle owns
    /// activation so service/config tests never instantiate the process notification singleton.
    func configure(
        _ policy: AppConfig.NotificationsConfig,
        notificationsEnabled: Bool
    ) async {
        self.policy = policy
        self.notificationsEnabled = notificationsEnabled
        guard systemCenterIsActive else { return }
        await revokeDisabledActionNotifications()
    }

    /// Called only by `ICloudGuardApp` after its notification categories and delegate exist.
    func activateSystemNotificationCenter(notificationsEnabled: Bool) async {
        guard SystemIntegrationPolicy.isEnabled() else { return }
        self.notificationsEnabled = notificationsEnabled
        systemCenterIsActive = true
        await revokeDisabledActionNotifications()
    }

    private func revokeDisabledActionNotifications() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        let deliveredIDs = delivered.compactMap {
            GuardNotificationRevocation.shouldRevoke(
                categoryIdentifier: $0.request.content.categoryIdentifier,
                eventRawValue: $0.request.content.userInfo[GuardNotificationProvenance.eventKey] as? String,
                notificationsEnabled: notificationsEnabled,
                policy: policy
            ) ? $0.request.identifier : nil
        }
        let pendingIDs = pending.compactMap {
            GuardNotificationRevocation.shouldRevoke(
                categoryIdentifier: $0.content.categoryIdentifier,
                eventRawValue: $0.content.userInfo[GuardNotificationProvenance.eventKey] as? String,
                notificationsEnabled: notificationsEnabled,
                policy: policy
            ) ? $0.identifier : nil
        }
        if !deliveredIDs.isEmpty { center.removeDeliveredNotifications(withIdentifiers: deliveredIDs) }
        if !pendingIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pendingIDs) }
    }

    /// Request notification authorization if not yet determined.
    func ensureAuthorized() async {
        guard systemCenterIsActive else { return }
        guard !hasAuthorized else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        hasAuthorized = true
    }

    /// Send a local notification. Honors the user's Settings toggle.
    func notify(
        event: GuardNotificationEvent,
        identifier: String,
        title: String,
        body: String,
        threadIdentifier: String? = nil,
        categoryIdentifier: String? = nil,
        scopeID: String? = nil,
        scopeGeneration: UInt64? = nil
    ) async {
        guard SystemIntegrationPolicy.isEnabled() else { return }
        guard systemCenterIsActive, notificationsEnabled,
              UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
        guard GuardNotificationPolicy.allows(event, config: policy) else { return }
        await ensureAuthorized()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo[GuardNotificationProvenance.eventKey] = event.rawValue
        if let scopeID, let scopeGeneration {
            content.userInfo[GuardNotificationProvenance.scopeIDKey] = scopeID
            content.userInfo[GuardNotificationProvenance.scopeGenerationKey] = String(scopeGeneration)
        }
        if let thread = threadIdentifier {
            content.threadIdentifier = thread
        }
        if policy.actionsEnabled, let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            let msg = "Notifier: failed to schedule notification: \(error)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    // MARK: - Eviction (always sent — user-initiated, low frequency)

    func notifyEvictionComplete(
        evictedCount: Int,
        reclaimedBytes: Int64,
        scopeID: String,
        scopeGeneration: UInt64
    ) async {
        await notify(
            event: .evictionCompleted,
            identifier: "icloud-guard.eviction.\(Int(Date().timeIntervalSince1970))",
            title: "iCloud Guard",
            body: "Evicted \(evictedCount) files, reclaimed \(formatBytes(reclaimedBytes))",
            threadIdentifier: "icloud-guard.eviction",
            categoryIdentifier: GuardNotificationCategory.eviction,
            scopeID: scopeID,
            scopeGeneration: scopeGeneration
        )
    }

    func notifyPartialFailure(message: String, scopeID: String, scopeGeneration: UInt64) async {
        await notify(
            event: .partialFailure,
            identifier: "icloud-guard.partial.\(Int(Date().timeIntervalSince1970))",
            title: "iCloud Guard needs attention",
            body: message,
            threadIdentifier: "icloud-guard.partial",
            categoryIdentifier: GuardNotificationCategory.attention,
            scopeID: scopeID,
            scopeGeneration: scopeGeneration
        )
    }

    func notifyRestoreComplete(verified: Int, pending: Int, failed: Int) async {
        await notify(
            event: .restoreCompleted,
            identifier: "icloud-guard.restore.\(Int(Date().timeIntervalSince1970))",
            title: "Restore request finished",
            body: "\(verified) local, \(pending) pending, \(failed) failed",
            threadIdentifier: "icloud-guard.restore"
        )
    }

    func notifyKeepDownloaded(verified: Int, pending: Int, failed: Int) async {
        await notify(
            event: .keepDownloaded,
            identifier: "icloud-guard.keep-downloaded.\(Int(Date().timeIntervalSince1970))",
            title: "Keep-downloaded rules checked",
            body: "\(verified) local, \(pending) pending, \(failed) failed",
            threadIdentifier: "icloud-guard.keep-downloaded"
        )
    }

    // MARK: - Rematerialization (throttled + batched)

    func notifyRematerialization(path _: String) async {
        let now = Date()
        rematerializationBatchCount += 1

        if let last = lastRematerializationNotify,
           GuardNotificationThrottle.shouldSuppress(
               now: now, last: last, interval: rematerializationThrottleSeconds
           ) {
            // Within throttle window — skip, count will be included in next flush
            return
        }

        // Flush: send a batched notification
        let body: String
        body = rematerializationBatchCount > 1
            ? "\(rematerializationBatchCount) files rematerialized"
            : "A watched file rematerialized"

        await notify(
            event: .fightingFiles,
            identifier: "icloud-guard.rematerial.\(Int(now.timeIntervalSince1970))",
            title: "iCloud Guard",
            body: body,
            threadIdentifier: "icloud-guard.rematerial"
        )

        lastRematerializationNotify = now
        rematerializationBatchCount = 0
    }

    func notifyFighting(count: Int, scopeID: String, scopeGeneration: UInt64) async {
        guard count > 0 else { return }
        await notify(
            event: .fightingFiles,
            identifier: "icloud-guard.fighting.\(Int(Date().timeIntervalSince1970))",
            title: "iCloud files keep returning",
            body: "\(count) path(s) were suspended after repeated downloads",
            threadIdentifier: "icloud-guard.fighting",
            categoryIdentifier: GuardNotificationCategory.attention,
            scopeID: scopeID,
            scopeGeneration: scopeGeneration
        )
    }

    // MARK: - Pollution threshold (throttled)

    func notifyPollutionThreshold(ratio: Double) async {
        let now = Date()

        if let last = lastPollutionNotify,
           GuardNotificationThrottle.shouldSuppress(now: now, last: last, interval: pollutionThrottleSeconds) {
            return
        }

        await notify(
            event: .partialFailure,
            identifier: "icloud-guard.pollution.\(Int(now.timeIntervalSince1970))",
            title: "iCloud Guard",
            body: "Pollution threshold crossed: \(Int(ratio * 100))%",
            threadIdentifier: "icloud-guard.pollution"
        )

        lastPollutionNotify = now
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

}

enum GuardNotificationRevocation {
    static func shouldRevoke(
        categoryIdentifier: String,
        eventRawValue: String?,
        notificationsEnabled: Bool,
        policy: AppConfig.NotificationsConfig
    ) -> Bool {
        guard !categoryIdentifier.isEmpty else { return false }
        guard notificationsEnabled else { return true }
        guard let raw = eventRawValue,
              let event = GuardNotificationEvent(rawValue: raw) else { return true }
        return !policy.actionsEnabled || !GuardNotificationPolicy.allows(event, config: policy)
    }
}

enum GuardNotificationThrottle {
    static func shouldSuppress(now: Date, last: Date, interval: TimeInterval) -> Bool {
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= 0 && elapsed < max(0, interval)
    }
}

enum GuardNotificationCategory {
    static let eviction = "icloud-guard.eviction-actions"
    static let attention = "icloud-guard.attention-actions"
    static let restoreLast = "icloud-guard.restore-last"
    static let pause = "icloud-guard.pause"
}

enum GuardNotificationProvenance {
    static let eventKey = "icloud-guard-event"
    static let scopeIDKey = "icloud-guard-scope-id"
    static let scopeGenerationKey = "icloud-guard-scope-generation"
}

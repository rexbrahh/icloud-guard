import Foundation
import UserNotifications

/// Actor that manages local notifications with lazy authorization.
///
/// Authorization is requested only when the current status is `.notDetermined`.
/// Notifications use stable identifiers and are grouped by threadIdentifier.
actor Notifier {
    static let shared = Notifier()

    private var hasAuthorized = false

    /// Request notification authorization if not yet determined.
    func ensureAuthorized() async {
        guard !hasAuthorized else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        hasAuthorized = true
    }

    /// Send a local notification with stable identifier.
    /// - Parameters:
    ///   - identifier: Stable identifier for the notification (deduplication)
    ///   - title: Notification title
    ///   - body: Notification body
    ///   - threadIdentifier: Grouping identifier (optional)
    func notify(identifier: String, title: String, body: String, threadIdentifier: String? = nil) async {
        await ensureAuthorized()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let thread = threadIdentifier {
            content.threadIdentifier = thread
        }

        // Floor trigger at 0.5s to avoid immediate-fire issues
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Swallow errors — notifications are best-effort
            let msg = "Notifier: failed to schedule notification: \(error)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    /// Convenience: notify on eviction completion.
    func notifyEvictionComplete(evictedCount: Int, reclaimedBytes: Int64) async {
        await notify(
            identifier: "icloud-guard.eviction.\(Int(Date().timeIntervalSince1970))",
            title: "iCloud Guard",
            body: "Evicted \(evictedCount) files, reclaimed \(formatBytes(reclaimedBytes))",
            threadIdentifier: "icloud-guard.eviction"
        )
    }

    /// Convenience: notify on rematerialization detected.
    func notifyRematerialization(path: String) async {
        await notify(
            identifier: "icloud-guard.rematerial.\(Int(Date().timeIntervalSince1970))",
            title: "iCloud Guard",
            body: "Rematerialization detected: \(path)",
            threadIdentifier: "icloud-guard.rematerial"
        )
    }

    /// Convenience: notify on pollution threshold crossing.
    func notifyPollutionThreshold(ratio: Double) async {
        await notify(
            identifier: "icloud-guard.pollution.\(Int(Date().timeIntervalSince1970))",
            title: "iCloud Guard",
            body: "Pollution threshold crossed: \(Int(ratio * 100))%",
            threadIdentifier: "icloud-guard.pollution"
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

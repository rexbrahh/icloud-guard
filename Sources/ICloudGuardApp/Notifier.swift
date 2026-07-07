import Foundation
import UserNotifications

/// Actor that manages local notifications with lazy authorization, throttling, and batching.
///
/// - Rematerialization notifications are throttled: only one per 60 seconds per category.
///   The path and count are batched into a single notification.
/// - Pollution threshold notifications are throttled to one per 5 minutes.
/// - Eviction completion notifications are always sent (user-initiated, low frequency).
actor Notifier {
    static let shared = Notifier()

    private var hasAuthorized = false

    // Throttling state
    private var lastRematerializationNotify: Date?
    private var rematerializationBatchCount = 0
    private var lastPollutionNotify: Date?

    // Minimum interval between throttled notifications (seconds)
    private let rematerializationThrottleSeconds: TimeInterval = 60
    private let pollutionThrottleSeconds: TimeInterval = 300

    /// Request notification authorization if not yet determined.
    func ensureAuthorized() async {
        guard !hasAuthorized else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        hasAuthorized = true
    }

    /// Send a local notification.
    func notify(identifier: String, title: String, body: String, threadIdentifier: String? = nil) async {
        await ensureAuthorized()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let thread = threadIdentifier {
            content.threadIdentifier = thread
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

    func notifyEvictionComplete(evictedCount: Int, reclaimedBytes: Int64) async {
        await notify(
            identifier: "icloud-guard.eviction.\(Int(Date().timeIntervalSince1970))",
            title: "iCloud Guard",
            body: "Evicted \(evictedCount) files, reclaimed \(formatBytes(reclaimedBytes))",
            threadIdentifier: "icloud-guard.eviction"
        )
    }

    // MARK: - Rematerialization (throttled + batched)

    func notifyRematerialization(path: String) async {
        let now = Date()
        rematerializationBatchCount += 1

        if let last = lastRematerializationNotify,
           now.timeIntervalSince(last) < rematerializationThrottleSeconds {
            // Within throttle window — skip, count will be included in next flush
            return
        }

        // Flush: send a batched notification
        let body: String
        if rematerializationBatchCount > 1 {
            body = "\(rematerializationBatchCount) files rematerialized (latest: \(shorten(path: path)))"
        } else {
            body = "Rematerialization detected: \(shorten(path: path))"
        }

        await notify(
            identifier: "icloud-guard.rematerial.\(Int(now.timeIntervalSince1970))",
            title: "iCloud Guard",
            body: body,
            threadIdentifier: "icloud-guard.rematerial"
        )

        lastRematerializationNotify = now
        rematerializationBatchCount = 0
    }

    // MARK: - Pollution threshold (throttled)

    func notifyPollutionThreshold(ratio: Double) async {
        let now = Date()

        if let last = lastPollutionNotify,
           now.timeIntervalSince(last) < pollutionThrottleSeconds {
            return
        }

        await notify(
            identifier: "icloud-guard.pollution.\(Int(now.timeIntervalSince1970))",
            title: "iCloud Guard",
            body: "Pollution threshold crossed: \(Int(ratio * 100))%",
            threadIdentifier: "icloud-guard.pollution"
        )

        lastPollutionNotify = now
    }

    // MARK: - Helpers

    private func shorten(path: String) -> String {
        let components = path.split(separator: "/")
        if components.count > 3 {
            return "…/" + components.suffix(2).joined(separator: "/")
        }
        return path
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private func formatBytes(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }
}

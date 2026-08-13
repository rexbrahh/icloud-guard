import Foundation
import ICloudGuardCore
import UserNotifications

/// Singleton delegate for UNUserNotificationCenter.
/// Ensures notifications are shown even when the app is in the foreground.
@MainActor
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterDelegate()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let context = GuardNotificationActionContext(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            eventRawValue: response.notification.request.content.userInfo[GuardNotificationProvenance.eventKey] as? String,
            scopeID: response.notification.request.content.userInfo[GuardNotificationProvenance.scopeIDKey] as? String,
            scopeGeneration: (response.notification.request.content.userInfo[GuardNotificationProvenance.scopeGenerationKey] as? String).flatMap(UInt64.init)
        )
        GuardNotificationActionDispatcher.dispatch(
            context: context,
            policyLoader: {
                guard let config = try? ConfigStore().loadValidated() else {
                    return nil
                }
                return GuardNotificationConsumptionPolicy(
                    notificationsEnabled: UserDefaults.standard.bool(forKey: "notificationsEnabled"),
                    notifications: config.notifications,
                    allowedScopeIDs: Set(config.scopes?.map(\.id) ?? ["default"])
                )
            },
            post: { action in
                NotificationCenter.default.post(
                    name: action.notificationName,
                    object: nil,
                    userInfo: [
                        GuardNotificationProvenance.scopeIDKey: action.scopeID,
                        GuardNotificationProvenance.scopeGenerationKey: String(action.scopeGeneration),
                    ]
                )
            },
            completionHandler: completionHandler
        )
    }
}

struct GuardNotificationActionContext: Equatable, Sendable {
    var actionIdentifier: String
    var categoryIdentifier: String
    var eventRawValue: String?
    var scopeID: String?
    var scopeGeneration: UInt64?

    init(
        actionIdentifier: String,
        categoryIdentifier: String,
        eventRawValue: String?,
        scopeID: String? = nil,
        scopeGeneration: UInt64? = nil
    ) {
        self.actionIdentifier = actionIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.eventRawValue = eventRawValue
        self.scopeID = scopeID
        self.scopeGeneration = scopeGeneration
    }
}

enum GuardNotificationAction: Equatable, Sendable {
    case restoreLast(scopeID: String, scopeGeneration: UInt64)
    case pause(scopeID: String, scopeGeneration: UInt64)

    var scopeID: String {
        switch self {
        case .restoreLast(let scopeID, _), .pause(let scopeID, _): return scopeID
        }
    }

    var scopeGeneration: UInt64 {
        switch self {
        case .restoreLast(_, let generation), .pause(_, let generation): return generation
        }
    }

    var notificationName: Notification.Name {
        switch self {
        case .restoreLast: return .icloudGuardRestoreLast
        case .pause: return .icloudGuardPause
        }
    }
}

struct GuardNotificationConsumptionPolicy: Equatable, Sendable {
    var notificationsEnabled: Bool
    var notifications: AppConfig.NotificationsConfig
    var allowedScopeIDs: Set<String>

    init(
        notificationsEnabled: Bool,
        notifications: AppConfig.NotificationsConfig,
        allowedScopeIDs: Set<String> = ["default"]
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.notifications = notifications
        self.allowedScopeIDs = allowedScopeIDs
    }
}

enum GuardNotificationActionRouter {
    static func action(
        for context: GuardNotificationActionContext,
        policy: GuardNotificationConsumptionPolicy?
    ) -> GuardNotificationAction? {
        guard let policy, policy.notificationsEnabled, policy.notifications.actionsEnabled,
              let raw = context.eventRawValue,
              let event = GuardNotificationEvent(rawValue: raw),
              let scopeID = context.scopeID,
              let scopeGeneration = context.scopeGeneration,
              policy.allowedScopeIDs.contains(scopeID),
              GuardNotificationPolicy.allows(event, config: policy.notifications) else { return nil }
        switch (context.actionIdentifier, context.categoryIdentifier, event) {
        case (GuardNotificationCategory.restoreLast, GuardNotificationCategory.eviction, .evictionCompleted):
            return .restoreLast(scopeID: scopeID, scopeGeneration: scopeGeneration)
        case (GuardNotificationCategory.pause, GuardNotificationCategory.eviction, .evictionCompleted),
             (GuardNotificationCategory.pause, GuardNotificationCategory.attention, .partialFailure),
             (GuardNotificationCategory.pause, GuardNotificationCategory.attention, .fightingFiles):
            return .pause(scopeID: scopeID, scopeGeneration: scopeGeneration)
        default:
            return nil
        }
    }
}

enum GuardNotificationActionDispatcher {
    nonisolated static func dispatch(
        context: GuardNotificationActionContext,
        policyLoader: @escaping @Sendable () async -> GuardNotificationConsumptionPolicy?,
        post: @escaping @MainActor @Sendable (GuardNotificationAction) -> Void,
        completionHandler: @escaping () -> Void
    ) {
        let completion = SingleShotNotificationCompletion(completionHandler)
        Task { @MainActor in
            defer { completion.call() }
            guard let action = GuardNotificationActionRouter.action(
                for: context,
                policy: await policyLoader()
            ) else { return }
            post(action)
        }
    }
}

private final class SingleShotNotificationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        lock.lock()
        let pending = handler
        handler = nil
        lock.unlock()
        pending?()
    }
}

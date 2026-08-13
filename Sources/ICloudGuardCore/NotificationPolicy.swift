import Foundation

public enum GuardNotificationEvent: String, Codable, CaseIterable, Sendable {
    case evictionCompleted = "eviction-completed"
    case partialFailure = "partial-failure"
    case fightingFiles = "fighting-files"
    case restoreCompleted = "restore-completed"
    case keepDownloaded = "keep-downloaded"
}

public enum GuardNotificationPolicy {
    public static func allows(_ event: GuardNotificationEvent, config: AppConfig.NotificationsConfig) -> Bool {
        switch event {
        case .evictionCompleted: return config.evictionCompleted
        case .partialFailure: return config.partialFailure
        case .fightingFiles: return config.fightingFiles
        case .restoreCompleted: return config.restoreCompleted
        case .keepDownloaded: return config.keepDownloaded
        }
    }
}

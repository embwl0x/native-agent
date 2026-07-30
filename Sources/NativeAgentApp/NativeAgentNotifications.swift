import Foundation
import PersistenceCore
import UserNotifications

struct NativeAgentNotificationPostResult: Sendable {
    let identifier: String
    let status: String
    let delivery: String
    let posted: Bool
    let visibleAlertsEnabled: Bool
    let authorizationStatus: String
    let alertSetting: String
    let soundSetting: String
    let badgeSetting: String
    let error: String?

    func deliveryFields() -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "status": .string(status),
            "delivery": .string(delivery),
            "posted": .bool(posted),
            "visibleAlertsEnabled": .bool(visibleAlertsEnabled),
            "authorizationStatus": .string(authorizationStatus),
            "alertSetting": .string(alertSetting),
            "soundSetting": .string(soundSetting),
            "badgeSetting": .string(badgeSetting),
            "notificationId": .string(identifier),
        ]
        if let error {
            obj["error"] = .string(error)
        }
        return obj
    }
}

enum NativeAgentNotifications {
    static func requestAuthorization() {
        Task {
            _ = await requestAuthorizationResult()
        }
    }

    static func post(title: String, body: String) {
        Task {
            _ = await postAndReport(title: title, body: body)
        }
    }

    static func postAndReport(title: String, body: String) async -> NativeAgentNotificationPostResult {
        let notificationTitle = NativeAgentNotificationDefaults.title(title)
        let center = UNUserNotificationCenter.current()
        var settings = await notificationSettings(center)
        var authError: String?
        if settings.isNotDetermined {
            let auth = await requestAuthorizationResult(center)
            authError = auth.error
            settings = await notificationSettings(center)
        }

        let identifier = UUID().uuidString
        let visibleAlertsEnabled = settings.alertsEnabled
        guard settings.isAuthorized else {
            return NativeAgentNotificationPostResult(
                identifier: identifier,
                status: "blocked",
                delivery: "macos_notifications_not_authorized",
                posted: false,
                visibleAlertsEnabled: false,
                authorizationStatus: settings.authorizationStatus,
                alertSetting: settings.alertSetting,
                soundSetting: settings.soundSetting,
                badgeSetting: settings.badgeSetting,
                error: authError ?? "NativeAgent macOS notifications are \(settings.authorizationStatus). Enable NativeAgent notifications in System Settings."
            )
        }

        let content = UNMutableNotificationContent()
        content.title = notificationTitle
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let addError = await add(request, center: center)
        if let addError {
            return NativeAgentNotificationPostResult(
                identifier: identifier,
                status: "failed",
                delivery: "macos_notification_add_failed",
                posted: false,
                visibleAlertsEnabled: visibleAlertsEnabled,
                authorizationStatus: settings.authorizationStatus,
                alertSetting: settings.alertSetting,
                soundSetting: settings.soundSetting,
                badgeSetting: settings.badgeSetting,
                error: addError
            )
        }

        return NativeAgentNotificationPostResult(
            identifier: identifier,
            status: "completed",
            delivery: visibleAlertsEnabled
                ? "posted_to_macos_notification_center"
                : "posted_to_macos_notification_center_alerts_disabled",
            posted: true,
            visibleAlertsEnabled: visibleAlertsEnabled,
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            soundSetting: settings.soundSetting,
            badgeSetting: settings.badgeSetting,
            error: nil
        )
    }

    private static func notificationSettings(_ center: UNUserNotificationCenter) async -> NotificationSettingsSnapshot {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: NotificationSettingsSnapshot(settings))
            }
        }
    }

    private static func requestAuthorizationResult(_ center: UNUserNotificationCenter = .current()) async -> (granted: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                continuation.resume(returning: (granted, error?.localizedDescription))
            }
        }
    }

    private static func add(_ request: UNNotificationRequest, center: UNUserNotificationCenter) async -> String? {
        await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private static func string(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "not_determined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private static func string(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported:
            return "not_supported"
        case .disabled:
            return "disabled"
        case .enabled:
            return "enabled"
        @unknown default:
            return "unknown"
        }
    }

    private struct NotificationSettingsSnapshot: Sendable {
        let authorizationStatus: String
        let alertSetting: String
        let soundSetting: String
        let badgeSetting: String
        let isNotDetermined: Bool
        let isAuthorized: Bool
        let alertsEnabled: Bool

        init(_ settings: UNNotificationSettings) {
            authorizationStatus = NativeAgentNotifications.string(settings.authorizationStatus)
            alertSetting = NativeAgentNotifications.string(settings.alertSetting)
            soundSetting = NativeAgentNotifications.string(settings.soundSetting)
            badgeSetting = NativeAgentNotifications.string(settings.badgeSetting)
            isNotDetermined = settings.authorizationStatus == .notDetermined
            isAuthorized = NativeAgentNotifications.isAuthorized(settings.authorizationStatus)
            alertsEnabled = settings.alertSetting == .enabled
        }
    }
}

import Foundation
import UserNotifications
import NativeAgentCore
import PersistenceCore
import NotificationInbox
import DeviceSync

/// The identity a banner carries and what a click on it does. A click OPENS
/// the item — it never approves, runs, or closes anything.
public enum NativeAgentNotificationRoute {
    /// userInfo key: the Desk handle a reminder is about.
    public static let deskHandleKey = "deskHandle"

    public static func deskHandle(in userInfo: [AnyHashable: Any]) -> String? {
        guard let handle = userInfo[deskHandleKey] as? String,
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return handle
    }
}

/// The OS adapter returns observations; admission and receipt meaning stay here.
public protocol MacNotificationDelivery {
    static func notificationSettings() async -> MacNotificationSettings
    static func requestAuthorizationError() async -> String?
    static func addNotification(
        identifier: String, title: String, body: String, category: String,
        userInfo: [String: String], soundName: String?
    ) async -> String?
}

public struct MacNotificationSettings: Sendable {
    public let authorizationStatus: String
    public let alertSetting: String
    public let soundSetting: String
    public let badgeSetting: String

    public init(authorizationStatus: String, alertSetting: String, soundSetting: String, badgeSetting: String) {
        self.authorizationStatus = authorizationStatus
        self.alertSetting = alertSetting
        self.soundSetting = soundSetting
        self.badgeSetting = badgeSetting
    }

    var isNotDetermined: Bool { authorizationStatus == "not_determined" }
    var isAuthorized: Bool { ["authorized", "provisional", "ephemeral"].contains(authorizationStatus) }
    var alertsEnabled: Bool { alertSetting == "enabled" }
}

extension AttentionRouter {
    public static func postMacNotification(
        title: String, body: String, userInfo: [String: String], soundName: String?,
        root: URL, delivery: any MacNotificationDelivery.Type
    ) async -> NativeAgentNotificationPostResult {
        // Her resident wake runs in his quiet hours; its banners wait in the
        // inbox until they end (AttentionRouter.releaseHeld).
        if AttentionRouter.holdsResidentWake(session: userInfo[NativeAgentNotificationActions.sessionKey], dataRoot: root) {
            var fields: [String: JSONValue] = ["held_user_info": .object(userInfo.mapValues(JSONValue.string))]
            if let soundName { fields["held_sound_name"] = .string(soundName) }
            do { try await LiveNotificationInbox.hold(dataRoot: root, title: title, body: body, ways: ["mac"], fields: fields) }
            catch {
                return NativeAgentNotificationPostResult(identifier: UUID().uuidString, status: "failed", delivery: "quiet_hours_hold_failed",
                    posted: false, visibleAlertsEnabled: false, authorizationStatus: "", alertSetting: "", soundSetting: "",
                    badgeSetting: "", error: error.localizedDescription)
            }
            return NativeAgentNotificationPostResult(identifier: UUID().uuidString, status: "held", delivery: "held_for_quiet_hours",
                posted: false, visibleAlertsEnabled: false, authorizationStatus: "", alertSetting: "", soundSetting: "",
                badgeSetting: "", error: nil)
        }
        let notificationTitle = NativeAgentNotificationDefaults.title(title)
        var settings = await delivery.notificationSettings()
        var authError: String?
        if settings.isNotDetermined {
            authError = await delivery.requestAuthorizationError()
            settings = await delivery.notificationSettings()
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
                error: authError ?? "NativeAgent does not have permission to show notifications. Open System Settings > Notifications > NativeAgent to allow them."
            )
        }

        let addError = await delivery.addNotification(
            identifier: identifier, title: notificationTitle, body: body,
            category: NativeAgentNotificationActions.category(for: userInfo),
            userInfo: userInfo, soundName: soundName
        )
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
}

public enum NativeAgentNotifications: MacNotificationDelivery {
    /// Tool-authored messages can be answered. Bind the route at posting time,
    /// never to whichever conversation happens to be visible when Reply lands.
    /// Messages outside a turn own a new, retained notification conversation.
    public static func postMessage(title: String, body: String, soundName: String? = nil) async -> NativeAgentNotificationPostResult {
        return await postAndReport(
            title: title, body: body,
            userInfo: NativeAgentNotificationActions.messageRoute,
            soundName: soundName
        )
    }

    public static func post(title: String, body: String) {
        Task {
            _ = await postAndReport(title: title, body: body)
        }
    }

    /// `userInfo` rides with the banner so a click can land on the thing the
    /// banner is about. Keys are plain strings; `NativeAgentNotificationRoute`
    /// owns the ones this app reads back.
    public static func postAndReport(
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        soundName: String? = nil
    ) async -> NativeAgentNotificationPostResult {
        await AttentionRouter.postMacNotification(
            title: title, body: body, userInfo: userInfo, soundName: soundName,
            root: PersistenceCore.defaultDataRoot(), delivery: Self.self
        )
    }

    public static func notificationSettings() async -> MacNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: MacNotificationSettings(
                    authorizationStatus: string(settings.authorizationStatus),
                    alertSetting: string(settings.alertSetting),
                    soundSetting: string(settings.soundSetting),
                    badgeSetting: string(settings.badgeSetting)
                ))
            }
        }
    }

    public static func requestAuthorizationError() async -> String? {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    public static func addNotification(
        identifier: String, title: String, body: String, category: String,
        userInfo: [String: String], soundName: String?
    ) async -> String? {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = soundName.flatMap {
            $0.isEmpty ? nil : UNNotificationSound(named: UNNotificationSoundName(rawValue: $0))
        } ?? .default
        if !userInfo.isEmpty { content.userInfo = userInfo }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error?.localizedDescription)
            }
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

}

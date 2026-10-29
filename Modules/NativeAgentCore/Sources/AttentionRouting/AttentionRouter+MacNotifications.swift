import Foundation
import Synchronization
import UserNotifications
import NativeAgentCore
import PersistenceCore
import NotificationInbox
import DeviceSync
// Blueprint: | `AttentionRouter+MacNotifications.swift` | Native UserNotifications transport, message-route binding and notification admission/receipts; fire-and-forget posts retain their handles through the OS outcome, and shutdown closes admission without joining or cancelling accepted banners |

/// The identity a banner carries and what a click on it does. A click OPENS
/// the item — it never approves, runs, or closes anything.
public enum NativeAgentNotificationRoute {
    public static let pageKey = "pageRoute"
    /// userInfo key: the Desk handle a reminder is about.
    public static let deskHandleKey = "deskHandle"

    public static func deskHandle(in userInfo: [AnyHashable: Any]) -> String? {
        guard let handle = userInfo[deskHandleKey] as? String,
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return handle
    }
}

extension NativeAgentNotifications {
    private static func postAccepted(
        title: String, body: String, userInfo: [String: String], soundName: String?
    ) async -> NativeAgentNotificationPostResult {
        let root = PersistenceCore.defaultDataRoot()
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
        var settings = await notificationSettings()
        var authError: String?
        if settings.authorizationStatus == .notDetermined {
            authError = await requestAuthorizationError()
            settings = await notificationSettings()
        }

        let identifier = UUID().uuidString
        let visibleAlertsEnabled = settings.alertSetting == .enabled
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
            return NativeAgentNotificationPostResult(
                identifier: identifier,
                status: "blocked",
                delivery: "macos_notifications_not_authorized",
                posted: false,
                visibleAlertsEnabled: false,
                authorizationStatus: string(settings.authorizationStatus),
                alertSetting: string(settings.alertSetting),
                soundSetting: string(settings.soundSetting),
                badgeSetting: string(settings.badgeSetting),
                error: authError ?? "NativeAgent does not have permission to show notifications. Open System Settings > Notifications > NativeAgent to allow them."
            )
        }

        guard !Task.isCancelled else {
            return NativeAgentNotificationPostResult(identifier: identifier, status: "cancelled", delivery: "task_cancelled",
                posted: false, visibleAlertsEnabled: visibleAlertsEnabled, authorizationStatus: string(settings.authorizationStatus),
                alertSetting: string(settings.alertSetting), soundSetting: string(settings.soundSetting), badgeSetting: string(settings.badgeSetting),
                error: CancellationError().localizedDescription)
        }
        let addError = await addNotification(
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
                authorizationStatus: string(settings.authorizationStatus),
                alertSetting: string(settings.alertSetting),
                soundSetting: string(settings.soundSetting),
                badgeSetting: string(settings.badgeSetting),
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
            authorizationStatus: string(settings.authorizationStatus),
            alertSetting: string(settings.alertSetting),
            soundSetting: string(settings.soundSetting),
            badgeSetting: string(settings.badgeSetting),
            error: nil
        )
    }
}

public enum NativeAgentNotifications {
    private static let delivery = Mutex<(stopped: Bool, posts: [UUID: Task<Void, Never>])>((false, [:]))

    /// Already accepted banners finish and retire at the OS callback, including
    /// errors. Close admission immediately; never join the OS during shutdown.
    public static func shutdown() {
        delivery.withLock { $0.stopped = true }
    }

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

    public static func post(title: String, body: String, userInfo: [String: String] = [:]) {
        delivery.withLock { state in
            guard !state.stopped else { return }
            let id = UUID()
            state.posts[id] = Task {
                _ = await postAccepted(title: title, body: body, userInfo: userInfo, soundName: nil)
                _ = delivery.withLock { $0.posts.removeValue(forKey: id) }
            }
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
        guard !Task.isCancelled, delivery.withLock({ !$0.stopped }) else {
            return NativeAgentNotificationPostResult(
                identifier: UUID().uuidString, status: "cancelled", delivery: "engine_shutdown",
                posted: false, visibleAlertsEnabled: false, authorizationStatus: "", alertSetting: "",
                soundSetting: "", badgeSetting: "", error: CancellationError().localizedDescription)
        }
        return await postAccepted(title: title, body: body, userInfo: userInfo, soundName: soundName)
    }

    public static func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
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

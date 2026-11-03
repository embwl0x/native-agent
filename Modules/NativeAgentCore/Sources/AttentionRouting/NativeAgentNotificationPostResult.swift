import Foundation
import PersistenceCore
// Blueprint: | `NativeAgentNotificationPostResult.swift` | `NativeAgentNotificationPostResult`: confirmed native delivery fields |

public struct NativeAgentNotificationPostResult: Sendable {
    public var notificationOutcome: NotificationDeliveryOutcome {
        if posted { return .delivered }
        if delivery == "notification_channel_disabled" { return .suppressed(preference: NotificationChannelPreference.inAppKey) }
        if status == "unknown" { return .unknown(sent: true, reason: error ?? delivery) }
        return .notDelivered(reason: error ?? delivery)
    }

    static func fromLedger(_ outcome: NotificationDeliveryOutcome, id: String, held: Bool = false) -> Self {
        let status: String
        let delivery: String
        let error: String?
        switch outcome {
        case .delivered: status = "completed"; delivery = "posted_to_macos_notification_center"; error = nil
        case .suppressed: status = "suppressed"; delivery = "notification_channel_disabled"; error = nil
        case .notDelivered(let reason): status = held ? "held" : "failed"; delivery = held ? "held_for_quiet_hours" : "not_posted"; error = reason
        case .unknown(_, let reason): status = "unknown"; delivery = "macos_notification_unconfirmed"; error = reason
        }
        return Self(identifier: id, status: status, delivery: delivery, posted: outcome == .delivered,
            visibleAlertsEnabled: false, authorizationStatus: "not_read", alertSetting: "not_read",
            soundSetting: "not_read", badgeSetting: "not_read", error: error)
    }
    public let identifier: String
    public let status: String
    public let delivery: String
    public let posted: Bool
    public let visibleAlertsEnabled: Bool
    public let authorizationStatus: String
    public let alertSetting: String
    public let soundSetting: String
    public let badgeSetting: String
    public let error: String?

    public init(identifier: String, status: String, delivery: String, posted: Bool, visibleAlertsEnabled: Bool, authorizationStatus: String, alertSetting: String, soundSetting: String, badgeSetting: String, error: String?) {
        self.identifier = identifier
        self.status = status
        self.delivery = delivery
        self.posted = posted
        self.visibleAlertsEnabled = visibleAlertsEnabled
        self.authorizationStatus = authorizationStatus
        self.alertSetting = alertSetting
        self.soundSetting = soundSetting
        self.badgeSetting = badgeSetting
        self.error = error
    }

    public func deliveryFields() -> [String: JSONValue] {
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

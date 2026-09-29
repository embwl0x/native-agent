import Foundation
import PersistenceCore

public struct NativeAgentNotificationPostResult: Sendable {
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

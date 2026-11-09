import Foundation
import PersistenceCore
// Blueprint: | `NativeAgentNotificationPostResult.swift` | `NativeAgentNotificationPostResult`: confirmed native delivery fields |

struct MacNotificationSettlementFailure: Error, LocalizedError {
    let result: NativeAgentNotificationPostResult
    var errorDescription: String? { result.error }
}

public struct NativeAgentNotificationPostResult: Sendable {
    public var notificationOutcome: NotificationDeliveryOutcome {
        if status == "settlement_failed" { return .unknown(sent: true, reason: error ?? delivery) }
        if let deferredUntil { return .deferred(until: deferredUntil) }
        if posted { return .delivered }
        if delivery == "notification_channel_disabled" { return .suppressed(preference: NotificationChannelPreference.inAppKey) }
        if status == "unknown" { return .unknown(sent: true, reason: error ?? delivery) }
        return .notDelivered(reason: error ?? delivery)
    }

    func receiptUnavailable(_ cause: any Error) -> Self {
        Self(identifier: identifier, status: "settlement_failed", delivery: "macos_notification_receipt_unavailable",
             posted: posted, visibleAlertsEnabled: visibleAlertsEnabled, authorizationStatus: authorizationStatus,
             alertSetting: alertSetting, soundSetting: soundSetting, badgeSetting: badgeSetting,
             error: "macOS accepted the banner, but its durable receipt failed: " + cause.localizedDescription
                 + ". Repair the experience store before reconciling this notification; do not post it again.")
    }

    static func from(_ outcome: NotificationDeliveryOutcome, id: String) -> Self {
        let status: String
        let delivery: String
        let error: String?
        let deferredUntil: Date?
        if case .deferred(let until) = outcome { deferredUntil = until } else { deferredUntil = nil }
        switch outcome {
        case .delivered: status = "completed"; delivery = "posted_to_macos_notification_center"; error = nil
        case .suppressed: status = "suppressed"; delivery = "notification_channel_disabled"; error = nil
        case .deferred: status = "held"; delivery = AttentionOutcome.Delivery.deferred.rawValue; error = nil
        case .notDelivered(let reason): status = "failed"; delivery = "not_posted"; error = reason
        case .unknown(_, let reason): status = "unknown"; delivery = "macos_notification_unconfirmed"; error = reason
        }
        return Self(identifier: id, status: status, delivery: delivery, posted: outcome == .delivered,
            visibleAlertsEnabled: false, authorizationStatus: "not_read", alertSetting: "not_read",
            soundSetting: "not_read", badgeSetting: "not_read", error: error, deferredUntil: deferredUntil)
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
    public let deferredUntil: Date?

    public init(
        identifier: String,
        status: String,
        delivery: String,
        posted: Bool,
        visibleAlertsEnabled: Bool,
        authorizationStatus: String,
        alertSetting: String,
        soundSetting: String,
        badgeSetting: String,
        error: String?,
        deferredUntil: Date? = nil
    ) {
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
        self.deferredUntil = deferredUntil
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
        if let held = notificationOutcome.deferredFields { obj.merge(held) { _, new in new } }
        return obj
    }
}

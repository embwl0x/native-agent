import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `MobileNotificationDeliveryReceipt.swift` | Keyless notification publication receipts name CloudKit ordinary alerts or signed-result readers, optional APNs wakes and unverified phone display |
public struct MobileNotificationDeliveryReceipt: Sendable {
    public let bridgeMessageID: String
    public let apnsReceipts: [SwiftNativeAPNSReceipt]
    public let apnsErrors: [String]
    public let eventID: String
    public let signedResult: Bool

    public init(bridgeMessageID: String, apnsReceipts: [SwiftNativeAPNSReceipt],
                apnsErrors: [String], eventID: String, signedResult: Bool) {
        self.bridgeMessageID = bridgeMessageID
        self.apnsReceipts = apnsReceipts
        self.apnsErrors = apnsErrors
        self.eventID = eventID
        self.signedResult = signedResult
    }

    /// Publication is proven; neither transport nor process receipt proves display.
    public var status: String { "queued" }

    public var notificationOutcome: NotificationDeliveryOutcome {
        .unknown(sent: true, reason: "CloudKit publication accepted; signed phone receipt pending")
    }

    public func deliveryFields() -> [String: JSONValue] {
        [
            "status": .string(status),
            "delivery": .string("queued_to_icloud_bridge"),
            "route": .string(signedResult ? "mac_icloud_bridge_notification" : "cloudkit_visible_notification"),
            "bridgeQueued": .bool(true),
            "bridgeMessageId": .string(bridgeMessageID),
            "eventId": .string(eventID),
            "apnsAccepted": .bool(apnsReceipts.contains { $0.isSuccess }),
            "apnsPushType": .string("background"),
            "apnsSemantics": .string("Optional APNS only wakes sync. No provider configuration is required; acceptance does not prove phone receipt or display."),
            "apnsReceipts": .array(apnsReceipts.map { $0.toJSON() }),
            "apnsErrors": .array(apnsErrors.map(JSONValue.string)),
            "lockScreenDisplayVerified": .bool(false),
            "deliveryVerification": .string("device_display_unverified"),
        ]
    }
}
public struct SwiftNativeAPNSReceipt: Sendable {
    public let apnsId: String
    public let createdAt: String
    public let status: String
    public let httpStatus: Int?
    public let response: String
    public let tokenSuffix: String
    public let deviceId: String
    public let pairedDeviceID: String?
    public let tokenSource: String
    public let tokenUpdatedAt: String?
    public let tokenAgeSeconds: Int?
    public let environment: String
    public let topic: String
    public let error: String?

    public var isSuccess: Bool {
        guard status == "ok", let httpStatus else { return false }
        return (200..<300).contains(httpStatus)
    }
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "apnsId": .string(apnsId),
            "createdAt": .string(createdAt),
            "status": .string(status),
            "response": .string(response),
            "tokenSuffix": .string(tokenSuffix),
            "deviceId": .string(deviceId),
            "pairedDeviceID": pairedDeviceID.map(JSONValue.string) ?? .null,
            "tokenSource": .string(tokenSource),
            "environment": .string(environment),
            "topic": .string(topic),
        ]
        if let tokenUpdatedAt {
            obj["tokenUpdatedAt"] = .string(tokenUpdatedAt)
        }
        if let tokenAgeSeconds {
            obj["tokenAgeSeconds"] = .int(Int64(tokenAgeSeconds))
        }
        if let httpStatus {
            obj["httpStatus"] = .int(Int64(httpStatus))
        }
        if let error {
            obj["error"] = .string(error)
        }
        return .object(obj)
    }
}

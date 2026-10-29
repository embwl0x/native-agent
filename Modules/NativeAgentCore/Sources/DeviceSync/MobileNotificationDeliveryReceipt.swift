import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `MobileNotificationDeliveryReceipt.swift` | Bridge/APNs notification receipts distinguish acceptance, display uncertainty and named errors |
public struct MobileNotificationDeliveryReceipt: Sendable {
    public let bridgeMessageID: String?
    public let bridgeError: String?
    public let apnsReceipts: [SwiftNativeAPNSReceipt]
    public let apnsErrors: [String]
    public let eventID: String?

    public init(
        bridgeMessageID: String?,
        bridgeError: String?,
        apnsReceipts: [SwiftNativeAPNSReceipt],
        apnsErrors: [String],
        eventID: String? = nil
    ) {
        self.bridgeMessageID = bridgeMessageID
        self.bridgeError = bridgeError
        self.apnsReceipts = apnsReceipts
        self.apnsErrors = apnsErrors
        self.eventID = eventID
    }
    public var apnsSent: Bool {
        apnsReceipts.contains { $0.isSuccess }
    }
    public var apnsAccepted: Bool {
        apnsSent
    }
    public var bridgeQueued: Bool {
        bridgeMessageID != nil
    }
    public var status: String {
        apnsAccepted ? "accepted" : (bridgeQueued ? "queued" : "failed")
    }
    public var route: String {
        if apnsSent && bridgeQueued { return "apns_and_icloud_bridge" }
        if apnsSent { return "apns" }
        return "mac_icloud_bridge_notification"
    }
    public var delivery: String {
        if apnsAccepted && bridgeQueued { return "accepted_by_apns_and_queued_to_icloud_bridge" }
        if apnsAccepted { return "accepted_by_apns" }
        return "queued_to_icloud_bridge"
    }
    public func deliveryFields() -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "status": .string(status),
            "delivery": .string(delivery),
            "route": .string(route),
            "bridgeQueued": .bool(bridgeQueued),
            "apnsSent": .bool(apnsSent),
            "apnsAccepted": .bool(apnsAccepted),
            "apnsSemantics": .string("APNS 2xx means Apple accepted the request, not that the device displayed it."),
            "providerAcceptanceOnly": .bool(apnsAccepted),
            "lockScreenDisplayVerified": .bool(false),
            "deliveryVerification": .string(
                apnsAccepted
                    ? "provider_accepted_device_display_unverified"
                    : "device_display_unverified"
            ),
            "requiresIOSAppActiveForBridge": .bool(bridgeQueued),
            "cloudKitVisualPushEligible": .bool(false),
        ]
        if let bridgeMessageID {
            obj["bridgeMessageId"] = .string(bridgeMessageID)
        }
        if let eventID {
            obj["eventId"] = .string(eventID)
        }
        if let bridgeError {
            obj["bridgeError"] = .string(bridgeError)
        }
        if !apnsReceipts.isEmpty {
            obj["apnsReceipts"] = .array(apnsReceipts.map { $0.toJSON() })
            obj["apnsReceiptCount"] = .int(Int64(apnsReceipts.count))
        }
        if !apnsErrors.isEmpty {
            obj["apnsErrors"] = .array(apnsErrors.map { .string($0) })
        }
        return obj
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

import CryptoKit
import Foundation
import UserNotifications

// Blueprint: | `DeviceEventIdentity.swift` | Stable cross-device notification/collapse identity and shared authenticated notification category construction |

public func nativeAgentNotificationCategories(approvalCategory: String, messageCategory: String,
    approve: String, deny: String, reply: String, replyPlaceholder: String) -> Set<UNNotificationCategory> {
    let authenticated: UNNotificationActionOptions = [.foreground, .authenticationRequired]
    let replyAction = UNTextInputNotificationAction(identifier: reply, title: "Reply", options: authenticated,
        textInputButtonTitle: "Send", textInputPlaceholder: replyPlaceholder)
    return [
        UNNotificationCategory(identifier: approvalCategory, actions: [
            UNNotificationAction(identifier: approve, title: "Approve", options: authenticated),
            UNNotificationAction(identifier: deny, title: "Deny", options: authenticated.union(.destructive)),
        ], intentIdentifiers: [], options: []),
        UNNotificationCategory(identifier: messageCategory, actions: [replyAction], intentIdentifiers: [], options: []),
    ]
}

/// A semantic key owns one payload-free, 64-byte-safe ID across APNS, iCloud and
/// local snapshots. Changing prose cannot create another alert for that event.
public enum NativeAgentDeviceEventIdentity {
    private static let canonicalHexCount = 64

    public static func notification(
        userInfo: [String: String],
        fallback: @autoclosure () -> String = UUID().uuidString
    ) -> String {
        if let explicit = clean(userInfo["eventId"]), isCanonical(explicit) {
            return explicit.lowercased()
        }
        let keys = ["eventId", "dedupKey", "itemId", "approvalId", "taskId", "trigger"]
        for key in keys {
            if let value = clean(userInfo[key]) {
                return digest("notification:\(key):\(value)")
            }
        }
        return digest("notification:fallback:\(fallback())")
    }

    public static func isCanonical(_ value: String) -> Bool {
        value.utf8.count == canonicalHexCount
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

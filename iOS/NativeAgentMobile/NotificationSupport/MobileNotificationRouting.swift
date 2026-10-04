import CloudKit
import NativeAgentShared
import UserNotifications

/// Presentation/routing hints only. Decisions still re-read the synced row
/// and enter the signed Mac action path; a push cannot grant approval authority.
enum MobileNotificationRouting {
    static let approvalCategory = "nativeagent.mobile.approval"
    static let messageCategory = "nativeagent.mobile.message"
    static let approve = "nativeagent.mobile.approve"
    static let deny = "nativeagent.mobile.deny"
    static let reply = "nativeagent.mobile.reply"

    static func register() {
        let authenticated: UNNotificationActionOptions = [.foreground, .authenticationRequired]
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: approvalCategory, actions: [
                UNNotificationAction(identifier: approve, title: "Approve", options: authenticated),
                UNNotificationAction(identifier: deny, title: "Deny", options: authenticated.union(.destructive)),
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: messageCategory, actions: [
                UNTextInputNotificationAction(identifier: reply, title: "Reply", options: authenticated,
                    textInputButtonTitle: "Send", textInputPlaceholder: "Message your agent"),
            ], intentIdentifiers: [], options: []),
        ])
    }

    static func categorized(_ content: UNNotificationContent) -> UNNotificationContent {
        let copy = content.mutableCopy() as! UNMutableNotificationContent
        if nonEmpty(copy.userInfo["approvalId"] as? String) != nil {
            copy.categoryIdentifier = approvalCategory
        } else if nonEmpty(copy.userInfo["sessionId"] as? String) != nil {
            copy.categoryIdentifier = messageCategory
        }
        return copy
    }

    /// CloudKit's three-field alert projection omits action IDs. Read the exact
    /// notified record's existing envelope, without changing the Mac schema or
    /// selecting a different request by title/time.
    static func resolvingCloudKitRouting(_ content: UNNotificationContent) async throws -> UNNotificationContent {
        guard let query = CKNotification(fromRemoteNotificationDictionary: content.userInfo) as? CKQueryNotification,
              let recordID = query.recordID else { return categorized(content) }
        guard let containerID = Bundle.main.object(forInfoDictionaryKey: "NativeAgentICloudContainerID") as? String,
              DeviceCloudKitPreflight.hasCloudKitEntitlement(),
              DeviceCloudKitPreflight.entitlementGrantsContainer(containerID) else {
            throw NSError(domain: "NativeAgentNotification", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Notification CloudKit container is not configured."])
        }
        let record = try await CKContainer(identifier: containerID).privateCloudDatabase.record(for: recordID)
        guard record.recordType == NADeviceSyncRecordType.notification,
              let payload = record["payloadJSON"] as? String, let data = payload.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = envelope["metadata"] as? [String: String], metadata["kind"] == "notification" else {
            throw NSError(domain: "NativeAgentNotification", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The notified record has no notification routing envelope."])
        }
        let copy = content.mutableCopy() as! UNMutableNotificationContent
        for key in ["itemId", "approvalId", "sessionId", "screen", "source", "eventId", "correlationId", "taskId"] {
            if let value = nonEmpty(metadata["userInfo.\(key)"]) { copy.userInfo[key] = value }
        }
        return categorized(copy)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return clean
    }
}

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
        UNUserNotificationCenter.current().setNotificationCategories(nativeAgentNotificationCategories(
            approvalCategory: approvalCategory, messageCategory: messageCategory,
            approve: approve, deny: deny, reply: reply, replyPlaceholder: "Message your agent"
        ))
    }

    static func categorized(_ content: UNNotificationContent) throws -> UNNotificationContent {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else {
            throw NSError(domain: "NativeAgentNotification", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Notification content could not be copied for routing."])
        }
        // The Mac's router names the conversation a knock came from as
        // `originSessionId`. A knock with no screen of its own opens that
        // conversation, with Reply, instead of the Activity queue.
        let screen = nonEmpty(copy.userInfo["screen"] as? String)
        if nonEmpty(copy.userInfo["sessionId"] as? String) == nil,
           nonEmpty(copy.userInfo["approvalId"] as? String) == nil,
           screen == nil || screen == "activity",
           let origin = nonEmpty(copy.userInfo["originSessionId"] as? String) {
            copy.userInfo["sessionId"] = origin
            copy.userInfo["screen"] = "chat"
        }
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
              let recordID = query.recordID else { return try categorized(content) }
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
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else {
            throw NSError(domain: "NativeAgentNotification", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Notification content could not be copied for routing."])
        }
        for key in ["itemId", "approvalId", "sessionId", "originSessionId", "screen", "source", "eventId", "correlationId", "taskId"] {
            if let value = nonEmpty(metadata["userInfo.\(key)"]) { copy.userInfo[key] = value }
        }
        return try categorized(copy)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return clean
    }
}

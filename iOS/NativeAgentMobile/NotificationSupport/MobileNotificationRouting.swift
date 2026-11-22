import CloudKit
import Foundation
import NativeAgentShared
import UserNotifications

/// Push hints carry no approval authority: decisions re-read the synced row and use signed Mac actions.
enum MobileNotificationRouting {
    static let approvalCategory = "nativeagent.mobile.approval"
    static let messageCategory = "nativeagent.mobile.message"
    static let approve = "nativeagent.mobile.approve"
    static let deny = "nativeagent.mobile.deny"
    static let reply = "nativeagent.mobile.reply"
    static let replyEnvelopeKey = "notificationReplyEnvelope"

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(nativeAgentNotificationCategories(
            approvalCategory: approvalCategory, messageCategory: messageCategory,
            approve: approve, deny: deny, reply: reply, replyPlaceholder: "Message your agent"
        ))
    }

    static func categorized(_ content: UNNotificationContent, replyEnvelope: String? = nil) throws -> UNNotificationContent {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else {
            throw NSError(domain: "NativeAgentNotification", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Notification content could not be copied for routing."])
        }
        // A knock without its own screen opens the conversation named by `originSessionId`.
        let screen = nonEmpty(copy.userInfo["screen"] as? String)
        if nonEmpty(copy.userInfo["sessionId"] as? String) == nil,
           nonEmpty(copy.userInfo["approvalId"] as? String) == nil,
           screen == nil || screen == "activity",
           let origin = nonEmpty(copy.userInfo["originSessionId"] as? String) {
            copy.userInfo["sessionId"] = origin
            copy.userInfo["screen"] = "chat"
        }
        copy.userInfo[replyEnvelopeKey] = replyEnvelope
        if nonEmpty(copy.userInfo["approvalId"] as? String) != nil {
            copy.categoryIdentifier = approvalCategory
        } else if nonEmpty(copy.userInfo["sessionId"] as? String) != nil {
            copy.categoryIdentifier = replyEnvelope != nil ? messageCategory : ""
        }
        return copy
    }

    /// CloudKit alerts omit action IDs; read the exact notified record's envelope, never choose a request by title or time.
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
              let payload = record["payloadJSON"] as? String,
              let envelope = try? decodeReplyEnvelope(payload), envelope.id == recordID.recordName,
              envelope.sender == "mac", let metadata = envelope.metadata, metadata["kind"] == "notification" else {
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
        // CloudKit's alert names only title and body; the envelope carries the subtitle the call gave.
        if let subtitle = nonEmpty(metadata["subtitle"]) { copy.subtitle = subtitle }
        // The extension has no pairing key. Carry the envelope for the app to authenticate before Reply.
        if replySession(metadata) != nil, let title = nonEmpty(metadata["title"]) {
            copy.title = title
            copy.body = envelope.text
            return try categorized(copy, replyEnvelope: payload)
        }
        return try categorized(copy)
    }

    static func decodeReplyEnvelope(_ payload: String) throws -> BridgeMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BridgeMessage.self, from: Data(payload.utf8))
    }

    static func replySession(_ metadata: [String: String]) -> String? {
        guard metadata["kind"] == "notification", nonEmpty(metadata[BridgeMessage.notificationPairingKey]) != nil,
              nonEmpty(metadata["userInfo.approvalId"]) == nil else { return nil }
        if let session = nonEmpty(metadata["userInfo.sessionId"]) { return session }
        let screen = nonEmpty(metadata["userInfo.screen"])
        return screen == nil || screen == "activity" ? nonEmpty(metadata["userInfo.originSessionId"]) : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return clean
    }
}

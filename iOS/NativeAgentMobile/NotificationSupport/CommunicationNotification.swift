import Foundation
import CloudKit
import Intents
import NativeAgentShared
import UIKit
import UserNotifications

enum NativeAgentRemoteNotificationPayload {
    static func string(
        directKey: String,
        cloudKitRecordKey: String,
        in userInfo: [AnyHashable: Any]
    ) -> String? {
        if let direct = nonEmpty(userInfo[directKey] as? String) {
            return direct
        }
        if let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
           let value = nonEmpty(query.recordFields?[cloudKitRecordKey] as? String) {
            return value
        }
        return nil
    }

    static func eventID(in userInfo: [AnyHashable: Any]) -> String? {
        let direct = string(directKey: "eventId", cloudKitRecordKey: "notificationEventId", in: userInfo)
        let nested = (userInfo["nativeagent"] as? [String: Any])?["eventId"] as? String
        return [direct, nested].compactMap { nonEmpty($0) }
            .first { NativeAgentDeviceEventIdentity.isCanonical($0) }?.lowercased()
    }

    static func matches(_ request: UNNotificationRequest, eventID: String) -> Bool {
        request.identifier == eventID
            || request.identifier == "nativeagent.event.\(eventID)"
            || self.eventID(in: request.content.userInfo) == eventID
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Shared by the app and its notification service extension. Only display
/// identity crosses the app group; pairing credentials stay in the Keychain.
enum CommunicationNotification {
    private static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NativeAgentNotificationGroup") as? String else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func remember(name: String, pairing: String) {
        defaults?.set(["name": name, "pairing": pairing], forKey: "sender")
    }

    static func forget() { defaults?.removeObject(forKey: "sender") }

    static func decorate(_ content: UNNotificationContent) async throws -> UNNotificationContent {
        guard let identity = defaults?.dictionary(forKey: "sender") as? [String: String],
              let name = identity["name"], let pairing = identity["pairing"] else {
            throw NSError(domain: "CommunicationNotification", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No paired sender identity has synced to this phone."])
        }
        // No persona avatar currently ships on iOS. Use it when supplied in
        // the shared resource catalog; never substitute the application icon.
        let avatar = UIImage(named: "AgentAvatar")?.pngData().map { INImage(imageData: $0) }
        let sender = INPerson(personHandle: INPersonHandle(value: "agent-\(pairing)", type: .unknown),
            nameComponents: nil, displayName: name, image: avatar, contactIdentifier: nil,
            customIdentifier: "agent-\(pairing)")
        let session = content.userInfo["sessionId"] as? String ?? "direct"
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
            content: content.body, speakableGroupName: nil,
            conversationIdentifier: "\(pairing)-\(session)", serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try await interaction.donate()
        return try content.updating(from: intent)
    }
}

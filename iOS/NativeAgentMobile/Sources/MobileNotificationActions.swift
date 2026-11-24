import Foundation
import NativeAgentShared
import UserNotifications
// Blueprint: | `MobileNotificationActions.swift` | `MobileNotificationActions` enum; `handle` |

enum MobileNotificationActions {
    struct Response: Sendable {
        let action: String
        let category: String
        let approvalID: String?
        let sessionID: String?
        let replyEnvelope: String?
        let text: String?
        init(_ response: UNNotificationResponse) {
            action = response.actionIdentifier
            let content = response.notification.request.content
            category = content.categoryIdentifier
            approvalID = content.userInfo["approvalId"] as? String
            sessionID = content.userInfo["sessionId"] as? String
            replyEnvelope = content.userInfo[MobileNotificationRouting.replyEnvelopeKey] as? String
            text = (response as? UNTextInputNotificationResponse)?.userText
        }
        var isAction: Bool {
            [MobileNotificationRouting.approve, MobileNotificationRouting.deny, MobileNotificationRouting.reply].contains(action)
        }
    }

    @MainActor
    static func handle(_ response: Response) async {
        do {
            switch (response.category, response.action) {
            case (MobileNotificationRouting.approvalCategory, MobileNotificationRouting.approve),
                 (MobileNotificationRouting.approvalCategory, MobileNotificationRouting.deny):
                open(screen: "approvals")
                guard let id = response.approvalID, !id.isEmpty else {
                    throw MobileIntentRuntime.failure("This notification does not identify an approval.")
                }
                let approve = response.action == MobileNotificationRouting.approve
                try await MobileIntentRuntime.decide(id: id, approve: approve)
                SystemToastCenter.shared.push(success: approve ? "Approved on your Mac." : "Declined on your Mac.")
            case (MobileNotificationRouting.messageCategory, MobileNotificationRouting.reply):
                guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MobileIntentRuntime.failure("The notification reply is empty.")
                }
                let store = ChatStore.shared
                await store.restorationTask?.value
                guard let secret = iCloudBridge.shared.pairingSecretForPhoneRequests,
                      let pairing = AgentNameCache.fingerprint(secret) else {
                    throw MobileIntentRuntime.failure("Connect this iPhone to a Mac before submitting a reply.")
                }
                guard let payload = response.replyEnvelope,
                      let envelope = try? MobileNotificationRouting.decodeReplyEnvelope(payload),
                      envelope.sender == "mac", envelope.verifySignature(secret: secret),
                      let metadata = envelope.metadata, metadata[BridgeMessage.notificationPairingKey] == pairing,
                      let session = MobileNotificationRouting.replySession(metadata),
                      session == response.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw MobileIntentRuntime.failure("This notification could not be verified for the current Mac pairing. Open Chat to start a new reply.")
                }
                open(screen: "chat", sessionID: session)
                let queued = QueuedChatSend(id: UUID(), sessionID: session, text: text,
                                            controls: .defaults, attachments: [], createdAt: Date(),
                                            pairingFingerprint: pairing)
                guard store.enqueueSend(queued) else {
                    throw MobileIntentRuntime.failure(store.errorBanner ?? "The chat queue is full.")
                }
                try await store.checkpointQueuedSend(queued.id)
                store.scheduleQueuedSendDrain()
                SystemToastCenter.shared.push(info: "Reply queued for your Mac.")
            default:
                throw MobileIntentRuntime.failure("This notification action is unavailable.")
            }
        } catch {
            SystemToastCenter.shared.push(error: error.localizedDescription, autoDismissAfter: nil)
        }
    }

    @MainActor
    private static func open(screen: String, sessionID: String? = nil) {
        NativeAgentNotificationLaunchIntent.stage(screen: screen, sessionID: sessionID)
        NotificationCenter.default.post(NativeAgentNotificationLaunchIntent.Staged())
    }
}

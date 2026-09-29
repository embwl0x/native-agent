import Foundation
import UserNotifications

enum MobileNotificationActions {
    struct Response: Sendable {
        let action: String
        let category: String
        let approvalID: String?
        let sessionID: String?
        let text: String?
        init(_ response: UNNotificationResponse) {
            action = response.actionIdentifier
            let content = response.notification.request.content
            category = content.categoryIdentifier
            approvalID = content.userInfo["approvalId"] as? String
            sessionID = content.userInfo["sessionId"] as? String
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
                iOSSystemToastCenter.shared.push(success: approve ? "Approved on your Mac." : "Denied on your Mac.")
            case (MobileNotificationRouting.messageCategory, MobileNotificationRouting.reply):
                guard let session = response.sessionID, !session.isEmpty,
                      let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MobileIntentRuntime.failure("This notification has no conversation or the reply is empty.")
                }
                open(screen: "chat", sessionID: session)
                try MobileIntentRuntime.prepare()
                _ = try await MacBridgeClient().sendMessage(text, sessionID: session)
                iOSSystemToastCenter.shared.push(info: "Reply sent. Waiting for your Mac.")
            default:
                throw MobileIntentRuntime.failure("This notification action is unavailable.")
            }
        } catch {
            iOSSystemToastCenter.shared.push(error: error.localizedDescription, autoDismissAfter: nil)
        }
    }

    @MainActor
    private static func open(screen: String, sessionID: String? = nil) {
        MobileNotifiedChatSessionIntent.stage(sessionID)
        NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: screen)
        NotificationCenter.default.post(name: .nativeagentOpenActivity, object: nil, userInfo: ["screen": screen])
    }
}

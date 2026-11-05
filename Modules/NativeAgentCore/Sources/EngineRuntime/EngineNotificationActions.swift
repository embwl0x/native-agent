import Foundation
import AttentionRouting
import ApprovalTransactions
import NativeAgentCore
// Blueprint: | `EngineNotificationActions.swift` | `NativeAgentEngine.handleNotificationAction`; Authenticated native response admission |

extension NativeAgentEngine {
    /// Authenticated notifications must share visible buttons’ approval execution and composer admission.
    @MainActor
    public func handleNotificationAction(
        _ response: NativeAgentNotificationActions.Response,
        showApprovals: () -> Void,
        openConversation: (String) async -> Void,
        resolveApproval: (String, String) async -> String?,
        startChatTurn: (String, String) async -> String?
    ) async throws {
        switch (response.category, response.action) {
        case (NativeAgentNotificationActions.approvalCategory, NativeAgentNotificationActions.approve), (NativeAgentNotificationActions.approvalCategory,
            NativeAgentNotificationActions.deny):
            guard let id = response.approvalID, !id.isEmpty else {
                throw actionError("Approvals are not ready. Open NativeAgent to review the request.")
            }
            showApprovals()
            // Payload is never authority; re-read the exact row and use the buttons’ executor and outcome UI.
            guard let record = try await self.approvals.list().first(where: { $0.id == id }),
                  record.status == "pending" else {
                throw actionError("This approval is no longer pending.")
            }
            guard ApprovalChatCards.canResolve(record) else {
                throw actionError(ApprovalChatCards.unavailableText)
            }
            if let failure = await resolveApproval(id, response.action == NativeAgentNotificationActions.approve ? "approved" : "denied") {
                throw actionError(failure)
            }
        case (NativeAgentNotificationActions.messageCategory, NativeAgentNotificationActions.reply):
            guard let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw actionError("Chat is not ready or the reply is empty. Open NativeAgent to reply.")
            }
            let sessionID: String
            let turnText: String
            if response.newConversation {
                sessionID = try await self.transcripts.create(title: "Notification reply").id
                turnText = """
                I'm replying to this notification:
                \(response.title)
                \(response.body)

                My reply: \(text)
                """
            } else if let id = response.sessionID,
                  NativeAgentChatSessionID.normalizedPathComponent(id) == id {
                sessionID = id
                turnText = text
            } else {
                throw actionError("The notification has no valid conversation.")
            }
            await openConversation(sessionID)
            // The composer owns admission, queueing, routing and Trust; a notification cannot overlap its still-sending turn.
            if let message = await startChatTurn(turnText, sessionID) {
                throw actionError(message)
            }
        default:
            return
        }
    }
}

private func actionError(_ message: String) -> NSError {
    NSError(domain: "NativeAgentNotification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

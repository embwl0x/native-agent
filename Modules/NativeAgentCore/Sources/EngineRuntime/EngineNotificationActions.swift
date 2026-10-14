import Foundation
import AttentionRouting
import ApprovalTransactions
import NativeAgentCore

extension NativeAgentEngine {
    /// Invoked by the authenticated native response entry; effects use the same
    /// approval executor and composer admission as the visible buttons.
    @MainActor
    public func handleNotificationAction(
        _ response: NativeAgentNotificationActions.Response,
        showApprovals: () -> Void,
        openConversation: (String) async -> Void,
        resolveApproval: (String, String) async -> String?,
        startChatTurn: (String, String) async -> String?
    ) async throws {
        switch (response.category, response.action) {
        case (NativeAgentNotificationActions.approvalCategory, NativeAgentNotificationActions.approve), (NativeAgentNotificationActions.approvalCategory, NativeAgentNotificationActions.deny):
            guard let id = response.approvalID, !id.isEmpty else {
                throw actionError("Approvals are not ready. Open NativeAgent to review the request.")
            }
            showApprovals()
            // Never treat the delivered payload as authority. Re-read the
            // exact row and use the same executor and outcome UI as buttons.
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
            // The composer owns admission, the busy-session queue, provider
            // routing, and Trust. A notification cannot start a second turn
            // over the one that is still sending its banner.
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

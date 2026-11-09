import AgentConversations
import AgentLinkTransport
import ChatTurnRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
// Blueprint: | `AgentContactHeldAnswer.swift` | `AgentContactHeldAnswer`: a contact's answer held as its one send row for the conversation store to deliver |

/// Holding needs no open turn: persist the contact's one send row, then hand delivery to the conversation store every door drains.
public enum AgentContactHeldAnswer {
    package static func complete(dataRoot: URL, peer: AgentPeerContact, session: String, deliveryID: String, requestDigest: String,
                                 response: ChatResponse, client: SwiftNativeChatOrchestrationClient, turn: Turn,
                                 lifecycle: CodexCompletionLifecycle) async throws {
        let outcome: Result<Void, Error> = await settle {
            do {
                guard response.terminalState == .completed else {
                    throw StandingBotsError.invalidValue("The contact's arrival turn did not complete; its saved partial answer was not held as a result.")
                }
                if !response.isSilentCompletion {
                    try await hold(dataRoot: dataRoot, peer: peer, session: session, deliveryID: deliveryID,
                        response: response, reusingCompletion: true, client: client, turn: turn)
                }
                try await lifecycle.recordDelivery(.init(status: "completed", surface: AgentConversationStore.heldReplySurface,
                    delivery: response.isSilentCompletion ? "silence" : "held_for_contact", artifactCount: response.isSilentCompletion ? 0 : 1,
                    attempts: 0, reason: response.isSilentCompletion ? "The agent chose to end silently." : "The contact's held exchange owns delivery."),
                    deliveryId: deliveryID, requestDigest: requestDigest)
                return .success(())
            } catch { return .failure(error) }
        }
        try outcome.get()
    }

    public static func hold(dataRoot: URL, peer: AgentPeerContact, session: String, deliveryID: String,
                            response: ChatResponse, reusingCompletion: Bool = false,
                            client: SwiftNativeChatOrchestrationClient, turn: Turn) async throws {
        guard !deliveryID.isEmpty, session.hasPrefix(ContactThread.prefix(owner: peer.id)) else {
            throw StandingBotsError.invalidValue("A held answer requires its delivery identity and exact contact conversation.")
        }
        let sendID = AgentBridgeCompletionRouter.stableUUID(deliveryID)
        let store = AgentConversationStore(dataRoot: dataRoot)
        let existing = try store.recordsUnlocked().filter { (($0.exchanges ?? []) + ($0.releasing ?? [])).contains { $0.id == sendID } }
        if !existing.isEmpty {
            guard existing.count == 1, existing[0].agent == "peer:" + peer.id else {
                throw StandingBotsError.invalidValue("The held answer's identity belongs to an ambiguous contact record.")
            }
            return
        }
        if let cut = response.workingCommentaryCharacters, cut < 0 || cut > response.output.count {
            throw StandingBotsError.invalidValue("The answer's commentary boundary is unreadable; nothing was held.")
        }
        let paths = try (response.attachments ?? []).map { attachment -> String in
            guard let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                throw StandingBotsError.invalidValue("A held answer attachment has no saved file reference; nothing was held.")
            }
            return path
        }
        let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
        let text = AgentConversationStore.heldText(answer, filePaths: paths)
        try AgentConversationStore.validateHeldText(text)
        let saved = try ContactThread.lines(dataRoot: dataRoot, owner: peer.id).filter { $0.sendID == sendID && $0.mine }
        if saved.isEmpty {
            try await client.appendAgentConversationSend(sessionID: session, text: text, clientUserMessageID: sendID,
                reusingCompletionID: reusingCompletion ? deliveryID : nil, turn: turn)
        }
        try store.holdReply(peer: peer, session: session, sendID: sendID, text: text)
    }
}


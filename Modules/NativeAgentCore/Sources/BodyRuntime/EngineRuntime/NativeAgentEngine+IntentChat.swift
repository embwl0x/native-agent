import MindCore
import NativeAgentCore
import Foundation
import NativeAgentShared
import MacNerves
import ProviderRouting
import SenseCore

// Blueprint: | `NativeAgentEngine+IntentChat.swift` | `NativeAgentEngine.replyToIntent`; Capture location before queue admission |

extension NativeAgentEngine {
    public func replyToIntent(_ message: String) async throws -> String {
        let snapshot = try await providers.routing.checkedProviderSnapshot()
        guard let selection = snapshot.routing.preferences["chat"] else {
            throw ProviderRoutingError.underlying("canonical routing snapshot is incomplete")
        }
        let sessionID = try SwiftNativeChatOrchestrationClient.resolveSessionId(
            ConversationAnchor.currentSessionId() ?? UUID().uuidString
        )
        _ = try? await ConversationAnchor.publish(
            sessionId: sessionID, source: "siri", conversationKind: .direct
        )
        // Capture the user’s prior session before entering the shared queue.
        let takeover = await MacWorkContinuation.admit(message)
        var turn = Turn(dataRoot: dataRoot, session: sessionID)
        turn.envelope = .native("intent:chat")
        turn.macContinuation = takeover
        if let takeover { turn.envelope = turn.envelope?.withMacContinuation(takeover) }
        let admitted = try await TurnAdmission.shared.run(dataRoot: dataRoot, sessionID: sessionID,
            arrival: TurnArrival(words: message, surface: "chat", row: .shown), turn: turn) { turn in
            try await TurnRequest(
                message: message,
                sessionID: sessionID,
                model: selection.model,
                reasoningEffort: selection.reasoningEffort,
                fileAccess: "auto",
                attachments: [],
                persona: nil,
                surface: "chat",
                suppressUserAppend: false,
                replacementAssistantMessageID: nil,
                serviceTier: selection.serviceTier,
                threadKind: .direct
            ).chat(on: self.chatClient(profile: .mac), parent: turn)
        }
        switch admitted {
        case .ran(let reply): return reply.output
        // The agent's turn in progress read it; its reply in the conversation answers it.
        case .steered: return "\(AgentVoice.live.Subject) \(AgentVoice.live.verb("be")) taking that into the work in progress now."
        }
    }
}

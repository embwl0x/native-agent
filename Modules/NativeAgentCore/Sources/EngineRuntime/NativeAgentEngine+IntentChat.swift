import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import Foundation
import NativeAgentShared
import MacControl
import ProviderRouting
import Transcripts

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
        var turn = Turn(session: sessionID)
        turn.envelope = .personOnMac("siri:chat")
        turn.macContinuation = takeover
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

import ChatTurnRuntime
import Foundation
import MacControl
import ProviderRouting
import Transcripts

// Blueprint: | `NativeAgentEngine+IntentChat.swift` | `NativeAgentEngine.replyToIntent`: captures the person's location before shared chat queue admission; chat applies the saved choice |

extension NativeAgentEngine {
    public func replyToIntent(_ message: String) async throws -> String {
        let snapshot: ProvidersFacade.SettingsSnapshot
        switch await providers.refreshSettings(refreshCatalog: false, cause: { error, _ in error.localizedDescription }) {
        case .loaded(let read): snapshot = read
        case .failed(let detail): throw ProviderRoutingError.underlying(detail)
        }
        let selection = try ProvidersFacade.modelRoutingConfig(from: snapshot.routing).current.chat
        let sessionID = try SwiftNativeChatOrchestrationClient.resolveSessionId(
            ConversationAnchor.currentSessionId() ?? UUID().uuidString
        )
        _ = try? await ConversationAnchor.publish(
            sessionId: sessionID, source: "siri", conversationKind: .direct
        )
        // Capture where User was before entering the shared session queue.
        let takeover = await MacWorkContinuation.admit(message)
        let reply = try await MacWorkContinuation.$current.withValue(takeover) {
            try await TurnAdmission.shared.run(sessionID: sessionID) {
                try await TurnRequest(
                    message: message,
                    sessionID: sessionID,
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    // The saved choice is applied by the chat itself.
                    fileAccess: "auto",
                    attachments: [],
                    persona: nil,
                    surface: "chat",
                    suppressUserAppend: false,
                    replacementAssistantMessageID: nil,
                    serviceTier: selection.serviceTier
                ).chat(on: self.chatClient(profile: .mac))
            }
        }
        return reply.output
    }
}

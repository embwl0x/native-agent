import ChatOrchestration
import Foundation
import MacControl
import Transcripts

extension NativeAgentEngine {
    public func replyToIntent(_ message: String) async throws -> String {
        // No pick means no pick; the chat surface resolves an empty model.
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? ""
        let reasoningEffort = UserDefaults.standard.string(forKey: "chatReasoningEffort") ?? "high"
        let fileAccess = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"
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
                    model: model,
                    reasoningEffort: reasoningEffort,
                    fileAccess: fileAccess,
                    attachments: [],
                    persona: nil,
                    surface: "chat",
                    suppressUserAppend: false,
                    replacementAssistantMessageID: nil,
                    serviceTier: NativeChatTurnOptions.current(surface: "chat").serviceTier
                ).chat(on: self.chatClient(profile: .mac))
            }
        }
        return reply.output
    }
}

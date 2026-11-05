import AgentWorkspace
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import Transcripts
import ChatToolRuntime
// Blueprint: | `ChatOrchestrationClient+HumanConversationReply.swift` | `SwiftNativeChatOrchestrationClient`; `appendHumanConversationReply` |

extension SwiftNativeChatOrchestrationClient {
    /// The caller must hold an at-most-once durable claim before a tool-authored reply is delivered without a provider turn.
    public func appendHumanConversationReply(sessionID: String, expectedLastMessageID: String,
                                            text: String, runID: String, turn: Turn) async throws {
        let snapshot = try await HumanConversationReader.read(sessionID: sessionID, dataRoot: dataRoot)
        guard snapshot.complete, snapshot.lastMessageID == expectedLastMessageID,
              let envelope = snapshot.route, HumanConversationReader.routeAvailable(envelope),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 16000 else {
            throw AutonomyGateError.toolDenied(reason: "The conversation changed or its destination is unavailable. Reopen it before replying.")
        }
        // Only use delivery provenance from the selected conversation; current-turn trust remains
        // in the outer dispatcher. The historical envelope never authorizes a tool.
        try await holding(turn.with(\.envelope, envelope)) { turn in
            try await holding(turn.with(\.envelope, envelope.withDeliveryRoute(envelope.replyRoute))) { turn in
                try await appendMessage(sessionId: sessionID, role: "assistant", content: text,
                                        runId: runID, attachments: [], source: ChatThreadKind.transcriptSource(surface: envelope.surface),
                                        expectedLastMessageID: expectedLastMessageID,
                                        answerFor: runID, messageId: runID, turn: turn)
            }
        }
    }
}

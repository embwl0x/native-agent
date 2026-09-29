import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ChatToolRuntime

extension SwiftNativeChatOrchestrationClient {
    /// Explicit tool-authored assistant reply. No user turn, provider run, or proactive timer.
    /// Caller owns an at-most-once durable claim before invoking this boundary.
    public func appendHumanConversationReply(sessionID: String, expectedLastMessageID: String,
                                            text: String, runID: String) async throws {
        let snapshot = try await HumanConversationReader.read(sessionID: sessionID, dataRoot: dataRoot)
        guard snapshot.complete, snapshot.lastMessageID == expectedLastMessageID,
              HumanConversationReader.routeAvailable(snapshot.route),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 16000 else {
            throw AutonomyGateError.toolDenied(reason: "The conversation changed or its destination is unavailable. Reopen it before replying.")
        }
        // Only use delivery provenance from the selected conversation; current-turn trust remains
        // in the outer dispatcher. The historical envelope never authorizes a tool.
        try await ChatToolSessionContext.$envelope.withValue(snapshot.route) {
            let route = snapshot.route!.replyRoute
            try await ChatToolSessionContext.$replyRoute.withValue(route) {
                try await TurnTraceContext.$destinationId.withValue(route.destinationId) {
                    try await TurnTraceContext.$threadId.withValue(route.threadId) {
                        try await appendMessage(sessionId: sessionID, role: "assistant", content: text,
                                                runId: runID, attachments: [], source: snapshot.route!.surface,
                                                expectedLastMessageID: expectedLastMessageID)
                    }
                }
            }
        }
    }
}

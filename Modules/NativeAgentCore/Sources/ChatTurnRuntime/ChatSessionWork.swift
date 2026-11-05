@_exported import ChatSessionWork
import Foundation
import NativeAgentCore
import NativeAgentShared
import Transcripts
import ProviderRouting
import ChatToolRuntime
// Blueprint: | `ChatSessionWork.swift` | `ChatSessionWork`; `SwiftNativeChatOrchestrationClient`; Bind the composed request tail fitting to its turn |

extension SwiftNativeChatOrchestrationClient {
    func withSessionContextMeasurement<T: Sendable>(sessionId: String, model: String, providerID: String?,
        surface: String, runId: String, progress: TurnEventSink?,
        nextTurnOutputBudgetTokens: Int? = nil,
        turn: Turn, work: ChatTurnWork,
        _ body: (ChatTurnWork) async throws -> T) async throws -> T {
        let fit: SessionRequestFit.Handler = { [self] context, codec, additional in
            try await self.fitSessionRequest(context, codec: codec, additionalMessages: additional, sessionId: sessionId,
                surface: surface, runId: runId, progress: progress, turn: turn)
        }
        return try await body(work.with(\.fit, fit))
    }
}

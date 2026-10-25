import Foundation
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
import PersistenceCore
import CognitiveSubstrate
// Blueprint: | `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`: `chat` supplies explicit provider choice, aggregate token budget and mechanical-row provenance; ordinary turns settle without requiring a token budget |

extension SwiftNativeChatOrchestrationClient {
    /// Explicit picker and one aggregate output allowance, scoped to this turn.
    /// `choice` nil means the same route Chat uses: the agent's own model.
    /// `mechanicalRow` stamps BOTH automatic transcript writes of this
    /// invocation — the brief and the reply — with the provenance the caller
    /// names. Nil is the ordinary case.
    public func chat(message: String, sessionId: String, choice: ProviderTurnChoice?,
                     tokenLimit: Int, surface: String,
                     fileAccess: String = "auto", suppressUserAppend: Bool = false,
                     mechanicalRow: CognitiveMechanicalRowKind? = nil,
                     progress: ChatOrchestrationProgressHandler? = nil) async throws -> ChatResponse {
        guard tokenLimit > 0 else { throw ChatOrchestrationError.underlying("The turn token limit must be positive.") }
        let budget = TurnTokenBudget(tokens: tokenLimit)
        let execution = ChatTurnExecution(mechanicalRow: mechanicalRow)
        return try await ProviderTurnChoice.$current.withValue(choice) {
        try await LLMCallContext.$turnTokenBudget.withValue(budget) {
        try await ChatTurnExecution.$current.withValue(execution) {
        try await LLMCallContext.$toolCapabilityNote.withValue({ execution.keepCapabilityNote($0) }) {
            var response = try await chatExecution(message: message, sessionId: sessionId, model: choice?.model ?? "",
                reasoningEffort: choice?.reasoningEffort ?? "", fileAccess: fileAccess, attachments: [], persona: nil,
                surface: surface, suppressUserAppend: suppressUserAppend, progress: progress).response
            response.runtimeStatus = response.runtimeStatus ?? response.terminalState?.rawValue
            return response
        }
        }
        }
        }
    }
}

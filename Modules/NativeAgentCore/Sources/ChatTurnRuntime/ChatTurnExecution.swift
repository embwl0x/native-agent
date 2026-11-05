import Foundation
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
import PersistenceCore
import CognitiveSubstrate
// Blueprint: | `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`; `chat`; Explicit route, budget and mechanical provenance |

extension SwiftNativeChatOrchestrationClient {
    /// Nil choice uses Chat's admitted route. One aggregate output allowance spans the turn.
    /// The caller's mechanical provenance stamps both brief and reply; nil leaves ordinary conversational rows.
    public func chat(message: String, sessionId: String, choice: ProviderTurnChoice?,
                     tokenLimit: Int, surface: String,
                     fileAccess: String = "auto", suppressUserAppend: Bool = false,
                     mechanicalRow: CognitiveMechanicalRowKind? = nil,
                     progress: TurnEventSink? = nil, turn: Turn, work: ChatTurnWork = .init()) async throws -> ChatResponse {
        guard tokenLimit > 0 else { throw ChatOrchestrationError.underlying("The turn token limit must be positive.") }
        let budget = TurnTokenBudget(tokens: tokenLimit)
        let execution = ChatTurnExecution(mechanicalRow: mechanicalRow)
        return try await holding(turn.with(\.providerChoice, choice)) { turn in
        try await holding(turn.with(\.tokenBudget, budget)) { turn in
        try await holding(turn.with(\.execution, execution)) { turn in
        try await holding(turn.with(\.capabilityNote, { execution.keepCapabilityNote($0) })) { turn in
            var response = try await chatExecution(message: message, sessionId: sessionId, model: choice?.model ?? "",
                reasoningEffort: choice?.reasoningEffort ?? "", fileAccess: fileAccess, attachments: [], persona: nil,
                surface: surface, suppressUserAppend: suppressUserAppend, progress: progress, turn: turn, work: work).response
            response.runtimeStatus = response.runtimeStatus ?? response.terminalState?.rawValue
            return response
        }
        }
        }
        }
    }
}

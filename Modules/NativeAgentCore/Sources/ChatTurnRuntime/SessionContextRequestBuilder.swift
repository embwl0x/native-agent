import Foundation
import NativeAgentCore
import NativeAgentShared
import ChatSessionWork
import PersistenceCore
import ProviderRouting
import TurnTrace
// Blueprint: | `SessionContextRequestBuilder.swift` | Fit the already-read replay at transcript-anchored half-budget checkpoints. |

enum SessionRequestFit {
    typealias Handler = @Sendable (TurnContext, ToolCallCodec, [LLMMessage]) async throws -> TurnContext
}

extension SwiftNativeChatOrchestrationClient {
    func fitSessionRequest(_ context: TurnContext, codec: ToolCallCodec, additionalMessages: [LLMMessage] = [],
        sessionId: String, surface: String, runId: String, progress: TurnEventSink?,
        turn: Turn
    ) async throws -> TurnContext {
        guard context.historyReplaySpec != nil,
              let window = ContextBudgetPolicy.windowTokens(forModel: context.modelId,
                providerID: context.providerId, dataRoot: dataRoot) else {
            throw ProviderRoutingError.configurationFailed("This request's replay builder or detected context window is unavailable.")
        }
        let call = LLMCall(turn: turn, surface: surface, purpose: "context_window", session: sessionId)
        func measure(_ context: TurnContext) async throws -> SessionContextMeasurement {
            let request = try ConversationPrefixSeeding.request(context, codec: codec, turn: turn).appending(additionalMessages)
            return try await SessionContextMeasurement.measure(try request.measurement, sessionId: sessionId,
                model: context.modelId, providerID: context.providerId, dataRoot: dataRoot, windowTokens: window, call: call)
        }
        let before = try await measure(context)
        guard before.tokens > max(0, window - before.outputTokens) else { return context }
        guard let tail = context.historyReplaySpec?.historySnapshot else {
            guard context.historyMessages.isEmpty else {
                throw ProviderRoutingError.configurationFailed("This request's admitted history snapshot is unavailable.")
            }
            return context
        }
        let halfBudget = SessionHistoryTail.halfBudgetCharacters(windowTokens: window, outputTokens: before.outputTokens)
        var next = context
        var after = before
        var selected: SessionHistoryTail.Checkpoint?
        let retainedCharacters = context.historyRowCharacters.values.reduce(0, +)
        // Earlier checkpoints cannot restore rows already dropped from this in-flight request.
        for checkpoint in tail.checkpoints(halfBudgetCharacters: halfBudget)
            where checkpoint.characters > tail.characters - retainedCharacters {
            let projected = tail.project(after: checkpoint)
            next.historyMessages = projected.messages
            next.replayedTurnContexts = projected.replayedContexts
            next.historyContextWindow = projected.contextWindow
            next.historyRowCharacters = projected.rowCharacters
            after = try await measure(next)
            selected = checkpoint
            if after.tokens <= max(0, window - after.outputTokens) { break }
        }
        if let selected {
            TurnTraceBus.fireFromContext(kind: "context.tail.cut", sessionId: sessionId, surface: surface, payload: .object([
                "inputTokensBefore": .int(Int64(before.tokens)), "inputTokensAfter": .int(Int64(after.tokens)),
                "windowTokens": .int(Int64(window)), "outputTokens": .int(Int64(after.outputTokens)),
                "halfBudgetCharacters": .int(Int64(halfBudget)), "checkpointThresholdCharacters": .int(Int64(selected.threshold)),
                "previousTurnStartCharacters": .int(Int64(selected.previousCharacters)),
                "droppedCharacters": .int(Int64(selected.characters)), "transcriptCharacters": .int(Int64(tail.characters)),
                "droppedRows": .int(Int64(selected.row)), "retainedRows": .int(Int64(tail.rowCount - selected.row)),
                "source": .string(after.source)
            ]), turn: turn)
        }
        return next
    }
}

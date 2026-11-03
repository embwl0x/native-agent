import Foundation
import NativeAgentCore
import NativeAgentShared
import ChatSessionWork
import ProviderRouting
import os
// Blueprint: | `SessionContextRequestBuilder.swift` | Fits the already-composed real request by rebuilding only its replay prefix through the canonical pure builder, then refuses measured over-window requests; no facts, contact consumption or digest work during candidate sizing |

enum SessionRequestFit {
    typealias Handler = @Sendable (TurnContext, ToolCallCodec, [LLMMessage]) async throws -> TurnContext
    @TaskLocal static var current: Handler?
}

extension SwiftNativeChatOrchestrationClient {
    func fitSessionRequest(_ context: TurnContext, codec: ToolCallCodec, additionalMessages: [LLMMessage] = [],
        sessionId: String, surface: String, runId: String, progress: TurnEventSink?
    ) async throws -> TurnContext {
        guard let replay = context.historyReplaySpec else {
            throw ProviderRoutingError.configurationFailed("This request's replay builder or detected context window is unavailable.")
        }
        let root = dataRoot
        let prepared = OSAllocatedUnfairLock<TurnContext?>(initialState: nil)
        let builder: SessionContextRequest.Builder = { rows, window, _ in
            let history = try await replay.project(rows, sessionId: sessionId, dataRoot: root, windowTokens: window)
            var next = context
            next.historyMessages = history.messages
            next.replayedTurnContexts = history.replayedContexts
            next.historyContextWindow = history.contextWindow
            next.historyRowCharacters = history.rowCharacters
            let request = try ConversationPrefixSeeding.request(next, codec: codec).appending(additionalMessages)
            let fitted = next
            prepared.withLock { $0 = fitted }
            return try request.measurement
        }
        let outcome = try await compactSession(sessionId: sessionId, model: context.modelId,
            surface: surface, runId: runId, providerID: context.providerId,
            trigger: "auto_threshold", force: false, progress: progress, requestBuilder: builder)
        let next: TurnContext
        if let fitted = prepared.withLock({ $0 }) { next = fitted }
        else {
            guard !outcome.compacted, outcome.summaryRowId == nil else {
                throw ProviderRoutingError.configurationFailed("Compaction did not produce a measured request after its fold.")
            }
            // Empty preparation never entered selection and changed no request.
            next = context
        }
        let request = try ConversationPrefixSeeding.request(next, codec: codec).appending(additionalMessages)
        try await SessionContextMeasurement.requireFits(try request.measurement, sessionId: sessionId,
            model: next.modelId, providerID: next.providerId, dataRoot: root,
            windowTokens: ContextBudgetPolicy.windowTokens(forModel: next.modelId,
                providerID: next.providerId, dataRoot: root))
        return next
    }
}

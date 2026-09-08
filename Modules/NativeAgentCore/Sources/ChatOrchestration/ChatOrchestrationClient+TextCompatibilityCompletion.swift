import Foundation
import PersistenceCore

extension SwiftNativeChatOrchestrationClient {
    func persistTextCompatibilityCompletion(
        finalResult: TurnEngineResult?,
        accumulated: String,
        resolvedSession: String,
        runId: String,
        message: String,
        persona: String?,
        surface: String,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) async {
        let replyText = finalResult?.reply ?? accumulated
        if !replyText.isEmpty {
            do {
                let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
                    from: finalResult?.toolDispatches ?? [],
                    dataRoot: dataRoot
                )
                try await appendMessage(
                    sessionId: resolvedSession,
                    role: "assistant",
                    content: replyText,
                    runId: runId,
                    attachments: generatedAttachments,
                    persona: persona,
                    source: surface,
                    recalledMemoryIds: finalResult?.recalledIds ?? [],
                    canonicalAssistantCompletion: true,
                    outcomeResult: finalResult,
                    outcomeContext: nil,
                    outcomeTurnID: TurnTraceContext.turnId ?? runId,
                    outcomeInterventionAssignment: nil
                )
                if let finalResult {
                    emitMetacognitiveTerminalTrace(
                        turnId: TurnTraceContext.turnId ?? runId,
                        sessionId: resolvedSession,
                        surface: surface,
                        context: nil,
                        result: finalResult
                    )
                }
            } catch {
                continuation.yield(.error("persist assistant turn failed: \(error)"))
            }
            if promoter != nil {
                // Sweep item 35: this lane terminates Claude turns without
                // going through `finishCompletedTurn`, so it must hand the
                // promoter its own tool evidence or the projection is dead
                // on the surface Agent actually talks on. Through the engine's
                // observer (2026-09-02) so this lane emits the same
                // memory.promotion stage — with the moment outcome — as the
                // tool-loop lane; before, the surface she actually talks on
                // left no receipt at all.
                await engine.observeMemoryPromotion(
                    userMessage: message,
                    assistantMessage: replyText,
                    toolDispatches: finalResult?.toolDispatches ?? [],
                    sessionId: resolvedSession,
                    surface: surface
                )
            }
        }
    }
}

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
        // THE FINAL WINS. `accumulated` is the raw running text of the rounds,
        // and on this lane it can still hold the model's own
        // `<tool_use name="…">{}</tool_use>` — which is protocol, not prose. A
        // turn whose model went straight to a tool persisted that marker as the
        // assistant's answer and the person read it as Agent speaking (Agent,
        // 2026-09-13). The fallback is kept for the case where there is no
        // final at all, but it is stripped to its visible prefix first, exactly
        // as the Mac UI shows it.
        let replyText = finalResult?.reply ?? ToolCallParser.visiblePrefix(
            in: ToolCallParser.stripToolUseMarkers(accumulated), invoke: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // The row the conversation keeps is not always the reply the transport
        // gets: a turn that ended waiting on a card persists the one-sentence
        // card-lane prose, because the card itself is persisted right beneath
        // it. The long compat sentence is for the routes that cannot draw one.
        let transcriptText = ChatTurnExecution.transcriptReply(replyText)
        if !transcriptText.isEmpty {
            do {
                let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
                    from: finalResult?.toolDispatches ?? [],
                    dataRoot: dataRoot
                )
                try await appendMessage(
                    sessionId: resolvedSession,
                    role: "assistant",
                    content: transcriptText,
                    runId: runId,
                    attachments: generatedAttachments,
                    persona: persona,
                    source: surface,
                    recalledMemoryIds: finalResult?.recalledIds ?? [],
                    canonicalAssistantCompletion: true,
                    outcomeResult: finalResult,
                    outcomeContext: nil,
                    outcomeTurnID: TurnTraceContext.turnId ?? runId,
                    outcomeInterventionAssignment: nil,
                    mechanicalRow: ChatTurnExecution.transcriptReplyIsCardLane ? .cardLane : ChatTurnExecution.transcriptRowKind
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
                // 2026-09-14 (User: "Agent is working" stayed up long after
                // she finished): this lane still AWAITED the promotion in
                // front of `continuation.finish()`, so the Mac working card
                // sat on the two memory calls (8 s tonight) after the reply
                // was on screen. Same shape as the structured lane: the
                // assistant row is durable at this point, so capture and
                // START the promotion here and let the stream close. The
                // retained task runs to completion on its own.
                let ticket = await engine.deferMemoryPromotion(
                    userMessage: message,
                    assistantMessage: transcriptText,
                    toolDispatches: finalResult?.toolDispatches ?? [],
                    sessionId: resolvedSession,
                    surface: surface
                )
                await engine.startDeferredMemoryPromotion(ticket: ticket)
            }
        }
    }
}

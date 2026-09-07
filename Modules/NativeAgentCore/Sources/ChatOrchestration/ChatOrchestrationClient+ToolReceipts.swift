import Foundation
import NativeAgentCore
import PersistenceCore

/// One tool receipt on its way to the transcript, fully redacted at the
/// point of production so the writer can drain the queue off the dispatch
/// critical path without touching turn state (A2). Every field is a value
/// type: the writer is a separate task, and the row must be complete before
/// it leaves the dispatch loop.
struct TextCompatToolReceipt: Sendable {
    let toolName: String
    let inputJSON: String
    let resultJSON: String
    let ok: Bool
    let redactedResult: JSONValue
}

extension SwiftNativeChatOrchestrationClient {
    /// Drain in call order inside the caller's existing writer task. A failed
    /// row reports its notice and does not prevent later rows from being saved.
    func writeTextCompatToolReceipts(
        _ receiptRows: AsyncStream<TextCompatToolReceipt>,
        resolvedSession: String,
        runId: String,
        surface: String,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) async {
        for await row in receiptRows {
            do {
                try await self.appendToolMessage(
                    sessionId: resolvedSession,
                    runId: runId,
                    toolName: row.toolName,
                    inputJSON: row.inputJSON,
                    resultSummary: row.resultJSON,
                    ok: row.ok,
                    cognitiveResult: ChatToolOutcome.cognitiveResult(
                        tool: row.toolName,
                        output: row.redactedResult
                    ),
                    source: surface
                )
            } catch {
                // M2 completion (gpt-5.5 review HIGH, 2026-07-09): the
                // sweep fixed the structured path and missed this
                // text-compat twin — the same dropped-receipt silent
                // loss, same fail-loud remedy.
                await Self.reportTranscriptWriteFailure(
                    label: "appendToolMessage(\(row.toolName)) [text-compat]",
                    path: self.dataRoot,
                    error: error,
                    userText: "Couldn't save the receipt for tool '\(row.toolName)' - it won't appear in the saved transcript.",
                    onNotice: { kind, text in continuation.yield(.notice(kind: kind, text: text)) }
                )
            }
        }
    }
}

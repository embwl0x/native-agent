import Foundation
import NativeAgentCore
import PersistenceCore

/// One tool receipt on its way to the transcript, fully redacted at the
/// point of production so the writer can drain the queue off the dispatch
/// critical path without touching turn state (A2). Every field is a value
/// type: the writer is a separate task, and the row must be complete before
/// it leaves the dispatch loop.
struct ToolReceipt: Sendable {
    let toolName: String
    let inputJSON: String
    let resultJSON: String
    let ok: Bool
    /// What the cognitive tool event is read from — the lane's own choice of
    /// raw or redacted output, kept exactly as each lane had it.
    let cognitiveOutput: JSONValue
}

/// The one writer of tool receipts to the transcript, for every lane. A
/// failed row reports its notice (M2 fail-loud: silent receipt loss is a
/// previously-fixed bug class) and never prevents later rows from being
/// saved. The loop `write`s each receipt as its result lands, awaited in its
/// progress handler.
struct ToolReceiptWriter: Sendable {
    let client: SwiftNativeChatOrchestrationClient
    let sessionId: String
    let runId: String
    let surface: String
    /// Names the lane in a failed write's log line.
    let laneLabel: String
    let onNotice: @Sendable (String, String) async -> Void

    func write(_ receipt: ToolReceipt) async {
        await client.persistToolReceipt(receipt, writer: self)
    }

}

extension SwiftNativeChatOrchestrationClient {
    func persistToolReceipt(_ receipt: ToolReceipt, writer: ToolReceiptWriter) async {
        do {
            try await appendToolMessage(
                sessionId: writer.sessionId,
                runId: writer.runId,
                toolName: receipt.toolName,
                inputJSON: receipt.inputJSON,
                resultSummary: receipt.resultJSON,
                ok: receipt.ok,
                cognitiveResult: ChatToolOutcome.cognitiveResult(
                    tool: receipt.toolName,
                    output: receipt.cognitiveOutput
                ),
                source: writer.surface
            )
        } catch {
            // M2 (2026-07-09): a swallowed failure here dropped the tool
            // receipt from the persisted transcript while the live pill still
            // rendered — on reload the user saw a reply with no evidence of
            // the tool that produced it.
            await Self.reportTranscriptWriteFailure(
                label: "appendToolMessage(\(receipt.toolName))\(writer.laneLabel)",
                path: dataRoot,
                error: error,
                userText: "Couldn't save the receipt for tool '\(receipt.toolName)' - it won't appear in the saved transcript.",
                onNotice: writer.onNotice
            )
        }
    }
}

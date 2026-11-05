import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
// Blueprint: | `ChatOrchestrationClient+ToolReceipts.swift` | `ToolReceipt`, `ToolProgress`; `SwiftNativeChatOrchestrationClient.persistToolReceipt` |

/// Redact the complete value-form receipt before it leaves dispatch.
struct ToolReceipt: Sendable {
    let turn: Turn
    let checkpoint: TurnCheckpointWriter?
    let invocationID: String
    let toolName: String
    let input: JSONValue
    let ranCall: (tool: String, input: [String: JSONValue])?
    let output: JSONValue
    let ok: Bool
    /// Preserve the producer's chosen raw or redacted output when building its cognitive event.
    let cognitiveOutput: JSONValue
}

/// Dispatch hands progress its exact receipt and invocation, including across
/// parallel children. Plain prose progress carries neither.
public struct ToolProgress: Sendable {
    public init(_ sink: @escaping TurnEventSink) {
        self.sink = { event, _, _ in await sink(event) }
    }
    init(_ sink: @escaping @Sendable (TurnStreamEvent, ToolReceipt?, String?) async -> Void) {
        self.sink = sink
    }
    let sink: @Sendable (TurnStreamEvent, ToolReceipt?, String?) async -> Void
    func callAsFunction(_ event: TurnStreamEvent, receipt: ToolReceipt? = nil,
                        invocationID: String? = nil) async {
        await sink(event, receipt, invocationID)
    }
}

/// Await each receipt write; a failed row is reported without dropping later rows.
struct ToolReceiptWriter: Sendable {
    let client: SwiftNativeChatOrchestrationClient
    let sessionId: String
    let runId: String
    let surface: String
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
                invocationID: receipt.invocationID,
                input: receipt.input,
                ranCall: receipt.ranCall,
                result: receipt.output,
                ok: receipt.ok,
                // An app call of a folded action is that tool's outcome.
                cognitiveResult: ChatToolOutcome.cognitiveResult(
                    tool: receipt.ranCall?.tool ?? ToolNameAliases.shown(receipt.toolName, input: receipt.input).name,
                    output: receipt.cognitiveOutput
                ),
                source: ChatThreadKind.transcriptSource(surface: receipt.turn.arrivalSurface(authorizing: writer.surface)), turn: receipt.turn
            )
            await receipt.checkpoint?.receiptWritten(turn: receipt.turn)
        } catch {
            await Self.reportTranscriptWriteFailure(
                label: "appendToolMessage(\(receipt.toolName))\(writer.laneLabel)",
                path: dataRoot,
                error: error,
                userText: "Couldn't save the receipt or restart checkpoint for tool '\(receipt.toolName)'; inspect the saved transcript before repeating it.",
                onNotice: writer.onNotice,
             turn: receipt.turn)
        }
    }
}

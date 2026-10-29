import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
// Blueprint: | `ChatOrchestrationClient+ToolReceipts.swift` | `SwiftNativeChatOrchestrationClient`: `persistToolReceipt` |

/// A complete value-form receipt, redacted before leaving dispatch.
struct ToolReceipt: Sendable {
    /// Carries the exact dispatch through progress to its awaited receipt write.
    @TaskLocal static var dispatched: ToolReceipt?
    let toolName: String
    let input: JSONValue
    let ranCall: (tool: String, input: [String: JSONValue])?
    let output: JSONValue
    let ok: Bool
    /// What the cognitive tool event is read from — the lane's own choice of
    /// raw or redacted output, kept exactly as each lane had it.
    let cognitiveOutput: JSONValue
}

/// Await each receipt write; a failed row is reported without dropping later rows.
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
                input: receipt.input,
                ranCall: receipt.ranCall,
                result: receipt.output,
                ok: receipt.ok,
                // An app call of a folded action is that tool's outcome.
                cognitiveResult: ChatToolOutcome.cognitiveResult(
                    tool: receipt.ranCall?.tool ?? ToolNameAliases.shown(receipt.toolName, input: receipt.input).name,
                    output: receipt.cognitiveOutput
                ),
                source: writer.surface
            )
            await TurnCheckpointScope.current?.receiptWritten()
        } catch {
            await Self.reportTranscriptWriteFailure(
                label: "appendToolMessage(\(receipt.toolName))\(writer.laneLabel)",
                path: dataRoot,
                error: error,
                userText: "Couldn't save the receipt or restart checkpoint for tool '\(receipt.toolName)'; inspect the saved transcript before repeating it.",
                onNotice: writer.onNotice
            )
        }
    }
}

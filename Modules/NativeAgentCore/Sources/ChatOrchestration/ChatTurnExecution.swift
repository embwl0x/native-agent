import Foundation
import NativeAgentCore
import ProviderRouting
import PersistenceCore

final class ChatTurnExecution: @unchecked Sendable {
    @TaskLocal static var current: ChatTurnExecution?
    private let lock = NSLock()
    private var waiting = false
    private var capabilityNote: String?
    func keepCapabilityNote(_ note: String) { lock.lock(); defer { lock.unlock() }; capabilityNote = note }
    func statusDetail(_ detail: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        let text = [detail, capabilityNote].compactMap { $0 }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
    private var records: [TurnEngineResult.ToolDispatchRecord] = []
    var toolRecords: [TurnEngineResult.ToolDispatchRecord] { lock.lock(); defer { lock.unlock() }; return records }
    func keepTools(_ values: [TurnEngineResult.ToolDispatchRecord]) { lock.lock(); defer { lock.unlock() }; records += values }
    private var pending: JSONValue?
    var pendingApproval: JSONValue? { lock.lock(); defer { lock.unlock() }; return pending }
    func keepApproval(_ value: JSONValue) { lock.lock(); defer { lock.unlock() }; pending = value; waiting = true }
    var waitingForApproval: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func waitForApproval() { lock.lock(); defer { lock.unlock() }; waiting = true }
}

extension SwiftNativeChatOrchestrationClient {
    /// Explicit picker and one aggregate output allowance, scoped to this turn.
    /// `choice` nil means the same route Chat uses: the agent's own model.
    public func chat(message: String, sessionId: String, choice: ProviderTurnChoice?,
                     tokenLimit: Int, surface: String,
                     progress: ChatOrchestrationProgressHandler? = nil) async throws -> ChatResponse {
        guard tokenLimit > 0 else { throw ChatOrchestrationError.underlying("The turn token limit must be positive.") }
        let budget = TurnTokenBudget(tokens: tokenLimit)
        let execution = ChatTurnExecution()
        return try await ProviderTurnChoice.$current.withValue(choice) {
        try await LLMCallContext.$turnTokenBudget.withValue(budget) {
        try await ChatTurnExecution.$current.withValue(execution) {
        try await LLMCallContext.$toolCapabilityNote.withValue({ execution.keepCapabilityNote($0) }) {
            do {
                var response = try await chat(message: message, sessionId: sessionId, model: choice?.model ?? "",
                    reasoningEffort: choice?.reasoningEffort ?? "", fileAccess: "auto", attachments: [], persona: nil,
                    surface: surface, suppressUserAppend: false, progress: progress)
                response.runtimeStatus = execution.waitingForApproval ? "waiting for approval"
                    : budget.exhausted || response.runtimeStatus == "interrupted" ? "interrupted" : "completed"
                response.statusDetail = execution.waitingForApproval ? "Approval is available in Approvals."
                    : budget.exhausted ? "Stopped at the per-run token limit." : nil
                response.statusDetail = execution.statusDetail(response.statusDetail)
                return response
            } catch {
                let partial = ToolCallParser.visiblePrefix(in: ToolCallParser.stripToolUseMarkers(budget.partialReply))
                let artifacts = ChatGeneratedImageArtifacts.attachments(from: execution.toolRecords, dataRoot: dataRoot)
                // Preserve already-produced work even when the provider throws.
                // The ordinary transcript and index remain the sole chat owners.
                if !partial.isEmpty {
                    try await appendMessage(sessionId: sessionId, role: "assistant", content: partial,
                        runId: UUID().uuidString, attachments: artifacts, source: surface,
                        responseOutcomeStatus: "incomplete")
                }
                var response = ChatResponse(runId: UUID().uuidString, model: choice?.model ?? "",
                    reasoningEffort: choice?.reasoningEffort, output: partial, sessionId: sessionId, attachments: artifacts.isEmpty ? nil : artifacts)
                response.runtimeStatus = error is CancellationError || budget.exhausted ? "interrupted" : "failed"
                response.statusDetail = budget.exhausted ? "Stopped at the per-run token limit."
                    : error is CancellationError ? "Stopped at the time limit or cancelled." : String(describing: error)
                response.statusDetail = execution.statusDetail(response.statusDetail)
                return response
            }
        }
        }
        }
        }
    }
}

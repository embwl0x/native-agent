import ChatOrchestration
import Foundation
import NativeAgentCore

extension NativeClient {
    /// Thin UI/client adapter over ChatOrchestration's canonical transcript
    /// compactor. Automatic and manual requests therefore share validation,
    /// verified backup, durable replacement, traces, and optional distillation.
    func compactSession(
        sessionId: String,
        model: String? = nil,
        providerID: String? = nil,
        force: Bool = false
    ) async throws -> CompactionResult {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.flatMap { $0.isEmpty ? nil : $0 }
        let outcome = try await Self.residentMacChatClient.compactSession(
            sessionId: sessionId,
            model: resolvedModel ?? nativeAgentPrimaryModel,
            surface: "chat",
            runId: nil,
            providerID: providerID,
            force: force
        )
        if outcome.compacted {
            NotificationCenter.default.post(
                name: .chatTurnCompleted,
                object: outcome.sessionId
            )
        }
        return CompactionResult(
            compacted: outcome.compacted,
            session_id: outcome.sessionId,
            messages_before: outcome.messagesBefore,
            messages_after: outcome.messagesAfter,
            summary_chars: outcome.summaryChars,
            messages_replaced: outcome.messagesReplaced,
            reason: outcome.reason,
            percent: nil,
            error: nil
        )
    }
}

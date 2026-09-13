import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

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
        // User, 2026-09-13: no hardcoded model on a call path. Compaction is a
        // Memory and mind activity ("Conversation summaries"), so when the caller
        // names no model the `compaction` surface answers — which is the group's
        // choice, or Chat's when the group has no override of its own.
        // The injected root, like every other reader here (third review): a test
        // or an alternate-root runtime must not resolve against the live app's
        // provider state.
        let routedModel = await SwiftNativeProviderRouting(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        ).modelStringForSurface("compaction")
        let outcome = try await Self.residentMacChatClient.compactSession(
            sessionId: sessionId,
            model: resolvedModel ?? routedModel ?? "",
            surface: "compaction",
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

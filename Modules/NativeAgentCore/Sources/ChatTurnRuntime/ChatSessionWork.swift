@_exported import ChatSessionWork
import Foundation
import NativeAgentCore
import NativeAgentShared
import Transcripts
// Blueprint: | `ChatSessionWork.swift` | Re-exports `ChatSessionWork`; `SwiftNativeChatOrchestrationClient` history preparation, automatic/manual compaction and transcript-aging integration |

extension SwiftNativeChatOrchestrationClient {
    /// Carry the compaction outcome so the window cursor does not rewrite the
    /// same prefix again, and the transcript bytes the compactor read so the
    /// turn's history selects from them instead of reading the file again.
    /// `progress` is the turn's own live state: a wait on a recollection says
    /// so there, in words, on every door that shows the turn.
    func prepareSessionHistoryForTurn(
        sessionId: String,
        model: String,
        surface: String,
        runId: String,
        progress: TurnEventSink? = nil
    ) async throws -> (compacted: Bool, transcript: Data?) {
        let outcome = try await compactSession(
            sessionId: sessionId, model: model, surface: surface, runId: runId,
            providerID: LLMCallContext.providerId, trigger: "auto_threshold", force: false,
            progress: progress
        )
        // The append may have crossed the aging boundary. Scheduling is not
        // awaited and cannot fail the turn; cancellation above never schedules.
        ChatSessionAgingConsolidation(
            dataRoot: dataRoot, autocompactionConfig: autocompactionConfig, llm: llm, clock: clock
        ).scheduleTranscriptAgingIfNeeded(
            sessionId: sessionId, model: model, surface: surface, runId: runId
        )
        return (outcome.compacted, outcome.transcript)
    }

    /// What a turn shows while it waits on a recollection. "waiting" in the
    /// kind is what every door reads as the waiting phase, which never ages
    /// into "stalled" — a full distill takes minutes and is not a stall.
    static let compactionWaitNoticeKind = "context_compaction_waiting"
    static let compactionWaitNoticeText = "Compacting this chat\u{2026}"

    /// Explicit user-requested compaction through the same canonical owner as
    /// automatic pre-turn compaction. `force` bypasses only the automatic
    /// enable/threshold gates; validation, verified backup, keep-tail,
    /// durable replacement, trace projection, and optional distillation remain
    /// identical.
    @discardableResult
    public func compactSession(
        sessionId: String,
        model: String,
        surface: String = "chat",
        runId: String? = nil,
        providerID: String? = nil,
        force: Bool = true
    ) async throws -> ChatSessionCompactionOutcome {
        try await compactSession(
            sessionId: sessionId,
            model: model,
            surface: surface,
            runId: runId,
            providerID: providerID,
            trigger: force ? "manual_request" : "manual_threshold",
            force: force
        )
    }

    private func compactSession(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?,
        providerID: String?,
        trigger: String,
        force: Bool,
        progress: TurnEventSink? = nil
    ) async throws -> ChatSessionCompactionOutcome {
        let compactor = ChatSessionAutocompactor(
            dataRoot: dataRoot,
            config: autocompactionConfig,
            now: clock
        )
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        ChatSessionIndexFile.beginTranscriptIndexSync(at: transcript)
        defer { ChatSessionIndexFile.endTranscriptIndexSync(at: transcript) }
        var outcome = try await compactor.compactIfNeeded(
            sessionId: sessionId,
            model: model,
            surface: surface,
            runId: runId,
            providerID: providerID,
            trigger: trigger,
            force: force
        )
        // Advance the version after compaction releases its transcript lock; ChatSessionIndexFile owns index locking.
        if outcome.compacted {
            await bumpSessionTranscriptGeneration(sessionId: outcome.sessionId)
        }
        // Pending recollection must finish before becoming turn history; show the turn's wait as it begins.
        var pending = outcome
        if pending.summaryRowId != nil {
            await progress?(.notice(kind: Self.compactionWaitNoticeKind, text: Self.compactionWaitNoticeText))
        }
        while let rowId = pending.summaryRowId,
           let backupPath = pending.backupPath {
            let dataRoot = self.dataRoot   // let/Sendable — nonisolated capture
            let llm = self.llm
            let clock = self.clock
                let distiller = ChatSessionAgingConsolidation.makeAgingDistiller(
                    dataRoot: dataRoot,
                    llm: llm,
                    now: clock
                )
                let ready = await distiller.distill(
                    sessionId: sessionId,
                    summaryRowId: rowId,
                    backupPath: backupPath,
                    rows: pending.recollectionSource,
                    turnModel: model,
                    surface: surface,
                    runId: runId
                )
                try Task.checkCancellation()
                guard ready else {
                    throw ToolFailureError("Recollection is unavailable; the original turns are retained in the compaction backup.",
                        effects: .none, owner: "chat/messages/\(sessionId).jsonl; providers.memory_and_mind_model",
                        nextCall: ToolFailureError.call("app", ["action": .string("chat.compact"),
                            "args": .object(["session_id": .string(sessionId)])]))
                }
                pending = try await compactor.compactIfNeeded(sessionId: sessionId, model: model,
                    surface: surface, runId: runId, providerID: providerID, trigger: trigger, pendingOnly: true)
                if let bytes = pending.transcript { outcome = outcome.carrying(bytes) }
        }
        return outcome
    }
}

@_exported import ChatSessionWork
import Foundation
import NativeAgentCore
import NativeAgentShared
import Transcripts
import ProviderRouting
import ChatToolRuntime
// Blueprint: | `ChatSessionWork.swift` | Re-exports `ChatSessionWork`; `SwiftNativeChatOrchestrationClient` history preparation, automatic/manual compaction and transcript-aging integration |

extension SwiftNativeChatOrchestrationClient {
    func withSessionContextMeasurement<T: Sendable>(sessionId: String, model: String, providerID: String?,
        surface: String, runId: String, progress: TurnEventSink?,
        nextTurnOutputBudgetTokens: Int? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        let fit: SessionRequestFit.Handler = { [self] context, codec, additional in
            try await self.fitSessionRequest(context, codec: codec, additionalMessages: additional, sessionId: sessionId,
                surface: surface, runId: runId, progress: progress)
        }
        let result = try await LLMCallContext.$conversationRequest.withValue(true) {
            try await SessionRequestFit.$current.withValue(fit, operation: body)
        }
        ChatSessionAgingConsolidation(dataRoot: dataRoot, autocompactionConfig: autocompactionConfig,
            llm: llm, clock: clock)
            .scheduleTranscriptAgingIfNeeded(sessionId: sessionId, model: model, surface: surface, runId: runId,
                outputBudgetTokens: nextTurnOutputBudgetTokens)
        return result
    }

    /// Finish already-owed recollection before context is prepared. Selection
    /// waits for the real composed request; this pass never sizes or starts a fold.
    func preparePendingSessionHistoryForTurn(sessionId: String, model: String, surface: String,
        runId: String, progress: TurnEventSink?
    ) async throws -> (compacted: Bool, transcript: Data?) {
        let outcome = try await compactSession(sessionId: sessionId, model: model, surface: surface,
            runId: runId, providerID: LLMCallContext.providerId, trigger: "auto_threshold", force: false,
            progress: progress, pendingOnly: true)
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
        let selectedModel: String
        let selectedProvider: String?
        let selectedEffort: String
        let helperBudgetTokens: Int?
        if let contract = await BotChatContract.checked(sessionId, dataRoot: dataRoot) {
            guard contract.modelChoiceProblem == nil, let choice = contract.choice,
                  let budgetTokens = contract.outputBudgetTokens else {
                throw ProviderRoutingError.configurationFailed(contract.modelChoiceProblem ?? "The helper's selected provider/model or output budget is unavailable.")
            }
            selectedModel = choice.model
            selectedProvider = choice.provider
            selectedEffort = choice.reasoningEffort
            helperBudgetTokens = budgetTokens
        } else if let providerID, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedModel = model
            selectedProvider = providerID
            if LLMCallContext.sessionId == sessionId,
               LLMCallContext.admittedModel == model, LLMCallContext.providerId == providerID,
               let effort = LLMCallContext.reasoningEffort {
                selectedEffort = effort
            } else {
                selectedEffort = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshot()
                    .routeAdmission(for: "chat", choice: nil).reasoningEffort
            }
            helperBudgetTokens = nil
        } else {
            let route = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshot()
                .routeAdmission(for: "chat", choice: nil)
            selectedModel = route.modelId
            selectedProvider = route.providerId
            selectedEffort = route.reasoningEffort
            helperBudgetTokens = nil
        }
        // A manual fold may target another conversation. Its output allowance
        // belongs to that conversation's route, never the calling turn's cap.
        let sameRequest = LLMCallContext.sessionId == sessionId
            && LLMCallContext.admittedModel == selectedModel
            && LLMCallContext.providerId == selectedProvider
            && LLMCallContext.reasoningEffort == selectedEffort
        let outputBudget: TurnTokenBudget?
        if sameRequest, let current = LLMCallContext.turnTokenBudget { outputBudget = current }
        else { outputBudget = helperBudgetTokens.map { TurnTokenBudget(tokens: $0) } }
        let admission = TurnRouteAdmission(routingSurface: "chat", modelId: selectedModel,
            reasoningEffort: selectedEffort, providerId: selectedProvider, serviceTier: nil)
        return try await withModelContext(admission, surface: surface) {
        try await LLMCallContext.$turnTokenBudget.withValue(outputBudget) {
        try await compactSession(
            sessionId: sessionId,
            model: selectedModel,
            surface: surface,
            runId: runId,
            providerID: selectedProvider,
            trigger: force ? "manual_request" : "manual_threshold",
            force: force
        )
        }
        }
    }

    func compactSession(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?,
        providerID: String?,
        trigger: String,
        force: Bool,
        progress: TurnEventSink? = nil,
        pendingOnly: Bool = false,
        requestBuilder: SessionContextRequest.Builder? = nil
    ) async throws -> ChatSessionCompactionOutcome {
        let compactor = ChatSessionAutocompactor(
            dataRoot: dataRoot,
            config: autocompactionConfig,
            requestBuilder: requestBuilder,
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
            force: force,
            pendingOnly: pendingOnly
        )
        // Advance the version after compaction releases its transcript lock; ChatSessionIndexFile owns index locking.
        if outcome.compacted {
            await bumpSessionTranscriptGeneration(sessionId: outcome.sessionId)
        }
        // A pending recollection is distilled before the turn (it replays as pending if it cannot be); show the wait as it begins.
        var pending = outcome
        let pursuingTarget = !pendingOnly && (outcome.compacted || outcome.summaryRowId != nil)
        if pending.summaryRowId != nil {
            await progress?(.notice(kind: Self.compactionWaitNoticeKind, text: Self.compactionWaitNoticeText))
        }
        // A recollection whose distill failed in this call is not retried in it (one model call per row).
        var failedRows = Set<String>()
        while true {
            let tokensBeforeFold = pending.estimatedTokensBefore
            while let rowId = pending.summaryRowId, !failedRows.contains(rowId),
                  let backupPath = pending.backupPath {
                let dataRoot = self.dataRoot
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
                    // An automatic fold never fails the turn: the row stays pending, its
                    // recollection is owed (RepairOwed) and the next turn distills again.
                    guard force else { failedRows.insert(rowId); break }
                    throw ToolFailureError("Recollection is unavailable; the original turns are retained in the compaction backup.",
                        effects: .none, owner: "chat/messages/\(sessionId).jsonl; providers.memory_and_mind_model",
                        nextCall: ToolFailureError.call("app", ["action": .string("chat.compact"),
                            "args": .object(["session_id": .string(sessionId)])]), code: "recollection_unavailable", recovery: .repair)
                }
                pending = try await compactor.compactIfNeeded(sessionId: sessionId, model: model,
                    surface: surface, runId: runId, providerID: providerID, trigger: trigger, pendingOnly: true)
                if let bytes = pending.transcript { outcome = outcome.carrying(bytes) }
            }
            guard pursuingTarget else { break }
            if try await compactor.targetReached(sessionId: sessionId, model: model, providerID: providerID,
                previousTokens: tokensBeforeFold > 0 ? tokensBeforeFold : nil) {
                outcome = outcome.finished(with: pending)
                break
            }
            let next = try await compactor.compactIfNeeded(sessionId: sessionId, model: model,
                surface: surface, runId: runId, providerID: providerID, trigger: trigger, towardTarget: true)
            guard next.compacted || next.summaryRowId != nil else {
                throw ToolFailureError("Compaction cannot reach its configured target: \(next.reason). Live cards, the latest user turn and the dream boundary remain protected.",
                    effects: .none, owner: "chat/messages/\(sessionId).jsonl")
            }
            // Only an already-failed pending row stands between here and the target:
            // the request goes as it is, and that recollection stays owed.
            if !next.compacted, let rowId = next.summaryRowId, failedRows.contains(rowId) { break }
            if next.compacted { await bumpSessionTranscriptGeneration(sessionId: sessionId) }
            outcome = outcome.followed(by: next)
            pending = next
        }
        return outcome
    }
}

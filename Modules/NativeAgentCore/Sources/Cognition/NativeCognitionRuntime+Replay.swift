import Foundation
import CognitiveSubstrate
import DreamREMCycle
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
// Blueprint: | `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime` replay evidence composition, checked integration and bounded event-driven reconciliation |

extension NativeCognitionRuntime {
    func handleEventDrivenReplayOutcome(
        _ outcome: LoopTickOutcome,
        reason: String,
        allowRetry: Bool
    ) async {
        switch outcome {
        case .completed:
            replayReconciliationPending = false
            replayRetryTask?.cancel()
            replayRetryTask = nil
        case .skipped(let detail, _) where detail == "no new replay evidence":
            replayReconciliationPending = false
            replayRetryTask?.cancel()
            replayRetryTask = nil
        case .skipped(let detail, _), .failed(error: let detail):
            replayReconciliationPending = true
            await substrate.recordReceipt(
                kind: "replay.reconciliation_pending",
                payload: .object([
                    "reason": .string(reason),
                    "outcome": .string(String(detail.prefix(300))),
                    "retryScheduled": .bool(allowRetry),
                ])
            )
            guard allowRetry, replayRetryTask == nil else { return }
            replayRetryTask = Task { [weak self] in
                let nanos = UInt64(Self.replayFailureRetryDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                await self?.retryPendingReplayReconciliation()
            }
        }
    }

    private func retryPendingReplayReconciliation() async {
        // Hold `replayRetryTask` non-nil across the replay await. The
        // arm site guards on `replayRetryTask == nil`, so clearing it before
        // awaiting would let a concurrent dream signal observe "no retry armed"
        // and double-run replay. Reconciliation stays idempotent; the task
        // self-clears only after this body completes.
        guard replayReconciliationPending, !isFlushedForTermination else {
            replayRetryTask = nil
            return
        }
        let reason = "replay_event_retry"
        let outcome = await runEventDrivenReplayWithDeadline(reason: reason)
        await handleEventDrivenReplayOutcome(outcome, reason: reason, allowRetry: false)
        replayRetryTask = nil
    }

    /// The unstructured deadline returns without joining cancellation-insensitive replay.
    /// Reconciliation remains durable and gets one bounded retry.
    func runEventDrivenReplayWithDeadline(
        reason: String
    ) async -> LoopTickOutcome {
        let outcome = await raceAgainstTimeout(seconds: Self.eventDrivenReplayDeadlineSeconds) { [weak self] in
            guard let self else {
                return LoopTickOutcome.failed(error: "cognitive runtime released before event-driven replay")
            }
            return await self.runReplay(reason: reason)
        }
        switch outcome {
        case .value(let result):
            return result
        case .failure(let detail):
            return .failed(error: "event-driven replay race failed: \(detail)")
        case .timedOut:
            let detail = "event-driven replay '\(reason)' exceeded "
                + "\(Self.eventDrivenReplayDeadlineSeconds)s deadline; task cancelled and reconciliation retained"
            deadlineLogger("TIMEOUT: \(detail)")
            return .failed(error: detail)
        case .cancelled:
            let detail = "event-driven replay '\(reason)' cancelled; reconciliation retained"
            deadlineLogger("CANCELLED: \(detail)")
            return .failed(error: detail)
        }
    }

    @discardableResult
    public func runReplay(reason: String) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(error: bootstrapFailure) }
        let configuration = await substrate.configurationSnapshot()
        guard configuration.enabled else {
            return .skipped(reason: LoopTickOutcome.offPrefix + "cognitive replay disabled")
        }
        do {
            let persistenceEnabled = configuration.persistenceEnabled
            let result = try await substrate.integrateReplayChecked(
                await makeReplayIntegrationInput(reason: reason)
            )
            guard !result.episodeIds.isEmpty || !result.schemaProposalIds.isEmpty || !result.timelineEventIds.isEmpty else {
                return .skipped(reason: "no new replay evidence")
            }
            scheduleDirtyMicrocycle(reason: "replay_integration")
            publishRuntimeChange(reason: "replay:completed")
            return .completed(result: persistenceEnabled
                ? "replay artifacts and lineage committed atomically"
                : "replay evidence integrated in memory-only mode")
        } catch {
            publishRuntimeChange(reason: "replay:failed")
            return .failed(error: "cognitive replay failed: \(error.localizedDescription)")
        }
    }

    func makeReplayIntegrationInput(reason: String) async -> CognitiveReplayIntegrationInput {
        let root = dataRoot
        var unavailable: [String] = []
        let diary = FileBackedDreamDiary(dataRoot: root).listEntriesChecked(limit: 8)
        if diary.storageUnreadable { unavailable.append("dream_diary: the diary could not be listed") }
        unavailable += diary.failures.sorted { $0.key < $1.key }.map { "dream_diary/\($0.key): \($0.value)" }
        let dreamEntries = diary.entries
            .compactMap { entry -> CognitiveDreamReplayReference? in
                guard let content = entry.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { return nil }
                return CognitiveDreamReplayReference(
                    id: entry.filename ?? entry.date,
                    date: entry.date,
                    filename: entry.filename,
                    content: content,
                    modifiedAt: entry.modifiedAt
                )
            }

        let rem = REMProposalStore(dataRoot: root).loadAllChecked()
        unavailable += rem.unreadable.map { "rem_proposals/\($0)" }
        let remProposals = rem.rows
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
            .prefix(8)
            .map { row in
                CognitiveREMProposalReference(
                    id: row.id,
                    target: row.targetDoc,
                    text: row.proposalText,
                    evidenceDates: row.evidenceDates,
                    confidence: row.confidence,
                    createdAt: row.createdAt
                )
            }

        return CognitiveReplayIntegrationInput(
            reason: reason,
            dreamEntries: dreamEntries,
            remProposals: Array(remProposals),
            unavailableEvidence: unavailable
        )
    }
}

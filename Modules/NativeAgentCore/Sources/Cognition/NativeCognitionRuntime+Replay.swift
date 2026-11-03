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
            let shouldRetry = allowRetry && !isFlushedForTermination
            await substrate.recordReceipt(
                kind: "replay.reconciliation_pending",
                payload: .object([
                    "reason": .string(reason),
                    "outcome": .string(String(detail.prefix(300))),
                    "retryScheduled": .bool(shouldRetry),
                ])
            )
            guard shouldRetry, replayRetryTask == nil else { return }
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
        _ = await runEventDrivenReplayWithDeadline(reason: reason, material: nil, allowRetry: false)
        replayRetryTask = nil
    }

    /// The deadline bounds the wait on a retained flight, never its commit.
    /// Only that flight's terminal result settles reconciliation and reflection.
    func runEventDrivenReplayWithDeadline(
        reason: String,
        material: [String: CognitiveReflectionCause]? = [:],
        allowRetry: Bool = true
    ) async -> LoopTickOutcome {
        replayReconciliationPending = true
        if let material {
            var pending = replayReflectionMaterial ?? [:]
            pending.merge(material) { _, new in new }
            replayReflectionMaterial = pending
        }
        if eventReplayTask != nil { eventReplayAgain = true }
        if eventReplayTask == nil {
            guard !isFlushedForTermination else { return .skipped(reason: "runtime stopping") }
            eventReplayTask = Task {
                var result: LoopTickOutcome
                repeat {
                    self.eventReplayAgain = false
                    result = await self.runReplay(reason: reason, requiringFreshInput: true)
                    if !self.eventReplayAgain {
                        await self.handleEventDrivenReplayOutcome(result, reason: reason, allowRetry: allowRetry)
                    }
                    await self.reportLoopOutcome(loopId: "cognition_replay", outcome: result)
                    let complete: Bool = switch result {
                    case .completed: true
                    case .skipped(let detail, _): detail == "no new replay evidence"
                    case .failed: false
                    }
                    // A later commit may have arrived after this pass captured
                    // its inputs. Integrate it before reflecting its material.
                    if complete && !self.eventReplayAgain, let material = self.replayReflectionMaterial {
                        self.replayReflectionMaterial = nil
                        await self.scheduleEventDrivenReflection(reason: "reflection_" + reason, material: material)
                    }
                } while self.eventReplayAgain && !self.isFlushedForTermination
                self.eventReplayTask = nil
                return result
            }
        }
        guard let flight = eventReplayTask else { return .failed(error: "replay flight not retained") }
        let outcome = await raceAgainstTimeout(seconds: Self.eventDrivenReplayDeadlineSeconds) {
            await flight.value
        }
        switch outcome {
        case .value(let result):
            return result
        case .failure(let detail):
            return .failed(error: "event-driven replay race failed: \(detail)")
        case .timedOut:
            let detail = "event-driven replay '\(reason)' exceeded "
                + "\(Self.eventDrivenReplayDeadlineSeconds)s wait deadline; retained integration is pending"
            deadlineLogger("TIMEOUT: \(detail)")
            return .skipped(reason: detail)
        case .cancelled:
            let detail = "event-driven replay '\(reason)' cancelled; reconciliation retained"
            deadlineLogger("CANCELLED: \(detail)")
            return .failed(error: detail)
        }
    }

    @discardableResult
    public func runReplay(reason: String, requiringFreshInput: Bool = false) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(error: bootstrapFailure) }
        if let replayTask {
            let result = await replayTask.value
            guard requiringFreshInput else { return result }
            // That flight may have frozen its inputs before this event's commit.
            // Its owner clears the slot before returning; a new pass reads after it.
            return await runReplay(reason: reason)
        }
        guard !isFlushedForTermination else { return .skipped(reason: "runtime stopping") }
        let flight = Task {
            let result = await self.performReplay(reason: reason)
            self.replayTask = nil
            return result
        }
        replayTask = flight
        return await flight.value
    }

    private func performReplay(reason: String) async -> LoopTickOutcome {
        let configuration = await substrate.configurationSnapshot()
        guard configuration.enabled else {
            return .skipped(reason: LoopTickOutcome.offPrefix + "cognitive replay disabled")
        }
        do {
            let persistenceEnabled = configuration.persistenceEnabled
            let input = await makeReplayIntegrationInput(reason: reason)
            let result = try await substrate.integrateReplayChecked(input)
            if !result.episodeIds.isEmpty || !result.schemaProposalIds.isEmpty || !result.timelineEventIds.isEmpty {
                scheduleDirtyMicrocycle(reason: "replay_integration")
                publishRuntimeChange(reason: "replay:committed")
            }
            guard input.unavailableEvidence.isEmpty else {
                return .failed(error: "replay input incomplete; independently committed artifacts kept: " + input.unavailableEvidence.joined(separator: "; "))
            }
            guard !result.episodeIds.isEmpty || !result.schemaProposalIds.isEmpty || !result.timelineEventIds.isEmpty else {
                return .skipped(reason: "no new replay evidence")
            }
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
                    content: content
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

import Foundation
import Privacy
import TurnTrace
import NativeAgentCore
import NativeAgentShared
import Transcripts
// Blueprint: | `MacChatTurnLifecycleIntake.swift` | `MacChatTurnPresentationPort`: `beginChatTurnLifecycle`, `applyChatTurnLifecycleInput`; `OtherDoorTurns` retains its trace subscription consumer, counts reply progress only from surface output evidence, stops at engine termination and unsubscribes on exit |

public extension MacChatTurnPresentationPort {
    /// Opens the exact generation for one accepted Mac turn. This is the only
    /// constructor for active lifecycle authority; every later event must name
    /// the same session and turn id.
    @discardableResult
    func beginChatTurnLifecycle(
        identity: MacChatTurnIdentity,
        generation: Int,
        at instant: Date
    ) async -> (persisted: Bool, isCurrent: Bool) {
        let sessionId = identity.sessionId
        guard !sessionId.isEmpty, !identity.turnId.isEmpty else { return (false, false) }
        macChatTurns.activeTurnIDsBySession[sessionId] = identity.turnId
        // A new turn starts with nothing on the glass. The previous turn's last
        // frame is not what this turn is looking at.
        macChatTurns.screenPreviewBySession.removeValue(forKey: sessionId)
        let state = MacChatTurnLifecycleState(
            identity: identity,
            startedAt: instant
        )
        macChatTurns.lifecycleBySession[sessionId] = state
        do {
            try await macChatTurns.lifecycleStore.begin(state)
            return (true, chatTurnAdmissionIsCurrent(identity: identity, generation: generation))
        } catch {
            logChatTurnLifecyclePersistenceFailure("begin", error: error)
            return (false, false)
        }
    }

    func chatTurnAdmissionIsCurrent(identity: MacChatTurnIdentity, generation: Int) -> Bool {
        let state = macChatTurns.lifecycle(for: identity.sessionId)
        return state?.identity == identity && state?.cancellationRequestedAt == nil
            && macChatTurns.taskGenerations[identity.sessionId] == generation && !Task.isCancelled
    }

    /// The one reducer entry for live, terminal, and cancellation evidence.
    /// Exact identity is checked before observable state changes.
    @discardableResult
    func applyChatTurnLifecycleInput(
        _ input: MacChatTurnLifecycleInput
    ) -> MacChatTurnLifecycleState? {
        let sessionId = input.identity.sessionId
        guard macChatTurns.activeTurnIDsBySession[sessionId] == input.identity.turnId,
              let state = macChatTurns.lifecycleBySession[sessionId],
              state.identity == input.identity else {
            return nil
        }
        let reduced = MacChatTurnLifecycleReducer.reduce(state, input: input)
        if reduced != state {
            macChatTurns.lifecycleBySession[sessionId] = reduced
            if reduced.replyTextSettled != state.replyTextSettled {
                if !reduced.replyTextSettled { macChatTurns.replyingSessions.remove(sessionId) }
                if !reduced.replyTextSettled {
                    macChatTurns.streamProgressAppliedAt[sessionId] = nil
                }
            }
            if reduced.presentation.lastMovementAt != state.presentation.lastMovementAt
                || reduced.presentation.phase != state.presentation.phase
                || reduced.replyTextSettled != state.replyTextSettled {
                macChatTurns.activityDidChange?()
            }
        }
        return reduced
    }

    @discardableResult
    func requestChatTurnCancellation(
        sessionId: String,
        turnId: String,
        at instant: Date
    ) -> MacChatTurnLifecycleState? {
        applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: MacChatTurnIdentity(sessionId: sessionId, turnId: turnId),
            kind: .cancellationRequested,
            occurredAt: instant
        ))
    }

    /// Fourteen publications a second each rewrote `macChatTurns.lifecycleBySession`
    /// with a new accumulated length and movement instant, and ChatView reads
    /// that dictionary (`showThinkingRow`, and the card host under it) — so
    /// every chunk invalidated the whole Chat screen and re-projected the
    /// working card for a number nobody can read faster than the card's own
    /// one-second readout schedule. A bump that only moves the length and the
    /// clock is coalesced to 1 Hz; anything that could change the card's PHASE
    /// (the first chunk after a tool call, a retry, a turn not in `.working`)
    /// goes straight through, so the card never lags what the turn is doing.
    @discardableResult
    func recordChatTurnStreamProgress(
        identity: MacChatTurnIdentity,
        accumulatedUTF16Length: Int,
        at instant: Date
    ) -> MacChatTurnLifecycleState? {
        let sessionId = identity.sessionId
        if macChatTurns.lifecycleBySession[sessionId]?.presentation.phase == .working,
           let last = macChatTurns.streamProgressAppliedAt[sessionId],
           last.turnId == identity.turnId,
           instant.timeIntervalSince(last.at) < MacChatTurnRuntime.streamProgressCoalesceSeconds {
            return nil
        }
        macChatTurns.streamProgressAppliedAt[sessionId] = (identity.turnId, instant)
        return applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: identity,
            kind: .streamProgress(accumulatedUTF16Length: accumulatedUTF16Length),
            occurredAt: instant
        ))
    }

    /// Closes process-local intake. A stream/task that exits without already
    /// carrying terminal proof becomes outcome-unknown; closure alone is never
    /// relabeled completed, failed, or canceled.
    @discardableResult
    func closeChatTurnLifecycleIntake(
        sessionId: String,
        turnId: String,
        at instant: Date
    ) -> MacChatTurnLifecycleState? {
        guard macChatTurns.activeTurnIDsBySession[sessionId] == turnId,
              var state = macChatTurns.lifecycleBySession[sessionId],
              state.identity.turnId == turnId else { return nil }
        if !state.presentation.isTerminal {
            state = MacChatTurnLifecycleReducer.reduce(
                state,
                input: MacChatTurnLifecycleInput(
                    identity: state.identity,
                    kind: .outcomeUnknown(
                        reason: "I'm not sure that finished \u{2014} if my answer isn't here, say it again and I'll pick it up."
                    ),
                    occurredAt: instant
                )
            )
            macChatTurns.lifecycleBySession[sessionId] = state
        }
        macChatTurns.activeTurnIDsBySession.removeValue(forKey: sessionId)
        // The pane is a live view of work in flight. Nothing is in flight now,
        // so the screenshot of the user's desktop stops being held in memory.
        macChatTurns.screenPreviewBySession.removeValue(forKey: sessionId)
        presentMacChatTurn(.intakeClosed)
        return state
    }

    /// Drops only the named turn's transient activity slot.
    func discardChatTurnLifecycleIntake(sessionId: String, turnId: String) {
        guard macChatTurns.activeTurnIDsBySession[sessionId] == turnId else { return }
        macChatTurns.activeTurnIDsBySession.removeValue(forKey: sessionId)
        if macChatTurns.lifecycleBySession[sessionId]?.identity.turnId == turnId {
            macChatTurns.lifecycleBySession.removeValue(forKey: sessionId)
        }
        // The discarded turn's frame goes with it; nothing will close this key.
        macChatTurns.screenPreviewBySession.removeValue(forKey: sessionId)
        presentMacChatTurn(.intakeClosed)
    }

    @discardableResult
    func persistChatTurnLifecycleUpdate(identity: MacChatTurnIdentity) async -> Bool {
        guard let state = macChatTurns.lifecycleBySession[identity.sessionId],
              state.identity == identity else { return false }
        do {
            let retained = try await macChatTurns.lifecycleStore.update(state)
            if !retained {
                // The durable owner no longer contains this exact turn. Keep
                // the in-memory projection for the current process, but force
                // the next admission/reload through canonical repair instead
                // of permanently treating the ledger as reconciled.
                macChatTurns.chatTurnLifecycleRepairCompleted = false
                logChatTurnLifecyclePersistenceFailure(
                    "update",
                    error: MacChatTurnLifecycleStoreError.missingExactTurn
                )
            }
            return retained
        } catch {
            macChatTurns.chatTurnLifecycleRepairCompleted = false
            logChatTurnLifecyclePersistenceFailure("update", error: error)
            return false
        }
    }

    @discardableResult
    func settleChatTurnLifecycle(
        identity: MacChatTurnIdentity,
        kind: MacChatTurnLifecycleInput.Kind,
        at instant: Date = Date()
    ) async -> MacChatTurnLifecycleState? {
        guard let state = applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: identity,
            kind: kind,
            occurredAt: instant
        )) else { return nil }
        _ = await persistChatTurnLifecycleUpdate(identity: state.identity)
        return state
    }

    /// Releases the reservation and removes only its exact pre-admission snapshot.
    func abandonChatTurnLifecycleBeforeAdmission(identity: MacChatTurnIdentity, generation: Int) async {
        _ = macChatTurns.finishRuntime(sessionId: identity.sessionId, generation: generation)
        discardChatTurnLifecycleIntake(
            sessionId: identity.sessionId,
            turnId: identity.turnId
        )
        do {
            try await macChatTurns.lifecycleStore.remove(
                sessionId: identity.sessionId,
                turnId: identity.turnId
            )
        } catch {
            logChatTurnLifecyclePersistenceFailure("admission_rollback", error: error)
        }
    }

    func readCanonicalChatTurnTerminalProof(
        identity: MacChatTurnIdentity
    ) async -> MacChatTurnTranscriptTerminalProof {
        do {
            return try await macChatTurns.chatTurnTranscriptProofReader.proof(for: identity)
        } catch {
            logChatTurnLifecyclePersistenceFailure("transcript_proof", error: error)
            return .unavailable
        }
    }

    /// One bounded launch repair. Existing terminal records carry their closed
    /// proof; nonterminal records are settled from the canonical transcript's
    /// exact turnTraceId/outcomeObservation, or outcome-unknown when absent.
    @discardableResult
    func repairChatTurnLifecyclesIfNeeded(
        knownSessionIds: Set<String>,
        at instant: Date = Date(),
        loadProof: @MainActor (MacChatTurnIdentity) async -> MacChatTurnTranscriptTerminalProof
    ) async -> Bool {
        await macChatTurns.loadQueuedTurnsIfNeeded()
        guard !macChatTurns.chatTurnLifecycleRepairCompleted else { return true }
        let records: [MacChatPersistedTurnLifecycle]
        do {
            records = try await macChatTurns.lifecycleStore.records()
        } catch {
            logChatTurnLifecyclePersistenceFailure("repair_load", error: error)
            return false
        }
        var hasPendingRepairWork = false
        var repairPersistenceFailed = false

        for record in records {
            let hasCheckpoint: Bool
            do {
                hasCheckpoint = try TurnCheckpoint.read(dataRoot: macChatTurns.dataRoot,
                    sessionId: record.sessionId, turnId: record.turnId) != nil
            } catch {
                hasPendingRepairWork = true
                logChatTurnLifecyclePersistenceFailure("repair_checkpoint", error: error)
                continue
            }
            if hasCheckpoint && !record.isTerminal { hasPendingRepairWork = true }
            let isIndexed = knownSessionIds.contains(record.sessionId)
            // Active indexed turns settle themselves; unindexed ownership
            // keeps repair pending until its outcome can be inspected.
            guard macChatTurns.activeTurnIDsBySession[record.sessionId] == nil else {
                if !isIndexed { hasPendingRepairWork = true }
                continue
            }
            if !isIndexed && record.isTerminal { continue }
            let proof = record.isTerminal ? .absent : await loadProof(record.identity)
            guard macChatTurns.activeTurnIDsBySession[record.sessionId] == nil else {
                if !isIndexed { hasPendingRepairWork = true }
                continue
            }
            guard let repaired = MacChatTurnLifecycleRestartRepair.repair(
                record: record,
                transcriptProof: proof,
                hasCheckpoint: hasCheckpoint,
                at: instant
            ) else {
                if !isIndexed { hasPendingRepairWork = true }
                continue
            }
            // Only indexed sessions publish; their exact live terminal truth
            // is immutable even when durable evidence lags behind it.
            let liveState = macChatTurns.lifecycleBySession[record.sessionId]
            let liveTerminalWins = isIndexed && liveState?.identity == record.identity
                && liveState?.presentation.isTerminal == true
            let settled = liveTerminalWins ? (liveState ?? repaired) : repaired
            if isIndexed && !liveTerminalWins {
                macChatTurns.lifecycleBySession[record.sessionId] = settled
            }
            if !record.isTerminal {
                do {
                    if try await macChatTurns.lifecycleStore.update(settled) == false {
                        repairPersistenceFailed = true
                    }
                } catch {
                    repairPersistenceFailed = true
                    logChatTurnLifecyclePersistenceFailure(isIndexed ? "repair_update" : "repair_unindexed", error: error)
                }
            }
        }
        macChatTurns.chatTurnLifecycleRepairCompleted = !hasPendingRepairWork && !repairPersistenceFailed
        return !repairPersistenceFailed
    }

    private func logChatTurnLifecyclePersistenceFailure(_ operation: String, error: Error) {
        let safe = NativeAppSecretRedactor.redactText(String(describing: error))
        nativeLog("Mac chat turn lifecycle %@ failed: %@", operation, safe)
    }

}

/// Every door fires the same trace milestones as a Mac turn, so this reads them into
/// the same lifecycle the card, the thinking glow and Work read. Display only:
/// no task, no Stop, no durable receipt, and a Mac turn in the session always
/// wins. It keeps every session's open turn, seeded from the engine's run
/// registry when it starts, so a turn already running when a chat is opened or
/// returned to shows too.
@MainActor
public final class OtherDoorTurns {
    public static let shared = OtherDoorTurns()
    /// Each session's other-door turn that began and has not ended.
    private var open: [String: MacChatTurnLifecycleState] = [:]
    private var task: Task<Void, Never>?
    private var generation: UUID?
    /// Her words reaching the surface: movement, and the card reads "replying".
    private static let outputKinds: Set<String> = [
        TurnLifecycleMilestone.surfaceOutputEnqueued.rawValue,
        TurnLifecycleMilestone.surfaceFirstRender.rawValue,
    ]

    public func start(_ appModel: any MacChatTurnPresentationPort) {
        guard task == nil else { return }
        let generation = UUID()
        self.generation = generation
        task = Task { await run(appModel, generation: generation) }
    }

    public func stop() -> Task<Void, Never> {
        generation = nil
        let consumer = task
        consumer?.cancel()
        open.removeAll()
        return Task.detached {
            await settle { await consumer?.value }
        }
    }

    /// Puts the session's open turn on its card, unless a Mac turn holds it.
    public func show(_ sessionId: String, _ appModel: any MacChatTurnPresentationPort) {
        guard let state = open[sessionId] else { return }
        let turns = appModel.macChatTurns
        if let held = turns.lifecycle(for: sessionId), held.identity.turnId != state.identity.turnId,
           !held.presentation.isTerminal { return }
        turns.lifecycleBySession[sessionId] = state
    }

    private func run(_ appModel: any MacChatTurnPresentationPort, generation: UUID) async {
        defer {
            task = nil
            open.removeAll()
            if self.generation == generation { self.generation = nil }
        }
        let subscription = await TurnTraceBus.shared.subscribe(capacity: 256)
        guard self.generation == generation, !Task.isCancelled else {
            await settle { await TurnTraceBus.shared.unsubscribe(subscription.id) }
            return
        }
        for turn in ChatCancelFlag.inFlightTurns(dataRoot: appModel.macChatTurns.dataRoot) {
            admit(MacChatTurnIdentity(sessionId: turn.sessionId, turnId: turn.turnId), at: turn.acceptedAt, appModel)
        }
        for sessionId in open.keys { show(sessionId, appModel) }
        for await event in subscription.stream {
            guard self.generation == generation, !Task.isCancelled else { break }
            guard let sessionId = event.sessionId, let ended = reduce(event, appModel) else { continue }
            if ended {
                // A refresh that started while the card was up is dropped by
                // its lifecycle guard; this one lands the reply.
                await appModel.refreshChatMessagesAfterTurn(sessionId: sessionId, messagesAlreadyRefreshed: false)
            } else {
                show(sessionId, appModel)
            }
        }
        await settle { await TurnTraceBus.shared.unsubscribe(subscription.id) }
    }

    /// Opens a turn another door started: false when it is already open or
    /// the Mac holds it.
    @discardableResult
    private func admit(_ identity: MacChatTurnIdentity, at startedAt: Date, _ appModel: any MacChatTurnPresentationPort) -> Bool {
        let sessionId = identity.sessionId
        let turns = appModel.macChatTurns
        guard open[sessionId]?.identity != identity,
              !turns.busySessions.contains(sessionId),
              turns.activeTurnIDsBySession[sessionId] != identity.turnId,
              turns.lifecycle(for: sessionId)?.identity.turnId != identity.turnId
        else { return false }
        open[sessionId] = MacChatTurnLifecycleState(identity: identity, startedAt: startedAt)
        return true
    }

    /// Folds one event in: nil when it is not an other-door turn's, else
    /// whether that turn ended.
    private func reduce(_ event: TurnTraceEvent, _ appModel: any MacChatTurnPresentationPort) -> Bool? {
        guard let sessionId = event.sessionId else { return nil }
        let turns = appModel.macChatTurns
        let identity = MacChatTurnIdentity(sessionId: sessionId, turnId: event.turnId)
        if event.kind == TurnLifecycleMilestone.turnAccepted.rawValue {
            return admit(identity, at: event.ts, appModel) ? false : nil
        }
        guard let state = open[sessionId], state.identity == identity else { return nil }
        let kind: MacChatTurnLifecycleInput.Kind
        switch event.kind {
        case "tool.dispatch":
            var action: String?
            if case .object(let payload) = event.payload, payload["phase"] == .string("begin"),
               case .string(let name)? = payload["shown"] ?? payload["name"] {
                action = ToolActivityPresentation.progress(name)
            }
            kind = .working(action: action)
        case let output where Self.outputKinds.contains(output):
            kind = .streamProgress(accumulatedUTF16Length: state.presentation.streamedTextLength + 1)
        case let terminal where TurnTraceEvent.isTerminalKind(terminal):
            open[sessionId] = nil
            if turns.lifecycle(for: sessionId)?.identity == identity {
                turns.lifecycleBySession.removeValue(forKey: sessionId)
            }
            return true
        default:
            return nil
        }
        open[sessionId] = MacChatTurnLifecycleReducer.reduce(
            state, input: MacChatTurnLifecycleInput(identity: identity, kind: kind, occurredAt: event.ts)
        )
        return false
    }
}

import Foundation
import Privacy

public extension MacChatTurnPresentationPort {
    /// Opens the exact generation for one accepted Mac turn. This is the only
    /// constructor for active lifecycle authority; every later event must name
    /// the same session and turn id.
    @discardableResult
    func beginChatTurnLifecycle(
        sessionId: String,
        turnId: String,
        at instant: Date
    ) -> MacChatTurnIdentity? {
        guard !sessionId.isEmpty, !turnId.isEmpty else { return nil }
        let identity = MacChatTurnIdentity(sessionId: sessionId, turnId: turnId)
        macChatTurns.activeTurnIDsBySession[sessionId] = turnId
        // A new turn starts with nothing on the glass. The previous turn's last
        // frame is not what this turn is looking at.
        presentMacChatTurn(.clearPreview(sessionId))
        macChatTurns.lifecycleBySession[sessionId] = MacChatTurnLifecycleState(
            identity: identity,
            startedAt: instant
        )
        return identity
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
                presentMacChatTurn(.replySettledChanged(sessionId: sessionId, settled: reduced.replyTextSettled))
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

    /// Existing notice and tool activity converges on the lifecycle reducer;
    /// no second event bus or raw payload store is introduced.
    func receiveChatTurnActivity(_ activity: MacChatTurnActivity) {
        guard applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: activity.identity,
            kind: .activity(activity),
            occurredAt: activity.occurredAt
        )) != nil else { return }

        presentMacChatTurn(.activity(activity))
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
        presentMacChatTurn(.clearPreview(sessionId))
        presentMacChatTurn(.intakeClosed)
        return state
    }

    /// Drops only the named turn's transient activity slot. Used when a
    /// placeholder session reconciles into a separately active canonical
    /// session and must not overwrite that session's evidence.
    func discardChatTurnLifecycleIntake(sessionId: String, turnId: String) {
        guard macChatTurns.activeTurnIDsBySession[sessionId] == turnId else { return }
        macChatTurns.activeTurnIDsBySession.removeValue(forKey: sessionId)
        if macChatTurns.lifecycleBySession[sessionId]?.identity.turnId == turnId {
            macChatTurns.lifecycleBySession.removeValue(forKey: sessionId)
        }
        // The discarded turn's frame goes with it; nothing will close this key.
        presentMacChatTurn(.clearPreview(sessionId))
        presentMacChatTurn(.intakeClosed)
    }

    /// Moves a placeholder session's exact activity generation alongside the
    /// existing chat/task dictionaries. A populated destination owned by a
    /// different turn wins and the placeholder evidence is discarded.
    @discardableResult
    func migrateChatTurnLifecycleIntake(
        from oldSessionId: String,
        to newSessionId: String,
        turnId: String
    ) -> MacChatTurnLifecycleState? {
        guard oldSessionId != newSessionId,
              macChatTurns.activeTurnIDsBySession[oldSessionId] == turnId
        else { return nil }
        if let destinationTurn = macChatTurns.activeTurnIDsBySession[newSessionId],
           destinationTurn != turnId {
            discardChatTurnLifecycleIntake(sessionId: oldSessionId, turnId: turnId)
            return nil
        }

        macChatTurns.activeTurnIDsBySession.removeValue(forKey: oldSessionId)
        macChatTurns.activeTurnIDsBySession[newSessionId] = turnId
        // The live computer pane moves with the turn. Rekeyed in the SAME step
        // as the lifecycle: left behind, the old entry's frame would be a
        // screenshot of the desktop retained under a key nothing closes any
        // more, while the card under the new key lost the picture it was
        // showing a moment ago.
        presentMacChatTurn(.movePreview(from: oldSessionId, to: newSessionId))
        if let oldState = macChatTurns.lifecycleBySession.removeValue(forKey: oldSessionId),
           oldState.identity.turnId == turnId {
            let reboundIdentity = MacChatTurnIdentity(
                sessionId: newSessionId,
                turnId: turnId
            )
            let rebound = MacChatTurnLifecycleState(
                identity: reboundIdentity,
                presentation: oldState.presentation,
                cancellationRequestedAt: oldState.cancellationRequestedAt,
                terminalEvidence: oldState.terminalEvidence
            )
            macChatTurns.lifecycleBySession[newSessionId] = rebound
            return rebound
        }
        return nil
    }

    @discardableResult
    func persistChatTurnLifecycleBegin(identity: MacChatTurnIdentity) async -> Bool {
        guard let state = macChatTurns.lifecycleBySession[identity.sessionId],
              state.identity == identity else { return false }
        do {
            try await macChatTurns.lifecycleStore.begin(state)
            return true
        } catch {
            logChatTurnLifecyclePersistenceFailure("begin", error: error)
            return false
        }
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

    @discardableResult
    func persistChatTurnLifecycleMigration(
        state: MacChatTurnLifecycleState,
        from oldSessionId: String
    ) async -> Bool {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                guard try await macChatTurns.lifecycleStore.migrate(
                    state: state,
                    from: oldSessionId
                ) else {
                    macChatTurns.chatTurnLifecycleRepairCompleted = false
                    logChatTurnLifecyclePersistenceFailure(
                        "migrate",
                        error: MacChatTurnLifecycleStoreError.missingExactTurn
                    )
                    return false
                }
                return true
            } catch {
                lastError = error
            }
        }
        logChatTurnLifecyclePersistenceFailure(
            "migrate",
            error: lastError ?? MacChatTurnLifecycleStoreError.missingExactTurn
        )
        macChatTurns.chatTurnLifecycleRepairCompleted = false
        return false
    }

    /// Roll back a lifecycle reservation that failed before provider admission.
    /// No turn was accepted at this point, so removing the exact snapshot is
    /// safer than leaving a repairable orphan that never performed work.
    func abandonChatTurnLifecycleBeforeAdmission(identity: MacChatTurnIdentity) async {
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
            guard knownSessionIds.contains(record.sessionId) else {
                // Session-index reconciliation is independently bounded at
                // launch, so a transcript can briefly exist before its index
                // row. Settle the snapshot itself, but keep it for a later
                // reload instead of treating index absence as deletion.
                //
                // Repair stays pending only while this record still has
                // outcome work left. A record we settle here — or one that
                // already carries closed terminal evidence — needs nothing
                // more, so a DELETED session's terminal tombstone must not
                // pin the flag false for the remaining life of the process.
                guard macChatTurns.activeTurnIDsBySession[record.sessionId] == nil else {
                    // A live turn in this process still owns the outcome.
                    hasPendingRepairWork = true
                    continue
                }
                guard !record.isTerminal else { continue }
                let proof = await loadProof(record.identity)
                guard macChatTurns.activeTurnIDsBySession[record.sessionId] == nil else {
                    hasPendingRepairWork = true
                    continue
                }
                guard let repaired = MacChatTurnLifecycleRestartRepair.repair(
                    record: record,
                    transcriptProof: proof,
                    at: instant
                ) else {
                    hasPendingRepairWork = true
                    continue
                }
                do {
                    if try await macChatTurns.lifecycleStore.update(repaired) == false {
                        repairPersistenceFailed = true
                    }
                } catch {
                    repairPersistenceFailed = true
                    logChatTurnLifecyclePersistenceFailure("repair_unindexed", error: error)
                }
                continue
            }
            // Indexed and live: the running turn already owns both its
            // in-memory projection and its own terminal settlement, so it
            // needs no later repair pass.
            guard macChatTurns.activeTurnIDsBySession[record.sessionId] == nil else {
                continue
            }
            let proof = record.isTerminal ? .absent : await loadProof(record.identity)
            guard let repaired = MacChatTurnLifecycleRestartRepair.repair(
                record: record,
                transcriptProof: proof,
                at: instant
            ) else { continue }
            guard macChatTurns.activeTurnIDsBySession[record.sessionId] == nil else {
                continue
            }
            // This is the one lifecycle write that does not pass through the
            // reducer or the store, both of which refuse to mutate a terminal.
            // Honour the same immutability here: an in-memory terminal for
            // THIS exact turn is settled truth the user has already seen, and
            // a durable row that lagged behind it (or a transiently
            // unreadable transcript yielding `.unavailable`) must never
            // downgrade a proven completed/failed/canceled turn to
            // outcome-unknown. Re-persist that truth instead of recomputing it.
            let liveState = macChatTurns.lifecycleBySession[record.sessionId]
            let liveTerminalWins = liveState?.identity == record.identity
                && liveState?.presentation.isTerminal == true
            let settled = liveTerminalWins ? (liveState ?? repaired) : repaired
            if !liveTerminalWins {
                macChatTurns.lifecycleBySession[record.sessionId] = settled
            }
            if !record.isTerminal {
                do {
                    if try await macChatTurns.lifecycleStore.update(settled) == false {
                        repairPersistenceFailed = true
                    }
                } catch {
                    repairPersistenceFailed = true
                    logChatTurnLifecyclePersistenceFailure("repair_update", error: error)
                }
            }
        }
        macChatTurns.chatTurnLifecycleRepairCompleted = !hasPendingRepairWork && !repairPersistenceFailed
        return !repairPersistenceFailed
    }

    private func logChatTurnLifecyclePersistenceFailure(_ operation: String, error: Error) {
        let safe = NativeAppSecretRedactor.redactText(String(describing: error))
        NSLog("Mac chat turn lifecycle %@ failed: %@", operation, safe)
    }

}

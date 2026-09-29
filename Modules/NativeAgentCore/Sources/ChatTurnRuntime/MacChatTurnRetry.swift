import Foundation
import TurnTrace

public struct MacChatRetryAdmission: Sendable {
    public let identity: MacChatTurnIdentity
    public let generation: Int
}

public extension MacChatTurnPresentationPort {
    func admitMacChatRetry(
        sessionId: String,
        matchesCanonical: @MainActor () async -> Bool,
        stillMatchesLocal: @MainActor () -> Bool
    ) async -> MacChatRetryAdmission? {
        // FIX 4: same Stop-then-quick-restart ordering barrier as sendChat.
        await awaitPendingCancelFlagWrite(for: sessionId)
        let repairAvailable = await repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: knownChatSessionIDs
        ) { identity in
            await self.readCanonicalChatTurnTerminalProof(identity: identity)
        }
        guard repairAvailable,
              knownChatSessionIDs.contains(sessionId) else {
            presentMacChatTurn(.status(repairAvailable
                ? "Regenerate failed: that chat session is no longer available"
                : "Regenerate failed: lifecycle recovery is unavailable"))
            return nil
        }
        // PATCH-2026-05-13: parallel-sessions — guard per-session, not global
        guard macChatTurns.tasks[sessionId] == nil, !macChatTurns.busySessions.contains(sessionId) else {
            presentMacChatTurn(.status("Chat is already running in that session"))
            return nil
        }
        // Reserve the session across canonical reads. A second ordinary send
        // may queue, but cannot race this retry into provider execution.
        macChatTurns.busySessions.insert(sessionId)
        let generation = (macChatTurns.taskGenerations[sessionId] ?? 0) + 1
        macChatTurns.taskGenerations[sessionId] = generation
        let lifecycleIdentity = MacChatTurnIdentity(
            sessionId: sessionId,
            turnId: TurnTraceContext.mintTurnId()
        )
        _ = beginChatTurnLifecycle(
            sessionId: lifecycleIdentity.sessionId,
            turnId: lifecycleIdentity.turnId,
            at: Date()
        )
        let lifecyclePersisted = await persistChatTurnLifecycleBegin(
            identity: lifecycleIdentity
        )
        let canonicalMatches = await matchesCanonical()
        let admissionStillCurrent = macChatTurns.lifecycle(for: sessionId)?.identity
            == lifecycleIdentity
            && macChatTurns.lifecycle(for: sessionId)?.cancellationRequestedAt == nil
            && canonicalMatches
            && stillMatchesLocal()
            && knownChatSessionIDs.contains(sessionId)
            && !Task.isCancelled
        guard lifecyclePersisted, admissionStillCurrent else {
            macChatTurns.busySessions.remove(sessionId)
            macChatTurns.taskGenerations[sessionId] = nil
            await abandonChatTurnLifecycleBeforeAdmission(identity: lifecycleIdentity)
            presentMacChatTurn(.status(lifecyclePersisted
                ? "Regenerate failed: the conversation changed before retry began"
                : "Regenerate failed: the turn could not be durably admitted"))
            await drainNextQueuedChatTurnIfPossible(sessionId: sessionId)
            return nil
        }
        return MacChatRetryAdmission(identity: lifecycleIdentity, generation: generation)
    }

    func runAdmittedMacChatRetry(
        _ admission: MacChatRetryAdmission,
        operation: @escaping @MainActor () async -> Bool,
        didComplete: @MainActor () -> Void
    ) async {
        let sessionId = admission.identity.sessionId
        let lifecycleIdentity = admission.identity
        var regeneratedTurnCompleted = false
        let task = Task { @MainActor in
            _ = applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
                identity: lifecycleIdentity,
                kind: .retrying(action: "Retrying response"),
                occurredAt: Date()
            ))
            do {
                regeneratedTurnCompleted = try await macChatTurns.runAdmittedTurn(sessionID: sessionId) {
                    await operation()
                }
            } catch {
                presentMacChatTurn(.status(error.localizedDescription))
            }
            if let closed = closeChatTurnLifecycleIntake(
                sessionId: sessionId,
                turnId: lifecycleIdentity.turnId,
                at: Date()
            ) {
                await persistChatTurnLifecycleUpdate(identity: closed.identity)
            }
        }
        macChatTurns.tasks[sessionId] = task
        macChatTurns.streamingSessions.insert(sessionId)
        await task.value
        _ = macChatTurns.finishRuntime(sessionId: sessionId, generation: admission.generation)
        if regeneratedTurnCompleted { didComplete() }
        await drainNextQueuedChatTurnIfPossible(sessionId: sessionId)
    }

    func settleMacChatRetry(
        identity: MacChatTurnIdentity,
        error: Error? = nil
    ) async -> MacChatStreamSettlement {
        let signal: MacChatTurnObservedTerminalSignal
        if let error {
            if error is CancellationError {
                // The compatibility API can throw cancellation-shaped text.
                // Only this task's actual cancellation supplies typed evidence.
                signal = Task.isCancelled ? .cancellationAcknowledged : .ambiguousTermination
            } else if Task.isCancelled {
                signal = .none
            } else {
                // A compatibility throw can follow an effect/persistence write;
                // canonical transcript evidence must decide its outcome.
                signal = .none
            }
        } else {
            signal = .finalResponse
        }
        let proof = await readCanonicalChatTurnTerminalProof(identity: identity)
        let state = await settleChatTurnLifecycle(
            identity: identity,
            kind: MacChatTurnLifecycleTerminalResolver.resolve(
                transcriptProof: proof, observedSignal: signal
            ),
            at: Date()
        )
        return MacChatStreamSettlement(proof: proof, state: state, signal: signal)
    }
}

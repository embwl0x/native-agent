import Foundation
import TurnTrace
// Blueprint: | `MacChatTurnRetry.swift` | `MacChatTurnPresentationPort`: `admitMacChatRetry`, `runAdmittedMacChatRetry` |

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
        guard let generation = macChatTurns.reserveTurn(sessionId: sessionId) else {
            presentMacChatTurn(.status("Chat is already running in that session"))
            return nil
        }
        var admitted = false
        defer {
            if !admitted { _ = macChatTurns.finishRuntime(sessionId: sessionId, generation: generation) }
        }
        // Stop's flag write precedes this turn's flag-clear.
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
        guard macChatTurns.taskGenerations[sessionId] == generation else {
            presentMacChatTurn(.status("Chat is already running in that session"))
            return nil
        }
        // Reserve the session across canonical reads. A second ordinary send
        // may queue, but cannot race this retry into provider execution.
        let lifecycleIdentity = MacChatTurnIdentity(
            sessionId: sessionId,
            turnId: TurnTraceContext.mintTurnId()
        )
        let lifecycle = await beginChatTurnLifecycle(
            identity: lifecycleIdentity,
            generation: generation,
            at: Date()
        )
        let canonicalMatches = await matchesCanonical()
        let admissionStillCurrent = chatTurnAdmissionIsCurrent(identity: lifecycleIdentity, generation: generation)
            && canonicalMatches
            && stillMatchesLocal()
            && knownChatSessionIDs.contains(sessionId)
        guard lifecycle.persisted, lifecycle.isCurrent, admissionStillCurrent else {
            await abandonChatTurnLifecycleBeforeAdmission(identity: lifecycleIdentity, generation: generation)
            presentMacChatTurn(.status(lifecycle.persisted
                ? "Regenerate failed: the conversation changed before retry began"
                : "Regenerate failed: the turn could not be durably admitted"))
            await drainNextQueuedChatTurnIfPossible(sessionId: sessionId)
            return nil
        }
        admitted = true
        return MacChatRetryAdmission(identity: lifecycleIdentity, generation: generation)
    }

    func runAdmittedMacChatRetry(
        _ admission: MacChatRetryAdmission,
        operation: @escaping @MainActor () async -> Bool,
        didComplete: @MainActor () -> Void
    ) async {
        let sessionId = admission.identity.sessionId
        let lifecycleIdentity = admission.identity
        guard macChatTurns.taskGenerations[sessionId] == admission.generation else { return }
        var regeneratedTurnCompleted = false
        let task = Task { @MainActor in
            _ = applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
                identity: lifecycleIdentity,
                kind: .retrying(action: "Retrying response"),
                occurredAt: Date()
            ))
            do {
                regeneratedTurnCompleted = try await macChatTurns.runAdmittedTurn(sessionID: sessionId, turnID: lifecycleIdentity.turnId) {
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


}

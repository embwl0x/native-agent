import Foundation
import NativeAgentShared
import TurnTrace
import PersistenceCore
import ChatTurnContracts
import MacControl
import NativeAgentCore
// Blueprint: | `MacChatTurnAdmission.swift` | `MacChatTurnPresentationPort`: `rejectMacChatTurn`, `startChatTurn`, `stopChatStream` |

public enum MacChatTurnAcceptance: Equatable, Sendable {
    case accepted(sessionId: String)
    case rejected(message: String)
}

public struct MacChatStartedTurn: Sendable {
    public let acceptance: MacChatTurnAcceptance
    public let task: Task<Void, Never>?
}

public extension MacChatTurnPresentationPort {
    func rejectMacChatTurn(_ message: String) -> MacChatTurnAcceptance {
        presentMacChatTurn(.status(message))
        return .rejected(message: message)
    }

    /// An idle conversation starts the person's turn; one the agent is working in takes the send as an arrival while the agent works.
    @MainActor
    func startChatTurn(
        _ text: String,
        attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId targetSessionId: String,
        hideUserBubble: Bool,
        requireActiveSession: Bool,
        requireIdleAndEmpty: Bool = false,
        origin: ChatMessageOrigin? = nil,
        parent: Turn? = nil
    ) async -> MacChatStartedTurn {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            let rejection = rejectMacChatTurn("Nothing to send")
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        guard !targetSessionId.isEmpty else {
            let rejection = rejectMacChatTurn("No active chat session. Your message was not sent.")
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        // Only the user's handoff takes the Mac back; agent-authored input cannot.
        if !hideUserBubble, origin == nil, UserMessageIntentSignals.isControlHandoff(text) {
            guard knownChatSessionIDs.contains(targetSessionId),
                  !requireActiveSession || activeChatSessionId == targetSessionId else {
                return MacChatStartedTurn(
                    acceptance: rejectMacChatTurn("That chat session is no longer available. Your message was not sent."),
                    task: nil
                )
            }
            let activity = macChatTurns.lifecycle(for: targetSessionId)?.presentation.currentAction
            await releaseControlForHandoff(sessionId: targetSessionId) {
                self.cancelICloudChatTurnForControlHandoff(sessionId: targetSessionId)
            }
            let reply = UserMessageIntentSignals.controlHandoffReply(lastActivity: activity)
            presentMacChatTurn(.status(reply))
            let handoffTurn = TurnRequest(message: text, sessionID: targetSessionId, surface: "chat",
                envelope: TurnEnvelope.personOnMac("mac_ui:handoff")).turn()
            let task = Task { @MainActor in
                do {
                    try await recordMacControlHandoff(text: text, reply: reply, sessionId: targetSessionId, turn: handoffTurn)
                } catch {
                    presentMacChatTurn(.status("Control released, but the handoff could not be saved: \(error.localizedDescription)"))
                }
            }
            return MacChatStartedTurn(acceptance: .accepted(sessionId: targetSessionId), task: task)
        }
        let reservation = macChatTurns.reserveTurn(sessionId: targetSessionId)
        var transferredReservation = false
        defer {
            if !transferredReservation, let reservation {
                _ = macChatTurns.finishRuntime(sessionId: targetSessionId, generation: reservation)
            }
        }
        let requestTurnID = TurnTraceContext.mintTurnId()
        let continuation: MacWorkContinuation?
        if let parent { continuation = parent.envelope?.macContinuation }
        else { continuation = await captureMacWorkContinuation(text, taskReference: requestTurnID) }
        // This is the native Mac send owner, so its local origin is explicit here.
        let nativeOrigin: TurnEnvelope
        if let parent {
            guard let heldOrigin = parent.envelope else {
                return MacChatStartedTurn(acceptance: rejectMacChatTurn("The continuing request has no origin. Nothing was sent."), task: nil)
            }
            nativeOrigin = heldOrigin
        } else { nativeOrigin = .personOnMac("mac_ui:chat.send") }
        let envelope = continuation.map { nativeOrigin.withMacContinuation($0) } ?? nativeOrigin
        // A shown send under a parent owns its run, so its row never collides with that turn's own user row.
        let ownRun: String?? = parent != nil && !hideUserBubble ? .some(UUID().uuidString) : nil
        // One id for the shown bubble, the row a steering persister writes and the row the turn writes.
        let turn = TurnRequest(message: text, sessionID: targetSessionId, surface: "chat",
            envelope: .some(envelope), origin: .some(origin ?? parent?.origin), pinnedRunID: ownRun)
            .turn(id: requestTurnID, parent: parent)
            .with(\.rows.pinnedUserMessageID, hideUserBubble ? nil : UUID().uuidString)
        // The words exactly as the turn writes its row, so the saved row, a steered row and the turn's own are one row.
        let words = trimmed.isEmpty ? "(see attachments)" : trimmed
        let arrival = TurnArrival(words: words, attachments: attachments, surface: "chat", row: hideUserBubble ? .hidden : .saved)
        // Await Stop's flag write before the busy guards and this turn's flag-clear.
        await awaitPendingCancelFlagWrite(for: targetSessionId)
        let repairAvailable = await repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: knownChatSessionIDs
        ) { identity in
            await self.readCanonicalChatTurnTerminalProof(identity: identity)
        }
        guard repairAvailable else {
            let rejection = rejectMacChatTurn(
                "Chat could not start safely because lifecycle recovery is unavailable"
            )
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        guard knownChatSessionIDs.contains(targetSessionId) else {
            let rejection = rejectMacChatTurn(
                "That chat session is no longer available. Your message was not sent."
            )
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        if requireActiveSession, activeChatSessionId != targetSessionId {
            let rejection = rejectMacChatTurn(
                "The active chat changed before send. Your message was not sent."
            )
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        if let reservation, macChatTurns.taskGenerations[targetSessionId] != reservation {
            return MacChatStartedTurn(acceptance: .rejected(message: "Chat admission was superseded"), task: nil)
        }
        // Recheck welcome eligibility after suspension so the greeting never rides a turn already running.
        if requireIdleAndEmpty && (reservation == nil || chatHasConversationRows(sessionId: targetSessionId)) {
            return MacChatStartedTurn(
                acceptance: .rejected(message: "The greeting's conversation is no longer idle and empty"),
                task: nil
            )
        }
        let identity = MacChatTurnIdentity(sessionId: targetSessionId, turnId: requestTurnID)
        // A shown send is saved before it is accepted, so a relaunch before it is answered resumes it; a hidden card keeps its own claim.
        if !hideUserBubble {
            do { try await saveMacArrival(words, attachments: attachments, sessionId: targetSessionId, turn: turn) }
            catch {
                return MacChatStartedTurn(acceptance: rejectMacChatTurn("Your message could not be saved, so it was not sent: "
                    + error.localizedDescription), task: nil)
            }
        }
        guard let generation = reservation else {
            let task = Task { @MainActor in
                await arriveWhileWorking(text, attachments: attachments, hideUserBubble: hideUserBubble,
                                         arrival: arrival, identity: identity, turn: turn)
            }
            return MacChatStartedTurn(acceptance: .accepted(sessionId: targetSessionId), task: task)
        }
        guard await beginMacChatTurn(identity: identity, generation: generation) else {
            let rejection = rejectMacChatTurn(
                "Chat could not start safely because its lifecycle receipt was not persisted"
            )
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        let task = launchMacChatTurn(identity: identity, generation: generation) { [self] finish in
            do {
                let admitted = try await macChatTurns.runAdmittedTurn(sessionID: targetSessionId, turnID: identity.turnId,
                                                                      arrival: arrival, turn: turn) { turn in
                    await runMacChatTurnBody(text, attachments: attachments, sessionId: targetSessionId, generation: generation,
                                             hideUserBubble: hideUserBubble, activityIdentity: identity, turn: turn)
                    await finish()
                }
                // Another door's turn of the agent's read it: the agent's reply there answers, so this turn ends with none.
                if case .steered = admitted { await settleChatTurnLifecycle(identity: identity, kind: .completed) }
            } catch {
                presentMacChatTurn(.status(error.localizedDescription))
            }
        }
        transferredReservation = true
        return MacChatStartedTurn(acceptance: .accepted(sessionId: targetSessionId), task: task)
    }

    /// The person's words while the agent works: offered to the agent's open turn, or run as their own turn when their place comes.
    /// Not the session's task until it runs, so Stop keeps targeting the turn in progress.
    @MainActor
    private func arriveWhileWorking(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment], hideUserBubble: Bool,
        arrival: TurnArrival, identity: MacChatTurnIdentity, turn: Turn
    ) async {
        let sid = identity.sessionId
        if !hideUserBubble { showMacChatUserBubble(text, attachments: attachments, sessionId: sid, turn: turn) }
        while true {
            let admitted: TurnAdmission.Admitted<Bool>
            do {
                admitted = try await macChatTurns.runAdmittedTurn(sessionID: sid, turnID: identity.turnId,
                                                                  arrival: arrival, turn: turn) { turn in
                    // A Mac turn finishes inside its own place, so one still holding the session never had its place yet:
                    // it was sent first and may wait in line behind this one. Give the place back rather than wait on it.
                    guard let generation = macChatTurns.reserveTurn(sessionId: sid) else { return false }
                    guard await beginMacChatTurn(identity: identity, generation: generation) else {
                        presentMacChatTurn(.status("Chat could not start safely because its lifecycle receipt was not persisted"))
                        return true
                    }
                    await launchMacChatTurn(identity: identity, generation: generation) { [self] finish in
                        await runMacChatTurnBody(text, attachments: attachments, sessionId: sid, generation: generation,
                                                 hideUserBubble: hideUserBubble, activityIdentity: identity, turn: turn)
                        await finish()
                    }.value
                    return true
                }
            } catch {
                presentMacChatTurn(.status(error.localizedDescription))
                return
            }
            guard case .ran(false) = admitted else { return }
            // Arrive again behind that turn once the Mac session moves.
            while macChatTurns.tasks[sid] != nil || macChatTurns.busySessions.contains(sid) {
                await macChatTurns.sessionSlotChange()
            }
        }
    }

    /// Begin the reserved turn's durable lifecycle; an unpersisted receipt releases the reservation.
    @MainActor
    private func beginMacChatTurn(identity: MacChatTurnIdentity, generation: Int) async -> Bool {
        let lifecycle = await beginChatTurnLifecycle(identity: identity, generation: generation, at: Date())
        guard lifecycle.persisted, lifecycle.isCurrent else {
            await abandonChatTurnLifecycleBeforeAdmission(identity: identity, generation: generation)
            return false
        }
        return true
    }

    /// The turn's own task: Stop targets it, the composer streams it, and it closes the lifecycle it began.
    /// `run` finishes the turn inside its admitted place, so the next arrival's place finds the session free.
    @MainActor
    private func launchMacChatTurn(identity: MacChatTurnIdentity, generation: Int,
                                   run: @escaping @MainActor @Sendable (_ finish: @escaping @MainActor @Sendable () async -> Void) async -> Void)
        -> Task<Void, Never> {
        let sid = identity.sessionId
        // Idempotent: a second close finds no open intake and a second finish no generation.
        let finish: @MainActor @Sendable () async -> Void = { [self] in
            if let closed = closeChatTurnLifecycleIntake(sessionId: sid, turnId: identity.turnId, at: Date()) {
                await persistChatTurnLifecycleUpdate(identity: closed.identity)
            }
            _ = macChatTurns.finishRuntime(sessionId: sid, generation: generation)
        }
        let task = Task { @MainActor in
            if !Task.isCancelled, macChatTurns.taskGenerations[sid] == generation {
                _ = applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(identity: identity, kind: .working(action: nil), occurredAt: Date()))
                await run(finish)
            }
            await finish()
        }
        macChatTurns.tasks[sid] = task
        macChatTurns.streamingSessions.insert(sid)
        return task
    }

    /// Retain the executing generation through cancellation so its cleanup can remove the optimistic bubble.
    /// A replacement generation must survive that cleanup; admission without a task is revoked by requestStop.
    @MainActor
    func stopChatStream(sessionId: String? = nil,
                        revokeDriverControl: (@MainActor @Sendable () async -> Void)? = nil) {
        // Main-window Stop targets only its active session; choosing an arbitrary background stream could cancel unrelated work.
        let sid = sessionId ?? activeChatSessionId
        guard !sid.isEmpty else { return }
        if let turnId = macChatTurns.activeTurnIDsBySession[sid],
           let requested = requestChatTurnCancellation(
               sessionId: sid,
               turnId: turnId,
               at: Date()
           ) {
            Task { @MainActor in
                await persistChatTurnLifecycleUpdate(identity: requested.identity)
            }
        }
        macChatTurns.requestStop(sessionId: sid,
                                 revokeDriverControl: revokeDriverControl)
        // Let the in-flight task clean its own busy state and buffers to avoid racing settlement.
    }

    /// Revoke the driver before Stop and supersede waiting remote inputs; suspended Mac admission must also be refused.
    @MainActor
    func releaseControlForHandoff(sessionId: String,
                                  cancelRemoteTurn: @escaping @MainActor @Sendable () -> Void) async {
        macChatTurns.controlHandoffGenerations[sessionId, default: 0] += 1
        stopChatStream(sessionId: sessionId, revokeDriverControl: {
            await MacAttentionSessionStore.shared.revokeDriverControl()
            cancelRemoteTurn()
        })
        await awaitPendingCancelFlagWrite(for: sessionId)
    }

    /// Wait for every pending Stop flag write before clearing it for a new turn, or a late write could cancel new work.
    /// Recheck after each await because another Stop may append a newer write.
    @MainActor
    func awaitPendingCancelFlagWrite(for sessionId: String) async {
        while let pending = macChatTurns.pendingStopWrites[sessionId] {
            await pending.value
        }
    }
}

import Foundation
import NativeAgentShared
import TurnTrace
import PersistenceCore
import ChatTurnContracts
import MacControl
import NativeAgentCore

public struct QueuedChatTurn: Identifiable, Equatable, Sendable {
    public static let maxPerSession = 20
    public let id: String
    public let text: String
    public let attachments: [NativeAgentShared.MultimodalAttachment]
    public let createdAt: Date
    public let hideUserBubble: Bool
    /// A steering append attempt; reconcile commitment before queue replay.
    public let enqueuedRunID: String?
    public let macContinuation: MacWorkContinuation?
    /// Who sent it when it was not User at this Mac (the agent's own
    /// `chat_session`/composer sends). Rides the queue so the row it writes
    /// later still says so.
    public let origin: ChatMessageOrigin?

    public init(
        id: String = UUID().uuidString,
        text: String,
        attachments: [NativeAgentShared.MultimodalAttachment] = [],
        createdAt: Date = Date(),
        hideUserBubble: Bool = false,
        enqueuedRunID: String? = nil,
        macContinuation: MacWorkContinuation? = nil,
        origin: ChatMessageOrigin? = nil
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.hideUserBubble = hideUserBubble
        self.enqueuedRunID = enqueuedRunID
        self.macContinuation = macContinuation
        self.origin = origin
    }

    public var preview: String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return attachments.count == 1 ? "One attachment" : "\(attachments.count) attachments"
    }

    public var shouldDisplayInSendNextQueue: Bool { !hideUserBubble }
}

public enum MacChatTurnAcceptance: Equatable, Sendable {
    case accepted(sessionId: String)
    case queued(sessionId: String, turnId: String)
    case rejected(message: String)
}

public struct MacChatStartedTurn: Sendable {
    public let acceptance: MacChatTurnAcceptance
    public let task: Task<Void, Never>?
}

/// Shared mutable back-channel between admission and the app's bubble body.
/// Placeholder migration updates the effective session so cleanup targets the
/// post-migration key. MainActor isolation keeps the existing ordering.
@MainActor
public final class MacChatTurnBodyContext {
    public var effectiveSessionId: String
    public init(initial: String) { effectiveSessionId = initial }
}

public extension MacChatTurnPresentationPort {
    func rejectMacChatTurn(_ message: String) -> MacChatTurnAcceptance {
        presentMacChatTurn(.status(message))
        return .rejected(message: message)
    }

    @MainActor
    func startChatTurn(
        _ text: String,
        attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId targetSessionId: String,
        hideUserBubble: Bool,
        requireActiveSession: Bool,
        fromQueue: Bool = false,
        requireIdleAndEmpty: Bool = false,
        enqueuedRunID: String? = nil,
        macContinuation queuedContinuation: MacWorkContinuation? = nil,
        origin: ChatMessageOrigin? = nil
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
        // A handoff is User taking the Mac back; words the agent sent are not that.
        if !fromQueue, !hideUserBubble, origin == nil, UserMessageIntentSignals.isControlHandoff(text) {
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
            let task = Task { @MainActor in
                do {
                    try await recordMacControlHandoff(text: text, reply: reply, sessionId: targetSessionId)
                } catch {
                    presentMacChatTurn(.status("Control released, but the handoff could not be saved: \(error.localizedDescription)"))
                }
            }
            return MacChatStartedTurn(acceptance: .accepted(sessionId: targetSessionId), task: task)
        }
        let requestTurnID = TurnTraceContext.mintTurnId()
        let continuation = fromQueue ? queuedContinuation
            : await captureMacWorkContinuation(text, taskReference: requestTurnID)
        let envelope = continuation.map { TurnEnvelope.current(surface: "chat").withMacContinuation($0) }
            ?? ChatToolSessionContext.envelope
        // FIX 4: order a pending Stop's cancelled.flag write BEFORE this
        // turn's flag-clear. Awaited ahead of the busy guards so the
        // suspension can't open a guard→install re-entrancy window.
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
        let sessionIsRunning = macChatTurns.tasks[targetSessionId] != nil || macChatTurns.busySessions.contains(targetSessionId)
        let queueDrainIsStarting = macChatTurns.drainingQueueSessions.contains(targetSessionId)
        let existingQueue = macChatTurns.queuedBySession[targetSessionId] ?? []
        // 2026-09-18: the welcome's eligibility read precedes suspension.
        // Recheck at admission so a competing turn cannot queue the greeting
        // behind itself; its task would not prove the greeting's delivery.
        if requireIdleAndEmpty && (sessionIsRunning || queueDrainIsStarting
            || !existingQueue.isEmpty || chatHasConversationRows(sessionId: targetSessionId)) {
            return MacChatStartedTurn(
                acceptance: .rejected(message: "The greeting's conversation is no longer idle and empty"),
                task: nil
            )
        }
        if !fromQueue && (sessionIsRunning || queueDrainIsStarting || !existingQueue.isEmpty) {
            guard existingQueue.count < QueuedChatTurn.maxPerSession else {
                let rejection = rejectMacChatTurn("Send-next queue is full (20 messages)")
                return MacChatStartedTurn(acceptance: rejection, task: nil)
            }
            let turn = QueuedChatTurn(
                text: text,
                attachments: attachments,
                hideUserBubble: hideUserBubble,
                macContinuation: continuation,
                origin: origin
            )
            macChatTurns.queuedBySession[targetSessionId, default: []].append(turn)
            presentMacChatTurn(.status(existingQueue.isEmpty ? "Message queued to send next" : "Message added to queue"))
            // Item 5 (third conversation pass): an ordinary follow-up sent while
            // a turn is working no longer has to wait for it to finish. Offer it
            // to the running turn, which takes it at its next tool boundary —
            // before it chooses another action. It stays in the queue (the
            // visible Next row, Steer and remove included) until the turn
            // takes it; refused or stranded → it runs exactly as it always
            // did. Attachments are never steered: their
            // bytes belong to a turn of their own.
            // The agent's own send is never folded into a running turn: it
            // would land there as User's words. Her queued sends do not keep
            // User's correction from steering his running turn.
            if continuation == nil, origin == nil, sessionIsRunning,
               existingQueue.allSatisfy({ $0.origin != nil }), attachments.isEmpty,
               !hideUserBubble, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { @MainActor in
                    let taken = await ChatTurnSteering.shared.offer(
                        ChatTurnSteering.Offer(id: turn.id, text: text),
                        sessionId: targetSessionId
                    ) {
                        // Delivered (its transcript row is on disk): leave the queue.
                        for (sid, turns) in self.macChatTurns.queuedBySession
                        where turns.contains(where: { $0.id == turn.id }) {
                            let left = turns.filter { $0.id != turn.id }
                            self.macChatTurns.queuedBySession[sid] = left.isEmpty ? nil : left
                        }
                    }
                    if taken {
                        presentMacChatTurn(.status("Sent to the turn in progress"))
                    }
                }
            }
            if !sessionIsRunning && !macChatTurns.pausedQueueSessions.contains(targetSessionId) {
                Task { @MainActor in await drainNextQueuedChatTurnIfPossible(sessionId: targetSessionId) }
            }
            return MacChatStartedTurn(
                acceptance: .queued(sessionId: targetSessionId, turnId: turn.id),
                task: nil
            )
        }
        guard !sessionIsRunning else {
            let rejection = rejectMacChatTurn("Chat is already running in that session")
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        guard !fromQueue || !macChatTurns.pausedQueueSessions.contains(targetSessionId) else {
            return MacChatStartedTurn(
                acceptance: .rejected(message: "Send-next queue is paused"),
                task: nil
            )
        }
        macChatTurns.pausedQueueSessions.remove(targetSessionId)
        let generation = (macChatTurns.taskGenerations[targetSessionId] ?? 0) + 1
        macChatTurns.taskGenerations[targetSessionId] = generation
        let activityIdentity = MacChatTurnIdentity(
            sessionId: targetSessionId,
            turnId: requestTurnID
        )
        _ = beginChatTurnLifecycle(
            sessionId: activityIdentity.sessionId,
            turnId: activityIdentity.turnId,
            at: Date()
        )
        macChatTurns.busySessions.insert(targetSessionId)
        let lifecyclePersisted = await persistChatTurnLifecycleBegin(
            identity: activityIdentity
        )
        let admissionStillCurrent = macChatTurns.lifecycle(for: targetSessionId)?.identity
            == activityIdentity
            && macChatTurns.lifecycle(for: targetSessionId)?.cancellationRequestedAt == nil
            && !Task.isCancelled
        guard lifecyclePersisted, admissionStillCurrent else {
            macChatTurns.busySessions.remove(targetSessionId)
            macChatTurns.taskGenerations[targetSessionId] = nil
            await abandonChatTurnLifecycleBeforeAdmission(identity: activityIdentity)
            let rejection = rejectMacChatTurn(
                "Chat could not start safely because its lifecycle receipt was not persisted"
            )
            await drainNextQueuedChatTurnIfPossible(sessionId: targetSessionId)
            return MacChatStartedTurn(acceptance: rejection, task: nil)
        }
        // 2026-06-08 W0.3 fix-2 HIGH: the placeholder-id latch inside
        // _sendChatBody may migrate per-session state from `targetSessionId`
        // to a confirmed `sid`. The cleanup below has to find the task /
        // generation / streamingSessions entry at its FINAL key, otherwise
        // they leak forever under `sid` and block future sends. The shared
        // context object is the back-channel _sendChatBody uses to report
        // its final effective session id.
        let bodyCtx = MacChatTurnBodyContext(initial: targetSessionId)
        let task = Task { @MainActor in
            if !Task.isCancelled {
                _ = applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
                    identity: activityIdentity,
                    kind: .working(action: nil),
                    occurredAt: Date()
                ))
                do {
                    try await macChatTurns.runAdmittedTurn(sessionID: targetSessionId) {
                        await ChatToolSessionContext.$envelope.withValue(envelope) {
                            await ChatPersistenceContext.$pinnedTurnRunID.withValue(enqueuedRunID) {
                                // The user row says who sent it, so a reply to the
                                // agent's own send never mirrors as User's. No origin
                                // keeps whatever the caller already bound.
                                await TurnRequest(message: text, sessionID: targetSessionId, surface: "chat",
                                    origin: .some(origin ?? ChatPersistenceContext.originProvenance)).bind {
                                    await runMacChatTurnBody(
                                        text,
                                        attachments: attachments,
                                        sessionId: targetSessionId,
                                        generation: generation,
                                        ctx: bodyCtx,
                                        hideUserBubble: hideUserBubble || enqueuedRunID != nil,
                                        activityIdentity: activityIdentity
                                    )
                                }
                            }
                        }
                    }
                } catch {
                    presentMacChatTurn(.status(error.localizedDescription))
                }
            }
            let cleanupId = bodyCtx.effectiveSessionId
            if let closed = closeChatTurnLifecycleIntake(
                sessionId: cleanupId,
                turnId: activityIdentity.turnId,
                at: Date()
            ) {
                await persistChatTurnLifecycleUpdate(identity: closed.identity)
            }
            _ = macChatTurns.finishRuntime(sessionId: cleanupId, generation: generation)
            // A steering offer the turn ended before it could take is not lost:
            // it goes back to the head of the queue and runs as an ordinary
            // turn, which is exactly what it would have done before item 5.
            // An unsaved offer is still queued unless it was removed or already
            // started; a saved one (run id) left the queue and always returns.
            let stranded = await ChatTurnSteering.shared.takeStranded(sessionId: cleanupId)
            for offer in stranded.reversed() {
                var turns = macChatTurns.queuedBySession[cleanupId] ?? []
                let wasQueued = turns.contains { $0.id == offer.id }
                guard wasQueued || offer.enqueuedRunID != nil else { continue }
                turns.removeAll { $0.id == offer.id }
                turns.insert(
                    QueuedChatTurn(id: offer.id, text: offer.text, attachments: [],
                                   hideUserBubble: false, enqueuedRunID: offer.enqueuedRunID),
                    at: 0
                )
                macChatTurns.queuedBySession[cleanupId] = turns
            }
            await drainNextQueuedChatTurnIfPossible(sessionId: cleanupId)
        }
        macChatTurns.tasks[targetSessionId] = task
        macChatTurns.streamingSessions.insert(targetSessionId)
        return MacChatStartedTurn(
            acceptance: .accepted(sessionId: targetSessionId),
            task: task
        )
    }

    /// Cancel the chat task for `sessionId` (defaults to the active session).
    /// Other sessions' in-flight tasks are unaffected.
    ///
    /// NOTE: we deliberately do NOT bump `chatTaskGenerations[sid]` here.
    /// The cancel-path cleanup in `_sendChatBody`'s catch block re-checks the
    /// generation before removing the optimistic streaming bubble; bumping
    /// would skip that cleanup and leave a stale empty bubble until the next
    /// manual reload. The generation guard is for "another sendChat replaced
    /// me" races, not for cancellation. `Task.cancel()` is sufficient.
    @MainActor
    func stopChatStream(sessionId: String? = nil, pauseQueuedTurns: Bool = true,
                        revokeDriverControl: (@MainActor @Sendable () async -> Void)? = nil) {
        // A main-window Stop always belongs to the active session. Falling
        // back to an arbitrary background stream after the first click can
        // cancel a different detached turn while the original is still
        // unwinding.
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
        macChatTurns.requestStop(sessionId: sid, pauseQueuedTurns: pauseQueuedTurns,
                                 revokeDriverControl: revokeDriverControl)
        // busySessions and the streaming buffers are cleaned up by the
        // _sendChatBody defer/cancellation path; touching them here would
        // race with the in-flight task.
    }

    /// Every door's handoff: supersede waiting remote inputs, then Stop with the
    /// driver revoked first. The lifecycle cancellation inside Stop also
    /// refuses a Mac turn still suspended in admission.
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

    /// FIX 4 barrier: block a new turn until any in-flight cancelled.flag
    /// write for `sessionId` has landed, so the turn-start flag-clear is
    /// ordered AFTER the write (a stale write landing mid-turn would cancel
    /// the new turn). Loops because a Stop during the await can chain a
    /// newer write; each completed write self-removes its dict entry before
    /// the await resumes, so the loop terminates.
    @MainActor
    func awaitPendingCancelFlagWrite(for sessionId: String) async {
        while let pending = macChatTurns.pendingStopWrites[sessionId] {
            await pending.value
        }
    }

    @MainActor
    func removeQueuedChatTurn(_ turnId: String, sessionId: String) {
        Task { await ChatTurnSteering.shared.withdraw(id: turnId) }
        guard var turns = macChatTurns.queuedBySession[sessionId] else { return }
        turns.removeAll { $0.id == turnId }
        if turns.isEmpty {
            macChatTurns.queuedBySession.removeValue(forKey: sessionId)
        } else {
            macChatTurns.queuedBySession[sessionId] = turns
        }
    }

    /// Promote one queued turn and interrupt the active response. The ordinary
    /// Stop path pauses the queue; steering deliberately keeps it live so the
    /// promoted turn starts only after cancellation persistence has completed.
    @MainActor
    func steerQueuedChatTurn(_ turnId: String, sessionId: String) {
        guard promoteQueuedChatTurn(turnId, sessionId: sessionId) else { return }
        macChatTurns.pausedQueueSessions.remove(sessionId)
        if macChatTurns.tasks[sessionId] != nil || macChatTurns.busySessions.contains(sessionId) || macChatTurns.streamingSessions.contains(sessionId) {
            stopChatStream(sessionId: sessionId, pauseQueuedTurns: false)
        } else {
            Task { @MainActor in await drainNextQueuedChatTurnIfPossible(sessionId: sessionId) }
        }
    }

    @MainActor
    func resumeQueuedChatTurns(sessionId: String, startingWith turnId: String? = nil) {
        if let turnId { _ = promoteQueuedChatTurn(turnId, sessionId: sessionId) }
        macChatTurns.pausedQueueSessions.remove(sessionId)
        Task { @MainActor in await drainNextQueuedChatTurnIfPossible(sessionId: sessionId) }
    }

    @discardableResult
    @MainActor
    func promoteQueuedChatTurn(_ turnId: String, sessionId: String) -> Bool {
        guard var turns = macChatTurns.queuedBySession[sessionId],
              let index = turns.firstIndex(where: { $0.id == turnId })
        else { return false }
        let selected = turns.remove(at: index)
        turns.insert(selected, at: 0)
        macChatTurns.queuedBySession[sessionId] = turns
        return true
    }

    @MainActor
    func drainNextQueuedChatTurnIfPossible(sessionId: String) async {
        guard !sessionId.isEmpty,
              !macChatTurns.pausedQueueSessions.contains(sessionId),
              !macChatTurns.drainingQueueSessions.contains(sessionId),
              macChatTurns.tasks[sessionId] == nil,
              !macChatTurns.busySessions.contains(sessionId),
              let candidate = macChatTurns.queuedBySession[sessionId]?.first
        else { return }

        macChatTurns.drainingQueueSessions.insert(sessionId)
        defer {
            macChatTurns.drainingQueueSessions.remove(sessionId)
            if let head = macChatTurns.queuedBySession[sessionId]?.first, head.id != candidate.id {
                Task { @MainActor in await drainNextQueuedChatTurnIfPossible(sessionId: sessionId) }
            }
        }
        var replayRunID = candidate.enqueuedRunID
        if let runID = replayRunID {
            do {
                let committed = try await SwiftNativeChatOrchestrationClient.steeringMessageCommitted(
                    message: candidate.text, sessionId: sessionId, runId: runID,
                    dataRoot: macChatTurns.dataRoot, persistence: SwiftNativePersistenceCore()
                )
                if !committed { replayRunID = nil }
            } catch {
                // Preserve both the queue entry and its unresolved identity.
                macChatTurns.pausedQueueSessions.insert(sessionId)
                macChatTurns.queuePauseReasons[sessionId] =
                    "Couldn't verify whether your message was saved. Resume the queue to try again."
                return
            }
        }
        // Reconciliation suspends: respect Stop, removal, promotion or a
        // competing start before taking the same head entry from the queue.
        guard !macChatTurns.pausedQueueSessions.contains(sessionId),
              macChatTurns.tasks[sessionId] == nil,
              !macChatTurns.busySessions.contains(sessionId),
              var turns = macChatTurns.queuedBySession[sessionId],
              turns.first?.id == candidate.id else { return }
        turns.removeFirst()
        let next = QueuedChatTurn(
            id: candidate.id, text: candidate.text, attachments: candidate.attachments,
            createdAt: candidate.createdAt, hideUserBubble: candidate.hideUserBubble,
            enqueuedRunID: replayRunID, macContinuation: candidate.macContinuation,
            origin: candidate.origin
        )
        if turns.isEmpty {
            macChatTurns.queuedBySession.removeValue(forKey: sessionId)
        } else {
            macChatTurns.queuedBySession[sessionId] = turns
        }
        let acceptance: MacChatTurnAcceptance
        if let queuedChatTurnStartOverride = macChatTurns.queuedChatTurnStartOverride {
            acceptance = await queuedChatTurnStartOverride(next, sessionId)
        } else {
            // A queued successor keeps its own origin, not the finishing
            // turn's envelope or reply routing.
            let port: any MacChatTurnPresentationPort = self
            acceptance = await Task.detached {
                await port.startChatTurn(
                    next.text,
                    attachments: next.attachments,
                    sessionId: sessionId,
                    hideUserBubble: next.hideUserBubble,
                    requireActiveSession: false,
                    fromQueue: true,
                    enqueuedRunID: next.enqueuedRunID,
                    macContinuation: next.macContinuation,
                    origin: next.origin
                ).acceptance
            }.value
        }
        if case .accepted = acceptance { return }

        // A session mutation or unexpected competing start won the await.
        // Preserve the user's turn at the head instead of dropping it.
        macChatTurns.queuedBySession[sessionId, default: []].insert(next, at: 0)
        macChatTurns.pausedQueueSessions.insert(sessionId)
        // 2026-09-06: carry the rejection's own words to the queue strip. A
        // pause with no stated cause is indistinguishable from one the person
        // asked for.
        if case .rejected(let failureMessage) = acceptance {
            macChatTurns.queuePauseReasons[sessionId] = failureMessage
        } else {
            macChatTurns.queuePauseReasons.removeValue(forKey: sessionId)
        }
    }

    @MainActor
    func migrateQueuedChatTurns(from oldSessionId: String, to newSessionId: String) {
        if let old = macChatTurns.queuedBySession.removeValue(forKey: oldSessionId), !old.isEmpty {
            macChatTurns.queuedBySession[newSessionId] = old + (macChatTurns.queuedBySession[newSessionId] ?? [])
        }
        if macChatTurns.pausedQueueSessions.remove(oldSessionId) != nil {
            macChatTurns.pausedQueueSessions.insert(newSessionId)
        }
        if let reason = macChatTurns.queuePauseReasons.removeValue(forKey: oldSessionId) {
            macChatTurns.queuePauseReasons[newSessionId] = reason
        }
    }

}

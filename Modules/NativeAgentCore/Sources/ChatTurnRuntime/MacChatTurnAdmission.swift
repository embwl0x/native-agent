import Foundation
import NativeAgentShared
import TurnTrace

public struct QueuedChatTurn: Identifiable, Equatable, Sendable {
    public static let maxPerSession = 20
    public let id: String
    public let text: String
    public let attachments: [NativeAgentShared.MultimodalAttachment]
    public let createdAt: Date
    public let hideUserBubble: Bool

    public init(
        id: String = UUID().uuidString,
        text: String,
        attachments: [NativeAgentShared.MultimodalAttachment] = [],
        createdAt: Date = Date(),
        hideUserBubble: Bool = false
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.hideUserBubble = hideUserBubble
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

public struct MacChatStartedTurn {
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
        requireIdleAndEmpty: Bool = false
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
                hideUserBubble: hideUserBubble
            )
            macChatTurns.queuedBySession[targetSessionId, default: []].append(turn)
            presentMacChatTurn(.status(existingQueue.isEmpty ? "Message queued to send next" : "Message added to queue"))
            // Item 5 (third conversation pass): an ordinary follow-up sent while
            // a turn is working no longer has to wait for it to finish. Offer it
            // to the running turn, which takes it at its next tool boundary —
            // before it chooses another action. Taken → it leaves the queue (the
            // running turn owns it now, transcript row included); refused, or
            // never picked up before the turn ended, → it stays queued and runs
            // exactly as it always did. Attachments are never steered: their
            // bytes belong to a turn of their own.
            if sessionIsRunning, existingQueue.isEmpty, attachments.isEmpty,
               !hideUserBubble, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { @MainActor in
                    let taken = await ChatTurnSteering.shared.offer(
                        ChatTurnSteering.Offer(id: turn.id, text: text),
                        sessionId: targetSessionId
                    )
                    if taken {
                        removeQueuedChatTurn(turn.id, sessionId: targetSessionId)
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
        macChatTurns.pausedQueueSessions.remove(targetSessionId)
        let generation = (macChatTurns.taskGenerations[targetSessionId] ?? 0) + 1
        macChatTurns.taskGenerations[targetSessionId] = generation
        let activityIdentity = MacChatTurnIdentity(
            sessionId: targetSessionId,
            turnId: TurnTraceContext.mintTurnId()
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
                        await runMacChatTurnBody(
                            text,
                            attachments: attachments,
                            sessionId: targetSessionId,
                            generation: generation,
                            ctx: bodyCtx,
                            hideUserBubble: hideUserBubble,
                            activityIdentity: activityIdentity
                        )
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
            let stranded = await ChatTurnSteering.shared.takeStranded(sessionId: cleanupId)
            for offer in stranded.reversed() {
                macChatTurns.queuedBySession[cleanupId, default: []].insert(
                    QueuedChatTurn(text: offer.text, attachments: [], hideUserBubble: false),
                    at: 0
                )
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
    func stopChatStream(sessionId: String? = nil, pauseQueuedTurns: Bool = true) {
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
        if pauseQueuedTurns {
            // An offered follow-up can return to the queue as the turn unwinds.
            // Stop must pause that work even when the visible queue is empty.
            macChatTurns.pausedQueueSessions.insert(sid)
            // A Stop is the person's own doing; no failure to report.
            macChatTurns.queuePauseReasons.removeValue(forKey: sid)
        } else if !pauseQueuedTurns {
            macChatTurns.pausedQueueSessions.remove(sid)
        }
        // FIX 4 (2026-06-10 audit): track the cancelled.flag write so a quick
        // re-Send can await it before its turn-start flag-clear. Chain onto
        // any prior pending write so completion order matches issue order.
        let generation = (macChatTurns.pendingStopWriteGenerations[sid] ?? 0) + 1
        macChatTurns.pendingStopWriteGenerations[sid] = generation
        let previousWrite = macChatTurns.pendingStopWrites[sid]
        macChatTurns.pendingStopWrites[sid] = Task { @MainActor in
            await previousWrite?.value
            try? await macChatTurns.stop(sessionId: sid)
            // Self-clean: only the LATEST write removes the bookkeeping.
            if macChatTurns.pendingStopWriteGenerations[sid] == generation {
                macChatTurns.pendingStopWrites[sid] = nil
                macChatTurns.pendingStopWriteGenerations[sid] = nil
            }
        }
        macChatTurns.tasks[sid]?.cancel()
        macChatTurns.tasks[sid] = nil
        macChatTurns.streamingSessions.remove(sid)
        // busySessions and the streaming buffers are cleaned up by the
        // _sendChatBody defer/cancellation path; touching them here would
        // race with the in-flight task.
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
              var turns = macChatTurns.queuedBySession[sessionId],
              !turns.isEmpty
        else { return }

        macChatTurns.drainingQueueSessions.insert(sessionId)
        defer { macChatTurns.drainingQueueSessions.remove(sessionId) }
        let next = turns.removeFirst()
        if turns.isEmpty {
            macChatTurns.queuedBySession.removeValue(forKey: sessionId)
        } else {
            macChatTurns.queuedBySession[sessionId] = turns
        }
        let acceptance: MacChatTurnAcceptance
        if let queuedChatTurnStartOverride = macChatTurns.queuedChatTurnStartOverride {
            acceptance = await queuedChatTurnStartOverride(next, sessionId)
        } else {
            acceptance = await startChatTurn(
                next.text,
                attachments: next.attachments,
                sessionId: sessionId,
                hideUserBubble: next.hideUserBubble,
                requireActiveSession: false,
                fromQueue: true
            ).acceptance
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

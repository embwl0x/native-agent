import Foundation
import NativeAgentShared
import TurnTrace
import PersistenceCore
import ChatTurnContracts
import MacControl
import NativeAgentCore

public struct QueuedChatTurn: Identifiable, Equatable, Sendable, Codable {
    public static let maxPerSession = 20
    public let id: String
    public let text: String
    public var attachments: [NativeAgentShared.MultimodalAttachment]
    public let createdAt: Date
    public let hideUserBubble: Bool
    /// A steering append attempt; reconcile commitment before queue replay.
    public var enqueuedRunID: String?
    private var liveContinuation: MacWorkContinuation? = nil
    public let hadMacContinuation: Bool
    public var macContinuation: MacWorkContinuation? {
        liveContinuation ?? (hadMacContinuation ? .unsupported("process_restarted", taskReference: id) : nil)
    }
    /// Who sent it when it was not User at this Mac (the agent's own
    /// `chat_session`/composer sends). Rides the queue so the row it writes
    /// later still says so.
    public let origin: ChatMessageOrigin?
    public var startedTurnID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, text, attachments, createdAt, hideUserBubble, enqueuedRunID, origin, startedTurnID, hadMacContinuation
    }

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
        self.liveContinuation = macContinuation
        self.hadMacContinuation = macContinuation != nil
        self.origin = origin
    }

    public var preview: String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return attachments.count == 1 ? "One attachment" : "\(attachments.count) attachments"
    }

    public var shouldDisplayInSendNextQueue: Bool { !hideUserBubble && startedTurnID == nil }

    /// Whether Steer can hand this to a running turn. Attachments need a turn
    /// of their own; the agent's own send would land there as User's words; a
    /// saved steering row (run id) is replayed, never offered twice.
    public var canSteerRunningTurn: Bool {
        startedTurnID == nil && attachments.isEmpty && origin == nil && macContinuation == nil && !hideUserBubble
            && enqueuedRunID == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
        queuedTurnID: String? = nil,
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
        // A queue storage failure refuses only queueing (below); an idle chat still sends.
        await macChatTurns.loadQueuedTurnsIfNeeded()
        let requestTurnID = queuedTurnID ?? TurnTraceContext.mintTurnId()
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
            guard existingQueue.filter({ $0.startedTurnID == nil }).count < QueuedChatTurn.maxPerSession else {
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
            await macChatTurns.updateQueuedTurns { queues in
                guard queues[targetSessionId, default: []].filter({ $0.startedTurnID == nil }).count < QueuedChatTurn.maxPerSession else { return }
                queues[targetSessionId, default: []].append(turn)
            }
            if let error = macChatTurns.queueStorageError {
                return MacChatStartedTurn(acceptance: rejectMacChatTurn(error), task: nil)
            }
            guard macChatTurns.queuedBySession[targetSessionId]?.contains(where: { $0.id == turn.id }) == true else {
                return MacChatStartedTurn(acceptance: rejectMacChatTurn("Send-next queue is full (20 messages)"), task: nil)
            }
            presentMacChatTurn(.status(existingQueue.isEmpty ? "Message queued to send next" : "Message added to queue"))
            // User, 2026-10-04: a send while she works waits its turn in the
            // queue. Handing it to the running turn is his choice (Steer).
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
            await macChatTurns.updateQueuedTurns { $0[cleanupId]?.removeAll { $0.startedTurnID == activityIdentity.turnId } }
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
        Task { @MainActor in
            await macChatTurns.updateQueuedTurns { queues in
                queues[sessionId]?.removeAll { $0.id == turnId && $0.startedTurnID == nil }
            }
            guard macChatTurns.queueStorageError == nil,
                  macChatTurns.queuedBySession[sessionId]?.contains(where: { $0.id == turnId }) != true else { return }
            await ChatTurnSteering.shared.withdraw(id: turnId)
            macChatTurns.steeringTurnIDs.remove(turnId)
        }
    }

    /// Steer: hand one queued message to the running turn, which reads it at
    /// its next tool boundary. It stays visible in the queue until the turn
    /// takes it, and leaves only then: the handler refuses delivery when it is
    /// no longer queued (removed, or started as its own turn), so it is sent
    /// exactly once. A turn that ends first puts it at the head of the queue.
    @MainActor
    func steerQueuedChatTurn(_ turnId: String, sessionId: String) {
        guard let turn = macChatTurns.queuedBySession[sessionId]?.first(where: { $0.id == turnId }),
              turn.canSteerRunningTurn,
              macChatTurns.steeringTurnIDs.insert(turnId).inserted else { return }
        Task { @MainActor in
            let taken = await ChatTurnSteering.shared.offer(
                ChatTurnSteering.Offer(id: turnId, text: turn.text,
                    envelope: TurnEnvelope(surface: "chat"), origin: turn.origin), sessionId: sessionId
            ) { offer, committed in
                self.macChatTurns.steeringTurnIDs.remove(turnId)
                guard let entry = self.macChatTurns.queuedBySession
                    .first(where: { $0.value.contains { $0.id == turnId } }) else { return false }
                let saved = await self.macChatTurns.updateQueuedTurns { queues in
                    if committed {
                        queues[entry.key]?.removeAll { $0.id == turnId }
                    } else if let index = queues[entry.key]?.firstIndex(where: {
                        $0.id == turnId && ($0.startedTurnID == nil || $0.startedTurnID == offer.enqueuedRunID)
                    }) {
                        queues[entry.key]?[index].enqueuedRunID = offer.enqueuedRunID
                        queues[entry.key]?[index].startedTurnID = offer.receivingTurnID ?? offer.enqueuedRunID
                    }
                }
                return saved && (committed || self.macChatTurns.queuedBySession[entry.key]?.contains(where: {
                    $0.id == turnId && $0.enqueuedRunID == offer.enqueuedRunID
                        && $0.startedTurnID == (offer.receivingTurnID ?? offer.enqueuedRunID)
                }) == true)
            } onReturned: { offer in
                self.macChatTurns.steeringTurnIDs.remove(offer.id)
                await self.macChatTurns.updateQueuedTurns { queues in
                    guard queues[sessionId]?.contains(where: { $0.id == offer.id }) == true || offer.enqueuedRunID != nil else { return }
                    queues[sessionId]?.removeAll { $0.id == offer.id }
                    queues[sessionId, default: []].insert(QueuedChatTurn(id: offer.id, text: offer.text,
                        enqueuedRunID: offer.enqueuedRunID, origin: offer.origin), at: 0)
                }
            }
            if taken {
                presentMacChatTurn(.status("Steering: it lands at the next step"))
            } else {
                macChatTurns.steeringTurnIDs.remove(turnId)
                presentMacChatTurn(.status("The reply in progress can't take it now; it stays queued"))
            }
        }
    }

    /// Send now: promote one queued turn and interrupt the active response.
    /// The ordinary Stop path pauses the queue; this deliberately keeps it live
    /// so the promoted turn starts only after cancellation persistence has completed.
    @MainActor
    func sendQueuedChatTurnNow(_ turnId: String, sessionId: String) {
        Task { @MainActor in
            guard await promoteQueuedChatTurn(turnId, sessionId: sessionId) else { return }
            macChatTurns.pausedQueueSessions.remove(sessionId)
            if macChatTurns.tasks[sessionId] != nil || macChatTurns.busySessions.contains(sessionId) || macChatTurns.streamingSessions.contains(sessionId) {
                stopChatStream(sessionId: sessionId, pauseQueuedTurns: false)
            } else {
                await drainNextQueuedChatTurnIfPossible(sessionId: sessionId)
            }
        }
    }

    @MainActor
    func resumeQueuedChatTurns(sessionId: String, startingWith turnId: String? = nil) {
        Task { @MainActor in
            await macChatTurns.loadQueuedTurnsIfNeeded()
            if let turnId, await promoteQueuedChatTurn(turnId, sessionId: sessionId) == false { return }
            macChatTurns.pausedQueueSessions.remove(sessionId)
            await drainNextQueuedChatTurnIfPossible(sessionId: sessionId)
        }
    }

    @discardableResult
    @MainActor
    func promoteQueuedChatTurn(_ turnId: String, sessionId: String) async -> Bool {
        let saved = await macChatTurns.updateQueuedTurns { queues in
            guard let index = queues[sessionId]?.firstIndex(where: { $0.id == turnId && $0.startedTurnID == nil }),
                  let selected = queues[sessionId]?.remove(at: index) else { return }
            queues[sessionId]?.insert(selected, at: 0)
        }
        return saved && macChatTurns.queuedBySession[sessionId]?.first?.id == turnId
    }

    @MainActor
    func drainNextQueuedChatTurnIfPossible(sessionId: String) async {
        await macChatTurns.loadQueuedTurnsIfNeeded()
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
        let attachments: [NativeAgentShared.MultimodalAttachment]
        do {
            attachments = try await macChatTurns.lifecycleStore.attachments(for: candidate)
        } catch {
            macChatTurns.pausedQueueSessions.insert(sessionId)
            macChatTurns.queuePauseReasons[sessionId] = "Couldn't read a queued attachment. Restore its saved file before resuming: \(error.localizedDescription)"
            return
        }
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
              macChatTurns.queuedBySession[sessionId]?.first?.id == candidate.id else { return }
        guard candidate.startedTurnID == nil else { return }
        macChatTurns.steeringTurnIDs.remove(candidate.id)
        let next = QueuedChatTurn(
            id: candidate.id, text: candidate.text, attachments: attachments,
            createdAt: candidate.createdAt, hideUserBubble: candidate.hideUserBubble,
            enqueuedRunID: replayRunID, macContinuation: candidate.macContinuation,
            origin: candidate.origin
        )
        guard await macChatTurns.updateQueuedTurns({ queues in
            guard queues[sessionId]?.first?.id == candidate.id,
                  queues[sessionId]?[0].startedTurnID == nil else { return }
            queues[sessionId]?[0].startedTurnID = candidate.id
        }), macChatTurns.queuedBySession[sessionId]?.first?.startedTurnID == candidate.id else { return }
        let acceptance: MacChatTurnAcceptance
        if macChatTurns.pausedQueueSessions.contains(sessionId) {
            acceptance = .rejected(message: "The queue is paused")
        } else if let queuedChatTurnStartOverride = macChatTurns.queuedChatTurnStartOverride {
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
                    queuedTurnID: next.id,
                    macContinuation: next.macContinuation,
                    origin: next.origin
                ).acceptance
            }.value
        }
        if case .accepted = acceptance { return }

        // A session mutation or unexpected competing start won the await.
        // Preserve the user's turn at the head instead of dropping it.
        await macChatTurns.updateQueuedTurns { queues in
            queues[sessionId]?.removeAll { $0.id == next.id }
            var waiting = candidate
            waiting.startedTurnID = nil
            queues[sessionId, default: []].insert(waiting, at: 0)
        }
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
    func migrateQueuedChatTurns(from oldSessionId: String, to newSessionId: String) async {
        await macChatTurns.updateQueuedTurns { queues in
            if let old = queues.removeValue(forKey: oldSessionId), !old.isEmpty {
                queues[newSessionId] = old + (queues[newSessionId] ?? [])
            }
        }
        if macChatTurns.pausedQueueSessions.remove(oldSessionId) != nil {
            macChatTurns.pausedQueueSessions.insert(newSessionId)
        }
        if let reason = macChatTurns.queuePauseReasons.removeValue(forKey: oldSessionId) {
            macChatTurns.queuePauseReasons[newSessionId] = reason
        }
    }

}

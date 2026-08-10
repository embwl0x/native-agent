import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

struct QueuedChatTurn: Identifiable, Equatable, Sendable {
    static let maxPerSession = 20
    let id: String
    let text: String
    let attachments: [MultimodalAttachment]
    let createdAt: Date
    let hideUserBubble: Bool

    init(
        id: String = UUID().uuidString,
        text: String,
        attachments: [MultimodalAttachment] = [],
        createdAt: Date = Date(),
        hideUserBubble: Bool = false
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.hideUserBubble = hideUserBubble
    }

    var preview: String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return attachments.count == 1 ? "One attachment" : "\(attachments.count) attachments"
    }

    var shouldDisplayInSendNextQueue: Bool { !hideUserBubble }
}

struct AppMutationResult: Equatable, Sendable {
    let succeeded: Bool
    let userMessage: String

    static func success(_ message: String) -> Self {
        Self(succeeded: true, userMessage: message)
    }

    static func failure(_ message: String) -> Self {
        Self(succeeded: false, userMessage: message)
    }
}

@MainActor
extension AppModel {
    func compactActiveChat() async -> AppMutationResult {
        guard !activeChatSessionId.isEmpty else {
            return .failure("No active session to compact")
        }
        do {
            _ = try await client.compactSession(sessionId: activeChatSessionId, force: true)
            chatMessages = (try? await client.getChatMessages(sessionId: activeChatSessionId)) ?? chatMessages
            statusText = "Session compacted"
            return .success(statusText)
        } catch {
            statusText = "Compact failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /clear support
    @MainActor
    func clearActiveChatMessages() async {
        guard !activeChatSessionId.isEmpty else { return }
        do {
            _ = try await client.clearChatMessages(sessionId: activeChatSessionId)
            chatMessages = []
        } catch {
            statusText = "Clear failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func regenerateAssistantMessage(_ message: ChatMessage) async {
        guard message.role == "assistant", let index = chatMessages.firstIndex(where: { $0.id == message.id }) else { return }
        let priorUser = chatMessages[..<index].last(where: { $0.role == "user" })
        guard let priorText = priorUser?.content.trimmingCharacters(in: .whitespacesAndNewlines), !priorText.isEmpty else {
            statusText = "Regenerate failed: no prior user message"
            return
        }
        let sessionId = message.sessionId ?? activeChatSessionId
        guard !sessionId.isEmpty else { return }
        // FIX 4: same Stop-then-quick-restart ordering barrier as sendChat.
        await awaitPendingCancelFlagWrite(for: sessionId)
        // PATCH-2026-05-13: parallel-sessions — guard per-session, not global
        guard chatTasks[sessionId] == nil, !busySessions.contains(sessionId) else {
            statusText = "Chat is already running in that session"
            return
        }
        let generation = (chatTaskGenerations[sessionId] ?? 0) + 1
        chatTaskGenerations[sessionId] = generation
        // Sweep R4 C7: synthetic error bubbles are in-memory only — they were
        // never written to chat/messages/<sid>.jsonl. Passing one as the
        // replacement target makes the persistence layer throw ("regenerate
        // replacement target must identify exactly one persisted message"), so
        // now that these bubbles DO render Try again, the retry has to re-send
        // as a fresh turn and simply drop the local notice instead.
        let isSyntheticNotice = message.id.hasPrefix(Self.syntheticErrorIDPrefix)
        // Whether the FAILED turn persisted the user's row decides the
        // re-send shape: the no-provider guard bails before client.chat, so
        // its bubble carries userRowPersisted=false and the retry must let
        // the fresh turn append the user message — suppressing it there
        // would drop the user's message from the persisted thread entirely
        // (gpt-5.5 review 2026-08-06, blocking). Stream/catch bubbles ran a
        // real turn, which appends the user row before the provider call.
        let suppressUserRow = isSyntheticNotice
            ? (message.metadata?.syntheticUserRowPersisted ?? true)
            : true
        if isSyntheticNotice {
            removeChatMessage(id: message.id, from: sessionId)
        }
        let task = Task { @MainActor in
            do {
                busySessions.insert(sessionId)
                defer { busySessions.remove(sessionId) }
                let reply = try await client.chat(
                    message: priorText,
                    sessionId: sessionId,
                    model: chatModel,
                    reasoningEffort: chatReasoningEffort,
                    fileAccess: chatFileAccess,
                    suppressUserAppend: suppressUserRow,
                    replacementAssistantMessageId: isSyntheticNotice ? nil : message.id
                )
                if Task.isCancelled { return }
                if activeChatSessionId == sessionId {
                    if let freshMessages = try? await client.getChatMessages(sessionId: sessionId), !freshMessages.isEmpty {
                        chatMessages = freshMessages
                    } else if let messages = reply.messages, !messages.isEmpty {
                        chatMessages = messages.filter { $0.id != message.id }
                    } else if let msg = reply.message {
                        chatMessages.removeAll { $0.id == message.id }
                        chatMessages.append(msg)
                    } else {
                        chatMessages.removeAll { $0.id == message.id }
                        chatMessages.append(ChatMessage(sessionId: sessionId, role: "assistant", content: reply.output, runId: reply.runId))
                    }
                }
                chatSessions = (try? await client.getChatSessions()) ?? chatSessions
                if activeChatSessionId == sessionId {
                    latestContextReceipt = try? await client.getLatestContextReceipt(sessionId: sessionId)
                }
                statusText = "Regenerated response"
            } catch {
                if !Task.isCancelled {
                    await loadChatState()
                    statusText = "Regenerate failed: \(error.localizedDescription)"
                }
            }
        }
        chatTasks[sessionId] = task
        streamingSessions.insert(sessionId)
        await task.value
        if chatTaskGenerations[sessionId] == generation {
            chatTasks[sessionId] = nil
            chatTaskGenerations[sessionId] = nil
            streamingSessions.remove(sessionId)
            busySessions.remove(sessionId)
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /remember
    @MainActor
    func addMemoryFact(_ text: String) async -> AppMutationResult {
        do {
            _ = try await client.addMemory(text: text)
            statusText = "Memory saved"
            return .success(statusText)
        } catch {
            statusText = "Remember failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    // PATCH-Phase1a-dispatcher: /note slash command handler.
    // POSTs to /v1/notes → daemon dispatches commit_memory via Dispatcher.run().
    // Same execution path as the agent calling commit_memory as a tool.
    func addNote(_ text: String) async -> AppMutationResult {
        do {
            _ = try await client.postNote(text: text, kind: "user_note")
            statusText = "Note committed"
            return .success(statusText)
        } catch {
            statusText = "Note failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    // PATCH-phase-3c: /scratch slash command handler.
    // POSTs to /v1/scratch → daemon dispatches scratchpad_write via Dispatcher.run().
    func writeScratch(key: String, value: String) async -> AppMutationResult {
        do {
            let sessionId = activeChatSessionId.isEmpty ? nil : activeChatSessionId
            let body = try await client.postScratch(key: key, value: value, sessionId: sessionId)
            // FIX 5a (2026-06-10 audit): postScratch reports refusals as
            // {ok:false, error} WITHOUT throwing (no-session, bad sid).
            // Ignoring the body toasted "Scratch set" over a write that never
            // happened.
            guard (body["ok"] as? Bool) == true else {
                let reason = (body["error"] as? String) ?? "scratch write rejected"
                statusText = "Scratch write failed: \(reason)"
                return .failure(statusText)
            }
            statusText = "Scratch \(key) set"
            return .success(statusText)
        } catch {
            statusText = "Scratch write failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    @MainActor
    func archiveActiveChat() async {
        guard !activeChatSessionId.isEmpty else { return }
        let archivingId = activeChatSessionId
        do {
            _ = try await client.updateChatSession(id: archivingId, title: nil, archived: true)
            // PATCH-2026-05-13: parallel-sessions — cancel any in-flight task
            // for the archived session and clean up per-session state so we
            // don't leak entries in the generation/text dicts.
            if chatTasks[archivingId] != nil || streamingSessions.contains(archivingId) {
                stopChatStream(sessionId: archivingId)
            }
            chatTaskGenerations[archivingId] = nil
            streamingTexts[archivingId] = nil
            streamingBubbleIds[archivingId] = nil
            streamingUserTurnIds[archivingId] = nil
            streamingUserTurnTexts[archivingId] = nil
            // 2026-07-21 audit fix: also drop the archived session's cached
            // messages/receipt/detached-refresh state — pruneSessionChatState
            // covers the queue entries the two inline lines used to clear.
            pruneSessionChatState(archivingId)
            activeChatSessionId = ""
            UserDefaults.standard.removeObject(forKey: "activeChatSessionId")
            await loadChatState()
        } catch {
            statusText = "Archive failed: \(error.localizedDescription)"
        }
    }

    enum ChatTurnAcceptance: Equatable, Sendable {
        case accepted(sessionId: String)
        case queued(sessionId: String, turnId: String)
        case rejected(message: String)
    }

    private struct _StartedChatTurn {
        let acceptance: ChatTurnAcceptance
        let task: Task<Void, Never>?
    }

    /// Accept a turn for the currently visible chat without waiting for the
    /// model response. The composer uses this transaction boundary so it only
    /// clears its draft and attachments after the task is actually installed.
    @MainActor
    func startActiveChatTurn(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        expectedSessionId: String? = nil
    ) async -> ChatTurnAcceptance {
        guard let targetSessionId = readyActiveChatSessionId() else {
            return rejectChatTurn(activeChatReadinessFailureMessage())
        }
        if let expectedSessionId,
           expectedSessionId.isEmpty || expectedSessionId != targetSessionId {
            return rejectChatTurn("The active chat changed before send. Your message was not sent.")
        }
        return await startChatTurn(
            text,
            attachments: attachments,
            sessionId: targetSessionId,
            hideUserBubble: false,
            requireActiveSession: true
        ).acceptance
    }

    /// Fixed-session acceptance boundary for detached chat panels. Like the
    /// active composer boundary, this returns as soon as the turn is started
    /// or queued; it does not keep the draft visible until the model finishes.
    @MainActor
    func startChatTurnForSession(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        sessionId: String
    ) async -> ChatTurnAcceptance {
        await startChatTurn(
            text,
            attachments: attachments,
            sessionId: sessionId,
            hideUserBubble: false,
            requireActiveSession: false
        ).acceptance
    }

    @MainActor
    // PATCH-2026-05-06: multimodal-ui Sprint 3 — sendChat now accepts optional attachments
    // PATCH-2026-05-08: wave2-chat-ux — wraps body in cancellable Task, sets isChatStreaming
    // PATCH-2026-05-13: parallel-sessions — guard and bookkeep per-session
    /// Returns the turn's acceptance so one-shot callers (first-run welcome)
    /// can tell a rejected send from an accepted one; ordinary callers ignore
    /// it. Acceptance means the turn was installed, not that streaming
    /// succeeded — mid-stream failures surface in the transcript, not here.
    @discardableResult
    func sendChat(_ text: String, attachments: [MultimodalAttachment] = [], sessionId: String? = nil, hideUserBubble: Bool = false) async -> ChatTurnAcceptance {
        let started: _StartedChatTurn
        if let sessionId, !sessionId.isEmpty {
            // Fixed-session callers (detached windows, first-run greeting) own
            // their target identity and may legitimately send while another
            // session is active.
            started = await startChatTurn(
                text,
                attachments: attachments,
                sessionId: sessionId,
                hideUserBubble: hideUserBubble,
                requireActiveSession: false
            )
        } else {
            guard let targetSessionId = readyActiveChatSessionId() else {
                return rejectChatTurn(activeChatReadinessFailureMessage())
            }
            started = await startChatTurn(
                text,
                attachments: attachments,
                sessionId: targetSessionId,
                hideUserBubble: hideUserBubble,
                requireActiveSession: true
            )
        }
        await started.task?.value
        return started.acceptance
    }

    @MainActor
    private func readyActiveChatSessionId() -> String? {
        let sessionId = activeChatSessionId
        guard !sessionId.isEmpty,
              chatSessions.contains(where: { $0.id == sessionId })
        else { return nil }
        return sessionId
    }

    @MainActor
    private func activeChatReadinessFailureMessage() -> String {
        if chatStateLoadInFlight || chatSessions.isEmpty {
            return "Chat is still starting. Your message was not sent."
        }
        return "No active chat session. Your message was not sent."
    }

    @MainActor
    private func rejectChatTurn(_ message: String) -> ChatTurnAcceptance {
        statusText = message
        return .rejected(message: message)
    }

    @MainActor
    private func startChatTurn(
        _ text: String,
        attachments: [MultimodalAttachment],
        sessionId targetSessionId: String,
        hideUserBubble: Bool,
        requireActiveSession: Bool,
        fromQueue: Bool = false
    ) async -> _StartedChatTurn {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            let rejection = rejectChatTurn("Nothing to send")
            return _StartedChatTurn(acceptance: rejection, task: nil)
        }
        guard !targetSessionId.isEmpty else {
            let rejection = rejectChatTurn("No active chat session. Your message was not sent.")
            return _StartedChatTurn(acceptance: rejection, task: nil)
        }
        // FIX 4: order a pending Stop's cancelled.flag write BEFORE this
        // turn's flag-clear. Awaited ahead of the busy guards so the
        // suspension can't open a guard→install re-entrancy window.
        await awaitPendingCancelFlagWrite(for: targetSessionId)
        if requireActiveSession {
            guard activeChatSessionId == targetSessionId,
                  chatSessions.contains(where: { $0.id == targetSessionId })
            else {
                let rejection = rejectChatTurn("The active chat changed before send. Your message was not sent.")
                return _StartedChatTurn(acceptance: rejection, task: nil)
            }
        }
        let sessionIsRunning = chatTasks[targetSessionId] != nil || busySessions.contains(targetSessionId)
        let queueDrainIsStarting = drainingChatQueueSessions.contains(targetSessionId)
        let existingQueue = queuedChatTurnsBySession[targetSessionId] ?? []
        if !fromQueue && (sessionIsRunning || queueDrainIsStarting || !existingQueue.isEmpty) {
            guard existingQueue.count < QueuedChatTurn.maxPerSession else {
                let rejection = rejectChatTurn("Send-next queue is full (20 messages)")
                return _StartedChatTurn(acceptance: rejection, task: nil)
            }
            let turn = QueuedChatTurn(
                text: text,
                attachments: attachments,
                hideUserBubble: hideUserBubble
            )
            queuedChatTurnsBySession[targetSessionId, default: []].append(turn)
            statusText = existingQueue.isEmpty ? "Message queued to send next" : "Message added to queue"
            if !sessionIsRunning && !pausedChatQueueSessions.contains(targetSessionId) {
                Task { @MainActor in await drainNextQueuedChatTurnIfPossible(sessionId: targetSessionId) }
            }
            return _StartedChatTurn(
                acceptance: .queued(sessionId: targetSessionId, turnId: turn.id),
                task: nil
            )
        }
        guard !sessionIsRunning else {
            let rejection = rejectChatTurn("Chat is already running in that session")
            return _StartedChatTurn(acceptance: rejection, task: nil)
        }
        pausedChatQueueSessions.remove(targetSessionId)
        let generation = (chatTaskGenerations[targetSessionId] ?? 0) + 1
        chatTaskGenerations[targetSessionId] = generation
        // 2026-06-08 W0.3 fix-2 HIGH: the placeholder-id latch inside
        // _sendChatBody may migrate per-session state from `targetSessionId`
        // to a confirmed `sid`. The cleanup below has to find the task /
        // generation / streamingSessions entry at its FINAL key, otherwise
        // they leak forever under `sid` and block future sends. The shared
        // context object is the back-channel _sendChatBody uses to report
        // its final effective session id.
        let bodyCtx = _ChatBodyContext(initial: targetSessionId)
        let task = Task { @MainActor in
            await _sendChatBody(text, attachments: attachments, sessionId: targetSessionId, generation: generation, ctx: bodyCtx, hideUserBubble: hideUserBubble)
            let cleanupId = bodyCtx.effectiveSessionId
            if chatTaskGenerations[cleanupId] == generation {
                streamingSessions.remove(cleanupId)
                busySessions.remove(cleanupId)
                chatTasks[cleanupId] = nil
                chatTaskGenerations[cleanupId] = nil
            }
            await drainNextQueuedChatTurnIfPossible(sessionId: cleanupId)
        }
        chatTasks[targetSessionId] = task
        streamingSessions.insert(targetSessionId)
        return _StartedChatTurn(
            acceptance: .accepted(sessionId: targetSessionId),
            task: task
        )
    }

    /// Shared mutable back-channel between `sendChat` and `_sendChatBody`.
    /// `_sendChatBody` updates `effectiveSessionId` when the placeholder-id
    /// latch migrates per-session state, so `sendChat`'s outer cleanup
    /// targets the post-migration key. @MainActor isolation means no
    /// locking required.
    @MainActor
    final class _ChatBodyContext {
        var effectiveSessionId: String
        init(initial: String) { effectiveSessionId = initial }
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
        let sid = sessionId ?? (streamingSessions.contains(activeChatSessionId) ? activeChatSessionId : (streamingSessions.first ?? activeChatSessionId))
        guard !sid.isEmpty else { return }
        if pauseQueuedTurns, !(queuedChatTurnsBySession[sid] ?? []).isEmpty {
            pausedChatQueueSessions.insert(sid)
        } else if !pauseQueuedTurns {
            pausedChatQueueSessions.remove(sid)
        }
        // FIX 4 (2026-06-10 audit): track the cancelled.flag write so a quick
        // re-Send can await it before its turn-start flag-clear. Chain onto
        // any prior pending write so completion order matches issue order.
        let generation = (pendingCancelFlagWriteGenerations[sid] ?? 0) + 1
        pendingCancelFlagWriteGenerations[sid] = generation
        let previousWrite = pendingCancelFlagWrites[sid]
        pendingCancelFlagWrites[sid] = Task { @MainActor in
            await previousWrite?.value
            _ = try? await client.cancelChatSession(sessionId: sid)
            // Self-clean: only the LATEST write removes the bookkeeping.
            if pendingCancelFlagWriteGenerations[sid] == generation {
                pendingCancelFlagWrites[sid] = nil
                pendingCancelFlagWriteGenerations[sid] = nil
            }
        }
        chatTasks[sid]?.cancel()
        chatTasks[sid] = nil
        streamingSessions.remove(sid)
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
    private func awaitPendingCancelFlagWrite(for sessionId: String) async {
        while let pending = pendingCancelFlagWrites[sessionId] {
            await pending.value
        }
    }

    /// Stop every in-flight chat task (e.g. on app shutdown or a user
    /// "stop everything" affordance).
    @MainActor
    func stopAllChatStreams() {
        let ids = Array(streamingSessions.union(Set(chatTasks.keys)))
        for sid in ids { stopChatStream(sessionId: sid) }
    }

    @MainActor
    func removeQueuedChatTurn(_ turnId: String, sessionId: String) {
        guard var turns = queuedChatTurnsBySession[sessionId] else { return }
        turns.removeAll { $0.id == turnId }
        if turns.isEmpty {
            queuedChatTurnsBySession.removeValue(forKey: sessionId)
            pausedChatQueueSessions.remove(sessionId)
        } else {
            queuedChatTurnsBySession[sessionId] = turns
        }
    }

    /// Promote one queued turn and interrupt the active response. The ordinary
    /// Stop path pauses the queue; steering deliberately keeps it live so the
    /// promoted turn starts only after cancellation persistence has completed.
    @MainActor
    func steerQueuedChatTurn(_ turnId: String, sessionId: String) {
        guard promoteQueuedChatTurn(turnId, sessionId: sessionId) else { return }
        pausedChatQueueSessions.remove(sessionId)
        if chatTasks[sessionId] != nil || busySessions.contains(sessionId) || streamingSessions.contains(sessionId) {
            stopChatStream(sessionId: sessionId, pauseQueuedTurns: false)
        } else {
            Task { @MainActor in await drainNextQueuedChatTurnIfPossible(sessionId: sessionId) }
        }
    }

    @MainActor
    func resumeQueuedChatTurns(sessionId: String, startingWith turnId: String? = nil) {
        if let turnId { _ = promoteQueuedChatTurn(turnId, sessionId: sessionId) }
        pausedChatQueueSessions.remove(sessionId)
        Task { @MainActor in await drainNextQueuedChatTurnIfPossible(sessionId: sessionId) }
    }

    @discardableResult
    @MainActor
    func promoteQueuedChatTurn(_ turnId: String, sessionId: String) -> Bool {
        guard var turns = queuedChatTurnsBySession[sessionId],
              let index = turns.firstIndex(where: { $0.id == turnId })
        else { return false }
        let selected = turns.remove(at: index)
        turns.insert(selected, at: 0)
        queuedChatTurnsBySession[sessionId] = turns
        return true
    }

    @MainActor
    private func drainNextQueuedChatTurnIfPossible(sessionId: String) async {
        guard !sessionId.isEmpty,
              !pausedChatQueueSessions.contains(sessionId),
              !drainingChatQueueSessions.contains(sessionId),
              chatTasks[sessionId] == nil,
              !busySessions.contains(sessionId),
              var turns = queuedChatTurnsBySession[sessionId],
              !turns.isEmpty
        else { return }

        drainingChatQueueSessions.insert(sessionId)
        defer { drainingChatQueueSessions.remove(sessionId) }
        let next = turns.removeFirst()
        if turns.isEmpty {
            queuedChatTurnsBySession.removeValue(forKey: sessionId)
        } else {
            queuedChatTurnsBySession[sessionId] = turns
        }
        let acceptance: ChatTurnAcceptance
        if let queuedChatTurnStartOverride {
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
        queuedChatTurnsBySession[sessionId, default: []].insert(next, at: 0)
        pausedChatQueueSessions.insert(sessionId)
    }

    @MainActor
    private func migrateQueuedChatTurns(from oldSessionId: String, to newSessionId: String) {
        if let old = queuedChatTurnsBySession.removeValue(forKey: oldSessionId), !old.isEmpty {
            queuedChatTurnsBySession[newSessionId] = old + (queuedChatTurnsBySession[newSessionId] ?? [])
        }
        if pausedChatQueueSessions.remove(oldSessionId) != nil {
            pausedChatQueueSessions.insert(newSessionId)
        }
    }

    @MainActor
    private func _sendChatBody(_ text: String, attachments: [MultimodalAttachment] = [], sessionId: String? = nil, generation: Int, ctx: _ChatBodyContext? = nil, hideUserBubble: Bool = false) async {
        // PATCH-2026-05-06: hotpath-4 streaming chat — add empty bubble immediately, stream deltas into it
        // PATCH-2026-05-13: parallel-sessions — only mutate `chatMessages`
        // when the active session still matches; otherwise this background
        // task would pollute the view of another session. The user can
        // navigate back and we re-fetch on the success/cancel/error paths.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if activeChatSessionId.isEmpty {
            await loadChatState()
        }
        // H4 follow-up (gpt-5.5 review, 2026-07-09): when the success path below
        // lands a fresh disk snapshot itself, the `.chatTurnCompleted` handler
        // must not read the whole transcript a second time. False whenever the
        // local refresh didn't happen (error path, failed fetch) so the
        // notification path stays the safety net exactly when it's needed.
        var messagesAlreadyRefreshed = false
        // 2026-06-08 detached-chat-windows W0.3 fix HIGH #1: this is `var`
        // (was `let`) so the placeholder-id latch below can rebind it when
        // the daemon returns a confirmed sessionId in metaBox. With dict
        // storage, every subsequent write needs to target the new id —
        // otherwise the active slot (now `sid`) goes empty while final
        // flush + disk refresh write to the dead `requestSessionId` slot.
        var requestSessionId = (sessionId?.isEmpty == false ? sessionId : activeChatSessionId) ?? ""
        let userContent = trimmed.isEmpty ? "(attached \(attachments.count) item(s))" : trimmed
        let bubbleId = UUID().uuidString
        let userTurnId = UUID().uuidString
        // Fresh-install honest surface (G4-6, 2026-07-04): if NO provider is
        // connected at all, don't fire a doomed turn (silent no-reply / provider
        // error). Show the user their message plus a clear "connect a provider"
        // reply. `missingProviderChatGuidance()` is conservative — it only trips
        // on a truly blank machine, never an established one, so User's setup is
        // unaffected. Placed BEFORE the streaming-state `defer` below so the
        // early return doesn't tear down state it never set up.
        if let guidance = missingProviderChatGuidance() {
            var typedBubble = ChatMessage(sessionId: requestSessionId, role: "user", content: userContent)
            typedBubble.id = userTurnId
            appendChatMessage(typedBubble, to: requestSessionId)
            // Tag the guidance with the synthetic-error prefix so the session
            // reload-preservation path keeps it when the user navigates to
            // the Providers tab and back (gpt-5.5 review 2026-07-04).
            let guidanceBubble = ChatMessage(
                id: Self.syntheticErrorIDPrefix + UUID().uuidString,
                sessionId: requestSessionId,
                role: "assistant",
                content: guidance,
                // Sweep R4 C7: without metadata.error the retry gate is false and
                // the bubble renders with no way to re-send once a provider is
                // connected. Stamp it so "Try again" is there when it will work.
                metadata: .syntheticError("no_provider_connected", userRowPersisted: false)
            )
            appendChatMessage(guidanceBubble, to: requestSessionId)
            statusText = "No AI provider connected — connect one in the Providers tab in the sidebar."
            return
        }
        // PATCH-2026-05-13: parallel-sessions — track the bubble id, the
        // user-turn id, and the live-delta buffer per session so
        // selectChatSession can restore both the prompt and the streaming
        // reply when the user comes back to this session mid-flight.
        streamingBubbleIds[requestSessionId] = bubbleId
        streamingTexts[requestSessionId] = ""
        // Hidden (agent-first) turns must not register user-turn restore state,
        // or a mid-greeting session switch would reinject the hidden kickoff as a
        // user bubble on return.
        if !hideUserBubble {
            streamingUserTurnIds[requestSessionId] = userTurnId
            streamingUserTurnTexts[requestSessionId] = userContent
        }
        // 2026-06-08 detached-chat-windows W0.3: optimistic bubbles now land
        // in the request session's slot unconditionally. When request ==
        // active, the active chat view re-renders (computed `chatMessages`
        // reads the same slot). When request != active, a detached panel
        // bound to this session sees them; the main view does not until the
        // user switches.
        // Proactive agent-first turns (first-run welcome) hide the user bubble:
        // the kickoff drives the LLM but is never shown or persisted (paired with
        // suppressUserAppend below), so only the agent's greeting lands.
        if !hideUserBubble {
            var userBubble = ChatMessage(sessionId: requestSessionId, role: "user", content: userContent)
            userBubble.id = userTurnId
            appendChatMessage(userBubble, to: requestSessionId)
        }
        var streamingBubble = ChatMessage(sessionId: requestSessionId, role: "assistant", content: "")
        streamingBubble.id = bubbleId
        appendChatMessage(streamingBubble, to: requestSessionId)
        busySessions.insert(requestSessionId)
        defer {
            busySessions.remove(requestSessionId)
            streamingTexts[requestSessionId] = nil
            streamingBubbleIds[requestSessionId] = nil
            streamingUserTurnIds[requestSessionId] = nil
            streamingUserTurnTexts[requestSessionId] = nil
        }

        do {
            var streamedText = ""
            var lastStreamPublish = Date.distantPast
            // S.5: use lock-guarded MetaBox for safe cross-isolation metadata passing
            let metaBox = NativeClient.MetaBox()
            let stream = client.chatStream(
                message: trimmed.isEmpty ? "(see attachments)" : trimmed,
                sessionId: requestSessionId,
                model: chatModel,
                reasoningEffort: chatReasoningEffort,
                fileAccess: chatFileAccess,
                attachments: attachments,
                metaBox: metaBox,
                suppressUserAppend: hideUserBubble
            )
            for try await delta in stream {
                try Task.checkCancellation()
                guard chatTaskGenerations[requestSessionId] == generation else { return }
                streamedText += delta
                // Update the per-session live buffer every delta so a switch-back
                // can restore the latest text immediately.
                streamingTexts[requestSessionId] = streamedText
                let now = Date()
                // 2026-06-08 W0.3: write deltas to the request session's slot
                // unconditionally. The debounce on lastStreamPublish controls
                // re-render frequency for ALL viewers (main window + any
                // detached panels bound to this session); same UX as before.
                if now.timeIntervalSince(lastStreamPublish) >= Self.chatStreamCoalesceSeconds {
                    updateChatMessageContent(id: bubbleId, in: requestSessionId, content: streamedText)
                    lastStreamPublish = now
                }
            }
            guard chatTaskGenerations[requestSessionId] == generation else { return }
            // Update sessionId from metadata if returned
            let metaValue = metaBox.get()
            let finalStreamText = (metaValue["output"] as? String)
                .flatMap { value -> String? in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : value
                } ?? streamedText
            // Safety-net: zero deltas streamed AND metaBox carries no output —
            // surface explicitly instead of leaving an empty assistant bubble.
            let finalTrimmed = finalStreamText.trimmingCharacters(in: .whitespacesAndNewlines)
            let streamProducedNoContent = finalTrimmed.isEmpty
            // 2026-06-08 W0.3: final flush + bubble cleanup target the
            // request session's slot directly, not just when active.
            if !streamProducedNoContent {
                updateChatMessageContent(id: bubbleId, in: requestSessionId, content: finalStreamText)
            }
            // activeChatSessionId latch — the metadata's confirmed sid may
            // replace a placeholder id on first-turn-of-a-new-session.
            // 2026-06-08 W0.3 fix HIGH #1: with dict storage, flipping
            // activeChatSessionId is not enough — subsequent writes still
            // target the old `requestSessionId` slot, leaving the new
            // active slot empty. Migrate the dict entries to the new key
            // AND update the local `requestSessionId` so the remaining
            // writes (no-content cleanup, disk refresh, error bubble,
            // receipt refresh) hit the right slot.
            //
            // 2026-06-08 W0.3 fix-2 HIGH-B: guard against overwriting a
            // pre-existing `sid` slot. If the daemon reconciled this
            // placeholder turn into an already-loaded real session (rare
            // race: concurrent session creates against the same sourceKey),
            // the real-id slot holds canonical state; blindly overwriting
            // would corrupt the active real session. Instead, DROP the
            // placeholder slot and let the in-flight stream continue
            // writing into the (now-shared) real-id slot. Disk refresh at
            // end-of-turn pulls canonical state for `sid`.
            if let sid = metaValue["sessionId"] as? String, !sid.isEmpty, sid != requestSessionId {
                let migratingActive = (activeChatSessionId == requestSessionId)
                let sidAlreadyPopulated = (chatMessagesBySession[sid] != nil)
                    || streamingSessions.contains(sid)
                    || chatTasks[sid] != nil

                if sidAlreadyPopulated {
                    // 2026-06-08 W0.3 fix-3 HIGH: the daemon reconciled this
                    // placeholder turn into an already-loaded/active session
                    // `sid` (rare sourceKey race). `sid`'s real state is
                    // canonical and may be ACTIVELY STREAMING — we must not
                    // migrate into it, rebind to it, or let the outer cleanup
                    // touch its task/generation (generation is per-session,
                    // so removing `chatTaskGenerations[sid]` could abort an
                    // unrelated real stream that happens to share a
                    // generation counter value).
                    //
                    // Correct move: drop ONLY this placeholder's transient
                    // optimistic UI (message/receipt/draft slots). Leave the
                    // placeholder's task/generation/busy/streaming bookkeeping
                    // INTACT and `requestSessionId` UNCHANGED so the OUTER
                    // sendChat cleanup (keyed off the unchanged placeholder
                    // via `ctx.effectiveSessionId`, which we do NOT advance to
                    // `sid`) and this function's `defer` tear them down
                    // exactly once — all against the placeholder, never
                    // against `sid`. Then bail: the turn already landed on
                    // disk under `sid`; sid's own refresh path / next
                    // selectChatSession surfaces it.
                    chatMessagesBySession.removeValue(forKey: requestSessionId)
                    latestContextReceiptBySession.removeValue(forKey: requestSessionId)
                    chatDrafts.removeValue(forKey: requestSessionId)
                    // ctx.effectiveSessionId stays at the placeholder (initial
                    // value) — outer cleanup tears down placeholder bookkeeping.
                    // requestSessionId stays at the placeholder — defer clears
                    // placeholder streaming buffers. Neither touches `sid`.
                    return
                } else {
                    // Normal placeholder migration. Move every per-session
                    // stash from the placeholder id to the confirmed `sid`.
                    if let placeholderMessages = chatMessagesBySession.removeValue(forKey: requestSessionId) {
                        chatMessagesBySession[sid] = placeholderMessages
                    }
                    if let placeholderReceipt = latestContextReceiptBySession.removeValue(forKey: requestSessionId) {
                        latestContextReceiptBySession[sid] = placeholderReceipt
                    }
                    if let v = streamingTexts.removeValue(forKey: requestSessionId) {
                        streamingTexts[sid] = v
                    }
                    if let v = streamingBubbleIds.removeValue(forKey: requestSessionId) {
                        streamingBubbleIds[sid] = v
                    }
                    if let v = streamingUserTurnIds.removeValue(forKey: requestSessionId) {
                        streamingUserTurnIds[sid] = v
                    }
                    if let v = streamingUserTurnTexts.removeValue(forKey: requestSessionId) {
                        streamingUserTurnTexts[sid] = v
                    }
                    if let v = chatDrafts.removeValue(forKey: requestSessionId) {
                        chatDrafts[sid] = v
                        // 2026-07-21 audit fix: carry the LRU timestamp too —
                        // without it the migrated draft is invisible to the
                        // 50-cap eviction ordering. Fall back to now only when
                        // the placeholder never recorded a touch.
                        chatDraftLastTouched[sid] = chatDraftLastTouched.removeValue(forKey: requestSessionId) ?? Date()
                    }
                    migrateQueuedChatTurns(from: requestSessionId, to: sid)
                    if streamingSessions.contains(requestSessionId) {
                        streamingSessions.remove(requestSessionId)
                        streamingSessions.insert(sid)
                    }
                    if busySessions.contains(requestSessionId) {
                        busySessions.remove(requestSessionId)
                        busySessions.insert(sid)
                    }
                    if let t = chatTasks.removeValue(forKey: requestSessionId) {
                        chatTasks[sid] = t
                    }
                    if let g = chatTaskGenerations.removeValue(forKey: requestSessionId) {
                        chatTaskGenerations[sid] = g
                    }
                }

                if migratingActive {
                    activeChatSessionId = sid
                    UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId")
                }
                // Re-bind the local so every subsequent write in this
                // function targets the new slot. ALSO report the effective
                // session id back to `sendChat` so its outer cleanup
                // targets the post-migration key (chatTasks, generation,
                // streamingSessions, busySessions all live under `sid`
                // now). Without this, those entries leak forever and
                // block future sends on this session.
                requestSessionId = sid
                ctx?.effectiveSessionId = sid
            }
            // After streaming, refresh messages to pick up any tool pills written by daemon.
            // When the stream produced no content, drop the optimistic empty bubble FIRST so
            // the no-content check below doesn't see it and mistake it for an assistant reply.
            // 2026-06-08 W0.3 fix HIGH #3: also clear the per-session
            // streaming bubble + user-turn ids BEFORE the disk-refresh
            // await below. Without this, a concurrent selectChatSession
            // during the await can re-inject the empty optimistic bubble
            // via the streamingSessions/streamingBubbleIds reinjection
            // block (lines ~1490-1505), and the subsequent assistantLanded
            // check would see the re-injected empty bubble and silently
            // suppress the error message. Mirrors the old inactive-path
            // clearStreamingBubbleState() call now folded into the unified
            // path.
            if streamProducedNoContent {
                removeChatMessage(id: bubbleId, from: requestSessionId)
                clearStreamingBubbleState(requestSessionId)
            }
            // 2026-06-08 W0.3: disk refresh now runs for EVERY session that
            // completes a turn, not just the active one. Tool pills + final
            // assistant content land in `chatMessagesBySession[req]` so a
            // detached panel for `req` sees them immediately.
            let freshOnSuccess: [ChatMessage]? = try? await client.getChatMessages(sessionId: requestSessionId)
            if let fresh = freshOnSuccess, !fresh.isEmpty {
                setChatMessages(fresh, for: requestSessionId)
                messagesAlreadyRefreshed = true
            }
            // Safety-net: if the stream produced no content AND no assistant turn landed on
            // disk for this run, append (or stash) a visible error bubble so the failure
            // isn't silent. Inverted check from "last is user" to "last is NOT assistant" so
            // a failed refresh (freshOnSuccess == nil) still surfaces the error instead of
            // leaving the cleared bubble + persisted user turn looking like a stall.
            if streamProducedNoContent {
                // Friendly, honest wording on the no-content path too (this
                // string does NOT pass through normalizeStreamErrorForChat).
                // audit finding #17, 2026-06-14.
                let errorText = "No reply came back. Use Try again to retry."
                // 2026-06-08 W0.3: with per-session storage, the active/inactive
                // branch collapses — consult the REQUEST session's tail (not
                // the active one) for the assistant-landed guard. Both main
                // window and detached panels see the error bubble correctly.
                let sessionMessages = chatMessages(for: requestSessionId)
                // A partial/cancelled row does NOT count as a landed reply, so
                // the no-content error bubble still surfaces (audit finding #2).
                let assistantLanded = isCompletedAssistant(sessionMessages.last)
                    || isCompletedAssistant(freshOnSuccess?.last)
                if !assistantLanded {
                    let errorBubble = ChatMessage(
                        id: Self.syntheticErrorIDPrefix + UUID().uuidString,
                        sessionId: requestSessionId,
                        role: "assistant",
                        content: errorText,
                        // Sweep R4 C7: this is THE bubble whose text says "Use
                        // Try again to retry" — messageNeedsRetry requires
                        // metadata.error, so without this stamp the copy named
                        // an affordance that never rendered.
                        metadata: .syntheticError("stream_produced_no_content")
                    )
                    appendChatMessage(errorBubble, to: requestSessionId)
                }
            }
            chatSessions = (try? await client.getChatSessions()) ?? chatSessions
            // 2026-06-08 W0.3: receipt refresh runs for the request session
            // regardless of active state, so a detached panel for `req` sees
            // the new context-receipt without waiting for a focus change.
            setLatestContextReceipt(
                try? await client.getLatestContextReceipt(sessionId: requestSessionId),
                for: requestSessionId
            )
            compiledPersonality = try? await client.getCompiledPersonality(surface: "chat")
        } catch {
            if Task.isCancelled {
                guard chatTaskGenerations[requestSessionId] == generation else { return }
                // 2026-06-08 W0.3: cancel-cleanup targets the request session
                // regardless of active state — a detached panel that was
                // streaming should also see its empty bubble disappear and
                // any partial tool pills land when the user stops the stream.
                removeChatMessage(id: bubbleId, from: requestSessionId)
                if let freshMessages = try? await client.getChatMessages(sessionId: requestSessionId),
                   !freshMessages.isEmpty {
                    setChatMessages(freshMessages, for: requestSessionId)
                }
                return
            }
            guard chatTaskGenerations[requestSessionId] == generation else { return }
            // Streaming failed after the Swift chat path may already have
            // appended the user turn. Do not submit a second chat request here;
            // that can duplicate the user message and run the request twice.
            // 2026-06-08 W0.3: optimistic-bubble cleanup targets the request
            // session's slot directly. Same UX for active viewer; detached
            // panels for this session also see the empty bubble disappear.
            removeChatMessage(id: bubbleId, from: requestSessionId)
            // The streaming LLM call failed AFTER the user turn was persisted (the Swift
            // chat path appends the user message BEFORE calling the LLM). A bare refresh
            // therefore shows the user bubble with NO assistant reply and no error —
            // looks identical to a stalled response. Surface the error explicitly when
            // no assistant turn landed; mirror the success-path pattern (invert from
            // "last is user" to "last is NOT assistant") so a failed refresh still fires.
            let errorText = normalizeStreamErrorForChat(error)
            let freshOnError: [ChatMessage]? = try? await client.getChatMessages(sessionId: requestSessionId)
            if let fresh = freshOnError, !fresh.isEmpty {
                setChatMessages(fresh, for: requestSessionId)
            }
            let sessionMessagesAfterErr = chatMessages(for: requestSessionId)
            // A partial/cancelled row (persistPartialIfNeeded on mid-stream
            // failure) must NOT count as a landed reply, else it suppresses the
            // normalized failure bubble — this is the chain that defeated the
            // shipped error surfacing (audit finding #2, 2026-06-14).
            let assistantLandedErr = isCompletedAssistant(sessionMessagesAfterErr.last)
                || isCompletedAssistant(freshOnError?.last)
            if !assistantLandedErr {
                // Carry sessionId (mirrors the no-content bubble above) so the
                // row is correctly attributed to its session for any code that
                // keys off msg.sessionId (e.g. detached-panel regeneration).
                // Sweep R4 C7: stamp metadata.error (the raw, un-normalized
                // failure) so the normalized bubble text — which ends in "Use
                // Try again to retry" on every arm — actually renders the
                // Try again button.
                let errorBubble = ChatMessage(
                    id: Self.syntheticErrorIDPrefix + UUID().uuidString,
                    sessionId: requestSessionId,
                    role: "assistant",
                    content: errorText,
                    metadata: .syntheticError(error.localizedDescription)
                )
                appendChatMessage(errorBubble, to: requestSessionId)
            }
            chatSessions = (try? await client.getChatSessions()) ?? chatSessions
        }
        // PATCH-2026-05-07: chat-context-fill notify the ContextFillBar so
        // it re-polls usage after each turn.
        NotificationCenter.default.post(
            name: .chatTurnCompleted, object: requestSessionId,
            userInfo: ["messagesAlreadyRefreshed": messagesAlreadyRefreshed])
    }

    /// Synthetic (in-memory-only) error/no-content bubbles use this id prefix so
    /// the post-turn disk reload (performLoadChatState) can PRESERVE them instead
    /// of wiping them — these notices are never persisted (audit #2 durability
    /// fix Z, 2026-06-14). Without this they flash for one frame then vanish on
    /// the async `.chatTurnCompleted` reload.
    static let syntheticErrorIDPrefix = "na-synthetic-error-"

    /// A persisted assistant row counts as a real, completed reply only if it is
    /// NOT a partial/cancelled truncation. persistPartialIfNeeded
    /// (NativeAgentCore) stamps metadata.partial/cancelled on mid-stream
    /// failures; treating those as "landed" suppresses the failure bubble
    /// (audit finding #2, 2026-06-14).
    func isCompletedAssistant(_ m: ChatMessage?) -> Bool {
        guard let m, m.role == "assistant" else { return false }
        if m.metadata?.partial == true { return false }
        if m.metadata?.cancelled == true { return false }
        return true
    }

    /// Maps a streaming failure to a clean, user-facing chat-bubble sentence.
    /// Runs ONLY at this UI catch site (line ~2343) — engine/orchestration-layer
    /// `.error` events still carry the raw provider text (ChatErrorSurfacingTests
    /// assert on that raw text). Keep the raw error in any os_log/telemetry on
    /// this path; only the bubble text is normalized.
    ///
    /// Match order: (1) the ProviderStreamGuard's OWN stable in-repo timeout
    /// strings (they flow through `LLMError.transient` -> "llm: transient: …"
    /// unchanged); (2) URLError categories / adapter transport strings; (3)
    /// provider transient (busy/rate-limited) and explicit auth failures; (4)
    /// default — preserve today's "Chat error: <desc>" so nothing regresses and
    /// unmatched provider text still reads.
    private func normalizeStreamErrorForChat(_ error: Error) -> String {
        let raw = error.localizedDescription
        let d = raw.lowercased()

        // Retry hints point at the visible Try again action on the failed or
        // partial last assistant message. The prior pointer-only Regenerate
        // instruction was inaccessible to keyboard and touch users.
        // (1) ProviderStreamGuard's stable timeout strings (idle/wall).
        if d.contains("idle timeout") || d.contains("wall timeout") {
            return "Couldn't get a reply in time - the connection looks stalled. Use Try again to retry."
        }
        // (2) URLError categories / adapter transport strings.
        if d.contains("network connection was lost") || d.contains("code=-1005") {
            return "Couldn't reach the model - the network connection dropped. Use Try again to retry."
        }
        if d.contains("not connected to internet") || d.contains("code=-1009") {
            return "No internet connection. Check your network, then use Try again to retry."
        }
        if d.contains("timed out") || d.contains("code=-1001") {
            return "The request timed out. Check your network, then use Try again to retry."
        }
        if d.contains("cannot connect to") || d.contains("code=-2003") {
            return "Couldn't reach the server. Use Try again to retry."
        }
        if d.contains("cannot resolve") || d.contains("cannot find host")
            || d.contains("code=-1003") || d.contains("code=-1004") {
            return "Couldn't resolve the server address. Check your network, then use Try again to retry."
        }
        // (3) Provider transient errors — overload / rate-limit / 5xx — the most
        // common transient class. LLMError surfaces these as
        // "llm: provider error: …overloaded…" and "llm: invalid response status 529"
        // (audit finding #11, 2026-06-14). Deliberately NOT matching a bare
        // "provider error": that would mask auth/invalid-request failures as
        // "busy" — let those fall to the raw default so the real cause shows.
        if d.contains("overloaded") || d.contains("rate limit") || d.contains("rate_limit")
            || d.contains("status 429") || d.contains("status 529")
            || d.contains("status 503") || d.contains("status 500") {
            return "The model is busy right now. Use Try again to retry."
        }
        if d.contains("stream truncated") {
            return "The reply was cut off. Use Try again to retry."
        }
        // (3b) Auth — sweep R4 C15. 401/unauthorized is the most common
        // self-inflicted failure (expired or mistyped key) and previously fell
        // through to the raw provider string. This arm is deliberately NARROW —
        // an explicit 401/invalid-key signal only — so the reasoning above
        // still holds: a bare "provider error" must NOT be dressed up as an
        // auth problem, it still falls through raw. A bare "unauthorized"
        // matcher was dropped (review 2026-08-06): provider errors echoing
        // tool/request content ("unauthorized file path") would misroute the
        // user to their API keys; real 401s carry the status code.
        if d.contains("status 401") || d.contains("code=401")
            || d.contains("invalid_api_key") || d.contains("invalid api key")
            || d.contains("authentication_error") || d.contains("invalid x-api-key") {
            return "The provider rejected the credentials for this model — the API key or sign-in looks expired or wrong. Update the key in the Providers tab in the sidebar, then use Try again to retry."
        }
        // (4) Default — unchanged behavior so nothing regresses.
        return "Chat error: \(raw)"
    }

}

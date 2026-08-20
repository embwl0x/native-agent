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

@MainActor
extension AppModel {
    /// Read per-session messages without going through `activeChatSessionId`.
    /// Used by detached chat panels and any code that needs to inspect a
    /// non-active session (e.g. sidebar streaming-indicator badges).
    func chatMessages(for sessionId: String) -> [ChatMessage] {
        chatMessagesBySession[sessionId] ?? []
    }

    /// Write per-session messages without affecting the active session's
    /// view. Detached panels write here; the singleton `chatMessages`
    /// setter routes through this with `activeChatSessionId` as the key.
    func setChatMessages(_ messages: [ChatMessage], for sessionId: String) {
        chatMessagesBySession[sessionId] = messages
    }

    func latestContextReceipt(for sessionId: String) -> ContextReceipt? {
        latestContextReceiptBySession[sessionId]
    }

    func setLatestContextReceipt(_ receipt: ContextReceipt?, for sessionId: String) {
        latestContextReceiptBySession[sessionId] = receipt
    }

    func chatTurnLifecycle(for sessionId: String) -> MacChatTurnLifecycleState? {
        chatTurnLifecycleBySession[sessionId]
    }

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
        activeChatTurnLifecycleIDsBySession[sessionId] = turnId
        chatTurnLifecycleBySession[sessionId] = MacChatTurnLifecycleState(
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
        guard activeChatTurnLifecycleIDsBySession[sessionId] == input.identity.turnId,
              let state = chatTurnLifecycleBySession[sessionId],
              state.identity == input.identity else {
            return nil
        }
        let reduced = MacChatTurnLifecycleReducer.reduce(state, input: input)
        if reduced != state {
            chatTurnLifecycleBySession[sessionId] = reduced
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

        // Preserve the existing user-visible notice/toast contract. Tool
        // activity shares this typed intake but does not create new chatter.
        guard case .notice(let kind) = activity.source,
              let text = activity.userVisibleNoticeText,
              !text.isEmpty else { return }
        NotificationCenter.default.post(
            name: .nativeAgentTurnNotice,
            object: nil,
            userInfo: [
                "kind": kind,
                "text": text,
                "sessionId": activity.identity.sessionId,
            ]
        )
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

    @discardableResult
    func recordChatTurnStreamProgress(
        identity: MacChatTurnIdentity,
        accumulatedUTF16Length: Int,
        at instant: Date
    ) -> MacChatTurnLifecycleState? {
        applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
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
        guard activeChatTurnLifecycleIDsBySession[sessionId] == turnId,
              var state = chatTurnLifecycleBySession[sessionId],
              state.identity.turnId == turnId else { return nil }
        if !state.presentation.isTerminal {
            state = MacChatTurnLifecycleReducer.reduce(
                state,
                input: MacChatTurnLifecycleInput(
                    identity: state.identity,
                    kind: .outcomeUnknown(
                        reason: "The turn ended without a provable terminal outcome."
                    ),
                    occurredAt: instant
                )
            )
            chatTurnLifecycleBySession[sessionId] = state
        }
        activeChatTurnLifecycleIDsBySession.removeValue(forKey: sessionId)
        return state
    }

    /// Drops only the named turn's transient activity slot. Used when a
    /// placeholder session reconciles into a separately active canonical
    /// session and must not overwrite that session's evidence.
    func discardChatTurnLifecycleIntake(sessionId: String, turnId: String) {
        guard activeChatTurnLifecycleIDsBySession[sessionId] == turnId else { return }
        activeChatTurnLifecycleIDsBySession.removeValue(forKey: sessionId)
        if chatTurnLifecycleBySession[sessionId]?.identity.turnId == turnId {
            chatTurnLifecycleBySession.removeValue(forKey: sessionId)
        }
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
              activeChatTurnLifecycleIDsBySession[oldSessionId] == turnId
        else { return nil }
        if let destinationTurn = activeChatTurnLifecycleIDsBySession[newSessionId],
           destinationTurn != turnId {
            discardChatTurnLifecycleIntake(sessionId: oldSessionId, turnId: turnId)
            return nil
        }

        activeChatTurnLifecycleIDsBySession.removeValue(forKey: oldSessionId)
        activeChatTurnLifecycleIDsBySession[newSessionId] = turnId
        if let oldState = chatTurnLifecycleBySession.removeValue(forKey: oldSessionId),
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
            chatTurnLifecycleBySession[newSessionId] = rebound
            return rebound
        }
        return nil
    }

    @discardableResult
    func persistChatTurnLifecycleBegin(identity: MacChatTurnIdentity) async -> Bool {
        guard let state = chatTurnLifecycleBySession[identity.sessionId],
              state.identity == identity else { return false }
        do {
            try await chatTurnLifecycleStore.begin(state)
            return true
        } catch {
            logChatTurnLifecyclePersistenceFailure("begin", error: error)
            return false
        }
    }

    @discardableResult
    func persistChatTurnLifecycleUpdate(identity: MacChatTurnIdentity) async -> Bool {
        guard let state = chatTurnLifecycleBySession[identity.sessionId],
              state.identity == identity else { return false }
        do {
            let retained = try await chatTurnLifecycleStore.update(state)
            if !retained {
                // The durable owner no longer contains this exact turn. Keep
                // the in-memory projection for the current process, but force
                // the next admission/reload through canonical repair instead
                // of permanently treating the ledger as reconciled.
                chatTurnLifecycleRepairCompleted = false
                logChatTurnLifecyclePersistenceFailure(
                    "update",
                    error: MacChatTurnLifecycleStoreError.missingExactTurn
                )
            }
            return retained
        } catch {
            chatTurnLifecycleRepairCompleted = false
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
                guard try await chatTurnLifecycleStore.migrate(
                    state: state,
                    from: oldSessionId
                ) else {
                    chatTurnLifecycleRepairCompleted = false
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
        chatTurnLifecycleRepairCompleted = false
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
            try await chatTurnLifecycleStore.remove(
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
            return try await chatTurnTranscriptProofReader.proof(for: identity)
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
        guard !chatTurnLifecycleRepairCompleted else { return true }
        let records: [MacChatPersistedTurnLifecycle]
        do {
            records = try await chatTurnLifecycleStore.records()
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
                guard activeChatTurnLifecycleIDsBySession[record.sessionId] == nil else {
                    // A live turn in this process still owns the outcome.
                    hasPendingRepairWork = true
                    continue
                }
                guard !record.isTerminal else { continue }
                let proof = await loadProof(record.identity)
                guard activeChatTurnLifecycleIDsBySession[record.sessionId] == nil else {
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
                    if try await chatTurnLifecycleStore.update(repaired) == false {
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
            guard activeChatTurnLifecycleIDsBySession[record.sessionId] == nil else {
                continue
            }
            let proof = record.isTerminal ? .absent : await loadProof(record.identity)
            guard let repaired = MacChatTurnLifecycleRestartRepair.repair(
                record: record,
                transcriptProof: proof,
                at: instant
            ) else { continue }
            guard activeChatTurnLifecycleIDsBySession[record.sessionId] == nil else {
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
            let liveState = chatTurnLifecycleBySession[record.sessionId]
            let liveTerminalWins = liveState?.identity == record.identity
                && liveState?.presentation.isTerminal == true
            let settled = liveTerminalWins ? (liveState ?? repaired) : repaired
            if !liveTerminalWins {
                chatTurnLifecycleBySession[record.sessionId] = settled
            }
            if !record.isTerminal {
                do {
                    if try await chatTurnLifecycleStore.update(settled) == false {
                        repairPersistenceFailed = true
                    }
                } catch {
                    repairPersistenceFailed = true
                    logChatTurnLifecyclePersistenceFailure("repair_update", error: error)
                }
            }
        }
        chatTurnLifecycleRepairCompleted = !hasPendingRepairWork && !repairPersistenceFailed
        return !repairPersistenceFailed
    }

    private func logChatTurnLifecyclePersistenceFailure(_ operation: String, error: Error) {
        let safe = NativeAppSecretRedactor.redactText(String(describing: error))
        NSLog("Mac chat turn lifecycle %@ failed: %@", operation, safe)
    }

    /// Drop a session's cached messages + receipt. Called when a session is
    /// deleted from the sidebar. The dict would otherwise grow unbounded as
    /// the user creates and discards sessions across a long-running app.
    func pruneSessionChatState(_ sessionId: String) {
        let activeLifecycleTurnId = activeChatTurnLifecycleIDsBySession[sessionId]
        let lifecycleTurnId = activeLifecycleTurnId == nil
            ? chatTurnLifecycleBySession[sessionId]?.identity.turnId
            : nil
        chatMessagesBySession.removeValue(forKey: sessionId)
        latestContextReceiptBySession.removeValue(forKey: sessionId)
        detachedChatRefreshStatus.removeValue(forKey: sessionId)
        detachedChatContextReceiptRefreshStatus.removeValue(forKey: sessionId)
        queuedChatTurnsBySession.removeValue(forKey: sessionId)
        pausedChatQueueSessions.remove(sessionId)
        // A Stop/Archive can reach pruning before its joined producer has
        // persisted terminal proof. Preserve that one exact authority until
        // normal task cleanup closes it; stale-session pruning will remove the
        // terminal projection on a later bounded session-index refresh.
        if activeLifecycleTurnId == nil {
            chatTurnLifecycleBySession.removeValue(forKey: sessionId)
            activeChatTurnLifecycleIDsBySession.removeValue(forKey: sessionId)
        }
        if let lifecycleTurnId {
            Task { [chatTurnLifecycleStore] in
                try? await chatTurnLifecycleStore.remove(
                    sessionId: sessionId,
                    turnId: lifecycleTurnId
                )
            }
        }
    }

    /// 2026-07-21 audit fix: pruneSessionChatState had zero callers, so the
    /// per-session dicts grew for the process lifetime. Sweep every cached
    /// session the fetched session list no longer reports (archived away or
    /// retired by ChatSessionRetention). Sessions with live work (streaming,
    /// busy, active) or an open detached panel are kept — their slots are
    /// still being written. No-op when nothing is stale, so it is safe to
    /// call from the existing low-frequency session-list refresh.
    func pruneStaleSessionChatState(knownSessionIds: Set<String>) {
        let cached = Set(chatMessagesBySession.keys)
            .union(latestContextReceiptBySession.keys)
            .union(detachedChatRefreshStatus.keys)
            .union(detachedChatContextReceiptRefreshStatus.keys)
            .union(queuedChatTurnsBySession.keys)
            .union(pausedChatQueueSessions)
            .union(chatTurnLifecycleBySession.keys)
            .union(activeChatTurnLifecycleIDsBySession.keys)
        for sessionId in cached {
            guard !knownSessionIds.contains(sessionId),
                  sessionId != activeChatSessionId,
                  !streamingSessions.contains(sessionId),
                  !busySessions.contains(sessionId),
                  !DetachedChatWindowController.shared.isDetached(sessionId)
            else { continue }
            pruneSessionChatState(sessionId)
        }
    }

    // MARK: - Detached chat windows (Phase 1)
    //
    // Helpers used by DetachedChatWindowController + DetachedChatPanelView.
    // The per-session storage from Phase 0 means a detached window can bind
    // to `chatMessages(for:)` for its fixed sessionId and stream into it
    // without disturbing the main window's active session.

    /// Load a detached session's messages + receipt from disk into the
    /// per-session slot. Called when a panel first opens so it shows history
    /// immediately even if the session was never the active one. Does NOT
    /// touch `activeChatSessionId` — the main window stays where it is.
    @MainActor
    func loadDetachedSessionMessages(_ sessionId: String) async {
        guard !sessionId.isEmpty else { return }
        // Skip if a stream is already populating this slot — overwriting
        // would clobber live deltas (mirrors selectChatSession's guard).
        if streamingSessions.contains(sessionId),
           !(chatMessagesBySession[sessionId] ?? []).isEmpty {
            return
        }
        var messageFailures: [String] = []
        let fetched: [ChatMessage]?
        do {
            fetched = try await client.getChatMessages(sessionId: sessionId)
        } catch {
            fetched = nil
            messageFailures.append("messages")
        }
        // 2026-06-08 W1.2 review fix (MEDIUM): re-check the streaming guard
        // AFTER the network await. A stream may have STARTED for this
        // session during the fetch (e.g. the user typed + sent in the
        // detached panel while history was loading). Writing the stale
        // disk snapshot now would drop the live optimistic + streaming
        // bubbles and the by-id delta updates would then miss. Only seed
        // the slot when no stream has taken ownership of it.
        let streamTookOver = streamingSessions.contains(sessionId)
            && !(chatMessagesBySession[sessionId] ?? []).isEmpty
        if let fetched, !streamTookOver {
            setChatMessages(fetched, for: sessionId)
        }
        detachedChatRefreshStatus[sessionId] = Self.nextRefreshStatus(
            previous: detachedChatRefreshStatus[sessionId],
            failedEndpoints: messageFailures,
            at: Date()
        )
        // Receipt is independent of the message-bubble stream state, but
        // still skip the write if a stream owns the slot so we don't stomp
        // a fresher in-flight receipt.
        if !streamTookOver {
            var receiptFailures: [String] = []
            do {
                setLatestContextReceipt(
                    try await client.getLatestContextReceipt(sessionId: sessionId),
                    for: sessionId
                )
            } catch {
                receiptFailures.append("context receipt")
            }
            detachedChatContextReceiptRefreshStatus[sessionId] = Self.nextRefreshStatus(
                previous: detachedChatContextReceiptRefreshStatus[sessionId],
                failedEndpoints: receiptFailures,
                at: Date()
            )
        }
    }

    /// Add a session to the pinned-chat strip from outside ChatView (the
    /// detached-window controller). The shared pin store updates ChatView's
    /// reactive `@AppStorage` value and the retention mirror together.
    /// Idempotent — a session already pinned is left as-is.
    @MainActor
    func pinChatSessionForDetachedWindow(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var ids = MacPinnedChatSessionStore.load()
        if !ids.contains(sessionId) {
            ids.append(sessionId)
        }
        guard (try? MacPinnedChatSessionStore.save(ids)) != nil else { return }
        MacSyncEngine.shared.requestChatSnapshotPublication(includeTranscripts: false)
    }

    /// Per-session message mutators. Used by `_sendChatBody` so optimistic
    /// bubbles + streaming deltas + error bubbles land in the right
    /// session's slot regardless of whether the user is currently looking
    /// at that session. Previously these writes were gated on
    /// `activeChatSessionId == requestSessionId` and the streamingTexts/
    /// streamingBubbleIds dicts handled the inactive-session case via
    /// selectChatSession's reinjection. With per-session storage, the gate
    /// is no longer needed — but the reinjection mechanism remains as a
    /// defensive idempotent double-write (guarded by !contains checks).
    func appendChatMessage(_ msg: ChatMessage, to sessionId: String) {
        var arr = chatMessagesBySession[sessionId] ?? []
        arr.append(msg)
        // chat-smoothness phase 6: the append seam is the ONLY place bubble
        // entrance animates — every genuine insert (optimistic send, streaming
        // placeholder, error bubble) flows through here, while wholesale
        // replaces (end-of-turn disk refresh, session load) stay instant so the
        // optimistic→daemon id swap never animates a teardown/rebuild.
        withAnimation(NativeAgentMotion.entranceSystem) {
            chatMessagesBySession[sessionId] = arr
        }
    }

    func removeChatMessage(id messageId: String, from sessionId: String) {
        guard var arr = chatMessagesBySession[sessionId] else { return }
        arr.removeAll { $0.id == messageId }
        chatMessagesBySession[sessionId] = arr
    }

    /// chat-smoothness phase 1 (the user, 2026-06-12): word-by-word flow, coalesced.
    /// ONE tunable knob for the Mac streaming cadence — raise for calmer
    /// ripple, lower for snappier. 70ms ≈ word-arrival rhythm at typical
    /// model token rates without hammering the renderer.
    static let chatStreamCoalesceSeconds: TimeInterval = 0.07

    func updateChatMessageContent(id messageId: String, in sessionId: String, content: String) {
        guard var arr = chatMessagesBySession[sessionId],
              let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }
        arr[idx].content = content
        chatMessagesBySession[sessionId] = arr
    }

    func clearStreamingBubbleState(_ sessionId: String) {
        streamingTexts[sessionId] = nil
        streamingBubbleIds[sessionId] = nil
        streamingUserTurnIds[sessionId] = nil
        streamingUserTurnTexts[sessionId] = nil
    }

    /// True iff the active chat session has work in flight.
    var isBusy: Bool { busySessions.contains(activeChatSessionId) }
    /// True iff the active chat session is actively streaming a response.
    var isChatStreaming: Bool { streamingSessions.contains(activeChatSessionId) }
    /// Back-compat: the single "running" session id many UI sites still ask
    /// about. We return the active session if it's running, else any other
    /// running session (so "another session running" banners can still
    /// detect work). Prefer `isSessionStreaming(_:)` in new code.
    var currentChatTaskSessionId: String? {
        if streamingSessions.contains(activeChatSessionId) { return activeChatSessionId }
        return streamingSessions.first
    }
    /// True if any session anywhere has work in flight.
    var anySessionBusy: Bool { !busySessions.isEmpty }
    /// True if any session anywhere is streaming.
    var anySessionStreaming: Bool { !streamingSessions.isEmpty }

    func isSessionBusy(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return busySessions.contains(sessionId)
    }

    func isSessionStreaming(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return streamingSessions.contains(sessionId)
    }

    func queuedChatTurns(for sessionId: String) -> [QueuedChatTurn] {
        guard !sessionId.isEmpty else { return [] }
        return queuedChatTurnsBySession[sessionId] ?? []
    }

    func isChatQueuePaused(_ sessionId: String) -> Bool {
        pausedChatQueueSessions.contains(sessionId)
    }
    // Fix 2: chat draft and pending attachments keyed by sessionId so they survive tab changes
}

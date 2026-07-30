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

    /// Drop a session's cached messages + receipt. Called when a session is
    /// deleted from the sidebar. The dict would otherwise grow unbounded as
    /// the user creates and discards sessions across a long-running app.
    func pruneSessionChatState(_ sessionId: String) {
        chatMessagesBySession.removeValue(forKey: sessionId)
        latestContextReceiptBySession.removeValue(forKey: sessionId)
        detachedChatRefreshStatus.removeValue(forKey: sessionId)
        detachedChatContextReceiptRefreshStatus.removeValue(forKey: sessionId)
        queuedChatTurnsBySession.removeValue(forKey: sessionId)
        pausedChatQueueSessions.remove(sessionId)
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
        Task { @MainActor in await MacSyncEngine.shared.writeSnapshots() }
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

    /// Returns true iff a message with this id exists in this session's
    /// in-memory list. Used by `_sendChatBody` to find optimistic bubbles
    /// to update without going through `chatMessages` (which only sees the
    /// active session).
    func chatMessageExists(id messageId: String, in sessionId: String) -> Bool {
        chatMessagesBySession[sessionId]?.contains(where: { $0.id == messageId }) ?? false
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
    // PATCH-2026-05-08: wave2-chat-ux — persona quick-switch for ChatBrainControlBar
    func cancelImprovementRefreshTask(_ id: String) {
        improvementRefreshTasks[id]?.cancel()
        improvementRefreshTasks[id] = nil
    }

    @MainActor
    func setImprovementRefreshTask(_ id: String, task: Task<Void, Never>) {
        improvementRefreshTasks[id]?.cancel()
        improvementRefreshTasks[id] = task
    }

    // Fix 2: chat draft and pending attachments keyed by sessionId so they survive tab changes
}

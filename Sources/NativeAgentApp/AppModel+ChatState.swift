import Transcripts
import Privacy
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
import DeviceSync

@MainActor
extension AppModel {
    /// The one intake for the live computer pane, fenced on the same exact
    /// identity the lifecycle reducer uses: a frame from a previous turn's
    /// trailing verb can never land in the turn that replaced it.
    func receiveMacScreenPreview(
        _ update: MacScreenPreviewUpdate,
        identity: MacChatTurnIdentity
    ) {
        guard engine.turns.activeTurnIDsBySession[identity.sessionId] == identity.turnId else { return }
        guard let merged = MacChatScreenPreview.merged(
            engine.turns.screenPreviewBySession[identity.sessionId],
            update: update
        ) else { return }
        engine.turns.screenPreviewBySession[identity.sessionId] = merged
    }

    /// Reload the resident mind after a profile repair, but never underneath a
    /// running turn (User, 2026-09-06). The refresh stops and restarts Context
    /// Flow and reloads cognition; doing that mid-turn changes the ground the
    /// answer in flight is standing on. `activeChatTurnLifecycleIDsBySession`
    /// is the app's existing record of which sessions own a live turn, so it
    /// is the gate, and the turn's own close drains the deferral.
    func refreshResidentMindAfterProfileRepair() async {
        guard engine.turns.activeTurnIDsBySession.isEmpty else {
            residentRefreshPendingAfterActiveTurns = true
            return
        }
        residentRefreshPendingAfterActiveTurns = false
        await applyProfileRepairToResidentMind()
    }

    /// Runs a deferred resident refresh once the last live turn has closed.
    func drainPendingResidentRefreshIfTurnsIdle() {
        guard residentRefreshPendingAfterActiveTurns,
              engine.turns.activeTurnIDsBySession.isEmpty else { return }
        residentRefreshPendingAfterActiveTurns = false
        Task { await self.applyProfileRepairToResidentMind() }
    }

    /// Everything a completed profile repair changes about the live agent, in
    /// one place so the gate above covers all of it (User, 2026-09-06: the
    /// personality reload ran ahead of the gate and re-taught the name mid-turn
    /// while the refresh it belongs with was still deferred).
    ///
    /// The repair rewrote the profile but left `personality` holding the
    /// pre-repair one, and Chat reloads it only when it is nil — so
    /// `agentDisplayName` (and AgentVoice) kept showing the fallback name until
    /// a screen that loads the profile was visited. A failed read leaves the
    /// previous value rather than blanking the header.
    /// User, 2026-09-25: the agent's name is read from THIS root's profile, at
    /// launch in every view and again once onboarding writes it. Simple view
    /// never loaded it, so after a relaunch the header fell back to the
    /// defaults cache — which is shared by every root this bundle runs against
    /// and, when the profile had been read before onboarding, held the seed's
    /// fallback "NativeAgent". A failed read keeps the current value.
    func reloadPersonality() async {
        guard let profile = try? await client.getPersonality() else { return }
        personality = profile
        teachMemoryHygieneName()
    }

    private func applyProfileRepairToResidentMind() async {
        if let repaired = try? await client.getPersonality() {
            personality = repaired
            teachMemoryHygieneName()
        }
        await client.refreshResidentMindAfterOnboardingTransition()
    }

    /// Drop a session's cached messages. Called when a session is
    /// deleted from the sidebar. The dict would otherwise grow unbounded as
    /// the user creates and discards sessions across a long-running app.
    func pruneSessionChatState(_ sessionId: String) {
        let activeLifecycleTurnId = engine.turns.activeTurnIDsBySession[sessionId]
        let lifecycleTurnId = activeLifecycleTurnId == nil
            ? engine.turns.lifecycleBySession[sessionId]?.identity.turnId
            : nil
        engine.transcripts.messagesBySession.removeValue(forKey: sessionId)
        detachedChatRefreshStatus.removeValue(forKey: sessionId)
        Task { await engine.turns.runtime.updateQueuedTurns { $0.removeValue(forKey: sessionId) } }
        engine.turns.pausedQueueSessions.remove(sessionId)
        engine.turns.queuePauseReasons.removeValue(forKey: sessionId)
        // A Stop/Archive can reach pruning before its joined producer has
        // persisted terminal proof. Preserve that one exact authority until
        // normal task cleanup closes it; stale-session pruning will remove the
        // terminal projection on a later bounded session-index refresh.
        if activeLifecycleTurnId == nil {
            engine.turns.lifecycleBySession.removeValue(forKey: sessionId)
            engine.turns.activeTurnIDsBySession.removeValue(forKey: sessionId)
        }
        if let lifecycleTurnId {
            Task { [lifecycleStore = engine.turns.lifecycleStore] in
                try? await lifecycleStore.remove(
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
        let cached = Set(engine.transcripts.messagesBySession.keys)
            .union(detachedChatRefreshStatus.keys)
            .union(engine.turns.queuedBySession.keys)
            .union(engine.turns.pausedQueueSessions)
            .union(engine.turns.lifecycleBySession.keys)
            .union(engine.turns.activeTurnIDsBySession.keys)
        for sessionId in cached {
            guard !knownSessionIds.contains(sessionId),
                  sessionId != activeChatSessionId,
                  !engine.turns.streamingSessions.contains(sessionId),
                  !engine.turns.busySessions.contains(sessionId),
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

    /// Load a detached session's messages from disk into the
    /// per-session slot. Called when a panel first opens so it shows history
    /// immediately even if the session was never the active one. Does NOT
    /// touch `activeChatSessionId` — the main window stays where it is.
    @MainActor
    func loadDetachedSessionMessages(_ sessionId: String) async {
        await loadDetachedSessionMessages(
            sessionId,
            loadMessages: { [transcripts = engine.transcripts] in try await transcripts.loadMessages(sessionId: $0, cached: true) })
    }

    @MainActor
    func loadDetachedSessionMessages(
        _ sessionId: String,
        loadMessages: (String) async throws -> [ChatMessage]
    ) async {
        guard !sessionId.isEmpty else { return }
        // Skip if a stream is already populating this slot — overwriting
        // would clobber live deltas (mirrors selectChatSession's guard).
        if engine.turns.streamingSessions.contains(sessionId),
           !(engine.transcripts.messagesBySession[sessionId] ?? []).isEmpty {
            return
        }
        let lifecycleAtLoadStart = engine.turns.lifecycle(for: sessionId)
        var messageFailures: [String] = []
        let fetched: [ChatMessage]?
        do {
            fetched = try await loadMessages(sessionId)
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
        let streamTookOver = engine.turns.streamingSessions.contains(sessionId)
            && !(engine.transcripts.messagesBySession[sessionId] ?? []).isEmpty
        let lifecycleAfterMessages = engine.turns.lifecycle(for: sessionId)
        guard !streamTookOver,
              lifecycleAfterMessages == nil || lifecycleAfterMessages == lifecycleAtLoadStart
        else { return }
        if let fetched {
            applyLoadedChatMessages(fetched, for: sessionId)
        }
        detachedChatRefreshStatus[sessionId] = Self.nextRefreshStatus(
            previous: detachedChatRefreshStatus[sessionId],
            failedEndpoints: messageFailures,
            at: Date()
        )
    }

    /// Add a session to the pinned-chat strip from outside ChatView (the
    /// detached-window controller). The shared pin store updates ChatView's
    /// reactive `@AppStorage` value and the retention mirror together.
    /// Idempotent — a session already pinned is left as-is.
    @MainActor
    func pinChatSessionForDetachedWindow(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var ids = MacPinnedChatSessionStore.load()
        let added = !ids.contains(sessionId)
        if added {
            ids.append(sessionId)
        }
        guard (try? MacPinnedChatSessionStore.save(ids)) != nil else { return }
        // 2026-09-06: a pin that ADDS a session asks for transcripts — the
        // published transcript set is chosen from the pins as they were before
        // this save, so publishing the new tab without them put an empty
        // conversation on the phone until some unrelated edge republished.
        NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: added)
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
        var arr = engine.transcripts.messagesBySession[sessionId] ?? []
        arr.append(msg)
        // chat-smoothness phase 6: the append seam is the ONLY place bubble
        // entrance animates — every genuine insert (optimistic send, streaming
        // placeholder, error bubble) flows through here, while wholesale
        // replaces (end-of-turn disk refresh, session load) stay instant so the
        // optimistic→daemon id swap never animates a teardown/rebuild.
        withAnimation(NativeAgentMotion.arrive) {
            engine.transcripts.messagesBySession[sessionId] = arr
        }
    }

    func removeChatMessage(id messageId: String, from sessionId: String) {
        guard var arr = engine.transcripts.messagesBySession[sessionId] else { return }
        arr.removeAll { $0.id == messageId }
        engine.transcripts.messagesBySession[sessionId] = arr
    }

    /// chat-smoothness phase 1 (the user, 2026-06-12): word-by-word flow, coalesced.
    /// ONE tunable knob for the Mac streaming cadence — raise for calmer
    /// ripple, lower for snappier. 70ms ≈ word-arrival rhythm at typical
    /// model token rates without hammering the renderer.
    static let chatStreamCoalesceSeconds = ChatStreamAccumulator.publishInterval

    func updateChatMessageContent(id messageId: String, in sessionId: String, content: String) {
        // THE STREAMING CASE FIRST (2026-09-13): the row being rewritten is the
        // last one on all but a handful of calls, and that case needs neither
        // the linear id search nor a mutated copy of the whole transcript.
        if engine.transcripts.setTailMessageContent(content, id: messageId, in: sessionId) { return }
        guard var arr = engine.transcripts.messagesBySession[sessionId],
              let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }
        arr[idx].content = content
        // 2026-09-06: only a rewrite of the FINAL row may keep the message
        // list's cached grouping (it patches that one row in place). An
        // interior row — a streaming reply with a slash command's system
        // message appended behind it — must invalidate the whole cache.
        if idx == arr.count - 1 {
            engine.transcripts.setMessagesTailOnly(arr, for: sessionId)
        } else {
            engine.transcripts.messagesBySession[sessionId] = arr
        }
    }

    /// Fluid glass A1: the streamed reply learns where its working notes end
    /// as soon as the core's final result says, so a reply that has already
    /// settled folds them in one animated swap, and the row the disk refresh
    /// puts in its place draws the same fold instead of snapping to it.
    func setChatMessageWorkingCommentary(_ characters: Int, id messageId: String, in sessionId: String) {
        guard var arr = engine.transcripts.messagesBySession[sessionId],
              let idx = arr.lastIndex(where: { $0.id == messageId }),
              arr[idx].metadata?.workingCommentaryChars != characters
        else { return }
        var metadata = arr[idx].metadata ?? ChatMessageMetadata()
        metadata.workingCommentaryChars = characters
        arr[idx].metadata = metadata
        withAnimation(NativeAgentMotion.arrive) {
            engine.transcripts.messagesBySession[sessionId] = arr
        }
    }

    /// Visible activity; the runtime sets retain ownership during a settled reply.
    var isBusy: Bool { engine.turns.isBusy(activeChatSessionId) }
    /// Whether the active chat should render its live response treatment.
    var isChatStreaming: Bool { engine.turns.isStreaming(activeChatSessionId) }

    /// Back-compat: the single "running" session id many UI sites still ask
    /// about. We return the active session if it's running, else any other
    /// running session (so "another session running" banners can still
    /// detect work). Prefer `engine.turns.isStreaming(_:)` in new code.
    var currentChatTaskSessionId: String? {
        if engine.turns.isStreaming(activeChatSessionId) { return activeChatSessionId }
        return engine.turns.streamingSessions.first { engine.turns.isStreaming($0) }
    }
    /// The exact runtime projection mounted by the "other sessions running"
    /// banner. It excludes only the foreground session, preserves canonical
    /// session-list order, and retains an unknown running id until the user can
    /// stop it or a lifecycle path clears it.
    var otherRunningChatSessionIDs: [String] {
        MacChatOtherSessionsProjection.otherRunning(
            streamingSessionIDs: engine.turns.liveStreamingSessionIDs,
            activeSessionID: activeChatSessionId,
            canonicalSessionIDs: engine.transcripts.sessions.map(\.id)
        )
    }

    // Fix 2: chat draft and pending attachments keyed by sessionId so they survive tab changes
}

// MARK: - Per-instance state that cannot live on AppModel
//
// Swift extensions cannot add stored properties, and `AppModel.swift` is not
// this change's to edit. The owner below is per-AppModel and strictly
// non-observable, so reading them during a SwiftUI view update cannot
// invalidate that update. Entries are pruned as soon as their owner dies.

@MainActor
private final class AppModelLiveState {
    weak var owner: AppModel?
    /// Installed at most once by `installDefaultsBackedSettingsObserver()`.
    var defaultsObserver: NSObjectProtocol?
    /// Re-entrancy guard: every setter in the reloaded block writes back to
    /// UserDefaults from its own `didSet`, which posts the very notification
    /// that drove the reload.
    var reloadingDefaults = false
    init(owner: AppModel) { self.owner = owner }
}

@MainActor
private var appModelLiveStates: [ObjectIdentifier: AppModelLiveState] = [:]

@MainActor
private func liveState(for model: AppModel) -> AppModelLiveState {
    if appModelLiveStates.count > 1 {
        for (key, dead) in appModelLiveStates where dead.owner == nil {
            if let observer = dead.defaultsObserver {
                NotificationCenter.default.removeObserver(observer)
                dead.defaultsObserver = nil
            }
            appModelLiveStates.removeValue(forKey: key)
        }
    }
    let key = ObjectIdentifier(model)
    if let existing = appModelLiveStates[key], existing.owner === model { return existing }
    let fresh = AppModelLiveState(owner: model)
    appModelLiveStates[key] = fresh
    return fresh
}

@MainActor
extension AppModel {

    // MARK: - Defaults-backed settings, kept live

    /// Installs the single `UserDefaults.didChangeNotification` observer that
    /// keeps the defaults-backed settings block in sync with disk. Without it
    /// a write from the Claude bridge or another process left the running app
    /// stale until relaunch. Idempotent; safe to call from every entry point.
    func installDefaultsBackedSettingsObserver() {
        let state = liveState(for: self)
        guard state.defaultsObserver == nil else { return }
        state.defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadDefaultsBackedSettings()
            }
        }
    }

    /// Re-reads exactly the block `AppModel.swift` reads once at construction
    /// (`AppModel.swift:106-160` plus `chatProvider` at `:573`). Assignments
    /// are value-guarded, and the whole pass is wrapped in a re-entrancy flag
    /// so the UserDefaults write-back in each `didSet` cannot loop.
    func reloadDefaultsBackedSettings() {
        let state = liveState(for: self)
        guard !state.reloadingDefaults else { return }
        state.reloadingDefaults = true
        defer { state.reloadingDefaults = false }

        let defaults = UserDefaults.standard
        let selectedPersona = NativeChatTurnOptions.normalizedPickerPersona(PersonaSelection.current())
        if chatPersona != selectedPersona { chatPersona = selectedPersona }
        func string(_ key: String, _ fallback: String) -> String {
            defaults.string(forKey: key) ?? fallback
        }

        let searxng = string("searxngBaseURL", "")
        if searxngBaseURL != searxng { searxngBaseURL = searxng }

        let allowedChats = string("telegramAllowedChats", "")
        if telegramAllowedChats != allowedChats { telegramAllowedChats = allowedChats }

        let allowedUsers = string("telegramAllowedUsers", "")
        if telegramAllowedUsers != allowedUsers { telegramAllowedUsers = allowedUsers }

        let requireMention = defaults.object(forKey: "telegramRequireMention") as? Bool ?? true
        if telegramRequireMention != requireMention { telegramRequireMention = requireMention }

        // Empty is "no pick of my own": the turn resolves through the Providers
        // group (2026-09-13). A literal here was a model chosen in code.
        let model = string("chatModel", "")
        if chatModel != model { chatModel = model }

        let effort = string("chatReasoningEffort", "high")
        if chatReasoningEffort != effort { chatReasoningEffort = effort }

        let fastMode = defaults.bool(forKey: "chatFastMode")
        if chatFastMode != fastMode { chatFastMode = fastMode }

        let fileAccess = string("chatFileAccess", "auto")
        if chatFileAccess != fileAccess { chatFileAccess = fileAccess }

        let tgModel = string("telegramModel", "")
        if telegramModel != tgModel { telegramModel = tgModel }

        let tgEffort = string("telegramReasoningEffort", "high")
        if telegramReasoningEffort != tgEffort { telegramReasoningEffort = tgEffort }

        let provider = string("chatProvider", "openai_oauth_direct")
        if chatProvider != provider { chatProvider = provider }
    }
}

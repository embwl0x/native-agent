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
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import ToolExecution
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
import TrustCenter
import DreamREMCycle
import DoctorChecks
import EngineRuntime
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
import MacIntegration
import WorkflowOrchestration
import Connectors
import Browser
import DeviceSync
// Blueprint: | `AppModel+ChatState.swift` | `AppModel`: `loadDetachedSessionMessages`, `pinChatSessionForDetachedWindow`, `pruneSessionChatState`, `pruneStaleSessionChatState` |

@MainActor
extension AppModel {
    func drainPendingResidentRefreshIfTurnsIdle() {
        engine.drainPendingResidentRefreshIfTurnsIdle(
            publishProfile: { await self.reloadPersonality() },
            refreshMind: { await NativeAgentEngine.live.refreshResidentMindAfterOnboardingTransition() }
        )
    }

    /// Publish the profile from this root after launch or repair; a failed
    /// read keeps the visible name rather than clearing the header.
    func reloadPersonality() async {
        let previousName = engine.persona.profile?.name
        guard (try? await engine.persona.loadProfile()) != nil else { return }
        teachMemoryHygieneName(previousName: previousName)
    }

    /// Drop a session's cached messages. Called when a session is
    /// deleted from the sidebar. The dict would otherwise grow unbounded as
    /// the user creates and discards sessions across a long-running app.
    func pruneSessionChatState(_ sessionId: String) {
        engine.transcripts.messagesBySession.removeValue(forKey: sessionId)
        detachedChatRefreshStatus.removeValue(forKey: sessionId)
        engine.turns.runtime.pruneSessionState(sessionId)
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
        for sessionId in engine.turns.runtime.staleSessionIDs(
            cached: cached, known: knownSessionIds,
            keepVisible: { $0 == activeChatSessionId || DetachedChatWindowController.shared.isDetached($0) }
        ) {
            pruneSessionChatState(sessionId)
        }
    }

    // MARK: - Detached chat windows (Phase 1)
    //
    // Helpers used by DetachedChatWindowController + DetachedChatPanelView.
    // The per-session storage from Phase 0 means a detached window can bind
    // to `chatMessages(for:)` for its fixed sessionId and stream into it
    // without disturbing the main window's active session.

    func loadDetachedSessionMessages(_ sessionId: String) async {
        await engine.loadDetachedSessionMessages(sessionId) { failures in
            detachedChatRefreshStatus[sessionId] = Self.nextRefreshStatus(
                previous: detachedChatRefreshStatus[sessionId],
                failedEndpoints: failures, at: Date()
            )
        }
    }

    /// Add a session to the pinned-chat strip from outside ChatView (the
    /// detached-window controller). The transcript owner publishes membership.
    /// Idempotent — a session already pinned is left as-is.
    @MainActor
    func pinChatSessionForDetachedWindow(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var ids = engine.transcripts.pinnedSessionIDs
        let added = !ids.contains(sessionId)
        if added {
            ids.append(sessionId)
        }
        guard let encoded = try? engine.transcripts.savePinnedSessionIDs(ids) else { return }
        // 2026-09-06: a pin that ADDS a session asks for transcripts — the
        // published transcript set is chosen from the pins as they were before
        // this save, so publishing the new tab without them put an empty
        // conversation on the phone until some unrelated edge republished.
        _ = engine.transcripts.publishPins(encoded, includeTranscripts: added)
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
    /// (`AppModel.swift`). Assignments
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

        let allowedChats = string("telegramAllowedChats", "")
        if telegramAllowedChats != allowedChats { telegramAllowedChats = allowedChats }

        let allowedUsers = string("telegramAllowedUsers", "")
        if telegramAllowedUsers != allowedUsers { telegramAllowedUsers = allowedUsers }

        let requireMention = defaults.object(forKey: "telegramRequireMention") as? Bool ?? true
        if telegramRequireMention != requireMention { telegramRequireMention = requireMention }

        let fileAccess = string("chatFileAccess", "auto")
        if chatFileAccess != fileAccess { chatFileAccess = fileAccess }


    }
}

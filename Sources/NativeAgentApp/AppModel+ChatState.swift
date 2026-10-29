import Foundation
import SwiftUI
import NativeAgentShared
import EngineRuntime
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
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

    /// Drop the cached messages for a deleted session.
    func pruneSessionChatState(_ sessionId: String) {
        engine.transcripts.removeMessages(for: sessionId)
        detachedChatRefreshStatus.removeValue(forKey: sessionId)
        engine.turns.runtime.pruneSessionState(sessionId)
    }

    /// Prune unknown cached sessions, keeping live work and mounted panels.
    func pruneStaleSessionChatState(knownSessionIds: Set<String>) {
        let cached = engine.transcripts.loadedSessionIDs
            .union(detachedChatRefreshStatus.keys)
        for sessionId in engine.turns.runtime.staleSessionIDs(
            cached: cached, known: knownSessionIds,
            keepVisible: { $0 == activeChatSessionId || DetachedChatWindowController.shared.isDetached($0) }
        ) {
            pruneSessionChatState(sessionId)
        }
    }

    // MARK: - Detached chat windows
    //
    // Detached windows stream their fixed session without changing the main window's active session.

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
        _ = try? engine.transcripts.pinSession(sessionId)
    }

    /// Visible activity; the runtime sets retain ownership during a settled reply.
    var isBusy: Bool { engine.turns.isBusy(activeChatSessionId) }
    /// Whether the active chat should render its live response treatment.
    var isChatStreaming: Bool { engine.turns.isStreaming(activeChatSessionId) }

    /// The exact runtime projection mounted by the "other sessions running"
    /// banner. It excludes only the foreground session, preserves canonical
    /// session-list order, and retains an unknown running id until the user can
    /// stop it or a lifecycle path clears it.
    var otherRunningChatSessionIDs: [String] {
        OtherRunningChats.otherRunning(
            streamingSessionIDs: engine.turns.liveStreamingSessionIDs,
            activeSessionID: activeChatSessionId,
            canonicalSessionIDs: engine.transcripts.sessions.map(\.id)
        )
    }

    // Fix 2: chat draft and pending attachments keyed by sessionId so they survive tab changes
}

@MainActor
extension AppModel {

    // MARK: - Defaults-backed settings, kept live

    /// Installs the single `UserDefaults.didChangeNotification` observer that
    /// keeps the defaults-backed settings block in sync with disk. Without it
    /// a write from the Claude bridge or another process left the running app
    /// stale until relaunch. Idempotent; safe to call from every entry point.
    func installDefaultsBackedSettingsObserver() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
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
        guard !reloadingDefaults else { return }
        reloadingDefaults = true
        defer { reloadingDefaults = false }

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

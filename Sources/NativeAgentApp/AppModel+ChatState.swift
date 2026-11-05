import Foundation
import SwiftUI
import NativeAgentShared
import EngineRuntime
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
// Blueprint: | `AppModel+ChatState.swift` | `AppModel`: Checked profile and transcript reads, pinning and pruning |

@MainActor
extension AppModel {
    /// Failed profile reads retain the owner's cause and mark identity unavailable.
    func reloadPersonality() async {
        let previousName = engine.persona.profile?.name
        do {
            try await engine.persona.loadProfile()
            teachMemoryHygieneName(previousName: previousName)
        } catch {
        }
    }

    func pruneSessionChatState(_ sessionId: String) {
        engine.transcripts.removeMessages(for: sessionId)
        detachedChatRefreshStatus.removeValue(forKey: sessionId)
        engine.turns.runtime.pruneSessionState(sessionId)
    }

    /// Pruning must preserve live work and mounted panels.
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
    // Detached windows must stream their fixed session without changing the main window's active session.

    func loadDetachedSessionMessages(_ sessionId: String) async {
        await engine.loadDetachedSessionMessages(sessionId) { failures in
            detachedChatRefreshStatus[sessionId] = Self.nextRefreshStatus(
                previous: detachedChatRefreshStatus[sessionId],
                failedEndpoints: failures, at: Date()
            )
        }
    }

    /// Publish pin membership through the transcript owner so detached and main windows agree.
    @MainActor
    func pinChatSessionForDetachedWindow(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        _ = try? engine.transcripts.pinSession(sessionId)
    }

    /// Runtime sets retain ownership while a reply settles.
    var isBusy: Bool { engine.turns.isBusy(activeChatSessionId) }
    var isChatStreaming: Bool { engine.turns.isStreaming(activeChatSessionId) }

    /// Exclude only the foreground session and retain unknown running IDs so work remains stoppable.
    var otherRunningChatSessionIDs: [String] {
        OtherRunningChats.otherRunning(
            streamingSessionIDs: engine.turns.liveStreamingSessionIDs,
            activeSessionID: activeChatSessionId,
            canonicalSessionIDs: engine.transcripts.sessions.map(\.id)
        )
    }

    // Key drafts and attachments by session so tab changes preserve unsent work.
}

@MainActor
extension AppModel {

    // MARK: - Defaults-backed settings, kept live

    /// Observe defaults changes once so bridge and external writes reach the running settings without a relaunch.
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

    /// Guard assignments and suppress re-entry so UserDefaults write-backs in didSet cannot loop.
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

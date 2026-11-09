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

    func pruneSessionChatState(_ sessionId: String) async {
        engine.transcripts.removeMessages(for: sessionId)
        engine.turns.runtime.pruneSessionState(sessionId)
        await engine.panelFreshness.removeDetached(sessionId)
    }

    /// Pruning must preserve live work and mounted panels.
    func pruneStaleSessionChatState(knownSessionIds: Set<String>) async {
        let visible: Set<String>
        do {
            let face = try BodyFacePresentation.current(model: self)
            let scope = try await BodyQuietChatCommands(face: face).scope()
            visible = scope.detachedSessionIDs.union([scope.selectedSessionID])
        } catch {
            setFailureStatus(error, action: "read visible conversations before pruning chat state")
            return
        }
        let detachedIDs = await engine.panelFreshness.detachedSessionIDs()
        guard Set(engine.transcripts.sessions.map(\.id)) == knownSessionIds else { return }
        let cached = engine.transcripts.loadedSessionIDs
            .union(detachedIDs)
        for sessionId in engine.turns.runtime.staleSessionIDs(
            cached: cached, known: knownSessionIds,
            keepVisible: { visible.contains($0) }
        ) {
            guard !engine.transcripts.sessions.contains(where: { $0.id == sessionId }),
                  !visible.contains(sessionId) else { continue }
            await pruneSessionChatState(sessionId)
        }
    }

    // MARK: - Detached chat windows
    // Detached windows must stream their fixed session without changing the main window's active session.

    func loadDetachedSessionMessages(_ sessionId: String) async {
        guard !sessionId.isEmpty else { return }
        await engine.panelFreshness.refreshDetached(session: sessionId) { [self] in
            await readDetachedSessionMessages(sessionId)
        }
    }

    private func readDetachedSessionMessages(_ sessionId: String) async -> [String]? {
        var outcome: [String]?
        await engine.loadDetachedSessionMessages(sessionId) { outcome = $0 }
        return outcome
    }

    /// Publish pin membership through the transcript owner so detached and main windows agree.
    @MainActor
    func pinChatSessionForDetachedWindow(_ sessionId: String) async -> Bool {
        guard !sessionId.isEmpty else { return false }
        do {
            _ = try await engine.transcripts.pinSession(sessionId)
            return true
        } catch {
            statusText = "Pinned tab save is unconfirmed: \(error.localizedDescription)"
            return false
        }
    }

    /// Turn presentation comes from this conversation's slot; commands keep their operational admission checks.
    var isBusy: Bool { turnPart("isBusy", for: activeChatSessionId) { $0?.isBusy == true } }
    var isChatStreaming: Bool { turnPart("isStreaming", for: activeChatSessionId) { $0?.isStreaming == true } }

    /// Exclude only the foreground session and retain unknown running IDs so work remains stoppable.
    var otherRunningChatSessionIDs: [String] {
        OtherRunningChats.otherRunning(
            streamingSessionIDs: turnSessionsFace?.streamingSessionIDs ?? [],
            activeSessionID: activeChatSessionId,
            canonicalSessionIDs: face.slot(.sessions).select("allIDs", as: SessionListFace.self) { $0?.allIDs ?? [] }
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

        let fileAccess = string("chatFileAccess", "auto")
        if chatFileAccess != fileAccess { chatFileAccess = fileAccess }


    }
}

extension AppModel {
    /// One part of a conversation's turn face: its reader redraws only when that part changes.
    func turnPart<Part: Equatable>(_ name: String, for sessionID: String, _ part: @escaping (TurnFace?) -> Part) -> Part {
        face.slot(.turn(session: sessionID)).select(name, as: TurnFace.self, part)
    }

    var turnSessionsFace: TurnSessionsFace? {
        face.slot(.turns).value(as: TurnSessionsFace.self)
    }
}

import ChatOrchestration

@MainActor
extension AppModel: MacChatSessionSelectionPort {
    func noteChatSessionUserChoice() {
        MacChatSelectionIntent.noteUserChoice()
    }

    func hasCachedChatTranscript(for sessionID: String) -> Bool {
        engine.transcripts.messagesBySession[sessionID] != nil
    }

    func containsChatSession(_ sessionID: String) -> Bool {
        engine.transcripts.sessions.contains(where: { $0.id == sessionID })
    }

    func chatSessionLifecycle(for sessionID: String) -> MacChatTurnLifecycleState? {
        engine.turns.lifecycle(for: sessionID)
    }

    func presentChatSessionStatus(_ text: String) {
        statusText = text
    }
}

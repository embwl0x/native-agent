import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.detached.emptyState
//
// Drives the same mounted-panel destination resolver used before the detached
// empty-state copy and composer availability are selected. An absent session
// must not be projected as a generic, sendable "Chat" destination.

private func detachedEmptyStateSession(_ id: String, title: String) throws -> ChatSession {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "title": title,
        "messageCount": 0,
        "createdAt": "2026-08-24T00:00:00Z",
    ])
    return try JSONDecoder().decode(ChatSession.self, from: data)
}

@Test("detached empty state distinguishes an available destination from a removed session")
func detachedChatEmptyStateUsesBoundSessionResolution() throws {
    let retained = try detachedEmptyStateSession("retained", title: "Project planning")

    #expect(
        DetachedChatSessionPresentation.resolve(
            sessionId: "retained",
            sessions: [retained]
        ) == .available(title: "Project planning")
    )

    let missing = DetachedChatSessionPresentation.resolve(
        sessionId: "removed",
        sessions: [retained]
    )
    #expect(missing == .unavailable)
    #expect(!missing.isAvailable)
    #expect(
        DetachedChatSessionPresentation.unavailableTitle
            == "This chat session is no longer available"
    )
    #expect(
        DetachedChatSessionPresentation.unavailableDetail
            == "Messages cannot be sent from this window. Close it and choose another conversation in the main app."
    )
}

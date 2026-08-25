import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.pinnedTabStrip
@Suite("Pinned chat tab strip")
struct ChatPinnedTabStripEvalTests {
    private func session(_ id: String, title: String) throws -> ChatSession {
        try JSONDecoder().decode(ChatSession.self, from: Data("""
        {"id":"\(id)","title":\(String(reflecting: title)),"createdAt":"2026-08-24T00:00:00Z"}
        """.utf8))
    }

    @Test("a pinned tab exposes its title and an explicit close label, while only streaming ids show the dot")
    func pinnedTabPresentationBindsTitlesCloseControlAndRunningState() throws {
        let streaming = try session("streaming", title: "Release planning")
        let idle = try session("idle", title: "Research notes")
        let activeIDs: Set<String> = [streaming.id]

        #expect(PinnedSessionTabPresentation.tabAccessibilityLabel(for: streaming) == "Release planning")
        #expect(PinnedSessionTabPresentation.closeAccessibilityLabel(for: streaming)
            == "Close pinned tab Release planning")
        #expect(PinnedSessionTabPresentation.showsRunningIndicator(
            sessionID: streaming.id,
            streamingSessionIDs: activeIDs
        ))
        #expect(!PinnedSessionTabPresentation.showsRunningIndicator(
            sessionID: idle.id,
            streamingSessionIDs: activeIDs
        ))
    }

    @Test("the mounted strip receives streaming and drag-target state from ChatView")
    func mountedStripWiringCannotLoseItsLiveInputs() throws {
        let stripSource = try AppSourceScraping.appSource("ContextReceiptView.swift")
        #expect(stripSource.contains(
            "running: PinnedSessionTabPresentation.showsRunningIndicator("
        ))
        #expect(stripSource.contains(
            ".accessibilityLabel(PinnedSessionTabPresentation.closeAccessibilityLabel(for: session))"
        ))
        #expect(stripSource.contains(
            ".accessibilityLabel(PinnedSessionTabPresentation.tabAccessibilityLabel(for: session))"
        ))

        let expectedRunningSessions: Set<String> = ["live-turn"]
        let strip = PinnedSessionTabStrip(
            sessions: [],
            activeSessionId: "",
            runningSessionIds: expectedRunningSessions,
            dropTargeted: true,
            onSelect: { _ in },
            onClose: { _ in },
            onRename: { _, _ in }
        )
        #expect(strip.runningSessionIds == expectedRunningSessions)
        #expect(PinnedSessionTabPresentation.showsRunningIndicator(
            sessionID: "live-turn",
            streamingSessionIDs: strip.runningSessionIds
        ))

        let chatSource = try AppSourceScraping.appSource("ChatView.swift")
        #expect(chatSource.contains("dropTargeted: pinnedSessionDropTargeted"))
        #expect(chatSource.contains("isTargeted: $pinnedSessionDropTargeted"))
    }
}

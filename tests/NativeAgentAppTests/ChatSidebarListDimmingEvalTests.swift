import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.sidebar.listDimming
@Suite("Chat sidebar list dimming")
struct ChatSidebarListDimmingEvalTests {
    @MainActor
    @Test("either retained-data failure dims the mounted session list and a full success clears both")
    func sidebarDimmingTracksBothLoadFailureOwners() throws {
        let model = AppModel()

        model.chatStateLoadFailed = true
        model.chatSessionIndexRefreshFailed = false
        #expect(model.chatSidebarSessionListOpacity == 0.55)

        model.chatStateLoadFailed = false
        model.chatSessionIndexRefreshFailed = true
        #expect(model.chatSidebarSessionListOpacity == 0.55)

        model.chatStateLoadFailed = true
        model.chatSessionIndexRefreshFailed = true
        #expect(model.chatSidebarSessionListOpacity == 0.55)

        model.markChatSidebarLoadSucceeded()
        #expect(!model.chatStateLoadFailed)
        #expect(!model.chatSessionIndexRefreshFailed)
        #expect(model.chatSidebarSessionListOpacity == 1)
    }

    @Test("the real session sidebar consumes the AppModel dimming projection")
    func mountedSessionSidebarUsesTheBehavioralProjection() throws {
        let source = try AppSourceScraping.appSource("ChatView.swift")
        let start = try #require(source.range(of: "var sessionSidebar: some View"))
        let end = try #require(source.range(
            of: "\n    func sessionSectionHeader",
            range: start.upperBound..<source.endIndex
        ))
        let sidebar = String(source[start.lowerBound..<end.lowerBound])

        #expect(sidebar.contains(".opacity(appModel.chatSidebarSessionListOpacity)"))
        #expect(!sidebar.contains(".opacity(appModel.chatStateLoadFailed"))

        let loaderSource = try AppSourceScraping.appSource("AppModel+ChatSessions.swift")
        let loader = try AppSourceScraping.functionBody(
            named: "performLoadChatState", in: loaderSource
        )
        #expect(loader.contains("markChatSidebarLoadSucceeded()"))
    }
}

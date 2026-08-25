import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.conversationSettings.refreshCatalogButton
@Suite("Chat conversation-settings catalog refresh")
struct ChatConversationSettingsRefreshCatalogEvalTests {
    @Test("every refresh result has an explicit visible receipt")
    func refreshReceiptNeverTreatsFailedReadsAsSuccess() {
        #expect(
            ChatCatalogRefreshPresentation.resolve(catalogRefreshed: true, providersFresh: true)
                == .refreshed
        )
        #expect(
            ChatCatalogRefreshPresentation.resolve(catalogRefreshed: false, providersFresh: true)
                .message == "Model catalog could not refresh. Showing existing choices."
        )
        #expect(
            ChatCatalogRefreshPresentation.resolve(catalogRefreshed: true, providersFresh: false)
                .message == "Providers could not refresh. Showing existing choices."
        )
        let bothFailed = ChatCatalogRefreshPresentation.resolve(
            catalogRefreshed: false,
            providersFresh: false
        )
        #expect(bothFailed == .catalogAndProvidersUnavailable)
        #expect(bothFailed.isFailure)
        #expect(bothFailed.message.contains("could not refresh"))
    }

    @Test("repeated taps cannot overlap and the completed result releases the control")
    func refreshStateSerializesRepeatedTaps() {
        var state = ChatCatalogRefreshState()

        let firstBegin = state.begin()
        #expect(firstBegin)
        #expect(state.isRefreshing)
        let overlappingBegin = state.begin()
        #expect(!overlappingBegin)

        state.finish(catalogRefreshed: false, providersFresh: true)
        #expect(!state.isRefreshing)
        #expect(state.presentation == .catalogUnavailable)
        let laterBegin = state.begin()
        #expect(laterBegin)
        state.finish(catalogRefreshed: true, providersFresh: true)
        #expect(state.presentation == .refreshed)
    }

    @Test("mounted refresh uses both production reads and exposes its local receipt")
    func refreshButtonIsWiredToVisibleOutcomeState() throws {
        let bar = try AppSourceScraping.appSource("ChatBrainControlBar.swift")
        #expect(bar.contains("Task { await refreshConversationCatalog() }"))
        #expect(bar.contains(".disabled(catalogRefresh.isRefreshing)"))
        #expect(bar.contains("chat.conversation-settings.catalog-refresh-status"))
        #expect(bar.contains("let catalogRefreshed = await appModel.refreshModelCatalog()"))
        #expect(bar.contains("let providersFresh = await appModel.loadProvidersForChat()"))
        #expect(bar.contains("catalogRefresh.finish("))

        let appModel = try AppSourceScraping.appSource("AppModel+ProvidersAuth.swift")
        guard let start = appModel.range(of: "func refreshModelCatalog() async -> Bool") else {
            Issue.record("catalog refresh owner moved")
            return
        }
        let body = String(appModel[start.lowerBound...].prefix(700))
        #expect(body.contains("return true"))
        #expect(body.contains("return false"))
        #expect(body.contains("statusText = \"Model refresh failed:"))
    }
}

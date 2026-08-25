import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.emptyStateVsLoading
//
// Drives the exact state resolver mounted by ToolsView. A catalog with zero
// rows is a completed read, while an unavailable catalog is a failed read;
// neither state is allowed to reuse the first-load progress state.
@Suite("Tools empty state versus loading", .serialized)
struct ToolsEmptyStateVsLoadingEvalTests {
    @Test("loading, a successfully empty catalog, and a failed catalog reader remain distinct")
    func loadedEmptyAndUnavailableNeverBorrowTheLoadingPresentation() {
        #expect(ChatToolCatalogPresentation.catalogState(
            catalog: nil,
            loadFailed: false,
            loadError: nil
        ) == .loading)

        #expect(ChatToolCatalogPresentation.catalogState(
            catalog: catalog(),
            loadFailed: false,
            loadError: nil
        ) == .empty)

        #expect(ChatToolCatalogPresentation.catalogState(
            catalog: nil,
            loadFailed: true,
            loadError: "tool catalog returned an invalid envelope"
        ) == .unavailable(detail: "tool catalog returned an invalid envelope"))
    }

    @Test("a failed refresh marks retained rows stale rather than rendering empty or loading")
    func retainedCatalogFailureIsVisibleAsStale() {
        let prior = catalog(tools: [ChatCatalogTool(
            name: "fixture_tool",
            description: "Fixture tool",
            parametersPreview: nil,
            dispatchableVia: "native",
            loadState: "loaded",
            effectiveAutonomy: "auto",
            availableNow: true
        )])

        let state = ChatToolCatalogPresentation.catalogState(
            catalog: prior,
            loadFailed: true,
            loadError: "dispatch unavailable"
        )
        #expect(state != .loading)
        #expect(state != .empty)
        #expect(state != .unavailable(detail: "dispatch unavailable"))
        guard case .stale(let catalog, let receipt, let detail) = state else {
            Issue.record("A failed refresh must retain and label the prior catalog as stale")
            return
        }
        #expect(catalog == prior)
        #expect(receipt.visibleToolCount == 1)
        #expect(detail == "dispatch unavailable")
    }

    private func catalog(tools: [ChatCatalogTool] = []) -> ChatToolCatalogSnapshot {
        ChatToolCatalogSnapshot(
            tools: tools,
            currentlyLoaded: [],
            builderAvailable: [],
            builderPolicyLocked: [],
            macAppAvailable: [],
            macAppPolicyLocked: [],
            fullMacActive: false,
            fileOpsAllowed: false,
            systemAllowed: false,
            appControlAllowed: false,
            builderModeDetail: "",
            permissionLevel: ""
        )
    }
}

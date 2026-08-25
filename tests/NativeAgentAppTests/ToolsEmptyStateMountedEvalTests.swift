import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.emptyState

@MainActor
@Suite("app.settings · Tools mounted empty state", .serialized)
struct ToolsEmptyStateMountedEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-empty-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func emptyCatalogFromRuntimeEnvelope() -> ChatToolCatalogSnapshot {
        // This is the exact JSON envelope parser used after the live
        // `tool_catalog` dispatcher returns; all optional metadata takes its
        // production defaults while `tools: []` remains a completed read.
        let envelope: JSONValue = .object(["tools": .array([])])
        return ChatToolCatalogSnapshot.from(jsonValue: envelope)!
    }

    @Test("a completed empty runtime envelope presents empty rather than a perpetual spinner")
    func emptyCatalogUsesTheCompletedEmptyPresentation() {
        let catalogState = ChatToolCatalogPresentation.catalogState(
            catalog: emptyCatalogFromRuntimeEnvelope(),
            loadFailed: false,
            loadError: nil
        )
        #expect(catalogState == .empty)
        #expect(ToolsCatalogSurfacePresentation.state(for: catalogState) == .empty(.init(
            title: "No Chat Tools Available",
            detail: "The live catalog completed successfully but returned no tools.",
            systemImage: "hammer"
        )))
    }

    @Test("a failed first read presents unavailable, not healthy empty")
    func unavailableCatalogKeepsItsFailureVisible() {
        let catalogState = ChatToolCatalogPresentation.catalogState(
            catalog: nil,
            loadFailed: true,
            loadError: "runtime tool catalog refused its envelope"
        )
        #expect(ToolsCatalogSurfacePresentation.state(for: catalogState) == .unavailable(.init(
            title: "Chat Tool Catalog Unavailable",
            detail: "The live catalog could not be read: runtime tool catalog refused its envelope. Tap Refresh to retry.",
            systemImage: "exclamationmark.triangle"
        )))
    }

    @Test("no catalog before a reader result presents loading rather than empty or unavailable")
    func loadingCatalogUsesTheInFlightPresentation() {
        let catalogState = ChatToolCatalogPresentation.catalogState(
            catalog: nil,
            loadFailed: false,
            loadError: nil
        )
        #expect(ToolsCatalogSurfacePresentation.state(for: catalogState) == .loading(.init(
            title: "Loading tool catalog",
            detail: "Loading tool catalog...",
            systemImage: "arrow.triangle.2.circlepath"
        )))
    }

    @Test("the real scoped refresh leaves first entry in a terminal catalog state")
    func realRefreshSettlesLoadingIntoCurrentOrHonestFailure() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        await app.refreshForSidebarItem(.tools)

        switch ChatToolCatalogPresentation.catalogState(
            catalog: app.chatToolCatalog,
            loadFailed: app.chatToolCatalogLoadFailed,
            loadError: app.chatToolCatalogLoadError
        ) {
        case .loading:
            Issue.record("The Tools refresh must settle into a runtime result or an explicit read failure")
        case .empty, .available, .unavailable, .stale:
            break
        }
    }
}

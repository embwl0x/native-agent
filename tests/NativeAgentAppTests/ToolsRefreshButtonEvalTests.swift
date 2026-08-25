import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.refreshButton

@MainActor
@Suite("Tools refresh button")
struct ToolsRefreshButtonEvalTests {
    @Test("the toolbar receipt distinguishes clean, partial, unavailable, and in-flight outcomes")
    func completionDoesNotCallACatalogFailureARefreshSuccess() {
        let clean = refreshStatus()
        let partial = refreshStatus(failures: ["mcp servers"])

        #expect(ToolsRefreshPresentation.completion(
            panelRefresh: clean,
            catalogLoadFailed: false,
            hasCatalog: true
        ) == .refreshed)
        #expect(ToolsRefreshPresentation.completion(
            panelRefresh: partial,
            catalogLoadFailed: false,
            hasCatalog: true
        ) == .partial)
        #expect(ToolsRefreshPresentation.completion(
            panelRefresh: clean,
            catalogLoadFailed: true,
            hasCatalog: true
        ) == .partial)
        #expect(ToolsRefreshPresentation.completion(
            panelRefresh: partial,
            catalogLoadFailed: true,
            hasCatalog: false
        ) == .unavailable)
        #expect(ToolsRefreshPresentation.message(for: .partial)?.contains("could not be refreshed") == true)
        #expect(ToolsRefreshPresentation.message(for: .unavailable)?.contains("could not be refreshed") == true)
    }

    @Test("the refresh action refuses a second request while an existing Tools refresh owns the lane")
    func actionIsSingleFlight() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        model.isRefreshingTools = true
        model.toolsRefreshState = .refreshing

        let ignored = await model.refreshToolsFromToolbar()

        #expect(ignored == .alreadyRefreshing)
        #expect(model.isRefreshingTools)
        #expect(model.toolsRefreshState == .refreshing)
    }

    @Test("the real toolbar action records the same completed receipt it leaves visible")
    func toolbarRefreshRunsTheScopedOwnerAndPublishesItsOutcome() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let result = await model.refreshToolsFromToolbar()

        #expect(!model.isRefreshingTools)
        #expect(model.toolsRefreshState == result)
        #expect(model.panelRefreshStatus[.tools] != nil)
        #expect(result == ToolsRefreshPresentation.completion(
            panelRefresh: model.panelRefreshStatus[.tools],
            catalogLoadFailed: model.chatToolCatalogLoadFailed,
            hasCatalog: model.chatToolCatalog != nil
        ))
        #expect(model.statusText == ToolsRefreshPresentation.message(for: result))
        #expect(result != .refreshing)
        #expect(result != .idle)
    }

    private func refreshStatus(failures: [String] = []) -> AppModel.PanelRefreshStatus {
        let now = Date(timeIntervalSince1970: 1_724_500_000)
        return AppModel.PanelRefreshStatus(
            lastAttemptAt: now,
            lastSuccessAt: failures.isEmpty ? now : nil,
            failedEndpoints: failures
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-refresh-button-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

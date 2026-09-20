import Foundation
import Testing
import ChatOrchestration
import MacIntegration
import NativeAgentCore
import PersistenceCore
import TrustCenter
@testable import NativeAgentApp

@Suite @MainActor struct PageNavigationReplayTests {
    @Test func repeatedCatalogSearchRespectsLimitAfterAppMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = SwiftToolDispatcher(dataRoot: root)
        let dispatcher = AppChatToolDispatcher(inner: core, activeToolsStore: core.activeToolsStore,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root), enforceAutonomySecurity: false,
            macIntegrationPermissionStore: MacIntegrationPermissionStore(dataRoot: root), organismPostureProvider: { nil })
        _ = await core.activeToolsStore.beginTurn(sessionId: "limit")
        for index in 0..<3 {
            let result = try await dispatcher.dispatch(tool: "tool_catalog", input: [
                "query": .string("settings"), "limit": .int(1), "__session_id": .string("limit")
            ], surface: "chat")
            guard case .object(let fields) = result, case .array(let matches)? = fields["matches"] else {
                Issue.record("Missing catalog matches"); return
            }
            #expect(matches.count == 1)
            #expect(fields["shown"] == .int(1))
            #expect(fields["no_tools_loaded_since_previous_search"] == .bool(index > 0))
        }
    }

    @Test func navigationPreloadGroupCanBeLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = SwiftToolDispatcher(dataRoot: root)
        let dispatcher = AppChatToolDispatcher(inner: core, activeToolsStore: core.activeToolsStore,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root), enforceAutonomySecurity: false,
            macIntegrationPermissionStore: MacIntegrationPermissionStore(dataRoot: root), organismPostureProvider: { nil })
        let prediction = try #require(ToolPreloadHeuristics.predict(userMessage: "Open your Settings page"))
        let group = try #require(prediction.groups.first)
        let result = try await dispatcher.dispatch(tool: "tool_load", input: [
            "category": .string(group.group), "__session_id": .string("navigation")
        ], surface: "chat")
        guard case .object(let fields) = result, case .array(let loaded)? = fields["loaded"] else {
            Issue.record("Navigation preload category did not load"); return
        }
        #expect(loaded.contains(.string("interaction_act")))
    }

    @Test func readDoesNotShowSettingsButSetPageDoes() throws {
        let coordinator = NativeAgentAppCoordinator(notificationCenter: NotificationCenter(),
            windowActions: .init(activateApplication: {}, openMainWindow: {}))
        var page = "chat"
        let scene = coordinator.mountMainScene(currentPage: { QuietPages.page(named: page) }) {
            if case .sidebar(let item) = $0 { page = item.rawValue }
        }
        defer { coordinator.unmountMainScene(id: scene) }
        let result = AppChatToolDispatcher.pageReadResult(page: "settings", fields: ["status": .string("ok")])
        guard case .object(let fields) = result else { Issue.record("Expected read receipt"); return }
        #expect(fields["page_read"] == .bool(true))
        #expect(fields["page_shown_by_this_call"] == .bool(false))
        #expect(coordinator.currentPage?.id == "chat")
        guard case .string(let summary)? = fields["summary"] else { Issue.record("Missing read summary"); return }
        #expect(summary.contains("not opened or shown"))
        let outcome = QuietComposerVerbs.setPage("settings", coordinator: coordinator)
        #expect(outcome.refusal == nil)
        #expect(coordinator.currentPage?.id == "settings")
        #expect(outcome.detail == "The window is now showing settings.")
    }

    @Test func navigationDoesNotClaimAnUndeliveredPage() {
        let coordinator = NativeAgentAppCoordinator(notificationCenter: NotificationCenter(),
            windowActions: .init(activateApplication: {}, openMainWindow: {}))
        let scene = coordinator.mountMainScene(currentPage: { QuietPages.page(named: "chat") }) { _ in }
        defer { coordinator.unmountMainScene(id: scene) }
        #expect(QuietComposerVerbs.setPage("settings", coordinator: coordinator).refusal?.reason == "page_not_shown")
    }

    @Test func pageRequestsPreloadAndFindTheShowingTool() throws {
        let schemas = AppChatToolDispatcher.appToolSchemas()
        let read = try #require(schemas.first { $0.name == "app_page_read" })
        #expect(read.description.contains("does not open or show"))
        for page in QuietPages.ids {
            for verb in ["open", "show", "go to"] {
                let query = "\(verb) your \(page) page"
                #expect(ToolPreloadHeuristics.predict(userMessage: query)?.candidateTools.contains("interaction_act") == true)
            }
        }
        for query in ["open your settings page", "show settings", "go to settings"] {
            let ranked = schemas.map { schema in
                (schema.name, SwiftToolDispatcher.catalogSearchScore(name: schema.name,
                    description: schema.description, groups: [],
                    needles: SwiftToolDispatcher.catalogSearchNeedles(query), query: query))
            }.sorted { $0.1 > $1.1 }
            #expect(ranked.prefix(3).contains { $0.0 == "interaction_act" })
        }
    }
}

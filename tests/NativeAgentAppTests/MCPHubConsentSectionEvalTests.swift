import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.MCPHub.consentSection

@MainActor
@Suite("MCP Hub consent section")
struct MCPHubConsentSectionEvalTests {
    @Test("production consent actions preserve durable grant and revoke authority, pending rows, and an unavailable ledger")
    func consentSectionKeepsItsAuthorityAndAdverseStatesVisible() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedConsentTestServer(root: root, id: "calendar")
        let cache = root.appendingPathComponent("mcp/cache/tools.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "calendar": ["tools": [[
                "name": "calendar.create", "riskClass": "external",
                "description": "Create an event", "inputSchema": ["type": "object"],
            ]]],
        ]).write(to: cache)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let server = MCPServerRecord(
            id: "calendar",
            name: "Calendar",
            transport: "stdio",
            endpoint: nil,
            command: "/usr/bin/true",
            status: "ready",
            healthStatus: "ok",
            toolCount: 1,
            resourceCount: 0,
            riskClass: "external",
            updatedAt: nil
        )
        await app.grantMCPConsent(server: server, toolName: "calendar.create")
        let granted = try #require(app.mcpConsent.first)
        #expect(granted.id == "calendar:calendar.create")
        #expect(granted.status == "granted")
        #expect(app.statusText == "MCP consent granted (external)")
        #expect(MCPHubConsentPresentation.resolve(
            consentCount: app.mcpConsent.count,
            refresh: app.panelRefreshStatus[.mcp]
        ) == .available)

        await app.revokeMCPConsent(granted)
        let revoked = try #require(app.mcpConsent.first)
        #expect(revoked.status == "revoked")
        #expect(revoked.revokedAt?.isEmpty == false)
        let reloaded = try await NativeClient(baseURL: "", dataRootOverride: root).getMCPConsent()
        #expect(reloaded.first?.status == "revoked")
        #expect(app.statusText == "MCP consent revoked")
        #expect(MCPHubConsentPresentation.resolve(
            consentCount: app.mcpConsent.count,
            refresh: app.panelRefreshStatus[.mcp]
        ) == .available)

        let pending = MCPConsentRecord(
            id: "calendar:calendar.preview",
            serverId: "calendar",
            toolName: "calendar.preview",
            scope: "server_tool",
            risk: "external",
            status: "pending",
            argumentSummary: "Awaiting user confirmation",
            grantedAt: nil,
            revokedAt: nil,
            updatedAt: "2026-08-24T12:00:00Z"
        )
        app.mcpConsent = [pending]
        app.recordPanelRefresh(.mcp, failedEndpoints: [])
        #expect(app.mcpConsent == [pending])
        #expect(MCPHubConsentPresentation.resolve(
            consentCount: app.mcpConsent.count,
            refresh: app.panelRefreshStatus[.mcp]
        ) == .available)

        let unavailableRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: unavailableRoot) }
        let ledger = unavailableRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("consent", isDirectory: true)
            .appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(
            at: ledger.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not valid json".utf8).write(to: ledger)

        let unavailableApp = AppModel(dataRootOverride: unavailableRoot, startBackgroundTasks: false)
        await unavailableApp.refreshForSidebarItem(.mcp)
        #expect(unavailableApp.panelRefreshStatus[.mcp]?.failedEndpoints.contains("mcp consent") == true)
        #expect(MCPHubConsentPresentation.resolve(
            consentCount: unavailableApp.mcpConsent.count,
            refresh: unavailableApp.panelRefreshStatus[.mcp]
        ) == .unavailable)
    }

    @Test("consent presentation does not turn a failed empty read into no decisions")
    func consentPresentationKeepsReadStatesNonVacuous() {
        let clean = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(), lastSuccessAt: Date(), failedEndpoints: []
        )
        let failed = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(), lastSuccessAt: nil, failedEndpoints: ["mcp consent"]
        )
        #expect(MCPHubConsentPresentation.resolve(consentCount: 0, refresh: nil) == .loading)
        #expect(MCPHubConsentPresentation.resolve(consentCount: 0, refresh: clean) == .empty)
        #expect(MCPHubConsentPresentation.resolve(consentCount: 1, refresh: failed) == .stale)
        #expect(MCPHubConsentPresentation.resolve(consentCount: 0, refresh: failed) == .unavailable)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-hub-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}

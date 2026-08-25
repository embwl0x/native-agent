import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.MCPHub.serverWarmRestartRefresh

@MainActor
@Suite("app.settings · MCP Hub warm/restart refresh", .serialized)
struct MCPHubServerWarmRestartRefreshEvalTests {
    private let serverID = "mcp-hub-root-scoped"

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-hub-warm-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func seedNativeServer(root: URL) throws -> MCPServerRecord {
        let server: [String: Any] = [
            "id": serverID,
            "name": "Root-scoped native MCP",
            "transport": "native",
            "endpoint": "nativeagent://internal",
            "status": "ready",
            "healthStatus": "ok",
            "toolCount": 1,
            "resourceCount": 0,
            "riskClass": "app_data_read",
            "updatedAt": "2026-08-24T12:00:00Z",
        ]
        try writeJSON([server], to: root.appendingPathComponent("mcp/servers.json"))
        try writeJSON([
            serverID: [
                "createdAt": "2026-08-24T12:00:00Z",
                "tools": [[
                    "name": "fixture.root_scoped",
                    "description": "A cached descriptor owned by this injected root.",
                ]],
            ],
        ], to: root.appendingPathComponent("mcp/cache/tools.json"))
        return MCPServerRecord(
            id: serverID,
            name: "Root-scoped native MCP",
            transport: "native",
            endpoint: "nativeagent://internal",
            command: nil,
            status: "ready",
            healthStatus: "ok",
            toolCount: 1,
            resourceCount: 0,
            riskClass: "app_data_read",
            updatedAt: "2026-08-24T12:00:00Z"
        )
    }

    @Test("root-scoped warm/restart actions refresh the selected inventory and keep its actions available")
    func warmAndRestartUseTheInjectedRuntimeAndReloadDetails() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try seedNativeServer(root: root)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.mcpServers = [server]
        #expect(MCPHubCollectionPresentation.resolve(
            recordCount: app.mcpServers.count,
            endpoint: "mcp servers",
            refresh: app.panelRefreshStatus[.mcp]
        ) == .available)

        await app.warmMCPServer(server)
        #expect(app.selectedMCPServerId == serverID)
        #expect(app.mcpTools.map(\.name) == ["fixture.root_scoped"])
        if case .current = app.mcpResourceReadState {
            // The native server has no resource cache; that is an honest empty
            // result, distinct from an unavailable resource read.
        } else {
            Issue.record("Warm must refresh the selected server's resource state")
        }
        #expect(app.mcpSessions.contains { $0.serverId == serverID })
        let inventoryNotice = MCPHubInventoryPresentation.notice(
            state: app.mcpToolReadState,
            selectedServerName: app.selectedMCPServer?.name,
            toolCount: app.mcpTools.count
        )
        #expect(inventoryNotice.showsTools)
        #expect(app.statusText == "MCP warmed and details refreshed: Root-scoped native MCP")

        await app.restartMCPServer(server)
        #expect(app.mcpTools.map(\.name) == ["fixture.root_scoped"])
        if case .current = app.mcpResourceReadState {
            // Restart must replace the child and then reload the same mounted inventory.
        } else {
            Issue.record("Restart must not leave a pre-restart details state on screen")
        }
        #expect(app.mcpSessions.contains { $0.serverId == serverID })
        #expect(app.statusText == "MCP restarted and details refreshed: Root-scoped native MCP")

        let freshClient = NativeClient(baseURL: "", dataRootOverride: root)
        let freshRead = try await freshClient.getMCPTools(serverId: serverID)
        #expect(freshRead.tools.map(\.name) == ["fixture.root_scoped"])
    }
}

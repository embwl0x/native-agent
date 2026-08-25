import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.MCPHub.emptyStates

@MainActor
@Suite("MCP Hub empty-state authority")
struct MCPHubEmptyStatesEvalTests {
    @Test("each MCP Hub reader distinguishes completed emptiness from an unavailable read")
    func fiveSectionEmptyStatesRemainNonVacuous() throws {
        let complete = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(),
            lastSuccessAt: Date(),
            failedEndpoints: []
        )
        let failed = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(),
            lastSuccessAt: nil,
            failedEndpoints: ["mcp servers", "mcp consent"]
        )

        #expect(MCPHubCollectionPresentation.resolve(
            recordCount: 0, endpoint: "mcp servers", refresh: complete
        ) == .empty)
        #expect(MCPHubCollectionPresentation.resolve(
            recordCount: 0, endpoint: "mcp servers", refresh: failed
        ) == .unavailable)

        #expect(MCPHubInventoryPresentation.notice(
            state: .current, selectedServerName: "Calendar", toolCount: 0
        ).text == "This server exposes no tools.")
        #expect(MCPHubInventoryPresentation.notice(
            state: .unavailable("connection refused"), selectedServerName: "Calendar", toolCount: 0
        ).isFailure)

        #expect(MCPHubResourcesPresentation.notice(state: .current, resourceCount: 0)?.text == "No resources exposed by this server.")
        #expect(MCPHubResourcesPresentation.notice(
            state: .unavailable("connection refused"), resourceCount: 0
        )?.isFailure == true)

        #expect(MCPHubConsentPresentation.resolve(consentCount: 0, refresh: complete) == .empty)
        #expect(MCPHubConsentPresentation.resolve(consentCount: 0, refresh: failed) == .unavailable)

        let absentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-hub-empty-state-missing-\(UUID().uuidString)", isDirectory: true)
        guard case .absent = MCPHubDurableCallHistory.read(root: absentRoot) else {
            Issue.record("A missing Activity receipt must be an honest absent history state")
            return
        }

        let unavailableRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-hub-empty-state-unavailable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unavailableRoot) }
        let receiptPath = unavailableRoot.appendingPathComponent("activity/events.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptPath, withIntermediateDirectories: true)
        guard case .unavailable = MCPHubDurableCallHistory.read(root: unavailableRoot) else {
            Issue.record("An unreadable Activity receipt must not be presented as absent")
            return
        }
    }

    @Test("five MCP Hub readers project unavailable evidence instead of reassuring zeroes")
    func unavailableStatesRemainDistinctAcrossAllFiveReaders() throws {
        let failed = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(),
            lastSuccessAt: nil,
            failedEndpoints: ["mcp servers", "mcp consent"]
        )

        #expect(MCPHubCollectionPresentation.resolve(
            recordCount: 0, endpoint: "mcp servers", refresh: failed
        ) == .unavailable)

        let tools = MCPHubInventoryPresentation.notice(
            state: .unavailable("connection refused"), selectedServerName: "Calendar", toolCount: 0
        )
        #expect(tools.isFailure)
        #expect(!tools.showsTools)

        let resources = MCPHubResourcesPresentation.notice(
            state: .unavailable("connection refused"), resourceCount: 0
        )
        #expect(resources?.isFailure == true)

        #expect(MCPHubConsentPresentation.resolve(
            consentCount: 0, refresh: failed
        ) == .unavailable)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-hub-recent-call-unavailable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiptPath = root.appendingPathComponent("activity/events.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptPath, withIntermediateDirectories: true)
        guard case .unavailable = MCPHubDurableCallHistory.read(root: root) else {
            Issue.record("the Activity reader must project an unreadable receipt as unavailable")
            return
        }
    }
}

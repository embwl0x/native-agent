import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("app.settings · MCP Hub resources and recent call", .serialized)
struct MCPHubResourcesAndRecentCallEvalTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-hub-recent-call-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test @MainActor
    func freshMCPHubModelRestoresTheLatestDurableCallReceiptAndLabelsPartialHistory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("activity/events.jsonl")
        let projection = try MCPResultEvidence.project(.object(["answer": .string("durable MCP evidence")]))
        let receipt = MCPResultEvidence.activityReceipt(
            callID: "call-from-prior-session",
            receiptID: "receipt-from-prior-session",
            serverID: "research-server",
            toolName: "search",
            status: "ok",
            durationSeconds: 0.42,
            createdAt: "2026-08-24T12:00:00Z",
            projection: projection
        )
        let persisted = await MCPResultEvidence.persist(
            receipt,
            to: path,
            using: SwiftNativePersistenceCore()
        )
        #expect(persisted.status == "recorded")

        // Simulate a later damaged row. The reader preserves the valid latest
        // MCP receipt and exposes that history is partial instead of flattening
        // the ledger into "no call".
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let freshApp = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        #expect(freshApp.latestMCPCall?.id == nil)
        freshApp.refreshMCPHubRecentCall()
        guard case .partial(let restored?, let rejectedRows) = freshApp.mcpRecentCallState else {
            Issue.record("fresh MCP Hub did not surface the durable receipt")
            return
        }
        #expect(rejectedRows == 1)
        #expect(restored.id == "call-from-prior-session")
        #expect(restored.serverId == "research-server")
        #expect(restored.toolName == "search")
        #expect(restored.evidenceStatus == "recorded")
    }

    @Test
    func resourceEmptyStateNeverRepresentsAnUnavailableRead() {
        let unavailable = MCPHubResourcesPresentation.notice(
            state: .unavailable("connection refused"),
            resourceCount: 0
        )
        let empty = MCPHubResourcesPresentation.notice(state: .current, resourceCount: 0)

        #expect(unavailable?.isFailure == true)
        #expect(unavailable?.text.contains("unavailable") == true)
        #expect(empty?.isFailure == false)
        #expect(empty?.text == "No resources exposed by this server.")
    }
}

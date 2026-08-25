import Foundation
import NativeAgentShared
import Testing
import ToolExecution
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Tools approve button", .serialized)
struct ToolsApproveButtonEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-approve-button-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func tool(
        id: String,
        status: String,
        validationStatus: String?
    ) -> ToolRecord {
        ToolRecord(
            id: id,
            name: "Tool \(id)",
            description: "Authored tool approval evaluation.",
            triggers: ["eval"],
            language: nil,
            entrypoint: "tool.swift",
            permissions: ["app_data_read"],
            status: status,
            phase: status,
            autoCreated: true,
            autoPromote: false,
            autoRun: false,
            autoPromotable: true,
            validationStatus: validationStatus,
            validationErrors: [],
            proposalPath: nil,
            activePath: nil,
            quarantinePath: nil,
            quarantineReason: nil,
            sourceRunId: nil,
            createdAt: nil,
            updatedAt: nil,
            useCount: 0,
            lastUsedAt: nil
        )
    }

    private func seedValidProposal(root: URL, id: String) async throws {
        let execution = SwiftNativeToolExecution(root: root)
        _ = try await execution.createProposal(.object([
            "id": .string(id),
            "name": .string("Tool \(id)"),
            "description": .string("Authored tool approval evaluation."),
            "triggers": .array([.string("eval")]),
            "permissions": .array([.string("app_data_read")]),
        ]))
        let proposal = root.appendingPathComponent("tools/proposals/\(id)", isDirectory: true)
        try Data("print(\"{}\")\n".utf8).write(to: proposal.appendingPathComponent("tool.swift"))
        try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8).write(to: proposal.appendingPathComponent("tests.json"))
    }

    @Test("Approve eligibility, action receipt, and durable promotion outcome share one boundary")
    func approveButtonUsesTheRealPromotionBoundaryAndFailsClosedForTerminalRows() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = tool(id: "ready", status: "proposed", validationStatus: "valid")
        let quarantined = tool(id: "held", status: "quarantined", validationStatus: "valid")
        try await seedValidProposal(root: root, id: valid.id)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.tools = [valid, quarantined]
        let ready = ToolApprovalPresentation.control(for: valid)
        let held = ToolApprovalPresentation.control(for: quarantined)
        #expect(ready.accessibilityIdentifier == "tools.authored.approve.ready")
        #expect(ready.isEnabled)
        #expect(ready.refusal == nil)
        #expect(held.accessibilityIdentifier == "tools.authored.approve.held")
        #expect(!held.isEnabled)
        #expect(held.refusal == "Quarantined tools must be reviewed before they can be approved.")
        #expect(held.help == held.refusal)

        await app.promoteTool(valid)

        let reader = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let active = try #require(try await reader.getTools().first(where: { $0.id == valid.id }))
        #expect(active.status == "active")
        #expect(app.tools.first(where: { $0.id == valid.id })?.status == "active")
        #expect(app.statusText == "Tool activated")
        #expect(app.toolOperationStatusReceipts.first?.outcome == .succeeded)
        #expect(app.toolOperationStatusReceipts.first?.message == "Tool activated")

        await app.promoteTool(quarantined)
        #expect(app.statusText == "Tool activation unavailable: Quarantined tools must be reviewed before they can be approved.")
        #expect(app.toolOperationStatusReceipts.first?.outcome == .failed)
        #expect(try await reader.getTools().count == 1)
    }
}

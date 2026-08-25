import Foundation
import NativeAgentShared
import Testing
import ToolExecution
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Tools authored-tool actions", .serialized)
struct ToolsAuthoredToolActionsEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-authored-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func proposedTool(root: URL, id: String) async throws -> ToolRecord {
        let execution = SwiftNativeToolExecution(root: root)
        _ = try await execution.createProposal(.object([
            "id": .string(id),
            "name": .string("Authored \(id)"),
            "description": .string("A valid authored tool for the mounted action path."),
            "triggers": .array([.string("eval")]),
            "entrypoint": .string("tool.swift"),
            "permissions": .array([.string("app_data_read")]),
        ]))
        let proposalDirectory = root
            .appendingPathComponent("tools/proposals/\(id)", isDirectory: true)
        try Data("print(\"{}\")\n".utf8)
            .write(to: proposalDirectory.appendingPathComponent("tool.swift"))
        try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8)
            .write(to: proposalDirectory.appendingPathComponent("tests.json"))

        return ToolRecord(
            id: id,
            name: "Authored \(id)",
            description: "A valid authored tool for the mounted action path.",
            triggers: ["eval"],
            language: nil,
            entrypoint: "tool.swift",
            permissions: ["app_data_read"],
            status: "proposed",
            phase: "proposed",
            autoCreated: true,
            autoPromote: false,
            autoRun: false,
            autoPromotable: true,
            validationStatus: "valid",
            validationErrors: [],
            proposalPath: proposalDirectory.path,
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

    @Test("approval and auto-run actions mutate and re-read only the injected registry")
    func approvalAndAutoRunActionsPersistThroughTheInjectedRoot() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposed = try await proposedTool(root: root, id: "authored-eval")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.tools = [proposed]
        let proposalActions = AuthoredToolPresentation.actionCatalog(for: proposed)
        let approve = try #require(proposalActions.first(where: { $0.action == .approve }))
        #expect(approve.isEnabled)
        #expect(approve.accessibilityIdentifier == "tools.authored.approve.\(proposed.id)")
        #expect(proposalActions.first(where: { $0.action == .autoRun })?.isEnabled == false)

        await app.promoteTool(proposed, userRequested: true)

        let reader = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let persistedActive = try #require(try await reader.getTools().first(where: { $0.id == proposed.id }))
        #expect(persistedActive.status == "active")
        #expect(persistedActive.validationStatus == "valid")
        #expect(app.tools.first(where: { $0.id == proposed.id })?.status == "active")
        #expect(app.statusText == "Tool activated")
        #expect(app.toolOperationStatusReceipts.first?.outcome == .succeeded)
        #expect(app.toolOperationStatusReceipts.first?.message == "Tool activated")
        let activePath = try #require(persistedActive.activePath)
        #expect(activePath == root.appendingPathComponent("tools/active/\(proposed.id)").path)
        #expect(FileManager.default.fileExists(atPath: activePath))

        let active = try #require(app.tools.first(where: { $0.id == proposed.id }))
        let activeActions = AuthoredToolPresentation.actionCatalog(for: active)
        #expect(activeActions.first(where: { $0.action == .autoRun })
            == .init(action: .autoRun, title: "Enable Auto-run", isEnabled: true,
                    accessibilityIdentifier: nil,
                    help: "Change whether this active tool may run automatically.", refusal: nil))
        await app.setToolAutoRun(active, autoRun: true)

        let autoRun = try #require(try await reader.getTools().first(where: { $0.id == proposed.id }))
        #expect(autoRun.autoRun == true)
        #expect(app.tools.first(where: { $0.id == proposed.id })?.autoRun == true)
        #expect(app.statusText == "Tool auto-run enabled")
        #expect(app.toolOperationStatusReceipts.first?.outcome == .succeeded)
        #expect(AuthoredToolPresentation.actionCatalog(for: autoRun)
            .first(where: { $0.action == .autoRun })?.title == "Disable Auto-run")
    }

    @Test("quarantine action confirms the post-write registry state and malformed authority stays visibly adverse")
    func quarantineAndMalformedRegistryRemainHonestAtTheToolsBoundary() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposed = try await proposedTool(root: root, id: "quarantine-eval")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.tools = [proposed]
        await app.promoteTool(proposed, userRequested: true)

        let active = try #require(app.tools.first(where: { $0.id == proposed.id }))
        #expect(AuthoredToolPresentation.actionCatalog(for: active)
            .first(where: { $0.action == .quarantine })?.isEnabled == true)
        await app.quarantineTool(active)

        let reader = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let quarantined = try #require(try await reader.getTools().first(where: { $0.id == proposed.id }))
        #expect(quarantined.status == "quarantined")
        #expect(app.tools.first(where: { $0.id == proposed.id })?.status == "quarantined")
        #expect(app.statusText == "Tool quarantined")
        #expect(app.toolOperationStatusReceipts.first?.outcome == .succeeded)
        let quarantinePath = try #require(quarantined.quarantinePath)
        #expect(quarantinePath == root.appendingPathComponent("tools/quarantine/\(proposed.id)").path)
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: quarantinePath).appendingPathComponent("tool.swift").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("tools/active/\(proposed.id)/tool.swift").path
        ), "quarantine retains the signed active artifact while removing the row from the active registry")
        #expect(try await reader.getTools().filter { $0.status == "active" }.isEmpty)

        let registry = root.appendingPathComponent("tools/registry.json")
        let malformed = Data("{ broken registry".utf8)
        try malformed.write(to: registry, options: .atomic)
        app.tools = [ToolRecord(
            id: proposed.id,
            name: proposed.name,
            description: proposed.description,
            triggers: proposed.triggers,
            language: nil,
            entrypoint: proposed.entrypoint,
            permissions: proposed.permissions,
            status: "active",
            phase: "active",
            autoCreated: proposed.autoCreated,
            autoPromote: false,
            autoRun: false,
            autoPromotable: true,
            validationStatus: "valid",
            validationErrors: [],
            proposalPath: nil,
            activePath: root.appendingPathComponent("tools/active/\(proposed.id)").path,
            quarantinePath: nil,
            quarantineReason: nil,
            sourceRunId: nil,
            createdAt: nil,
            updatedAt: nil,
            useCount: 0,
            lastUsedAt: nil
        )]
        let staleActive = try #require(app.tools.first(where: { $0.id == proposed.id }))
        #expect(AuthoredToolPresentation.actionCatalog(for: staleActive)
            .first(where: { $0.action == .autoRun })?.isEnabled == true)
        await app.setToolAutoRun(staleActive, autoRun: true)

        #expect(app.statusText.hasPrefix("Tool update failed:"))
        #expect(app.toolOperationStatusReceipts.first?.outcome == .failed)
        #expect(app.toolOperationStatusReceipts.first?.message.hasPrefix("Tool update failed:") == true)
        #expect(try Data(contentsOf: registry) == malformed)
    }
}

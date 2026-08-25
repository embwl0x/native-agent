import Foundation
import NativeAgentShared
import Testing
import ToolExecution
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.toolStatusBadge

@Suite("app.settings · Tools tool-status badge")
struct ToolsToolStatusBadgeBehaviorEvalTests {
    @Test("live dispatcher availability, autonomy, and load receipts render their matching badge")
    func runtimeCatalogReceiptsRemainDistinctAtTheBadgeOwner() {
        let catalog = snapshot(
            tools: [
                tool("locked", availableNow: false, autonomy: "blocked", loadState: "loaded"),
                tool("offline", availableNow: false, autonomy: "auto", loadState: "loaded"),
                tool("blocked", availableNow: true, autonomy: "blocked", loadState: "loaded"),
                tool("approval", availableNow: true, autonomy: "confirm", loadState: "discovery_only"),
                tool("active", availableNow: true, autonomy: "auto", loadState: "loaded"),
                tool("on-demand", availableNow: true, autonomy: "auto", loadState: "discovery_only"),
                tool("available", availableNow: true, autonomy: "auto"),
            ],
            policyLocked: ["LOCKED"]
        )

        #expect(badges(in: catalog) == [
            ChatToolCatalogPresentation.ToolStatusBadge(title: "policy-locked", systemImage: "lock", tone: .warning),
            ChatToolCatalogPresentation.ToolStatusBadge(title: "unavailable", systemImage: "minus.circle", tone: .neutral),
            ChatToolCatalogPresentation.ToolStatusBadge(title: "blocked", systemImage: "hand.raised", tone: .danger),
            ChatToolCatalogPresentation.ToolStatusBadge(title: "approval", systemImage: "checkmark.shield", tone: .warning),
            ChatToolCatalogPresentation.ToolStatusBadge(title: "active", systemImage: "circle.fill", tone: .positive),
            ChatToolCatalogPresentation.ToolStatusBadge(title: "on demand", systemImage: "bolt.circle", tone: .neutral),
            ChatToolCatalogPresentation.ToolStatusBadge(title: "available", systemImage: "checkmark.circle", tone: .neutral),
        ])
    }

    @Test("missing or malformed authority never falls through to an available badge")
    func adverseOrIncompleteCatalogEvidenceStaysExplicitlyUnavailable() {
        let catalog = snapshot(tools: [
            tool("missing-availability", availableNow: nil, autonomy: "auto", loadState: "loaded"),
            tool("unknown-autonomy", availableNow: true, autonomy: "surprise", loadState: "loaded"),
            tool("unknown-load-state", availableNow: true, autonomy: "auto", loadState: "mystery"),
            tool("loaded-by-list", availableNow: true, autonomy: "auto"),
        ], currentlyLoaded: ["LOADED-BY-LIST"])

        let rendered = badges(in: catalog)
        #expect(rendered.prefix(3).allSatisfy { $0.title == "status unavailable" })
        #expect(rendered.prefix(3).allSatisfy { $0.systemImage == "questionmark.circle" })
        #expect(rendered.prefix(3).allSatisfy { $0.tone == .warning })
        #expect(rendered[3] == ChatToolCatalogPresentation.ToolStatusBadge(
            title: "active", systemImage: "circle.fill", tone: .positive
        ))
        #expect(rendered.prefix(3).allSatisfy { $0.title != "available" })
    }

    @Test("durable authored-tool registry rows retain their lifecycle badge through promotion and quarantine")
    @MainActor
    func durableRegistryRowsUseTheSharedAuthoredStatusBadge() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "durable-badge"
        let execution = SwiftNativeToolExecution(root: root)
        _ = try await execution.createProposal(.object([
            "id": .string(id),
            "name": .string("Durable Badge"),
            "description": .string("Exercises durable authored-tool badge states."),
            "triggers": .array([.string("eval")]),
            "entrypoint": .string("tool.swift"),
            "permissions": .array([.string("app_data_read")]),
        ]))
        let proposalDirectory = root.appendingPathComponent("tools/proposals/\(id)", isDirectory: true)
        try Data("print(\"{}\")\n".utf8).write(to: proposalDirectory.appendingPathComponent("tool.swift"))
        try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8)
            .write(to: proposalDirectory.appendingPathComponent("tests.json"))

        let promotable = ToolRecord(
            id: id,
            name: "Durable Badge",
            description: "Exercises durable authored-tool badge states.",
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
        #expect(AuthoredToolPresentation.statusBadge(for: promotable)
            == .init(title: "proposed", systemImage: "clock", tone: .warning))

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.tools = [promotable]
        await app.promoteTool(promotable)
        let reader = NativeClient(baseURL: "", dataRootOverride: root)
        let active = try #require(try await reader.getTools().first(where: { $0.id == id }))
        #expect(AuthoredToolPresentation.statusBadge(for: active)
            == .init(title: "active", systemImage: "circle.fill", tone: .positive))
        let activePath = try #require(active.activePath)
        #expect(activePath == root.appendingPathComponent("tools/active/\(id)").path)

        await app.quarantineTool(active)
        let quarantined = try #require(try await reader.getTools().first(where: { $0.id == id }))
        #expect(AuthoredToolPresentation.statusBadge(for: quarantined)
            == .init(title: "quarantined", systemImage: "exclamationmark.triangle", tone: .danger))
        let quarantinePath = try #require(quarantined.quarantinePath)
        #expect(quarantinePath == root.appendingPathComponent("tools/quarantine/\(id)").path)
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: quarantinePath).appendingPathComponent("manifest.json").path
        ))
    }

    private func badges(in catalog: ChatToolCatalogSnapshot) -> [ChatToolCatalogPresentation.ToolStatusBadge] {
        catalog.tools.map { ChatToolCatalogPresentation.toolStatusBadge(for: $0, in: catalog) }
    }

    private func snapshot(
        tools: [ChatCatalogTool],
        currentlyLoaded: Set<String> = [],
        policyLocked: [String] = []
    ) -> ChatToolCatalogSnapshot {
        ChatToolCatalogSnapshot(
            tools: tools,
            currentlyLoaded: currentlyLoaded,
            builderAvailable: [],
            builderPolicyLocked: policyLocked,
            macAppAvailable: [],
            macAppPolicyLocked: [],
            fullMacActive: false,
            fileOpsAllowed: true,
            systemAllowed: true,
            appControlAllowed: true,
            builderModeDetail: "",
            permissionLevel: "confirm"
        )
    }

    private func tool(
        _ name: String,
        availableNow: Bool?,
        autonomy: String?,
        loadState: String? = nil
    ) -> ChatCatalogTool {
        ChatCatalogTool(
            name: name,
            description: "Tool status badge eval",
            parametersPreview: nil,
            dispatchableVia: "nativeagent_app_tool_dispatcher",
            loadState: loadState,
            effectiveAutonomy: autonomy,
            availableNow: availableNow
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-status-badge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

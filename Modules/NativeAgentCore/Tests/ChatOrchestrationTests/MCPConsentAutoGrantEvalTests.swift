import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MCPDispatcher

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger row: chat.tools.dispatch.mcpRoute  (silent consent widening)
//
// When no consent row matches, the dispatch path AUTO-GRANTS one for anything
// `MCPToolBridge.riskRequiresApproval` calls low. The approval decision
// therefore rests entirely on a risk classifier the dispatch path never
// re-checks — and the human sees an ALREADY-GRANTED row afterwards, which reads
// like they approved it. Nothing in ChatOrchestrationTests dispatched an
// `mcp__*` name at all before this file.
//
// The teeth: the approval-gated cases must leave the consent ledger EMPTY.
// A throw alone is not enough — a throw that still wrote a row would grant
// standing permission for every later call.
// ─────────────────────────────────────────────────────────────────────────────

private struct MCPConsentEvalRoot {
    let dataRoot: URL

    /// Three servers, one per classification the gate has to separate:
    ///   • readserver  — explicit read tier on both server and tool → auto-grant
    ///   • writeserver — a write class → approval required
    ///   • norisk      — read-tier server, but the TOOL row carries no risk
    ///                   class, which resolves to `approval_gated_missing_tool_risk`
    ///                   (fail-closed) rather than inheriting the server's tier
    static func make() throws -> MCPConsentEvalRoot {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPConsentEval-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let mcpRoot = dataRoot.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mcpRoot.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        let servers = """
        [
          {"id": "readserver", "name": "read", "transport": "http", "endpoint": "http://127.0.0.1:1",
           "status": "ready", "riskClass": "app_data_read"},
          {"id": "writeserver", "name": "write", "transport": "http", "endpoint": "http://127.0.0.1:1",
           "status": "ready", "riskClass": "app_write"},
          {"id": "norisk", "name": "norisk", "transport": "http", "endpoint": "http://127.0.0.1:1",
           "status": "ready", "riskClass": "app_data_read"}
        ]
        """
        try Data(servers.utf8).write(to: mcpRoot.appendingPathComponent("servers.json"))
        let cache = """
        {
          "readserver":  {"tools": [{"name": "peek", "risk_class": "app_data_read"}]},
          "writeserver": {"tools": [{"name": "poke", "risk_class": "app_write"}]},
          "norisk":      {"tools": [{"name": "mystery"}]}
        }
        """
        try Data(cache.utf8).write(
            to: mcpRoot.appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("tools.json")
        )
        return MCPConsentEvalRoot(dataRoot: dataRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent())
    }

    func consents() async -> [MCPConsent] {
        (try? await SwiftNativeMCPDispatcher(root: dataRoot).listConsents()) ?? []
    }

    func enableFullMacYolo() throws {
        let trustRoot = dataRoot.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustRoot, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        ])
        try policy.serializedData(pretty: true)
            .write(to: trustRoot.appendingPathComponent("policy.json"))
    }
}

/// Approval-gated risk classes must refuse AND leave no consent behind. This is
/// the half that matters: a refusal that still stamps a row hands the model
/// standing permission it never had, and the human sees a granted row they
/// never granted.
@Test func mcpDispatch_approvalGatedRisksRefuseWithoutWritingConsent() async throws {
    let root = try MCPConsentEvalRoot.make()
    defer { root.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: root.dataRoot)

    #expect(await root.consents().isEmpty, "the fixture must start with no consent rows")

    for (server, tool, why) in [
        ("writeserver", "poke", "a write class must never auto-grant"),
        ("norisk", "mystery", "a MISSING tool risk class must fail closed, not inherit the server's read tier"),
    ] {
        await #expect(throws: (any Error).self, "\(server)/\(tool): \(why)") {
            _ = try await dispatcher.impl_mcp_tool(
                serverId: server, toolName: tool, input: ["q": .string("x")], surface: "chat"
            )
        }
        let rows = await root.consents()
        #expect(
            rows.allSatisfy { $0.serverId != server },
            "\(server)/\(tool) wrote a consent row while refusing — that is standing permission nobody granted: \(rows.map { "\($0.serverId)/\($0.toolName)" })"
        )
    }

    // Independent read of the classifier the dispatch path trusts, so a
    // regression that loosens `riskRequiresApproval` is named here too rather
    // than only showing up as a missing throw.
    #expect(MCPToolBridge.riskRequiresApproval("app_write"))
    #expect(MCPToolBridge.riskRequiresApproval("approval_gated_missing_tool_risk"))
    #expect(MCPToolBridge.riskRequiresApproval("something_nobody_has_classified"))
    #expect(!MCPToolBridge.riskRequiresApproval("app_data_read"))
}

/// The auto-grant side. A read-tier tool DOES earn a stored consent on first
/// model call — that is the designed behaviour — but it must earn EXACTLY ONE,
/// for exactly that server/tool, stamped with the effective risk that justified
/// it. (The live call itself then fails against the unreachable fixture
/// endpoint; the consent write happens first and is what this eval reads.)
@Test func mcpDispatch_readTierAutoGrantsExactlyOneScopedConsentRow() async throws {
    let root = try MCPConsentEvalRoot.make()
    defer { root.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: root.dataRoot)

    _ = try? await dispatcher.impl_mcp_tool(
        serverId: "readserver", toolName: "peek", input: ["q": .string("x")], surface: "chat"
    )

    let rows = await root.consents()
    let granted = rows.filter { $0.serverId == "readserver" && $0.toolName == "peek" }
    #expect(granted.count == 1, "a read-tier call must auto-grant exactly one row, got \(granted.count)")
    #expect(
        rows.count == granted.count,
        "the auto-grant must be scoped to the tool that was called, not the server: \(rows.map { "\($0.serverId)/\($0.toolName)" })"
    )
    if let row = granted.first {
        #expect(row.status.lowercased() == "granted")
        #expect(
            MCPToolBridge.consent(row, matchesCurrentEffectiveRisk: "app_data_read"),
            "the stored consent must be pinned to the risk that justified it, so a later risk INCREASE re-prompts"
        )
        #expect(
            !MCPToolBridge.consent(row, matchesCurrentEffectiveRisk: "app_write"),
            "a read-tier consent must not satisfy a write-tier call — that would be silent escalation"
        )
    }
}

@Test func mcpDispatch_fullMacYoloRunsApprovalRiskWithoutPersistingStandingConsent() async throws {
    let root = try MCPConsentEvalRoot.make()
    defer { root.cleanup() }
    try root.enableFullMacYolo()
    let dispatcher = SwiftToolDispatcher(dataRoot: root.dataRoot)

    do {
        _ = try await dispatcher.impl_mcp_tool(
            serverId: "writeserver",
            toolName: "poke",
            input: ["q": .string("x")],
            surface: "chat"
        )
        Issue.record("the unreachable MCP fixture should fail at transport")
    } catch is AutonomyGateError {
        Issue.record("admitted Full Mac YOLO must reach MCP transport instead of asking for approval")
    } catch {
        // Expected: the fixture endpoint is deliberately unreachable. Reaching
        // that boundary proves the approval prompt was bypassed.
    }

    #expect(await root.consents().isEmpty, "YOLO is per-call authority, not a standing MCP consent grant")
}

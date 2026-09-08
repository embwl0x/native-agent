import Foundation
import Testing
import MCPDispatcher
import NativeAgentCore
import TrustCenter
import ApprovalInbox
import ChatOrchestration
@testable import NativeAgentApp

// da1ddc63 binds consent to a registered, resolvable execution identity.
func seedConsentTestServer(root: URL, id: String, risk: String = "external") throws {
    let registry = root.appendingPathComponent("mcp/servers.json")
    try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
    let row: [String: Any] = [
        "id": id, "name": id, "transport": "stdio", "endpoint": "", "command": "/usr/bin/true",
        "status": "ready", "healthStatus": "ok", "toolCount": 1, "resourceCount": 0,
        "riskClass": risk, "createdAt": "2026-05-01T00:00:00Z", "updatedAt": "2026-05-01T00:00:00Z",
    ]
    try JSONSerialization.data(withJSONObject: [row]).write(to: registry)
}

/// Coverage-ledger fence `app.settings` — the MCP Hub / Capabilities consent
/// surface.
///
/// Rows closed here (docs/evals/ledger.json):
///   * `store.mcp.consentLedger`            (REPORTS-ONLY → state-lifecycle leak + UNMEASURED)
///   * `ui.MCPHub.grantConsentButton`       (UNCOVERED)
///   * `ui.MCPHub.revokeConsentButton`      (UNCOVERED)
///   * `setting.capabilitiesShowMCPBuilder` (UNCOVERED → duplicate mutation surface)
///
/// `data/mcp/consent/ledger.json` is a standing grant for an EXTERNAL server to
/// run a tool. Two separate UIs write it and nothing read it back. The
/// state-lifecycle question — "does a grant survive its revoke?" — is answered
/// here against the real dispatcher over a throwaway root.
@Suite("app.settings · MCP consent ledger lifecycle")
struct MCPConsentLedgerLifecycleEvalTests {
    @Test(arguments: ["existing", "legacy", "auto-granted"])
    func uiRefusesUnpinnedConsentBeforeDispatch(_ scenario: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("server-started")
        let script = root.appendingPathComponent("server.sh")
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        let registry = root.appendingPathComponent("mcp/servers.json")
        var servers = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [[String: Any]]
        // An env option prevents the dispatcher from pinning the implementation.
        servers[0]["command"] = "/usr/bin/env -i /bin/sh '\(script.path)'"
        servers[0]["riskClass"] = "network_read"
        try JSONSerialization.data(withJSONObject: servers).write(to: registry)
        let cache = root.appendingPathComponent("mcp/cache/tools.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"srv-ext":{"tools":[{"name":"read_status","riskClass":"network_read"}]}}"#.utf8).write(to: cache)
        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        let ledger = root.appendingPathComponent("mcp/consent/ledger.json")
        if scenario != "auto-granted" {
            let grant = try await dispatcher.grantConsent(MCPConsentGrant(
                serverId: "srv-ext", toolName: "read_status", risk: "network_read"
            ))
            #expect(grant.unpinned)
            if scenario == "legacy" {
                var rows = try ledgerRows(root: root)
                rows[0].removeValue(forKey: "unpinned")
                try JSONSerialization.data(withJSONObject: rows).write(to: ledger)
            }
        }
        let previousLedger = try? Data(contentsOf: ledger)
        let expectedReason = scenario == "auto-granted"
            ? "MCP server 'srv-ext' could not be pinned; resolve its implementation and explicitly grant consent again"
            : "MCP tool 'srv-ext/read_status' has unpinned consent; resolve/pin its implementation and explicitly grant consent again"
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        await #expect(throws: AutonomyGateError.toolDenied(reason: expectedReason)) {
            _ = try await client.callMCPTool(serverId: "srv-ext", toolName: "read_status", input: [:])
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        if let previousLedger {
            #expect(try Data(contentsOf: ledger) == previousLedger)
        }
    }

    @Test func confirmFilesApprovalAndReplaysExactMCPCallOnce() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server.swift")
        try #"""
        import Foundation
        let calls = URL(fileURLWithPath: CommandLine.arguments[1])
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard let id = request["id"] else { continue }
            let result: [String: Any]
            switch request["method"] as? String {
            case "initialize":
                result = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "fixture", "version": "1"]]
            case "tools/list":
                result = ["tools": [["name": "send_message", "description": "Fixture", "inputSchema": ["type": "object", "properties": ["body": ["type": "string"]]]]]]
            case "tools/call":
                var data = (try? Data(contentsOf: calls)) ?? Data()
                data.append(try JSONSerialization.data(withJSONObject: request["params"]!))
                data.append(10)
                try data.write(to: calls)
                result = ["content": [["type": "text", "text": "sent"]], "isError": false]
            default: result = [:]
            }
            var bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            bytes.append(10)
            FileHandle.standardOutput.write(bytes)
        }
        """#.write(to: script, atomically: true, encoding: .utf8)
        let calls = root.appendingPathComponent("calls.jsonl")
        let registry = root.appendingPathComponent("mcp/servers.json")
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [[String: Any]]
        rows[0]["command"] = "/usr/bin/swift '\(script.path)' '\(calls.path)'"
        try JSONSerialization.data(withJSONObject: rows).write(to: registry)
        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        _ = try await dispatcher.listToolsLive(forServer: "srv-ext", cached: false)
        let risk = MCPToolBridge.effectiveRiskClass(serverId: "srv-ext", toolName: "send_message", serverRiskClass: "external", dataRoot: root)
        _ = try await dispatcher.grantConsent(MCPConsentGrant(serverId: "srv-ext", toolName: "send_message", risk: risk))
        let trust = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        try Data(#"{"permissionLevel":"app_only","toolAutonomy":{"mcp__srv-ext__send_message":"confirm"}}"#.utf8).write(to: trust.appendingPathComponent("policy.json"))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let result = try await client.callMCPTool(serverId: "srv-ext", toolName: "send_message", input: ["body": "approved body"])
        #expect(result.status == "needs_approval")
        let id = try #require(result.approvalId)
        #expect(!FileManager.default.fileExists(atPath: calls.path))
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.get(id)
        #expect(pending.status == "pending")
        let resolved = try await inbox.resolve(id, decision: .approved, decidedBy: "test")
        await NativeClient.applyResolvedChatToolApproval(from: resolved, dataRoot: root)
        let annotated = try await inbox.get(id)
        await NativeClient.applyResolvedChatToolApproval(from: annotated, dataRoot: root)
        await dispatcher.stopSubprocess(serverId: "srv-ext")
        try #require(FileManager.default.fileExists(atPath: calls.path), "Replay receipt: \(String(describing: annotated.executedAction)); \(annotated.detail ?? "")")
        let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let call = try JSONSerialization.jsonObject(with: Data(try #require(lines.first).utf8)) as! [String: Any]
        #expect(call["name"] as? String == "send_message")
        #expect(call["arguments"] as? [String: String] == ["body": "approved body"])
    }

    @Test(arguments: ["allow", "ask", "block"])
    func uiAdmissionRecordsCanonicalSecurityEnvelope(_ decision: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        let policy: [String: Any] = [
            "permissionLevel": decision == "allow" ? "full_mac_os" : "app_only",
            "fullMacNeverExpires": true, "fullMacExpiresAt": "never",
            "toolAutonomy": ["mcp__srv-ext__send_message": decision == "block" ? "blocked" : "confirm"],
        ]
        try JSONSerialization.data(withJSONObject: policy).write(to: trust.appendingPathComponent("policy.json"))
        let envelope = await NativeClient.evaluateMCPUIAdmission(serverId: "srv-ext", toolName: "send_message", arguments: ["body": .string("hello")], dataRoot: root)
        #expect(envelope.decision.rawValue == decision)
        let lines = try String(contentsOf: root.appendingPathComponent("security/audit.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let recorded = try JSONSerialization.jsonObject(with: Data(try #require(lines.first).utf8)) as! [String: Any]
        #expect(recorded["id"] as? String == envelope.id)
        #expect(recorded["tool"] as? String == envelope.tool)
        #expect(recorded["surface"] as? String == "mcp_ui")
        #expect(recorded["decision"] as? String == decision)
        #expect(recorded["allowed"] as? Bool == envelope.allowed)
        #expect(recorded["requires_approval"] as? Bool == envelope.requiresApproval)
        #expect(recorded["reasons"] as? [String] == envelope.reasons)
        #expect(recorded["input_preview"] as? [String: String] == ["body": "hello"])
        #expect(recorded["origin"] as? [String: String] == ["surface": "mcp_ui"])
    }

    @Test(arguments: ["kill", "block", "corrupt", "secret", "ask", "allow"])
    func consentNeverBypassesFreshSecurityAdmission(_ scenario: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = "send_message"
        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        let risk = MCPToolBridge.effectiveRiskClass(
            serverId: "srv-ext", toolName: tool, serverRiskClass: "external", dataRoot: root
        )
        _ = try await dispatcher.grantConsent(MCPConsentGrant(serverId: "srv-ext", toolName: tool, risk: risk))
        let consents = try await dispatcher.listConsents()
        #expect(consents.contains { MCPToolBridge.consent($0, matchesCurrentEffectiveRisk: risk) })
        let trust = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        let policy: [String: Any] = [
            "permissionLevel": scenario == "ask" ? "app_only" : "full_mac_os",
            "fullMacNeverExpires": true, "fullMacExpiresAt": "never",
            "toolAutonomy": ["mcp__srv-ext__send_message": scenario == "block" ? "blocked" : "confirm"],
            "securityPolicy": ["killSwitchEnabled": scenario == "kill"],
        ]
        let bytes = scenario == "corrupt" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: policy)
        let path = trust.appendingPathComponent("policy.json")
        try bytes.write(to: path)
        let body = scenario == "secret" ? "sk-test-secret-secret-secret-secret" : "hello"
        let envelope = await NativeClient.evaluateMCPUIAdmission(
            serverId: "srv-ext", toolName: tool, arguments: ["body": .string(body)], dataRoot: root
        )
        #expect(envelope.tool == "mcp__srv-ext__send_message")
        #expect(envelope.surface == "mcp_ui")
        #expect(envelope.decision == (scenario == "allow" ? .allow : scenario == "ask" ? .ask : .block))
        if scenario != "allow" {
            // /usr/bin/true cannot speak MCP: reaching live dispatch would throw.
            let result = try await NativeClient(baseURL: "", dataRootOverride: root).callMCPTool(
                serverId: "srv-ext", toolName: tool, input: ["body": body]
            )
            #expect(result.status == (scenario == "ask" ? "needs_approval" : "blocked"))
        }
        if scenario == "corrupt" { #expect(try Data(contentsOf: path) == bytes) }
    }


    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-consent-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedConsentTestServer(root: dir, id: "srv-ext")
        return dir
    }

    private func ledgerRows(root: URL) throws -> [[String: Any]] {
        let url = root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("consent", isDirectory: true)
            .appendingPathComponent("ledger.json")
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Revoke must actually withdraw authority. The ledger keeps the row (a
    /// revoked grant is audit history, not a hole in the record) but the gate
    /// the app's `callMCPTool` consults must flip to false. The leak this
    /// bites: a revoke that only repaints the UI row while the execution gate
    /// keeps matching on (serverId, toolName) and lets the tool run forever.
    @Test func revokeWithdrawsAuthorityWhileKeepingTheRowAsAuditHistory() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftNativeMCPDispatcher(root: root)

        _ = try await dispatcher.grantConsent(MCPConsentGrant(
            serverId: "srv-ext", toolName: "tool.write", risk: "external"
        ))

        let granted = try await dispatcher.listConsents()
        #expect(granted.count == 1)
        #expect(granted[0].id == "srv-ext:tool.write")
        #expect(granted[0].status == "granted")
        #expect(MCPToolBridge.consent(granted[0], matchesCurrentEffectiveRisk: "external") == true,
                "a fresh grant must authorize the tool at the risk it was granted for")

        try await dispatcher.revokeConsent(serverId: "srv-ext", toolName: "tool.write")

        let after = try await dispatcher.listConsents()
        #expect(after.count == 1, "the revoked grant stays in the ledger as audit history")
        #expect(after[0].status == "revoked")
        #expect(after[0].revokedAt?.isEmpty == false, "a revoke must stamp WHEN")
        #expect(MCPToolBridge.consent(after[0], matchesCurrentEffectiveRisk: "external") == false,
                "LEAK: a revoked grant must not authorize execution")

        // The on-disk row is the same row, mutated — not a duplicate.
        let rows = try ledgerRows(root: root)
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as? String == "srv-ext:tool.write")
        #expect(rows[0]["status"] as? String == "revoked")
    }

    /// Re-granting after a revoke must reuse the one row for the key. A second
    /// row for the same `(server, tool)` is not just untidy — the ledger reader
    /// FAILS CLOSED on duplicates, so a duplicating grant path would brick
    /// every subsequent consent read.
    @Test func regrantAfterRevokeReusesTheSingleRowRatherThanAppendingADuplicate() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftNativeMCPDispatcher(root: root)

        _ = try await dispatcher.grantConsent(MCPConsentGrant(
            serverId: "srv-ext", toolName: "tool.write", risk: "external"
        ))
        try await dispatcher.revokeConsent(serverId: "srv-ext", toolName: "tool.write")
        _ = try await dispatcher.grantConsent(MCPConsentGrant(
            serverId: "srv-ext", toolName: "tool.write", risk: "external"
        ))

        let rows = try ledgerRows(root: root)
        #expect(rows.count == 1, "exactly one row per (server, tool) — the reader rejects duplicates")
        #expect(rows[0]["status"] as? String == "granted")
        // The wire shape always carries the key; `null` is the cleared form.
        #expect(rows[0]["revokedAt"] is NSNull || rows[0]["revokedAt"] == nil,
                "a re-grant must clear the stale revocation stamp on the wire")

        let listed = try await dispatcher.listConsents()
        #expect(listed.count == 1)
        #expect(listed[0].revokedAt == nil, "a re-grant must clear the stale revocation stamp")
        #expect(listed[0].status == "granted")
        #expect(MCPToolBridge.consent(listed[0], matchesCurrentEffectiveRisk: "external") == true)
    }

    /// A standing grant is scoped to the risk class it was granted AT. If the
    /// tool's effective risk later escalates (a server reclassified from
    /// `network_read` to `external`, or a tool descriptor gaining a risk),
    /// the old grant must STOP authorizing it. Silent failure otherwise: a
    /// consent the user gave for a read tool silently covers a write tool
    /// after a server config change.
    @Test func aStandingGrantDoesNotSurviveARiskEscalation() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftNativeMCPDispatcher(root: root)

        _ = try await dispatcher.grantConsent(MCPConsentGrant(
            serverId: "srv-ext", toolName: "tool.read", risk: "network_read"
        ))
        let consent = try #require(try await dispatcher.listConsents().first)

        #expect(MCPToolBridge.consent(consent, matchesCurrentEffectiveRisk: "network_read") == true)
        #expect(MCPToolBridge.consent(consent, matchesCurrentEffectiveRisk: "external") == false,
                "an escalated tool must re-prompt, not ride the old grant")

        // And the escalated class is one that genuinely needs approval, so the
        // false above routes to `needs_approval` rather than auto-grant.
        #expect(MCPToolBridge.riskRequiresApproval("external") == true)
        #expect(MCPToolBridge.riskRequiresApproval("network_read") == false)
    }

    /// A grant with no risk recorded (legacy row, or a writer that forgot the
    /// field) must NOT match anything. Empty-vs-empty is the classic
    /// vacuous-match bug: it would authorize every tool whose effective risk
    /// also failed to resolve.
    @Test func aRisklessGrantAuthorizesNothing() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftNativeMCPDispatcher(root: root)

        _ = try await dispatcher.grantConsent(MCPConsentGrant(
            serverId: "srv-ext", toolName: "tool.mystery", risk: "   "
        ))
        let consent = try #require(try await dispatcher.listConsents().first)
        #expect(consent.status == "granted")
        #expect(MCPToolBridge.consent(consent, matchesCurrentEffectiveRisk: "") == false,
                "empty risk must never match empty risk — that is an authorize-everything hole")
        #expect(MCPToolBridge.consent(consent, matchesCurrentEffectiveRisk: "external") == false)
    }

    /// `setting.capabilitiesShowMCPBuilder` reveals a SECOND full copy of the
    /// MCP Hub's grant/revoke controls. That duplication is tolerated at the
    /// VIEW layer only because both copies funnel through one AppModel
    /// entry point, which funnels through one NativeClient writer. This pins
    /// that funnel: a third UI, or a view that reaches past AppModel straight
    /// to `client.grantMCPConsent`, fails here.
    @Test func everyConsentMutationFunnelsThroughOneAppModelEntryPoint() throws {
        let root = try AppSourceScraping.appSourcesRoot()
        let sources = try AppSourceScraping.swiftSourceContents(under: root)

        var appModelDefinitions: Set<String> = []
        var clientDefinitions: Set<String> = []
        var viewCallSites: Set<String> = []
        var directClientCallers: Set<String> = []

        for (file, source) in sources {
            for verb in ["grantMCPConsent", "revokeMCPConsent"] {
                if source.contains("func \(verb)(") {
                    if file.hasPrefix("AppModel") { appModelDefinitions.insert(file) }
                    if file.hasPrefix("NativeClient") { clientDefinitions.insert(file) }
                }
                if source.contains("appModel.\(verb)(") { viewCallSites.insert(file) }
                if source.contains("client.\(verb)(") && !file.hasPrefix("AppModel") {
                    directClientCallers.insert(file)
                }
            }
        }

        #expect(appModelDefinitions == ["AppModel+RoutingWorkflowMCP.swift"],
                "grant/revoke must have exactly ONE AppModel funnel; found \(appModelDefinitions.sorted())")
        #expect(clientDefinitions == ["NativeClient+MCP.swift"],
                "grant/revoke must have exactly ONE NativeClient writer; found \(clientDefinitions.sorted())")
        #expect(directClientCallers.isEmpty,
                "no view may reach past the AppModel funnel to the client: \(directClientCallers.sorted())")
        // The two known consent UIs (MCP Hub is canonical; the Capabilities
        // MCP-builder panel is the duplicate the ledger row names). A THIRD
        // one is drift and must be justified by updating this list.
        #expect(viewCallSites == ["CapabilitiesView.swift", "MCPHubView.swift"],
                "unexpected consent UI surface(s): \(viewCallSites.sorted())")
    }
}

import Foundation
import Testing
import MCPDispatcher
import NativeAgentCore
@testable import NativeAgentApp

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

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-consent-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

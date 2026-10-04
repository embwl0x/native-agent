import Foundation
import ChatOrchestration
import PersistenceCore
import ProviderRouting
import NativeAgentCore
import ToolRegistry
import TrustCenter

// MARK: - Bridge external-MCP guard

/// Bridge external-MCP guard (2026-06-13).
///
/// The claude/codex bridge surfaces are human-OUT-of-the-loop. Per the user's call
/// ("the bridges should be open"), every NativeAgent-NATIVE tool — builder
/// (shell/git/…), integration-send (mail/messages/…), self-evolution, execution,
/// memory — is fully available on the bridge, gated by the SAME chain as local
/// Mac chat (yolo window for builder, the self_install approval card for
/// evolution, `read_only` fileAccess + canonical approval filing on the /claude/tool
/// RPC). There is NO bridge-specific NativeAgent deny-list anymore.
///
/// The ONE boundary this guard still enforces is the external MCP namespace
/// (`mcp__*`): third-party connectors — including a wired real-money brokerage
/// order path — must never be reachable from a turn with no human at the
/// trigger. That is a third-party-side-effect line (the user did not authorise
/// unattended external trade execution), distinct from Claude's own tools.
/// Used on BOTH bridge paths: the /claude/message chat client (via the
/// `.bridge` surface profile) and the /claude/tool RPC client (via the shared
/// app-owned bridge tool factory).
///
public final class ClaudeBridgeDenyDispatcher: ToolDispatchClient, BuiltInAgentLaneProviding, PreApprovalToolValidating, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    public func builtInAgentLaneUsable(_ name: String) -> Bool {
        (inner as? any BuiltInAgentLaneProviding)?.builtInAgentLaneUsable(name) == true
    }

    public init(inner: any ToolDispatchClient) {
        self.inner = inner
    }

    public func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        if let validating = inner as? any PreApprovalToolValidating {
            return await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
        }
        return await (inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input)
    }

    public func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        await (inner as? any PreApprovalToolValidating)?.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    /// True iff `name` is an external MCP-bridged tool (`mcp__<server>__<tool>`).
    /// 2026-09-22: the built-in SearXNG server is NativeAgent's own read-only
    /// web search, not a third-party connector — bridge turns keep it.
    static func isExternalMcpTool(_ name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("mcp__")
            && !(ToolPreloadHeuristics.webSearchTools.contains(lowered) && searxngIsBuiltIn())
    }

    /// The same tool as the `app` action that runs it: `mcp.<server>.<tool>`,
    /// alone or leading an action line ("mcp.x.y(args) What it does").
    static func namesExternalMcpTool(_ text: String) -> Bool {
        let id = String(text.prefix { $0 != "(" && !$0.isWhitespace })
        return isExternalMcpTool(text) || ToolNameAliases.mcpTool(id).map(isExternalMcpTool) == true
    }

    /// The exemption holds only while `searxng-local` resolves (the same merge
    /// MCPDispatcher does: saved servers.json keys over the built-in default)
    /// to http on a loopback endpoint. A saved override that swaps transport
    /// or points elsewhere is an ordinary external server again.
    private static func searxngIsBuiltIn(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> Bool {
        func json(_ path: String) -> Any? {
            (try? Data(contentsOf: dataRoot.appendingPathComponent(path)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        let saved = (json("mcp/servers.json") as? [[String: Any]])?
            .first { $0["id"] as? String == "searxng-local" } ?? [:]
        let transport = saved["transport"] as? String ?? "http"
        let endpoint = saved["endpoint"] as? String
            ?? (json("research/config.json") as? [String: Any])?["searxng_base_url"] as? String ?? ""
        guard transport == "http", let url = URL(string: endpoint),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// Meta-tools whose RESULT enumerates the MCP list from the inner
    /// dispatcher (built below this guard). Even though `dispatch` denies CALLING
    /// an `mcp__*` tool, these results would still NAME them (agent_introspect
    /// emits mcp_tools/mcp_tool_count; app's home, pages and find list each as
    /// the action `mcp.<server>.<tool>`). So scrub external-MCP
    /// names out of these results — an out-of-loop bridge caller must not even
    /// learn external connector names (e.g. a wired brokerage tool). Mirrors the
    /// meta-result scrub the removed builder guard carried.
    private static let mcpEnumeratingMetaTools: Set<String> = [
        "agent_introspect", "daemon_introspect", "app",
    ]

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // MCP-bridged names (mcp__server__tool) route to live external MCP
        // dispatch — with side-effecting connectors wired (e.g. brokerage order
        // placement) that is an un-human-gated execution path. The bridge has no
        // authority for external MCP tools, so deny that namespace here. Claude
        // and Agent reach MCP tools through normal local chat, where the consent
        // + risk gates are wired. Everything NativeAgent-native passes through.
        // 2026-09-15, User's ruling on the peer bridge: an inbound PEER turn is
        // not human-out-of-the-loop in the way this guard assumes. She is
        // fully herself there, and an effect she is asked for raises the
        // person's permission card (PeerTurnEffectPolicy, applied in
        // AutonomyGatedDispatcher ABOVE this guard) — so the brokerage case
        // this guard was written for is answered by the card, not by making
        // her blind to every connector including read-only ones. The effect
        // split comes from the MCP registry's own per-tool risk metadata, and
        // a server with no metadata asks. Claude's own `claude-bridge` lane
        // is unchanged: it keeps the flat deny.
        let envelope = ChatToolSessionContext.envelope
        let elevatedPeer = surface == "chat" && envelope?.surface == surface && envelope?.agent == "peer"
            && envelope?.commandSignatureVerified == true && envelope?.declaredRemote == false
            && envelope?.verifiedUserId != nil
        let peerBridge = PeerTurnEffectPolicy.isPeerBridge(surface: surface) || elevatedPeer
        if Self.isExternalMcpTool(tool), !peerBridge {
            throw AutonomyGateError.toolDenied(
                reason: "human-out-of-the-loop bridge surface denies external MCP tool: \(tool)"
            )
        }
        let lower = tool.lowercased()
        // On the peer bridge she can CALL external MCP tools, so she must also
        // be able to see their names.
        let result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        if Self.mcpEnumeratingMetaTools.contains(lower), !peerBridge {
            return Self.scrubExternalMcpNames(from: result)
        }
        return result
    }

    /// Recursively drop external-MCP entries from a meta-tool result: array
    /// elements that name one (`mcp__*` or its `mcp.*` action), and array
    /// elements that are objects whose `name` or `action` does. Also zero the derived
    /// `mcp_tool_count` so it can't contradict the emptied list. Walks the whole
    /// tree rather than hard-coding the catalog's field set (drift defense).
    static func scrubExternalMcpNames(from value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            let kept: [JSONValue] = items.compactMap { item in
                if case .string(let s) = item, namesExternalMcpTool(s) { return nil }
                if case .object(let obj) = item, [obj["name"], obj["action"]].contains(where: {
                    if case .string(let n)? = $0 { namesExternalMcpTool(n) } else { false }
                }) { return nil }
                return scrubExternalMcpNames(from: item)
            }
            return .array(kept)
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (k, v) in obj { out[k] = scrubExternalMcpNames(from: v) }
            // Keep derived counts consistent with their now-scrubbed sibling
            // arrays so a residual count can't betray how many mcp__ entries were
            // removed (mcp_tool_count → 0; active_tool_count → native count).
            if out["mcp_tool_count"] != nil {
                if case .array(let a)? = out["mcp_tools"] { out["mcp_tool_count"] = .int(Int64(a.count)) }
                else { out["mcp_tool_count"] = .int(0) }
            }
            if out["active_tool_count"] != nil, case .array(let a)? = out["active_tools"] {
                out["active_tool_count"] = .int(Int64(a.count))
            }
            return .object(out)
        default:
            return value
        }
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().filter { !Self.isExternalMcpTool($0) }
    }

    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names).filter { !Self.isExternalMcpTool($0.name) }
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().filter { !Self.isExternalMcpTool($0.name) }
    }
}

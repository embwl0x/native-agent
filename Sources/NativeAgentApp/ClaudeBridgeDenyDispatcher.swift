import Foundation
import ChatOrchestration
import PersistenceCore
import ProviderRouting
import NativeAgentCore

// MARK: - Bridge external-MCP guard

/// Bridge external-MCP guard (2026-06-13).
///
/// The claude/codex bridge surfaces are human-OUT-of-the-loop. Per the user's call
/// ("the bridges should be open"), every NativeAgent-NATIVE tool — builder
/// (shell/git/…), integration-send (mail/messages/…), self-evolution, execution,
/// memory — is fully available on the bridge, gated by the SAME chain as local
/// Mac chat (yolo window for builder, the self_install approval card for
/// evolution, `read_only` fileAccess + no-approval-inbox on the /claude/tool
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
/// Internal (not private) so NativeAgentAppTests can dispatch through the guard
/// directly and prove the mcp__ namespace stays unreachable from the bridge.
/// Internal visibility adds no production exposure — NativeAgentApp is an
/// executable, not a library.
final class ClaudeBridgeDenyDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient

    init(inner: any ToolDispatchClient) {
        self.inner = inner
    }

    /// True iff `name` is an external MCP-bridged tool (`mcp__<server>__<tool>`).
    static func isExternalMcpTool(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("mcp__")
    }

    /// Meta-tools whose RESULT enumerates the tool set / MCP list from the inner
    /// dispatcher (built below this guard). Even though `dispatch` denies CALLING
    /// an `mcp__*` tool, these results would still NAME them (impl_tool_catalog
    /// unions MCP names into available_tools/tools/currently_loaded;
    /// agent_introspect emits mcp_tools/mcp_tool_count). So scrub external-MCP
    /// names out of these results — an out-of-loop bridge caller must not even
    /// learn external connector names (e.g. a wired brokerage tool). Mirrors the
    /// meta-result scrub the removed builder guard carried.
    private static let mcpEnumeratingMetaTools: Set<String> = [
        "tool_catalog", "list_tools", "tool_load", "tool_unload",
        "agent_introspect", "daemon_introspect",
    ]

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // MCP-bridged names (mcp__server__tool) route to live external MCP
        // dispatch — with side-effecting connectors wired (e.g. brokerage order
        // placement) that is an un-human-gated execution path. The bridge has no
        // approval inbox, so deny the whole external MCP namespace here. Claude
        // and Agent reach MCP tools through normal local chat, where the consent
        // + risk gates are wired. Everything NativeAgent-native passes through.
        if Self.isExternalMcpTool(tool) {
            throw AutonomyGateError.toolDenied(
                reason: "human-out-of-the-loop bridge surface denies external MCP tool: \(tool)"
            )
        }
        let lower = tool.lowercased()
        // tool_load / tool_unload MUTATE the active-tool set keyed on their INPUT
        // names. A bridge caller passing an mcp__ name would load/probe an external
        // connector, and the returned session_active_count would confirm the name
        // was valid even though it's scrubbed from the name arrays — an existence
        // oracle. Strip mcp__ names from the input so the inner never sees them.
        let effectiveInput = (lower == "tool_load" || lower == "tool_unload")
            ? Self.stripExternalMcpFromLoadInput(input)
            : input
        let result = try await inner.dispatch(tool: tool, input: effectiveInput, surface: surface)
        if Self.mcpEnumeratingMetaTools.contains(lower) {
            return Self.scrubExternalMcpNames(from: result)
        }
        return result
    }

    /// Drop external-MCP names from a tool_load/tool_unload input (`names` array
    /// and singular `name`) so the inner dispatcher never loads, probes, or
    /// counts an mcp__ tool on behalf of an out-of-loop bridge caller.
    static func stripExternalMcpFromLoadInput(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var out = input
        if case .array(let arr)? = out["names"] {
            out["names"] = .array(arr.filter { item in
                if case .string(let s) = item { return !isExternalMcpTool(s) }
                return true
            })
        }
        if case .string(let s)? = out["name"], isExternalMcpTool(s) {
            out["name"] = nil
        }
        return out
    }

    /// Recursively drop external-MCP entries from a meta-tool result: array
    /// elements that are a bare `mcp__*` string, and array elements that are
    /// objects whose `name` is an `mcp__*` tool. Also zero the derived
    /// `mcp_tool_count` so it can't contradict the emptied list. Walks the whole
    /// tree rather than hard-coding the catalog's field set (drift defense).
    static func scrubExternalMcpNames(from value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            let kept: [JSONValue] = items.compactMap { item in
                if case .string(let s) = item, isExternalMcpTool(s) { return nil }
                if case .object(let obj) = item,
                   case .string(let n)? = obj["name"], isExternalMcpTool(n) { return nil }
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
            // Same rule for the session-pinned pair agent_introspect now emits:
            // its array is scrubbed above like any other, so the count must be
            // re-derived or it betrays the removals.
            if out["session_pinned_tool_count"] != nil,
               case .array(let a)? = out["session_pinned_tools"] {
                out["session_pinned_tool_count"] = .int(Int64(a.count))
            }
            return .object(out)
        default:
            return value
        }
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().filter { !Self.isExternalMcpTool($0) }
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().filter { !Self.isExternalMcpTool($0.name) }
    }
}

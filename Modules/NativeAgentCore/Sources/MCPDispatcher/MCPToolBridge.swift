import Foundation
import PersistenceCore

/// Process-wide "already warned about this server" set. `listMCPTools` runs on
/// every chat turn, so the warning is deduped per server id — loud once, not
/// once per turn.
final class _MCPWarnedServerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    private var order: [String] = []

    /// Returns true when this is the FIRST time we've seen `serverId`.
    func insert(_ serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard seen.insert(serverId).inserted else { return false }
        order.append(serverId)
        return true
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    func reset() {
        lock.lock()
        seen.removeAll()
        order.removeAll()
        lock.unlock()
    }
}

/// Descriptor surfaced to the LLM-side tool list. The bridged-tool name
/// convention is `mcp__<serverId>__<toolName>` (matches the daemon's
/// `mcp_dispatcher_bridge` shape so consent/risk lookup stays uniform).
public struct MCPToolDescriptor: Sendable, Equatable {
    /// Bridged tool name as the LLM should see it (`mcp__<server>__<tool>`).
    public let bridgedName: String
    /// Source server id (slug used in `<root>/mcp/servers.json`).
    public let serverId: String
    /// Tool name as the upstream MCP server advertises it.
    public let toolName: String
    /// Server-level risk class — drives AutonomyGate tier on dispatch.
    /// Per `nativeagent-mcp-dispatcher-bridge`: all `mcp__*` tools are
    /// tier-B by default; finer-grained risk_class on the tool itself
    /// may upgrade to tier C.
    public let serverRiskClass: String
    /// Optional per-tool risk class from cache/tools.json (`risk_class` /
    /// `riskClass` keys). `nil` when the upstream cache didn't stamp one.
    public let toolRiskClass: String?
    public let description: String?
    /// JSON Schema for the tool's arguments, verbatim from the upstream
    /// server's `inputSchema` in cache/tools.json. `nil` when the cache row
    /// didn't carry one (callers fall back to a permissive object schema).
    public let inputSchema: JSONValue?

    public var effectiveRiskClass: String {
        MCPToolBridge.effectiveRiskClass(
            serverId: serverId,
            serverRiskClass: serverRiskClass,
            toolRiskClass: toolRiskClass
        )
    }

    public init(
        bridgedName: String,
        serverId: String,
        toolName: String,
        serverRiskClass: String,
        toolRiskClass: String?,
        description: String?,
        inputSchema: JSONValue? = nil
    ) {
        self.bridgedName = bridgedName
        self.serverId = serverId
        self.toolName = toolName
        self.serverRiskClass = serverRiskClass
        self.toolRiskClass = toolRiskClass
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Bridge that enumerates MCP tools from local MCP registry/cache state
/// (`<dataRoot>/mcp/servers.json` + `<dataRoot>/mcp/cache/tools.json`) and
/// returns them under the bridged `mcp__<server>__<tool>` naming convention
/// so the chat path can surface and dispatch them.
///
/// Intentional scope (W6 partial):
///   - Descriptor enumeration: DONE.
///   - Plug into `listAvailableTools`: DONE.
///   - Adapter `tools:` schema wiring: DONE via SwiftToolDispatcher.
///   - Dispatch through SwiftNativeMCPDispatcher.callToolLive: DONE for stdio
///     servers whose risk is low or already consented.
public enum MCPToolBridge {

    /// Enumerate MCP tools as bridged descriptors. Best-effort: missing
    /// files / malformed JSON return `[]` rather than throwing — the chat
    /// path tolerates an empty list.
    public static func listMCPTools(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [MCPToolDescriptor] {
        let mcpRoot = dataRoot.appendingPathComponent("mcp", isDirectory: true)
        let servers = readServers(at: mcpRoot.appendingPathComponent("servers.json"))
        guard !servers.isEmpty else { return [] }
        let toolsCache = readToolsCache(
            at: mcpRoot.appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("tools.json")
        )
        var out: [MCPToolDescriptor] = []
        out.reserveCapacity(servers.count * 4)
        for (serverId, serverRisk) in servers {
            guard let tools = toolsCache[serverId], !tools.isEmpty else {
                // FAIL LOUD (NORTHSTAR clause 2). A server that servers.json
                // says is usable but that contributes ZERO descriptors is a
                // silent capability loss — the model is told it has no such
                // tools and reports "I don't have access". Before F-B3 this
                // was the state of EVERY stdio server, because nothing wrote
                // `mcp/cache/tools.json` after the daemon was retired. The
                // cure is `SwiftNativeMCPDispatcher.refreshAllToolsCaches()`;
                // this line makes the disease visible either way.
                warnEmptyServer(
                    serverId: serverId,
                    reason: toolsCache[serverId] == nil
                        ? "no entry in mcp/cache/tools.json (never handshaked, or the cache was never stamped)"
                        : "its cache entry lists zero tools"
                )
                continue
            }
            for t in tools {
                let bridged = "mcp__\(serverId)__\(t.name)"
                out.append(
                    MCPToolDescriptor(
                        bridgedName: bridged,
                        serverId: serverId,
                        toolName: t.name,
                        serverRiskClass: serverRisk,
                        toolRiskClass: t.riskClass,
                        description: t.description,
                        inputSchema: t.inputSchema
                    )
                )
            }
        }
        return out.sorted { $0.bridgedName < $1.bridgedName }
    }

    /// Convenience wrapper returning just the bridged names — what
    /// `ToolDispatchClient.listAvailableTools()` ultimately needs.
    public static func listMCPToolNames(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [String] {
        listMCPTools(dataRoot: dataRoot).map(\.bridgedName)
    }

    public static func effectiveRiskClass(
        serverId: String,
        toolName: String,
        serverRiskClass: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        let descriptor = listMCPTools(dataRoot: dataRoot).first {
            $0.serverId == serverId && $0.toolName == toolName
        }
        return effectiveRiskClass(
            serverId: serverId,
            serverRiskClass: serverRiskClass,
            toolRiskClass: descriptor?.toolRiskClass
        )
    }

    public static func effectiveRiskClass(
        serverId: String,
        serverRiskClass: String,
        toolRiskClass: String?
    ) -> String {
        let serverRisk = normalizedRisk(serverRiskClass, fallback: "network_read")
        guard let toolRisk = normalizedOptionalRisk(toolRiskClass) else {
            return isTrustedBuiltInReadServer(serverId: serverId, serverRiskClass: serverRisk)
                ? serverRisk
                : "approval_gated_missing_tool_risk"
        }
        return riskRank(toolRisk) > riskRank(serverRisk) ? toolRisk : serverRisk
    }

    /// Explicit read tiers stamped for side-effect-free MCP tools — the ONLY
    /// effective-risk classes safe to auto-grant low-risk consent for.
    /// app_data_read / network_read are what's actually stamped today
    /// (MCPDispatcher seeds + the network_read fallback); the synonyms are
    /// defensive against future naming.
    public static let autoGrantReadTiers: Set<String> = [
        "app_data_read", "network_read", "read", "read_only", "readonly", "none", "low", "safe",
    ]

    /// Canonical MCP auto-grant gate (loop-A A3 fix, 2026-06-13). FAIL CLOSED:
    /// auto-grant consent ONLY for the explicit read tiers above; EVERYTHING
    /// else requires approval — unknown classes, every write/send/exec/admin
    /// class, the network-reach classes (`network_localhost` reaches local
    /// services; `external` / `network_public`), money classes
    /// (trade/order/brokerage), and the `approval_gated_missing_tool_risk`
    /// sentinel. Replaces three drifting per-call-site denylists
    /// (SwiftToolDispatcher, WorkflowOrchestration, NativeClient+MCP) that
    /// auto-granted any class lacking a hardcoded danger keyword, so unanticipated
    /// side-effecting classes slipped through and auto-executed. One source so
    /// the gate can't drift across call sites.
    public static func riskRequiresApproval(_ riskClass: String) -> Bool {
        let lower = riskClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !autoGrantReadTiers.contains(lower)
    }

    public static func consent(
        _ consent: MCPConsent,
        matchesCurrentEffectiveRisk effectiveRiskClass: String
    ) -> Bool {
        guard consent.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "granted" else {
            return false
        }
        let consentRisk = normalizedRisk(consent.risk, fallback: "")
        let currentRisk = normalizedRisk(effectiveRiskClass, fallback: "")
        return !consentRisk.isEmpty && consentRisk == currentRisk
    }

    // MARK: - Silent-loss warnings

    /// Servers already warned about, so the per-turn tool-list assembly logs
    /// once per server rather than on every chat turn.
    private static let warnedServers = _MCPWarnedServerSet()

    /// Server ids warned about this process, in first-seen order. The
    /// observable half of the loud failure — stderr is the human half.
    public static var emptyServerWarnings: [String] { warnedServers.recorded }

    /// Test seam — forget the warned set so a test can observe the warning.
    public static func _resetEmptyServerWarnings() { warnedServers.reset() }

    private static func warnEmptyServer(serverId: String, reason: String) {
        guard warnedServers.insert(serverId) else { return }
        let message = "MCPToolBridge: server '\(serverId)' is configured but contributes ZERO tool "
            + "descriptors — \(reason). The model will not see any mcp__\(serverId)__* tools. Run "
            + "SwiftNativeMCPDispatcher.refreshAllToolsCaches() to stamp the cache from a live handshake.\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    // MARK: - File IO

    private static func readServers(at url: URL) -> [(id: String, risk: String)] {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        guard let arr = parsed as? [[String: Any]] else { return [] }
        var out: [(String, String)] = []
        out.reserveCapacity(arr.count)
        for obj in arr {
            guard let id = obj["id"] as? String, !id.isEmpty else { continue }
            let status = (obj["status"] as? String) ?? ""
            // Skip records explicitly marked as not yet usable. Match the
            // daemon's surface: only "configured" / "ready" servers count
            // as bridgeable; "needs_setup" / "error" hide.
            if status == "needs_setup" || status == "error" { continue }
            let risk = (obj["riskClass"] as? String)
                ?? (obj["risk_class"] as? String)
                ?? "network_read"
            out.append((id, risk))
        }
        return out
    }

    private static func normalizedOptionalRisk(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedRisk(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func isTrustedBuiltInReadServer(serverId: String, serverRiskClass: String) -> Bool {
        switch serverId {
        case "nativeagent-internal":
            return true
        case "searxng-local":
            return riskRank(serverRiskClass) <= riskRank("network_read")
        default:
            return false
        }
    }

    private static func riskRank(_ risk: String) -> Int {
        let lower = risk.lowercased()
        if lower.contains("critical") || lower.contains("admin") || lower.contains("delete")
            || lower.contains("write") || lower.contains("send") || lower.contains("money") {
            return 50
        }
        if lower.contains("approval") || lower.contains("risky") || lower.contains("high") {
            return 40
        }
        if lower.contains("medium") || lower.contains("network") || lower.contains("external") {
            return 30
        }
        if lower.contains("read") || lower.contains("low") || lower.contains("app_data") {
            return 10
        }
        return 20
    }

    private struct CachedTool {
        let name: String
        let description: String?
        let riskClass: String?
        let inputSchema: JSONValue?
    }

    private static func readToolsCache(at url: URL) -> [String: [CachedTool]] {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        var out: [String: [CachedTool]] = [:]
        for (serverId, entryAny) in parsed {
            guard let entry = entryAny as? [String: Any],
                  let tools = entry["tools"] as? [[String: Any]]
            else { continue }
            var parsedTools: [CachedTool] = []
            parsedTools.reserveCapacity(tools.count)
            for t in tools {
                guard let name = t["name"] as? String, !name.isEmpty else { continue }
                let desc = t["description"] as? String
                let risk = (t["risk_class"] as? String)
                    ?? (t["riskClass"] as? String)
                // Only object-shaped schemas count — a stray string/array
                // here would fail provider-side tool validation.
                let schema: JSONValue? = (t["inputSchema"] as? [String: Any])
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { try? JSONValue.parse($0) }
                parsedTools.append(CachedTool(
                    name: name, description: desc, riskClass: risk, inputSchema: schema
                ))
            }
            out[serverId] = parsedTools.sorted { $0.name < $1.name }
        }
        return out
    }
}

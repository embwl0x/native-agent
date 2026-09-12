import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import DreamREMCycle
import ApprovalInbox
import MacIntegration
import CognitiveSubstrate

private let makeTempRoot: @Sendable (String) throws -> URL = makeChatOrchestrationTempRoot

private struct ProjectedDispatchTestError: Error, LocalizedError {
    let errorDescription: String?
}

@Test
func projectedToolDispatchErrorPrefersUsefulSafeBoundedDescription() {
    let home = NSHomeDirectory()
    let message = SwiftNativeTurnEngine.projectedToolDispatchError(
        ProjectedDispatchTestError(
            errorDescription: "Could not read \(home)/Library/private.txt; token=secret-value"
        )
    )

    #expect(message.contains("~/Library/private.txt"))
    #expect(!message.contains(home))
    #expect(!message.contains("secret-value"))
    #expect(message.count <= 2_000)
}

@Test func searchKGToolFailsClosedOnCorruptCanonicalSQLite() async throws {
    let root = try makeTempRoot("search-kg-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    // 2026-09-06: 130f1553 gates graph reads on explicit consent. Exercise
    // the corrupt canonical reader, rather than the earlier disabled refusal.
    try writeTrustPolicy(root, .object([
        "memoryPolicy": .object(["knowledge_graph_enabled": .bool(true)])
    ]))
    let memoryDirectory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
    let sqlitePath = memoryDirectory.appendingPathComponent("memory.sqlite")
    let corruptBytes = Data("not a sqlite database; stale JSON must never impersonate success".utf8)
    try corruptBytes.write(to: sqlitePath)
    try Data(#"{"entities":{"stale":{"id":"stale","name":"Needle","type":"fact"}},"edges":[]}"#.utf8)
        .write(to: memoryDirectory.appendingPathComponent("knowledge_graph.json"))
    let tools = SwiftToolDispatcher(dataRoot: root)

    await #expect(throws: (any Error).self) {
        _ = try await tools.dispatch(
            tool: "search_kg",
            input: ["query": .string("Needle")],
            surface: "chat"
        )
    }
    #expect(try Data(contentsOf: sqlitePath) == corruptBytes)
}

// MARK: - Tests

@Test
func swiftToolDispatcher_surfaces_mcp_names_and_schemas() async throws {
    let root = try makeTempRoot("mcp-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    let mcp = root.appendingPathComponent("mcp", isDirectory: true)
    let cache = mcp.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try """
    [
      {"id":"local","name":"Local MCP","transport":"stdio","command":"/bin/echo","status":"ready","riskClass":"network_read"},
      {"id":"nativeagent-internal","name":"NativeAgent Internal MCP","transport":"native","status":"ready","riskClass":"app_data_read"}
    ]
    """.write(to: mcp.appendingPathComponent("servers.json"), atomically: true, encoding: .utf8)
    try """
    {
      "local":{"tools":[
        {"name":"search","description":"Search through MCP."},
        {"name":"lookup","description":"Lookup with typed args.",
         "inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}}
      ]},
      "nativeagent-internal":{"tools":[
        {"name":"capabilities.summary","description":"Internal capability summary."}
      ]}
    }
    """.write(to: cache.appendingPathComponent("tools.json"), atomically: true, encoding: .utf8)

    let tools = SwiftToolDispatcher(dataRoot: root)
    let names = try await tools.listAvailableTools()
    #expect(names.contains("mcp__local__search"))
    // Raw compatibility remains available to the Tools/MCP UI and external
    // clients, even though ordinary model turns should not be offered a
    // duplicate self-MCP route.
    let internalName = "mcp__nativeagent-internal__capabilities.summary"
    #expect(names.contains(internalName))
    #expect(MCPToolBridge.listMCPToolNames(dataRoot: root).contains(internalName))

    let schemas = try await tools.listAvailableToolSchemas()
    #expect(!schemas.contains { $0.name == internalName })
    // No inputSchema in the cache row → permissive fallback object.
    let schema = try #require(schemas.first(where: { $0.name == "mcp__local__search" }))
    #expect(schema.description == "Search through MCP.")
    let parsed = try JSONValue.parse(schema.parametersJSON)
    guard case .object(let obj) = parsed else {
        Issue.record("MCP schema should be object")
        return
    }
    #expect(obj["type"] == .string("object"))
    #expect(obj["additionalProperties"] == .bool(true))

    // Cache row carries a real inputSchema → surfaced verbatim to the LLM
    // (NOT replaced by the permissive fallback).
    let typed = try #require(schemas.first(where: { $0.name == "mcp__local__lookup" }))
    let typedParsed = try JSONValue.parse(typed.parametersJSON)
    guard case .object(let typedObj) = typedParsed else {
        Issue.record("typed MCP schema should be object")
        return
    }
    #expect(typedObj["type"] == .string("object"))
    #expect(typedObj["required"] == .array([.string("q")]))
    guard case .object(let props)? = typedObj["properties"],
          case .object(let qProp)? = props["q"] else {
        Issue.record("typed MCP schema should carry properties.q")
        return
    }
    #expect(qProp["type"] == .string("string"))
    #expect(typedObj["additionalProperties"] == nil)

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "chat")
    guard case .object(let catalogObject) = catalog,
          case .array(let available)? = catalogObject["available_tools"] else {
        Issue.record("expected compact model-visible catalog")
        return
    }
    #expect(!available.contains(.string(internalName)))

    let rawResult = try await SwiftNativeMCPDispatcher(root: root).callToolLive(
        forServer: "nativeagent-internal",
        toolName: "capabilities.summary"
    )
    guard case .object(let rawObject) = rawResult else {
        Issue.record("expected raw native MCP result")
        return
    }
    #expect(rawObject["status"] == .string("ok"))
}

@Test
func mcpToolBridge_effectiveRisk_uses_tool_risk_and_fails_closed_for_external_missing_risk() async throws {
    let root = try makeTempRoot("mcp-risk")
    defer { try? FileManager.default.removeItem(at: root) }
    let mcp = root.appendingPathComponent("mcp", isDirectory: true)
    let cache = mcp.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try """
    [
      {"id":"local","name":"Local MCP","transport":"stdio","command":"/bin/echo","status":"ready","riskClass":"network_read"},
      {"id":"nativeagent-internal","name":"NativeAgent Internal MCP","transport":"native","status":"ready","riskClass":"app_data_read"},
      {"id":"searxng-local","name":"SearXNG Local Search","transport":"http","endpoint":"http://127.0.0.1:8888","status":"ready","riskClass":"network_read"}
    ]
    """.write(to: mcp.appendingPathComponent("servers.json"), atomically: true, encoding: .utf8)
    try """
    {
      "local":{"tools":[
        {"name":"graphql","description":"Mutating query.","risk_class":"external_write"},
        {"name":"search","description":"Missing risk."}
      ]},
      "nativeagent-internal":{"tools":[
        {"name":"agent.operating_map","description":"Internal read."}
      ]},
      "searxng-local":{"tools":[
        {"name":"search","description":"Built-in local search missing tool risk."}
      ]}
    }
    """.write(to: cache.appendingPathComponent("tools.json"), atomically: true, encoding: .utf8)

    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "local",
        toolName: "graphql",
        serverRiskClass: "network_read",
        dataRoot: root
    ) == "external_write")
    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "local",
        toolName: "search",
        serverRiskClass: "network_read",
        dataRoot: root
    ) == "approval_gated_missing_tool_risk")
    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "nativeagent-internal",
        toolName: "agent.operating_map",
        serverRiskClass: "app_data_read",
        dataRoot: root
    ) == "app_data_read")
    #expect(MCPToolBridge.effectiveRiskClass(
        serverId: "searxng-local",
        toolName: "search",
        serverRiskClass: "network_read",
        dataRoot: root
    ) == "network_read")
}

@Test
func mcpToolBridge_consentMustMatch_currentEffectiveRisk() async throws {
    let granted = MCPConsent(
        id: "local:search",
        serverId: "local",
        toolName: "search",
        risk: "app_data_read",
        status: "granted",
        grantedAt: "2026-06-05T00:00:00+00:00",
        updatedAt: "2026-06-05T00:00:00+00:00"
    )
    let revoked = MCPConsent(
        id: "local:search",
        serverId: "local",
        toolName: "search",
        risk: "app_data_read",
        status: "revoked",
        grantedAt: "2026-06-05T00:00:00+00:00",
        updatedAt: "2026-06-05T00:00:00+00:00"
    )

    // An unbound legacy row cannot authorize even an unchanged risk: the
    // shared reader must also validate the current server execution identity.
    #expect(!MCPToolBridge.consent(granted, matchesCurrentEffectiveRisk: "app_data_read"))
    #expect(!MCPToolBridge.consent(granted, matchesCurrentEffectiveRisk: "external_write"))
    #expect(!MCPToolBridge.consent(revoked, matchesCurrentEffectiveRisk: "app_data_read"))
}

@Test
func swiftToolDispatcher_reports_swift_runtime_introspection_aliases() async throws {
    let root = try makeTempRoot("introspect")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let agent = try await tools.dispatch(
        tool: "agent_introspect", input: ["detail": .string("full")], surface: "chat")
    guard case .object(let agentObj) = agent else {
        Issue.record("expected agent_introspect object")
        return
    }
    #expect(agentObj["runtime"] == .string("swift-native"))
    #expect(agentObj["detail"] == .string("full"))
    #expect(agentObj["python_daemon"] == .string("retired"))
    let expectedRuntimeID = "swift-native-\(ProcessInfo.processInfo.processIdentifier)"
    #expect(agentObj["runtime_instance_id"] == .string(expectedRuntimeID))
    #expect(agentObj["process_id"] == .int(Int64(ProcessInfo.processInfo.processIdentifier)))
    #expect(agentObj["conversation_session_id"] == nil)
    #expect(agentObj["session_id"] == nil)
    guard case .array(let activeTools)? = agentObj["active_tools"] else {
        Issue.record("expected active tool list")
        return
    }
    #expect(activeTools.contains(.string("agent_introspect")))
    #expect(!activeTools.contains(.string("daemon_introspect")))
    #expect(agentObj["active_tool_count"] == .int(Int64(activeTools.count)))
    guard case .int(let availableCount)? = agentObj["available_tool_count"] else {
        Issue.record("expected available tool count")
        return
    }
    #expect(availableCount >= Int64(activeTools.count))
    #expect(agentObj["lazy_loading"] != nil)
    guard case .object(let outcomeHealth)? = agentObj["outcome_dimension_health"] else {
        Issue.record("expected production outcome population health")
        return
    }
    #expect(outcomeHealth["status"] == .string("absent"))
    #expect(outcomeHealth["source_status"] == .string("absent"))
    #expect(outcomeHealth["absent_is_zero"] == .bool(false))

    let compat = try await tools.dispatch(tool: "daemon_introspect", input: [:], surface: "chat")
    guard case .object(let compatObj) = compat else {
        Issue.record("expected daemon_introspect object")
        return
    }
    #expect(compatObj["runtime"] == .string("swift-native"))
    #expect(compatObj["detail"] == .string("compact"))
    #expect(compatObj["invoked_as"] == .string("daemon_introspect"))
    #expect(compatObj["active_tools"] == nil)
}

@Test
func swiftToolDispatcher_introspectionSeparatesConversationFromRuntimeIdentity() async throws {
    let root = try makeTempRoot("introspect-session-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let value = try await tools.dispatch(
        tool: "agent_introspect",
        input: ["__session_id": .string("conversation-exact-123")],
        surface: "chat"
    )
    guard case .object(let object) = value else {
        Issue.record("expected agent_introspect object")
        return
    }
    #expect(object["runtime_instance_id"]
        == .string("swift-native-\(ProcessInfo.processInfo.processIdentifier)"))
    #expect(object["conversation_session_id"] == .string("conversation-exact-123"))
    #expect(object["session_id"] == .string("conversation-exact-123"))
    #expect(object["detail"] == .string("compact"))
    #expect(object["outcome_dimension_health"] == nil)
}

@Test
func swiftToolDispatcher_introspection_marksUnreadableOutcomePopulationUnavailable() async throws {
    let root = try makeTempRoot("introspect-unreadable-outcome-population")
    defer { try? FileManager.default.removeItem(at: root) }
    let chat = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
    // A non-directory at the canonical population path is deterministic
    // unreadable-store evidence (unlike chmod, which uid 0 can bypass).
    try Data("not-a-transcript-directory".utf8).write(
        to: chat.appendingPathComponent("messages")
    )

    let tools = SwiftToolDispatcher(dataRoot: root)
    let value = try await tools.dispatch(
        tool: "agent_introspect", input: ["detail": .string("full")], surface: "chat")
    guard case .object(let object) = value,
          case .object(let health)? = object["outcome_dimension_health"] else {
        Issue.record("expected outcome health in production introspection")
        return
    }
    #expect(health["status"] == .string("unavailable"))
    #expect(health["absent_is_zero"] == .bool(false))
    #expect(health["error_class"] != nil)
}

@Test
func swiftToolDispatcher_tool_catalog_includes_swift_aliases() async throws {
    let root = try makeTempRoot("catalog")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let compact = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "chat")
    guard case .object(let compactObj) = compact else {
        Issue.record("expected compact tool_catalog object")
        return
    }
    #expect(compactObj["catalog_detail"] == .string("compact"))
    #expect(compactObj["tools"] == .array([]))
    #expect(compactObj["tool_groups"] != nil)

    let catalog = try await tools.dispatch(
        tool: "tool_catalog",
        input: ["detail": .string("full")],
        surface: "chat"
    )
    guard case .object(let obj) = catalog else {
        Issue.record("expected tool_catalog object")
        return
    }
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["catalog_detail"] == .string("full"))
    // 2026-06-08 lazy-tool-skill-loading: tool_catalog now reports lazy_load=true
    // (it WAS false in the eager-everything-on era). The test was stale.
    #expect(obj["lazy_load"] == .bool(true))
    #expect(obj["builder_mode"] == .string("policy_locked"))
    #expect(obj["full_mac_active"] == .bool(false))
    #expect(SwiftToolDispatcher.modelVisibleCatalogToolNames([
        "mac_focus_app", "mac_quit_app", "act", "go", "market_status",
    ]) == ["act", "go", "market_status"])
    guard case .array(let names)? = obj["available_tools"] else {
        Issue.record("expected available_tools")
        return
    }
    #expect(names.contains(.string("tool_catalog")))
    #expect(names.contains(.string("list_tools")))
    #expect(names.contains(.string("tool_load")))
    #expect(names.contains(.string("recall_search")))
    #expect(names.contains(.string("recall_memory")))
    #expect(names.contains(.string("search_chat_history")))
    #expect(names.contains(.string("session_search")))
    #expect(names.contains(.string("context_lookup")))
    #expect(names.contains(.string("scratchpad_read")))
    #expect(names.contains(.string("recent_trace_summary")))
    #expect(names.contains(.string("market_status")))
    #expect(names.contains(.string("market_watchlists")))
    #expect(names.contains(.string("tradingview_watchlist")))
    #expect(names.contains(.string("market_quote")))
    #expect(names.contains(.string("persona_read")))
    #expect(names.contains(.string("persona_write")))
    #expect(names.contains(.string("persona_append_section")))
    guard case .array(let rows)? = obj["tools"] else {
        Issue.record("expected tool catalog rows")
        return
    }
    for row in rows {
        guard case .object(let rowObj) = row else {
            Issue.record("expected object tool row")
            continue
        }
        guard case .object(let parameters)? = rowObj["parameters"] else {
            Issue.record("expected parameter schema for every catalog row")
            continue
        }
        #expect(parameters["type"] == .string("object"))
        #expect(parameters["properties"] != nil)
        #expect(parameters["required"] != nil)
        #expect(rowObj["load_state"] != nil)
    }
}

@Test
func swiftToolDispatcher_alwaysOnCoreNames_staysWithinLazyLoadBudget() async throws {
    let alwaysOn = SwiftToolDispatcher.alwaysOnCoreNames
    // Budget guard for the hot lazy-load-exempt core. Bumped 20→21 when
    // commit_memory (Agent's memory WRITE path) was restored: the write must
    // be always-loaded so the model can save a fact mid-turn without a
    // tool_load dance, symmetric with the always-on recall_memory.
    // Bumped 21→22 for desk_read (2026-06-29, User's pull-to-retrieve flow:
    // "what's on the desk" must work regardless of phrasing — the nine desk
    // mutations stay lazy).
    // Bumped 22→23 for ContextFlow's context_expand. As of 2026-09-01 its
    // schema is advertised on EVERY turn — a floor that appears and disappears
    // with the packet is a per-turn prefix rewrite, not a floor.
    // Canonical-only hot names: compatibility aliases remain catalog-visible
    // but no longer tax every ordinary provider request.
    // 2026-09-06: bumped 24→25 for `inner_state` (259a331a, personality depth
    // item 3). It is always-on for the same reason `agent_introspect` is — a
    // tool she must `tool_load` before answering "how are you" is one she will
    // not reach for mid-sentence. One catalog row, zero prompt bytes until she
    // pulls it, so the budget this guard protects is unchanged in kind.
    // 2026-09-12: back down to the shipped 20 (docs/TOOL_LOADING.md rule 1).
    // Agent's working-set ruling of 2026-09-11 dropped scratchpad_read,
    // save_skill, search_kg, omp_message and codex_message off the floor —
    // zero to two real calls in eleven days each, all still loadable.
    #expect(alwaysOn.count == 20)
    #expect(alwaysOn.contains("tool_load"))
    #expect(alwaysOn.contains("tool_result_page"))
    #expect(alwaysOn.contains("search_chat_history"))
    #expect(!alwaysOn.contains("session_search"))
    #expect(alwaysOn.contains("claude_message"))
    #expect(!alwaysOn.contains("invoke_claude"))
    // codex_message left the floor on 2026-09-11 with the rest of the
    // working-set trim; it stays catalog-visible and one `tool_load` away.
    #expect(!alwaysOn.contains("codex_message"))
    #expect(!alwaysOn.contains("invoke_codex"))
    #expect(!alwaysOn.contains("omp_message"))
    #expect(!alwaysOn.contains("save_skill"))
    #expect(!alwaysOn.contains("search_kg"))
    #expect(!alwaysOn.contains("scratchpad_read"))
    #expect(alwaysOn.contains("recall_memory"))
    #expect(!alwaysOn.contains("recall_search"))
    #expect(!alwaysOn.contains("list_tools"))
    #expect(!alwaysOn.contains("daemon_introspect"))
    #expect(alwaysOn.contains("commit_memory"))
}

@Test
func swiftToolDispatcher_personaAppendSection_writesGrowthOnTelegramSurface() async throws {
    let root = try makeTempRoot("persona-growth")
    defer { try? FileManager.default.removeItem(at: root) }
    let personaRoot = root
        .appendingPathComponent("persona", isDirectory: true)
        .appendingPathComponent("Agent", isDirectory: true)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try "# Soul".write(to: personaRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    try "# Growth\n\nSeed".write(to: personaRoot.appendingPathComponent("GROWTH.md"), atomically: true, encoding: .utf8)

    let tools = SwiftToolDispatcher(dataRoot: root)
    let result = try await tools.dispatch(
        tool: "persona_append_section",
        input: [
            "kind": .string("growth"),
            "title": .string("Telegram calibration"),
            "content": .string("Telegram can add to Agent's growth journal."),
        ],
        surface: "telegram"
    )

    guard case .object(let obj) = result else {
        Issue.record("expected persona_append_section result object")
        return
    }
    #expect(obj["ok"] == .bool(true))
    #expect(obj["kind"] == .string("growth"))
    guard case .string(let rawPath)? = obj["path"] else {
        Issue.record("expected path string")
        return
    }
    #expect(
        URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        == personaRoot.appendingPathComponent("GROWTH.md").resolvingSymlinksInPath().path
    )
    guard case .int(let bytes)? = obj["bytes_appended"] else {
        Issue.record("expected bytes_appended")
        return
    }
    #expect(bytes > 0)

    let body = try String(contentsOf: personaRoot.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(body.contains("## Telegram calibration"))
    #expect(body.contains("Telegram can add to Agent's growth journal."))

    let readBack = try await tools.dispatch(
        tool: "persona_read",
        input: ["kind": .string("growth")],
        surface: "telegram"
    )
    guard case .object(let readObj) = readBack else {
        Issue.record("expected persona_read object")
        return
    }
    #expect(readObj["ok"] == .bool(true))
    if case .string(let content)? = readObj["content"] {
        #expect(content.contains("## Telegram calibration"))
    } else {
        Issue.record("expected persona_read content")
    }
}

@Test
func swiftToolDispatcher_list_tools_aliases_tool_catalog() async throws {
    let root = try makeTempRoot("list-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let alias = try await tools.dispatch(tool: "list_tools", input: [:], surface: "telegram")
    guard case .object(let obj) = alias else {
        Issue.record("expected list_tools object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(obj["runtime"] == .string("swift-native"))
    guard case .array(let names)? = obj["available_tools"] else {
        Issue.record("expected available_tools")
        return
    }
    #expect(names.contains(.string("tool_catalog")))
    #expect(names.contains(.string("list_tools")))
    #expect(names.contains(.string("tool_load")))
    #expect(names.contains(.string("context_lookup")))
    #expect(names.contains(.string("scratchpad_read")))
    #expect(names.contains(.string("recent_trace_summary")))
    #expect(names.contains(.string("search_chat_history")))
    #expect(names.contains(.string("session_search")))
}

@Test
func swiftToolDispatcher_search_chat_history_finds_ranked_session_snippets() async throws {
    let root = try makeTempRoot("search-chat-history")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeChatSessionsJSON(root, sessions: [
        ["id": "alpha", "title": "Coffee lead", "createdAt": "2026-06-01T10:00:00Z"],
        ["id": "beta", "title": "Memory work", "createdAt": "2026-06-02T10:00:00Z"],
    ])
    try writeMessagesJSONL(root, sessionId: "alpha", lines: [
        try chatMessageLine(role: "user", content: "We should check Verve Coffee Roasters again.", createdAt: "2026-06-01T10:00:01Z"),
        try chatMessageLine(role: "assistant", content: "I will search the market notes.", createdAt: "2026-06-01T10:00:02Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "beta", lines: [
        try chatMessageLine(role: "user", content: "Make recall natural and add session search.", createdAt: "2026-06-02T10:00:01Z"),
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "search_chat_history",
        input: ["query": .string("Verve Coffee")],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let hits)? = obj["hits"],
          case .object(let first)? = hits.first else {
        Issue.record("expected chat history search hits")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["source"] == .string("chat_history_jsonl"))
    #expect(first["session_id"] == .string("alpha"))
    #expect(first["session_title"] == .string("Coffee lead"))
    #expect(first["role"] == .string("user"))
    guard case .string(let preview)? = first["preview"] else {
        Issue.record("expected preview")
        return
    }
    #expect(preview.contains("Verve Coffee Roasters"))
}

@Test
func swiftToolDispatcher_search_chat_history_defaults_current_session_first() async throws {
    let root = try makeTempRoot("search-current-first")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMessagesJSONL(root, sessionId: "current", lines: [
        try chatMessageLine(role: "user", content: "The silver compass belongs in this active chat.", createdAt: "2026-06-01T10:00:01Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "older", lines: [
        try chatMessageLine(role: "user", content: "The silver compass appears in an older chat too.", createdAt: "2026-06-02T10:00:01Z"),
        try chatMessageLine(role: "assistant", content: "The orchard note is only in the older chat.", createdAt: "2026-06-02T10:00:02Z"),
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)

    let currentFirst = try await tools.dispatch(
        tool: "search_chat_history",
        input: [
            "query": .string("silver compass"),
            "current_session_id": .string("current"),
        ],
        surface: "chat"
    )
    guard case .object(let currentObj) = currentFirst,
          case .array(let currentHits)? = currentObj["hits"],
          case .object(let firstCurrent)? = currentHits.first else {
        Issue.record("expected current-session-first hits")
        return
    }
    #expect(currentObj["scope"] == .string("auto"))
    #expect(currentObj["phase"] == .string("current_session"))
    #expect(currentObj["fallback_skipped"] == .string("all_sessions"))
    #expect(currentObj["searched_session_count"] == .int(1))
    #expect(firstCurrent["session_id"] == .string("current"))

    let broad = try await tools.dispatch(
        tool: "search_chat_history",
        input: [
            "query": .string("orchard"),
            "current_session_id": .string("current"),
            "scope": .string("all_sessions"),
        ],
        surface: "chat"
    )
    guard case .object(let broadObj) = broad,
          case .array(let broadHits)? = broadObj["hits"],
          case .object(let firstBroad)? = broadHits.first else {
        Issue.record("expected all-session hits")
        return
    }
    #expect(broadObj["phase"] == .string("all_sessions"))
    #expect(firstBroad["session_id"] == .string("older"))
}

@Test
func swiftToolDispatcher_session_search_alias_can_scope_to_one_session() async throws {
    let root = try makeTempRoot("session-search-alias")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMessagesJSONL(root, sessionId: "alpha", lines: [
        try chatMessageLine(role: "user", content: "Find honk shoo in this session.", createdAt: "2026-06-01T10:00:01Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "beta", lines: [
        try chatMessageLine(role: "user", content: "Another honk shoo mention that should be out of scope.", createdAt: "2026-06-02T10:00:01Z"),
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)

    let load = try await tools.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string("alpha"),
            "names": .array([.string("session_search")]),
        ],
        surface: "telegram"
    )
    guard case .object(let loadObj) = load else {
        Issue.record("expected session_search load result")
        return
    }
    #expect(loadObj["loaded"] == .array([.string("session_search")]))

    let result = try await tools.dispatch(
        tool: "session_search",
        input: [
            "query": .string("honk shoo"),
            "session_id": .string("alpha"),
        ],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let hits)? = obj["hits"],
          case .object(let first)? = hits.first else {
        Issue.record("expected scoped session_search hit")
        return
    }
    #expect(obj["tool"] == .string("session_search"))
    #expect(obj["searched_session_count"] == .int(1))
    #expect(first["session_id"] == .string("alpha"))
}

@Test
func swiftToolDispatcher_context_lookup_uses_swift_context_module() async throws {
    let root = try makeTempRoot("context-lookup")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "context_lookup",
        input: ["query": .string("memory")],
        surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected context_lookup object")
        return
    }
    #expect(obj["status"] == .string("ready"))
    #expect(obj["type"] == .string("lookup_feature_surface"))
    guard case .array(let features)? = obj["features"] else {
        Issue.record("expected feature-surface records")
        return
    }
    #expect(!features.isEmpty)
}

@Test
func swiftToolDispatcher_scratchpad_read_reads_session_scratch_json() async throws {
    let root = try makeTempRoot("scratchpad-read")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = "telegram:12345"
    let scratchPath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
        .appendingPathComponent("scratch.json")
    try FileManager.default.createDirectory(
        at: scratchPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONValue.object([
        "plan": .string("ship swift"),
        "count": .int(2),
    ]).serializedData(pretty: true).write(to: scratchPath)

    let tools = SwiftToolDispatcher(dataRoot: root)
    let all = try await tools.dispatch(
        tool: "scratchpad_read",
        input: ["session_id": .string(sessionID)],
        surface: "telegram"
    )
    guard case .object(let allObj) = all,
          case .array(let keys)? = allObj["keys"],
          case .object(let entries)? = allObj["entries"] else {
        Issue.record("expected scratchpad_read entries")
        return
    }
    #expect(allObj["found"] == .bool(true))
    #expect(keys.contains(.string("plan")))
    #expect(entries["plan"] == .string("ship swift"))

    let one = try await tools.dispatch(
        tool: "scratchpad_read",
        input: [
            "session_id": .string(sessionID),
            "key": .string("plan"),
        ],
        surface: "telegram"
    )
    guard case .object(let oneObj) = one else {
        Issue.record("expected keyed scratchpad_read object")
        return
    }
    #expect(oneObj["found"] == .bool(true))
    #expect(oneObj["value"] == .string("ship swift"))
}

@Test
func swiftToolDispatcher_recent_trace_summary_omits_raw_payload_values() async throws {
    let root = try makeTempRoot("recent-traces")
    defer { try? FileManager.default.removeItem(at: root) }
    let lane = TurnTracePersistLane(dataRootOverride: root)
    await lane.append(TurnTraceEvent(
        turnId: "t1",
        kind: "research.run",
        payload: .object([
            "status": .string("completed"),
            "secret": .string("RAW_SECRET_NEVER_RETURN"),
            "sourceCount": .int(2),
        ])
    ))
    await lane.append(TurnTraceEvent(
        turnId: "t2",
        kind: "dream.rem",
        payload: .object([
            "status": .string("completed"),
            "body": .string("RAW_DREAM_BODY_NEVER_RETURN"),
        ])
    ))

    let tools = SwiftToolDispatcher(dataRoot: root)
    let result = try await tools.dispatch(
        tool: "recent_trace_summary",
        input: ["kind": .string("research"), "limit": .int(10)],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let traces)? = obj["traces"],
          case .object(let trace)? = traces.first,
          case .array(let payloadKeys)? = trace["payload_keys"] else {
        Issue.record("expected trace summary")
        return
    }
    #expect(obj["count"] == .int(1))
    #expect(trace["turn_id"] == .string("t1"))
    #expect(payloadKeys.contains(.string("secret")))
    let rendered = String(data: try result.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!rendered.contains("RAW_SECRET_NEVER_RETURN"))
    #expect(!rendered.contains("RAW_DREAM_BODY_NEVER_RETURN"))
}

@Test
func swiftToolDispatcher_recent_trace_summary_schema_supports_session_aliases() async throws {
    let root = try makeTempRoot("recent-traces-schema")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()
    let schema = try #require(schemas.first { $0.name == "recent_trace_summary" })
    let parsed = try JSONValue.parse(schema.parametersJSON)
    guard case .object(let object) = parsed,
          case .object(let properties)? = object["properties"] else {
        Issue.record("expected recent_trace_summary object schema")
        return
    }
    #expect(properties["session_id"] != nil)
    #expect(properties["sessionId"] != nil)
}

@Test
func swiftToolDispatcher_builderMessageSchemasExposeConversationReplies() async throws {
    let root = try makeTempRoot("builder-conversation-schemas")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()
    for name in ["invoke_codex", "codex_message"] {
        let schema = try #require(schemas.first { $0.name == name })
        let decoded = try #require(JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any])
        let properties = try #require(decoded["properties"] as? [String: [String: Any]])
        let models = try #require(properties["model"]?["enum"] as? [String])
        #expect(models.contains("gpt-6-astra"))
        #expect(!models.contains("gpt-6"))
    }
    for toolName in ["codex_message", "claude_message", "omp_message"] {
        let schema = try #require(schemas.first { $0.name == toolName })
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let object) = parsed,
              case .object(let properties)? = object["properties"] else {
            Issue.record("expected \(toolName) object schema")
            continue
        }
        #expect(properties["conversation_id"] != nil)
        #expect(schema.description.contains("conversationId"))
    }
}

@Test
func swiftToolDispatcher_codexSchemasAdvertiseTheExactCurrentModelIDs() async throws {
    let root = try makeTempRoot("codex-model-schemas")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()
    for toolName in ["invoke_codex", "codex_message"] {
        let schema = try #require(schemas.first { $0.name == toolName })
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let object) = parsed,
              case .object(let properties)? = object["properties"],
              case .object(let model)? = properties["model"],
              case .array(let values)? = model["enum"] else {
            Issue.record("expected \(toolName) model enum")
            continue
        }
        #expect(values == OpenAIExecutionControls.codexBridgeModelIDs.map(JSONValue.string))
    }
}

@Test
func swiftToolDispatcher_tool_load_reports_context_trace_scratch_tools() async throws {
    let root = try makeTempRoot("tool-load-context")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("context")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected context tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("context_lookup")))
    #expect(loaded.contains(.string("scratchpad_read")))
    #expect(loaded.contains(.string("recent_trace_summary")))
}

@Test
func swiftToolDispatcher_tool_load_reports_memory_and_session_search_tools() async throws {
    let root = try makeTempRoot("tool-load-memory")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("memory")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected memory tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("recall_memory")))
    #expect(loaded.contains(.string("recall_search")))
    #expect(loaded.contains(.string("search_kg")))
    #expect(loaded.contains(.string("search_chat_history")))
    #expect(loaded.contains(.string("session_search")))
}

@Test
func swiftToolDispatcher_tool_load_categoryWithSession_persistsTools() async throws {
    let root = try makeTempRoot("tool-load-category-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "test-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")
    defer { try? FileManager.default.removeItem(at: activePath) }

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "category": .string("markets"),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"],
          case .array(let schemasAdded)? = obj["schemas_added"] else {
        Issue.record("expected persisted category load object")
        return
    }
    #expect(obj["status"] == .string("loaded"))
    #expect(loaded.contains(.string("market_status")))
    #expect(schemasAdded.contains { row in
        guard case .object(let rowObj) = row else { return false }
        return rowObj["name"] == .string("market_status") && rowObj["parameters"] != nil
    })

    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(state.activeTools.contains("market_status"))
    let schemas = try await tools.listAvailableToolSchemas(activeTools: state.activeTools)
    #expect(schemas.contains { $0.name == "market_status" })
}

@Test
func swiftToolDispatcher_turnActiveToolsAllowsLazyDispatchWithoutPersisting() async throws {
    let root = try makeTempRoot("turn-active-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
    let sessionId = "turn-active-\(UUID().uuidString)"

    let blocked = try await tools.dispatch(
        tool: "market_status",
        input: ["__session_id": .string(sessionId)],
        surface: "chat"
    )
    guard case .object(let blockedObj) = blocked else {
        Issue.record("expected not_loaded object")
        return
    }
    #expect(blockedObj["reason"] == .string("not_loaded"))

    let allowed = try await LLMCallContext.$turnActiveTools.withValue(["market_status"]) {
        try await tools.dispatch(
            tool: "market_status",
            input: ["__session_id": .string(sessionId)],
            surface: "chat"
        )
    }
    guard case .object(let allowedObj) = allowed else {
        Issue.record("expected market_status object")
        return
    }
    #expect(allowedObj["runtime"] == .string("swift-native"))
    #expect(allowedObj["reason"] == nil)

    // 2026-07-21 audit: assert against the temp-root store the dispatcher
    // under test owns; ActiveToolsStore.shared.load sweeps the LIVE dir.
    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(!state.activeTools.contains("market_status"))
}

@Test
func swiftToolDispatcher_toolLoadSkipsPersistingTurnActiveTools() async throws {
    let root = try makeTempRoot("tool-load-turn-active")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "tool-load-turn-active-\(UUID().uuidString)"

    let result = try await LLMCallContext.$turnActiveTools.withValue(["market_status"]) {
        try await tools.dispatch(
            tool: "tool_load",
            input: [
                "session_id": .string(sessionId),
                "names": .array([.string("market_status")]),
            ],
            surface: "chat"
        )
    }
    guard case .object(let obj) = result,
          case .array(let loadedNow)? = obj["loaded_now"],
          case .array(let alreadyActive)? = obj["already_active"],
          case .array(let turnActive)? = obj["turn_active"] else {
        Issue.record("expected tool_load object with active arrays")
        return
    }
    #expect(obj["status"] == .string("loaded"))
    #expect(loadedNow.isEmpty)
    #expect(alreadyActive.contains(.string("market_status")))
    #expect(turnActive.contains(.string("market_status")))
    #expect(obj["session_active_count"] == .int(0))

    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(!state.activeTools.contains("market_status"))
}

@Test
func swiftToolDispatcher_toolCatalogReportsTurnActiveToolsWithoutPersisting() async throws {
    let root = try makeTempRoot("tool-catalog-turn-active")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "tool-catalog-turn-active-\(UUID().uuidString)"

    let result = try await LLMCallContext.$turnActiveTools.withValue(["market_status"]) {
        try await tools.dispatch(
            tool: "tool_catalog",
            input: ["session_id": .string(sessionId)],
            surface: "chat"
        )
    }
    guard case .object(let obj) = result,
          case .array(let currentlyLoaded)? = obj["currently_loaded"],
          case .array(let discoveryOnly)? = obj["discovery_only_tools"],
          case .array(let turnActive)? = obj["turn_active_tools"] else {
        Issue.record("expected tool_catalog active arrays")
        return
    }
    #expect(currentlyLoaded.contains(.string("market_status")))
    #expect(!discoveryOnly.contains(.string("market_status")))
    #expect(turnActive.contains(.string("market_status")))

    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(!state.activeTools.contains("market_status"))
}

@Test
func swiftToolDispatcher_tool_load_reports_builder_gap_truthfully() async throws {
    let root = try makeTempRoot("tool-load-builder")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("builder")],
        surface: "telegram"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected tool_load object")
        return
    }
    #expect(obj["status"] == .string("partial"))
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["builder_mode"] == .string("policy_locked"))
    #expect(obj["full_mac_active"] == .bool(false))
    guard case .array(let loaded)? = obj["loaded"],
          case .array(let unavailable)? = obj["unavailable"],
          case .array(let activeTools)? = obj["active_tools"] else {
        Issue.record("expected loaded, unavailable, and active_tools arrays")
        return
    }
    #expect(unavailable.contains(.string("shell")))
    #expect(unavailable.contains(.string("git")))
    #expect(!unavailable.contains(.string("write_file")))
    #expect(loaded.contains(.string("write_file")))
    #expect(!activeTools.contains(.string("list_tools")))
    #expect(activeTools.contains(.string("tool_catalog")))
    #expect(activeTools.contains(.string("tool_load")))
    #expect(activeTools.contains(.string("write_file")))
}

@Test
func swiftToolDispatcher_trustedWorkspaceRootsExposeAllObsidianVaults() async throws {
    let repo = try makeTempRoot("trusted-obsidian-root")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    let obsidianRoot = repo.appendingPathComponent("Obsidian Documents", isDirectory: true)
    let codexVault = obsidianRoot.appendingPathComponent("Codex", isDirectory: true)
    let claudeVault = obsidianRoot.appendingPathComponent("Claude code", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexVault, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeVault, withIntermediateDirectories: true)
    try "codex start".write(
        to: codexVault.appendingPathComponent("00 Start Here.md"),
        atomically: true,
        encoding: .utf8
    )
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("balanced"),
        "filePolicy": .object([
            "workspaceRoots": .array([.string(obsidianRoot.path)]),
            "outsideWorkspaceDefault": .string("deny"),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let names = try await tools.listAvailableTools()
    #expect(names.contains("write_file"))

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "telegram")
    guard case .object(let catalogObj) = catalog,
          case .array(let trustedRoots)? = catalogObj["trusted_workspace_roots"] else {
        Issue.record("expected trusted_workspace_roots in tool catalog")
        return
    }
    #expect(trustedRoots.contains(.string(obsidianRoot.path)))
    let canonicalWorkspace = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
    #expect(trustedRoots.contains(.string(canonicalWorkspace.path)))

    _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
    let workspaceWrite = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string("workspace/demo.txt"),
            "content": .string("canonical workspace"),
        ],
        surface: "telegram"
    )
    guard case .object(let workspaceWriteObject) = workspaceWrite else {
        Issue.record("expected canonical workspace write receipt")
        return
    }
    #expect(workspaceWriteObject["ok"] == .bool(true))
    #expect(try String(
        contentsOf: canonicalWorkspace.appendingPathComponent("demo.txt"),
        encoding: .utf8
    ) == "canonical workspace")

    let list = try await tools.dispatch(
        tool: "list_dir",
        input: ["path": .string(obsidianRoot.path)],
        surface: "telegram"
    )
    guard case .array(let vaults) = list else {
        Issue.record("expected vault list")
        return
    }
    #expect(vaults.contains(.string("Codex")))
    #expect(vaults.contains(.string("Claude code")))

    let read = try await tools.dispatch(
        tool: "read_file",
        input: ["path": .string(codexVault.appendingPathComponent("00 Start Here.md").path)],
        surface: "telegram"
    )
    #expect(read == .string("codex start"))

    let target = claudeVault.appendingPathComponent("handoff.md")
    let writeResult = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string(target.path),
            "content": .string("shared note"),
        ],
        surface: "telegram"
    )
    guard case .object(let writeObj) = writeResult else {
        Issue.record("expected write_file object")
        return
    }
    #expect(writeObj["ok"] == .bool(true))
    #expect((try? String(contentsOf: target, encoding: .utf8)) == "shared note")
}

@Test
func swiftToolDispatcher_trustedWorkspaceWriteRejectsOutsideRootWithoutFullMac() async throws {
    let repo = try makeTempRoot("trusted-obsidian-reject")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    let obsidianRoot = repo.appendingPathComponent("Obsidian Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: obsidianRoot, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("balanced"),
        "filePolicy": .object([
            "workspaceRoots": .array([.string(obsidianRoot.path)]),
            "outsideWorkspaceDefault": .string("deny"),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let target = repo.appendingPathComponent("outside.md")
    do {
        _ = try await tools.dispatch(
            tool: "write_file",
            input: [
                "path": .string(target.path),
                "content": .string("blocked"),
            ],
            surface: "telegram"
        )
        Issue.record("expected write_file outside trusted workspace root to be blocked")
    } catch AutonomyGateError.toolDenied(let reason) {
        #expect(reason.contains("outside trusted workspace roots"))
    }
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@Test
func swiftToolDispatcher_market_status_sanitizes_configured_sources() async throws {
    let root = try makeTempRoot("market-status")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMarketSecrets(root)
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(tool: "market_status", input: [:], surface: "chat")
    guard case .object(let obj) = result else {
        Issue.record("expected market_status object")
        return
    }
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["markets_configured"] == .bool(true))
    #expect(obj["tradingview_configured"] == .bool(true))
    guard case .array(let sources)? = obj["sources"],
          case .array(let watchlists)? = obj["watchlists"],
          case .object(let tv)? = obj["tradingview"] else {
        Issue.record("expected sources/watchlists/tradingview")
        return
    }
    #expect(sources.contains { item in
        guard case .object(let row) = item else { return false }
        return row["id"] == .string("finnhub")
            && row["enabled"] == .bool(true)
            && row["has_secret"] == .bool(true)
    })
    #expect(watchlists.contains { item in
        guard case .object(let row) = item else { return false }
        return row["id"] == .string("crypto") && row["symbol_count"] == .int(2)
    })
    #expect(tv["plan"] == .string("pro"))
    #expect(tv["has_session_cookie"] == .bool(true))
    #expect(tv["has_auth_token"] == .bool(true))

    let rendered = String(data: try result.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!rendered.contains("FINNHUB_TEST_KEY_NEVER_RETURN"))
    #expect(!rendered.contains("TV_SESSION_NEVER_RETURN"))
    #expect(!rendered.contains("TV_AUTH_TOKEN_NEVER_RETURN"))
}

@Test
func swiftToolDispatcher_market_watchlists_reads_local_groups() async throws {
    let root = try makeTempRoot("market-watchlists")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMarketSecrets(root)
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "market_watchlists",
        input: ["group": .string("crypto")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let watchlists)? = obj["watchlists"],
          case .object(let row)? = watchlists.first,
          case .array(let symbols)? = row["symbols"] else {
        Issue.record("expected crypto watchlist row")
        return
    }
    #expect(obj["source"] == .string("local"))
    #expect(row["id"] == .string("crypto"))
    #expect(symbols == [.string("BTC-USD"), .string("ETH-USD")])
}

@Test
func swiftToolDispatcher_tool_load_reports_market_tools() async throws {
    let root = try makeTempRoot("tool-load-market")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("markets")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected market tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("market_status")))
    #expect(loaded.contains(.string("market_watchlists")))
    #expect(loaded.contains(.string("tradingview_watchlist")))
    #expect(loaded.contains(.string("market_quote")))
}

@Test
func swiftToolDispatcher_tool_load_reports_agentmail_tools() async throws {
    let root = try makeTempRoot("tool-load-agentmail")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)
    let sessionId = "agentmail-\(UUID().uuidString)"

    let catalog = try await tools.dispatch(
        tool: "tool_catalog",
        input: ["session_id": .string(sessionId)],
        surface: "chat"
    )
    guard case .object(let catalogObj) = catalog,
          case .array(let discoveryOnly)? = catalogObj["discovery_only_tools"],
          case .array(let currentlyLoaded)? = catalogObj["currently_loaded"] else {
        Issue.record("expected catalog arrays")
        return
    }
    #expect(discoveryOnly.contains(.string("agentmail_list")))
    #expect(discoveryOnly.contains(.string("agentmail_read")))
    #expect(discoveryOnly.contains(.string("agentmail_send")))
    #expect(!currentlyLoaded.contains(.string("agentmail_list")))
    #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("agentmail_list"))

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "category": .string("agentmail"),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"],
          case .array(let schemasAdded)? = obj["schemas_added"] else {
        Issue.record("expected agentmail tool_load object")
        return
    }
    #expect(obj["status"] == .string("loaded"))
    #expect(loaded.contains(.string("agentmail_list")))
    #expect(loaded.contains(.string("agentmail_read")))
    #expect(loaded.contains(.string("agentmail_send")))
    #expect(schemasAdded.contains { row in
        guard case .object(let rowObj) = row else { return false }
        return rowObj["name"] == .string("agentmail_send") && rowObj["parameters"] != nil
    })
}

@Test
func swiftToolDispatcher_tool_load_reports_slack_tools() async throws {
    let root = try makeTempRoot("tool-load-slack")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("slack")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected slack tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("slack_status")))
    #expect(loaded.contains(.string("slack_list_channels")))
    #expect(loaded.contains(.string("slack_search_messages")))
    #expect(loaded.contains(.string("slack_post_message")))
    #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("slack_post_message"))
}

@Test
func swiftToolDispatcher_tool_load_reports_github_tools() async throws {
    let root = try makeTempRoot("tool-load-github")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "tool_load",
        input: ["category": .string("github")],
        surface: "telegram"
    )
    guard case .object(let obj) = result,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected github tool_load object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(loaded.contains(.string("github_status")))
    #expect(loaded.contains(.string("github_list_repos")))
    #expect(loaded.contains(.string("github_list_notifications")))
    #expect(loaded.contains(.string("github_get_repository")))
    #expect(loaded.contains(.string("github_read_repository_content")))
    #expect(loaded.contains(.string("github_list_commits")))
    #expect(loaded.contains(.string("github_list_issues")))
    #expect(loaded.contains(.string("github_search")))
    #expect(loaded.contains(.string("github_list_pull_requests")))
    #expect(loaded.contains(.string("github_get_issue")))
    #expect(loaded.contains(.string("github_get_pull_request")))
    #expect(loaded.contains(.string("github_pull_request_files")))
    #expect(loaded.contains(.string("github_pull_request_activity")))
    #expect(loaded.contains(.string("github_discover_tracking")))
    #expect(loaded.contains(.string("github_project_digest")))
    #expect(loaded.contains(.string("github_mutate")))
    #expect(loaded.contains(.string("github_set_repo_visibility")))
    #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("github_list_repos"))
}

@Test
func swiftToolDispatcher_agentmailSendStagingFailsWhenUnconfigured() async throws {
    let root = try makeTempRoot("agentmail-send-direct")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = SwiftToolDispatcher(dataRoot: root)

    let result = try await tools.dispatch(
        tool: "agentmail_send",
        input: [
            "to": .string("user@example.com"),
            "subject": .string("Direct test"),
            "body": .string("This should attempt Agent's AgentMail send path."),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected AgentMail send result")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(obj["actionId"] == .string("agentmail.send"))
    #expect(obj["error"] == .string("agentmail_not_configured"))

    let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .all)
    #expect(approvals.isEmpty)
}

@Test
func autonomyGate_agentmailSendStagingWithApprovalPolicy() async throws {
    let root = try makeTempRoot("agentmail-send-gated-direct")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTrustPolicy(root, .object([
        "toolAutonomy": .object([
            "agentmail.send": .string("send_approval"),
            "agentmail_send": .string("send_approval"),
        ]),
    ]))
    let tools = SwiftToolDispatcher(dataRoot: root)
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))
    let gated = AutonomyGatedDispatcher(
        inner: tools,
        gate: gate,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root)
    )

    let result = try await gated.dispatch(
        tool: "agentmail_send",
        input: [
            "to": .string("user@example.com"),
            "subject": .string("Gated approval test"),
            "body": .string("This should stage through the autonomy wrapper."),
        ],
        surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected AgentMail approval staging result")
        return
    }

    #expect(obj["status"] == .string("failed"))
    #expect(obj["actionId"] == .string("agentmail.send"))
    #expect(obj["error"] == .string("agentmail_not_configured"))
    let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .all)
    #expect(approvals.isEmpty)
}

@Test
func swiftToolDispatcher_fullMacTrust_exposes_builder_and_mac_app_tools() async throws {
    let repo = try makeTempRoot("full-mac-builder")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "requireBackupBeforeWrite": .bool(false),
            "allowDestructiveActions": .bool(true),
        ]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "accessibility_allowed": .bool(true),
            "shell_allowed": .bool(true),
            "remote_from_ios_allowed": .bool(true),
            "approval_required_for": .array([]),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let names = try await tools.listAvailableTools()
    #expect(names.contains("write_file"))
    #expect(names.contains("grep"))
    #expect(names.contains("git_status"))
    #expect(names.contains("repo_dirty_summary"))
    #expect(names.contains("system_info"))
    #expect(names.contains("restart_app"))
    #expect(names.contains("install_app"))
    #expect(names.contains("mac_focus_app"))
    #expect(names.contains("mac_quit_app"))

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "telegram")
    guard case .object(let catalogObj) = catalog else {
        Issue.record("expected catalog object")
        return
    }
    #expect(catalogObj["builder_mode"] == .string("available"))
    #expect(catalogObj["full_mac_active"] == .bool(true))
    #expect(catalogObj["app_control_allowed"] == .bool(true))
    if case .array(let builderTools)? = catalogObj["builder_available_tools"] {
        #expect(builderTools.contains(.string("restart_app")))
        #expect(builderTools.contains(.string("install_app")))
    } else {
        Issue.record("expected builder_available_tools array")
    }
    if case .array(let appTools)? = catalogObj["mac_app_available_tools"] {
        // Legacy app routes remain dispatchable above, but conversational
        // discovery exposes the native four verbs, not schema-less aliases.
        #expect(appTools.isEmpty)
    } else {
        Issue.record("expected mac_app_available_tools array")
    }
    guard case .array(let modelTools)? = catalogObj["available_tools"] else {
        Issue.record("expected available_tools array")
        return
    }
    for name in ["screen", "act", "go", "wait"] {
        #expect(modelTools.contains(.string(name)))
    }
    #expect(!modelTools.contains(.string("mac_focus_app")))
    #expect(!modelTools.contains(.string("mac_quit_app")))

    let target = repo
        .appendingPathComponent("outside-workspace", isDirectory: true)
        .appendingPathComponent("note.txt")
    let writeResult = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string(target.path),
            "content": .string("full mac swift write"),
        ],
        surface: "telegram"
    )
    guard case .object(let writeObj) = writeResult else {
        Issue.record("expected write_file object")
        return
    }
    #expect(writeObj["ok"] == .bool(true))
    #expect((try? String(contentsOf: target, encoding: .utf8)) == "full mac swift write")

    let readResult = try await tools.dispatch(
        tool: "read_file",
        input: ["path": .string(target.path)],
        surface: "telegram"
    )
    #expect(readResult == .string("full mac swift write"))

    let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
    let gate = AutonomyGate(trust: trust)
    #expect(try await gate.autonomyLevel(toolName: "write_file", surface: "telegram", originTrusted: true) == "auto")
    #expect(try await gate.autonomyLevel(toolName: "git_status", surface: "telegram", originTrusted: true) == "auto")
    #expect(try await gate.autonomyLevel(toolName: "mac_focus_app", surface: "telegram", originTrusted: true) == "auto")
    for surface in ["chat", "telegram", "ios", "icloud", "iphone", "ipad", "mobile", "watch"] {
        #expect(try await gate.autonomyLevel(toolName: "install_app", surface: surface, originTrusted: true) == "auto")
        #expect(try await gate.autonomyLevel(toolName: "restart_app", surface: surface, originTrusted: true) == "auto")
    }
}

@Test
func swiftToolDispatcher_iOSFullMacRequiresRemoteIOSPolicy() async throws {
    let repo = try makeTempRoot("full-mac-ios-remote")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "requireBackupBeforeWrite": .bool(false),
            "allowDestructiveActions": .bool(true),
        ]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "accessibility_allowed": .bool(true),
            "remote_from_ios_allowed": .bool(false),
            "approval_required_for": .array([]),
        ]),
    ]))

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let target = repo
        .appendingPathComponent("outside-workspace", isDirectory: true)
        .appendingPathComponent("ios-remote-note.txt")

    do {
        _ = try await tools.dispatch(
            tool: "write_file",
            input: [
                "path": .string(target.path),
                "content": .string("should not write"),
            ],
            surface: "ios"
        )
        Issue.record("expected iOS Full Mac write_file to respect remote_from_ios_allowed=false")
    } catch AutonomyGateError.toolDenied(let reason) {
        #expect(reason.contains("outside trusted workspace roots"))
    }
    #expect(!FileManager.default.fileExists(atPath: target.path))

    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "ios")
    guard case .object(let catalogObj) = catalog else {
        Issue.record("expected catalog object")
        return
    }
    #expect(catalogObj["full_mac_active"] == .bool(true))
    #expect(catalogObj["file_ops_allowed"] == .bool(false))
    #expect(catalogObj["builder_mode"] == .string("policy_locked"))

    let localWrite = try await tools.dispatch(
        tool: "write_file",
        input: [
            "path": .string(target.path),
            "content": .string("local write allowed"),
        ],
        surface: "chat"
    )
    guard case .object(let localObj) = localWrite else {
        Issue.record("expected local write_file object")
        return
    }
    #expect(localObj["ok"] == .bool(true))

    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: with remote_from_ios_allowed=false the
    // AUTONOMY gate also refused to auto-allow write_file on the "ios" surface,
    // as a second layer behind the file-ops gate. NEW CONTRACT: the untrusted
    // remote origin still fails the Full-Mac branch, but the fall-through lands
    // on the `default: auto` catch-all, so the autonomy layer returns .allow on
    // both surfaces. The enforcement that actually stops the remote write is
    // the MacControl file-ops gate asserted above — the write throws and the
    // file does not exist. Autonomy is no longer a second layer here.
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: dataRoot))
    #expect(try await gate.decide(toolName: "write_file", surface: "ios") == .allow)
    #expect(try await gate.decide(toolName: "write_file", surface: "chat") == .allow)
    // TEETH: a remote surface without authenticated origin evidence does not
    // inherit admitted YOLO authority for a self-install action.
    if case .allow = try await gate.decide(toolName: "self_install", surface: "ios") {
        Issue.record("untrusted iOS origin must not inherit Full Mac YOLO")
    }
}

@Test
func swiftToolDispatcher_lists_and_reads_persona_skill_bodies() async throws {
    let repo = try makeTempRoot("skills-repo")
    defer { try? FileManager.default.removeItem(at: repo) }
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    let bodyDir = repo
        .appendingPathComponent("persona", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("bodies", isDirectory: true)
    let dataSkillBodyDir = dataRoot
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("bodies", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bodyDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataSkillBodyDir, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\n".write(
        to: repo.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("script", isDirectory: true),
        withIntermediateDirectories: true
    )
    try "#!/usr/bin/env bash\n".write(
        to: repo.appendingPathComponent("script/init_persona.sh"),
        atomically: true,
        encoding: .utf8
    )
    try "# Template\n".write(
        to: repo.appendingPathComponent("persona/SOUL.template.md"),
        atomically: true,
        encoding: .utf8
    )
    try "# Fixture\n".write(
        to: repo.appendingPathComponent("persona/SOUL.md"),
        atomically: true,
        encoding: .utf8
    )
    try """
    # Demo Skill

    Use this when Swift skill discovery needs a body fallback.
    """
    .write(to: bodyDir.appendingPathComponent("demo-skill.md"), atomically: true, encoding: .utf8)
    try """
    # Dirty Skill

    Use this when the python daemon should be loaded.
    """
    .write(to: bodyDir.appendingPathComponent("dirty-skill.md"), atomically: true, encoding: .utf8)
    let dirtyRegistryBody = dataSkillBodyDir.appendingPathComponent("dirty-registry.md")
    try """
    # Dirty Registry

    Use this when the python daemon should be loaded.
    """
    .write(to: dirtyRegistryBody, atomically: true, encoding: .utf8)
    let registry: JSONValue = .array([
        .object([
            "id": .string("dirty-registry"),
            "name": .string("dirty-registry"),
            "bodyPath": .string(dirtyRegistryBody.path),
        ]),
    ])
    try registry.serializedData(pretty: false).write(
        to: dataRoot.appendingPathComponent("skills/registry.json")
    )

    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let listed = try await tools.dispatch(tool: "list_skills", input: [:], surface: "chat")
    guard case .array(let rows) = listed else {
        Issue.record("expected skill rows")
        return
    }
    #expect(rows.contains { row in
        guard case .object(let obj) = row else { return false }
        return obj["name"] == .string("demo-skill")
            && obj["source"] == .string("persona_body")
    })
    #expect(!rows.contains { row in
        guard case .object(let obj) = row else { return false }
        return obj["name"] == .string("dirty-skill")
    })
    #expect(!rows.contains { row in
        guard case .object(let obj) = row else { return false }
        return obj["name"] == .string("dirty-registry")
    })

    let body = try await tools.dispatch(
        tool: "read_skill",
        input: ["name": .string("demo-skill")],
        surface: "chat"
    )
    guard case .string(let text) = body else {
        Issue.record("expected skill body text")
        return
    }
    #expect(text.contains("Swift skill discovery"))

    await #expect(throws: (any Error).self) {
        _ = try await tools.dispatch(
            tool: "read_skill",
            input: ["name": .string("dirty-skill")],
            surface: "chat"
        )
    }
}

// EVAL FENCE: core.chat.persistence
// Ledger row: chat.persistence.outcomeDimensionStates
//
// This is the canonical accepted-turn path: admission, provider execution,
// durable assistant persistence, then a reload of the exact outcome bytes.

private func chatMessageLine(
    id: String = UUID().uuidString,
    role: String,
    content: String,
    createdAt: String
) throws -> String {
    let data = try JSONValue.object([
        "id": .string(id),
        "role": .string(role),
        "content": .string(content),
        "createdAt": .string(createdAt),
    ]).serializedData(pretty: false)
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func writeMarketSecrets(_ root: URL) throws {
    let dir = root.appendingPathComponent("secrets", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try """
    {
      "_about": "test market config",
      "sources": {
        "finnhub": {"enabled": true, "key": "FINNHUB_TEST_KEY_NEVER_RETURN"},
        "coingecko": {"enabled": true},
        "fred": {"enabled": false, "key": "FRED_TEST_KEY_NEVER_RETURN"}
      },
      "watchlists": {
        "equities": {"symbols": ["SPY", "AAPL", "NVDA"]},
        "crypto": ["BTC-USD", "ETH-USD"]
      },
      "chat_binding": {"channel": "telegram"}
    }
    """.write(to: dir.appendingPathComponent("markets.json"), atomically: true, encoding: .utf8)
    try """
    {
      "_about": "test tradingview config",
      "plan": "pro",
      "capabilities": ["custom watchlist read", "scanner quote/technical snapshot"],
      "sessionid": "TV_SESSION_NEVER_RETURN",
      "sessionid_sign": "TV_SESSION_SIGN_NEVER_RETURN",
      "auth_token": "TV_AUTH_TOKEN_NEVER_RETURN",
      "jwt_expires_at": "2026-03-19T19:53:37Z",
      "watchlist_endpoint": "https://www.tradingview.com/api/v1/symbols_list/custom/",
      "scanner_endpoint": "https://scanner.tradingview.com/global/scan"
    }
    """.write(to: dir.appendingPathComponent("tradingview.json"), atomically: true, encoding: .utf8)
}

// End-to-end: an image attachment on chat() reaches the LLM as a NATIVE .image
// content block on the first user message (not a stringified mention).

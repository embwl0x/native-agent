import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore

@Test func optionalBooleanSchemasKeepNullDistinctFromFalse() throws {
    let schemas = BuiltInToolSchemaFactory(requestedNames: nil).schemas(
        includeFullMacFileTools: true, includeFullMacSystemTools: true,
        includeFullMacAppTools: true, includeFullMacAccessibilityReadTools: true,
        includeFullMacAccessibilityInjectionTools: true, includeActivityQueryTool: true)
    for (name, field) in [
        ("swift_build", "disable_swiftpm_sandbox"), ("swift_test", "disable_swiftpm_sandbox"),
        ("apply_patch", "three_way"), ("github_discover_tracking", "persist"),
        ("github_project_digest", "refresh"), ("market_watchlists", "includeSymbols"),
        ("tradingview_watchlist", "includeSymbols"), ("agent_swarm", "synthesize"),
        ("studio_canon", "include_proposals"), ("bot_create", "fast"), ("bot_update", "fast")
    ] {
        let schema = try #require(schemas.first { $0.name == name })
        let root = try #require(JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any])
        var properties = try #require(root["properties"] as? [String: [String: Any]])
        if name == "bot_update" {
            properties = try #require(properties["fields"]?["properties"] as? [String: [String: Any]])
        }
        #expect(properties[field]?["type"] as? [String] == ["boolean", "null"])
    }
}

@Test func toolSchemaUpgradeRefreshesCodeOwnedPinsOnlyAtTurnBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("mcp"), withIntermediateDirectories: true)
    try Data(#"[{"id":"server","status":"ready"}]"#.utf8)
        .write(to: root.appendingPathComponent("mcp/servers.json"))
    let session = "schema-upgrade"
    let names: Set<String> = ["mac_calendar_modify_event", "app_owned_probe", "mcp__server__probe"]
    func schemas(_ version: String) -> [LLMToolSchema] {
        names.sorted().map {
            LLMToolSchema(name: $0, description: version, parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8))
        }
    }
    let old = schemas("old")
    let store = ActiveToolsStore(dataRoot: root)
    _ = try await store.addLoaded(sessionId: session, names: names,
        descriptors: Dictionary(uniqueKeysWithValues: old.map { ($0.name, PinnedToolSchema($0)) }))
    let first = try #require(await store.commitTurnStartContract(sessionId: session, promoting: [], catalog: old))
    let generation = first.state.declarationGeneration
    // Simulate a relaunch: a new store sees the persisted old contract, not a
    // fresh session. Reading does not change the in-flight/frozen descriptor.
    let relaunched = ActiveToolsStore(dataRoot: root)
    #expect(await relaunched.load(sessionId: session).pinnedSchemas["mac_calendar_modify_event"]?.description == "old")
    let current = schemas("new")
    let refreshed = try #require(await relaunched.commitTurnStartContract(
        sessionId: session, promoting: [], catalog: current,
        codeOwnedToolNames: ["mac_calendar_modify_event", "app_owned_probe"]))
    for name in ["mac_calendar_modify_event", "app_owned_probe"] {
        #expect(refreshed.state.pinnedSchemas[name]?.description == "new")
        #expect(refreshed.state.declaredSchemas?[name]?.description == "new")
    }
    #expect(first.state.declaredSchemas?["mac_calendar_modify_event"]?.description == "old")
    #expect(refreshed.state.declaredSchemas?["mcp__server__probe"]?.description == "new")
    #expect(refreshed.state.pinnedSchemas["mcp__server__probe"]?.description == "new")
    #expect(refreshed.state.declarationGeneration == (generation ?? 0) + 1)
    let unchanged = try #require(await relaunched.commitTurnStartContract(
        sessionId: session, promoting: [], catalog: current,
        codeOwnedToolNames: ["mac_calendar_modify_event", "app_owned_probe"]))
    #expect(unchanged.state.declarationGeneration == refreshed.state.declarationGeneration)
    #expect(!unchanged.declarationRepinned)
}

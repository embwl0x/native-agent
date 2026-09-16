import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore

@Test func toolSchemaUpgradeRefreshesCodeOwnedPinsOnlyAtTurnBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
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
    #expect(refreshed.state.declaredSchemas?["mcp__server__probe"]?.description == "old")
    #expect(refreshed.state.declarationGeneration == (generation ?? 0) + 1)
    let unchanged = try #require(await relaunched.commitTurnStartContract(
        sessionId: session, promoting: [], catalog: current,
        codeOwnedToolNames: ["mac_calendar_modify_event", "app_owned_probe"]))
    #expect(unchanged.state.declarationGeneration == refreshed.state.declarationGeneration)
    #expect(!unchanged.declarationRepinned)
}

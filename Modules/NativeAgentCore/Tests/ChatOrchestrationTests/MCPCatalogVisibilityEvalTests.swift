import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MCPDispatcher

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger rows closed here:
//   • chat.tools.mcp.internalServerHiding          (leak or hole)
//   • chat.tools.modelVisibleMCPTools              (self-protocol loop)
//   • chat.tools.mcpToolSchemas.permissiveFallback (wrong value, silent)
//
// The literal "nativeagent-internal" is duplicated across TWO functions with no
// shared constant. Drop it from one and NativeAgent advertises its own native
// tools back to its own model over an MCP hop; drop it from the other and the
// hidden set stops matching. Both are silent — the calls still succeed.
// ─────────────────────────────────────────────────────────────────────────────

private struct MCPEvalRoot {
    let dataRoot: URL

    static func make() throws -> MCPEvalRoot {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPCatalogEval-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let mcpRoot = dataRoot.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mcpRoot.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true
        )

        let servers = """
        [
          {"id": "nativeagent-internal", "status": "ready", "riskClass": "app_data_read"},
          {"id": "thirdparty", "status": "ready", "riskClass": "app_data_read"}
        ]
        """
        try Data(servers.utf8).write(to: mcpRoot.appendingPathComponent("servers.json"))

        // `remote_schemaful` declares an inputSchema; `remote_schemaless` does
        // not (the partial-handshake / schema-format-change shape).
        let cache = """
        {
          "nativeagent-internal": {
            "tools": [{"name": "self_echo", "description": "internal echo",
                       "inputSchema": {"type": "object", "properties": {"q": {"type": "string"}}}}]
          },
          "thirdparty": {
            "tools": [
              {"name": "remote_schemaful", "description": "has a schema",
               "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}},
                               "required": ["query"], "additionalProperties": false}},
              {"name": "remote_schemaless", "description": "cache row lost its schema"}
            ]
          }
        }
        """
        try Data(cache.utf8).write(
            to: mcpRoot.appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("tools.json")
        )
        return MCPEvalRoot(dataRoot: dataRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent())
    }
}

private let internalBridgedName = "mcp__nativeagent-internal__self_echo"
private let thirdPartySchemaful = "mcp__thirdparty__remote_schemaful"
private let thirdPartySchemaless = "mcp__thirdparty__remote_schemaless"

/// The internal/model split must be REAL, not accidental: every model-facing
/// catalog builder excludes the internal server, while the operator-facing
/// `listAvailableTools()` still knows about it. Asserting BOTH halves is what
/// makes this non-vacuous — a build where nothing lists anything would fail the
/// third-party expectations.
@Test func mcpCatalog_internalServerIsHiddenFromEveryModelFacingBuilder() async throws {
    let root = try MCPEvalRoot.make()
    defer { root.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: root.dataRoot)

    let visibleNames = dispatcher.modelVisibleMCPToolNames()
    #expect(!visibleNames.contains(internalBridgedName), "modelVisibleMCPTools leaked the internal server")
    #expect(visibleNames.contains(thirdPartySchemaful))
    #expect(visibleNames.contains(thirdPartySchemaless))

    let schemaNames = dispatcher.mcpToolSchemas().map(\.name)
    #expect(!schemaNames.contains(internalBridgedName), "mcpToolSchemas leaked the internal server")
    #expect(schemaNames.contains(thirdPartySchemaful))
    #expect(schemaNames.contains(thirdPartySchemaless))

    let modelNames = await dispatcher.modelVisibleToolNames()
    #expect(!modelNames.contains(internalBridgedName), "modelVisibleToolNames leaked the internal server")
    #expect(modelNames.contains(thirdPartySchemaful))

    // The OPERATOR-facing catalog still carries it. If this expectation ever
    // fails, the hiding moved from "not advertised to the model" to "gone",
    // which breaks the Tools tab and the MCP UI rather than the model.
    let allNames = try await dispatcher.listAvailableTools()
    #expect(
        allNames.contains(internalBridgedName),
        "the internal server must still exist for the operator catalog — hiding it from the MODEL is the contract, not deleting it"
    )
}

/// The permissive fallback is admitted in the source comment: "the LLM has to
/// guess argument names for those". A cache row that loses its inputSchema does
/// not error — it degrades to a free-form object and the failure later looks
/// like the model being stupid.
///
/// KNOWN GAP recorded rather than asserted away: nothing in the emitted schema
/// MARKS the row as schema-unknown, so a genuinely argument-free tool that
/// declared `additionalProperties: true` would be byte-identical to a lossy
/// one. Making a fallback observable needs a production change (see
/// productionSeamNeeded). What this eval pins today is that a schemaful row is
/// never silently replaced by the fallback — that direction IS a wrong value
/// the model acts on.
@Test func mcpCatalog_schemalessRowFallsBackPermissivelyAndSchemafulRowIsPreserved() throws {
    let root = try MCPEvalRoot.make()
    defer { root.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: root.dataRoot)
    let schemas = dispatcher.mcpToolSchemas()

    let schemaful = try #require(schemas.first { $0.name == thirdPartySchemaful })
    guard case .object(let schemafulObject) = try JSONValue.parse(schemaful.parametersJSON) else {
        Issue.record("schemaful parameters must parse to an object")
        return
    }
    guard case .object(let properties)? = schemafulObject["properties"] else {
        Issue.record("declared properties were dropped: \(schemafulObject)")
        return
    }
    #expect(properties["query"] != nil, "a declared argument name must survive into the model's schema")
    #expect(schemafulObject["required"] == .array([.string("query")]))
    #expect(
        schemafulObject["additionalProperties"] == .bool(false),
        "a strict server's strictness must reach the model — silently loosening it invites rejected calls"
    )

    let schemaless = try #require(schemas.first { $0.name == thirdPartySchemaless })
    guard case .object(let schemalessObject) = try JSONValue.parse(schemaless.parametersJSON) else {
        Issue.record("schemaless parameters must parse to an object")
        return
    }
    #expect(schemalessObject["type"] == .string("object"))
    #expect(schemalessObject["properties"] == .object([:]))
    #expect(
        schemalessObject["additionalProperties"] == .bool(true),
        "the fallback must stay permissive — a strict empty schema would make every call to that tool fail"
    )

    // Description still identifies the tool, so a fallback row is at least
    // traceable back to its server by hand.
    #expect(schemaless.description.isEmpty == false)
}

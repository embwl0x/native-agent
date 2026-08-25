import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.MCPHub.toolInputForm
@MainActor
@Suite("MCP Hub tool input form", .serialized)
struct MCPHubToolInputFormEvalTests {
    @Test("valid schema-shaped values preserve JSON types through the live MCP call owner")
    func validValuesAreAcceptedWithTheirActualTypes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try seedNativeServer(root: root)
        let schema = inputSchema()
        let tool = MCPToolRecord(name: "production.summary", description: "Fixture", inputSchema: schema)
        let values: [String: JSONValue] = [
            "query": .string("calendar"),
            "limit": .int(3),
            "includeCancelled": .bool(false),
        ]

        #expect(MCPInputSchemaForm.validationMessage(schema: schema, values: values) == nil)
        let foundation = MCPInputSchemaForm.toFoundationDict(values)
        #expect(foundation["query"] as? String == "calendar")
        #expect(foundation["limit"] as? Int64 == 3)
        #expect(foundation["includeCancelled"] as? Bool == false)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.callMCPToolWithInput(server: server, tool: tool, input: values)
        let call = try #require(app.latestMCPCall)
        #expect(call.serverId == server.id)
        #expect(call.toolName == tool.name)
        #expect(call.status != "failed")
    }

    @Test("form validation and call owner refuse missing or malformed schema input before a call is created")
    func formAndCallOwnerRefuseInvalidInputWithoutMakingAnMCPCall() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let server = fixtureServer()
        let tool = MCPToolRecord(name: "fixture.search", description: "Fixture", inputSchema: inputSchema())
        let missing = MCPInputSchemaForm.validationMessage(schema: tool.inputSchema, values: [:])
        #expect(missing?.contains("Enter a value for required field ‘query’") == true)

        await app.callMCPToolWithInput(server: server, tool: tool, input: [:])
        #expect(app.statusText.contains("MCP input refused"))
        #expect(app.statusText.contains("Enter a value for required field ‘query’"))
        #expect(app.latestMCPCall == nil)

        let malformed: JSONValue = .object([
            "type": .string("object"),
            "properties": .string("not an object"),
        ])
        let refusal = MCPInputSchemaForm.validationMessage(schema: malformed, values: [:])
        #expect(refusal?.contains("malformed properties") == true)
        let malformedTool = MCPToolRecord(name: "fixture.malformed", description: nil, inputSchema: malformed)
        await app.callMCPToolWithInput(server: server, tool: malformedTool, input: [:])
        #expect(app.statusText.contains("malformed properties"))
        #expect(app.latestMCPCall == nil)
        #expect(MCPInputSchemaForm.validationMessage(
            schema: inputSchema(),
            values: ["query": .int(4)]
        )?.contains("must be string") == true)
    }

    private func fixtureServer() -> MCPServerRecord {
        MCPServerRecord(
            id: "fixture-native-server",
            name: "Fixture native server",
            transport: "native",
            endpoint: "nativeagent://internal",
            command: nil,
            status: "ready",
            healthStatus: "ok",
            toolCount: 1,
            resourceCount: 0,
            riskClass: "app_data_read",
            updatedAt: nil
        )
    }

    private func seedNativeServer(root: URL) throws -> MCPServerRecord {
        let server = fixtureServer()
        let record: [String: Any] = [
            "id": server.id,
            "name": server.name,
            "transport": "native",
            "endpoint": "nativeagent://internal",
            "status": "ready",
            "healthStatus": "ok",
            "toolCount": 1,
            "resourceCount": 0,
            "riskClass": "app_data_read",
        ]
        let path = root.appendingPathComponent("mcp/servers.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [record], options: [.sortedKeys])
            .write(to: path, options: .atomic)
        return server
    }

    private func inputSchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "required": .array([.string("query")]),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(10),
                ]),
                "includeCancelled": .object(["type": .string("boolean")]),
            ]),
        ])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-hub-tool-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}

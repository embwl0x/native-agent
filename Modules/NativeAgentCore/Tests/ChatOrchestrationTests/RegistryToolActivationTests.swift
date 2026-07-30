import Testing
import Foundation
import NativeAgentCore
import ToolExecution
import PersistenceCore
@testable import ChatOrchestration

// R9: the custom-tool activation gap. Registry tools from
// data/tools/registry.json were catalog-visible by NAME but had no schema and
// no dispatch route — the LLM could see and tool_load one, then every call
// died with not_in_dispatch_table. These tests pin the closed gap end-to-end
// AND its seatbelts (gpt-5.5 review round 1): the Full-Mac shell-class gate,
// fail-closed on unsigned tools, and reserved built-in names never shadowed.
@Suite struct RegistryToolActivationTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegistryActivation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Full-Mac trust policy so the dispatch-time file_ops gate opens
    /// (mirrors EvolutionChatToolsTests).
    private func seedFullMac(_ dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
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
        ])
        try policy.serializedData(pretty: true)
            .write(to: dir.appendingPathComponent("policy.json"))
    }

    private func activeToolDir(_ root: URL, id: String) -> URL {
        root.appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Writes the active tool dir (manifest + optional entrypoint), computes
    /// the REAL code fingerprint, and returns it.
    @discardableResult
    private func seedActiveTool(
        _ root: URL,
        id: String,
        entrypointBody: String?
    ) throws -> String {
        let dir = activeToolDir(root, id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": id,
            "description": "Echoes its input back.",
            "entrypoint": "tool.swift",
            "inputSchema": [
                "type": "object",
                "properties": ["message": ["type": "string"]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: dir.appendingPathComponent("manifest.json"))
        if let body = entrypointBody {
            try Data(body.utf8).write(to: dir.appendingPathComponent("tool.swift"))
        }
        return computeToolCodeFingerprint(toolRoot: dir, entrypointName: "tool.swift")
    }

    private func writeRegistry(_ root: URL, records: [[String: Any]]) throws {
        let toolsDir = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: records)
            .write(to: toolsDir.appendingPathComponent("registry.json"))
    }

    // MARK: dispatch routing + seatbelts

    @Test func gateClosedReturnsFullMacRequiredEnvelope() async throws {
        let root = try makeRoot() // no trust policy — file_ops gate closed
        let fp = try seedActiveTool(root, id: "echo_tool", entrypointBody: "print(\"{}\")")
        try writeRegistry(root, records: [
            ["id": "echo_tool", "name": "echo_tool", "status": "active", "createdAt": "2026-07-01T00:00:00Z", "codeFingerprint": fp],
        ])
        let result = try await SwiftToolDispatcher(dataRoot: root)
            .dispatch(tool: "echo_tool", input: [:], surface: "chat")
        guard case .object(let obj) = result else {
            Issue.record("expected envelope"); return
        }
        #expect(obj["reason"] == .string("trust_center_full_mac_required"))
    }

    @Test func unsignedToolFailsClosed() async throws {
        let root = try makeRoot()
        try seedFullMac(root)
        // Active tool, real entrypoint — but NO fingerprint in the registry
        // record or manifest.
        _ = try seedActiveTool(root, id: "echo_tool", entrypointBody: "print(\"{}\")")
        try writeRegistry(root, records: [
            ["id": "echo_tool", "name": "echo_tool", "status": "active", "createdAt": "2026-07-01T00:00:00Z"],
        ])
        let result = try await SwiftToolDispatcher(dataRoot: root)
            .dispatch(tool: "echo_tool", input: [:], surface: "chat")
        guard case .object(let obj) = result else {
            Issue.record("expected envelope"); return
        }
        #expect(obj["reason"] == .string("unsigned_tool"))
    }

    @Test func nonActiveRegistryToolRoutesToExecutionEngineNotDispatchTableDenial() async throws {
        let root = try makeRoot()
        try seedFullMac(root)
        try writeRegistry(root, records: [
            ["id": "parked_tool", "name": "parked_tool", "status": "proposed", "createdAt": "2026-07-01T00:00:00Z", "codeFingerprint": "deadbeef"],
        ])
        // parked_tool passes the gate + signature checks but is not active.
        // Pre-R9 this threw "not in the dispatch table"; now it must reach
        // ToolExecution and fail on the ACTIVE-STATUS gate — the route exists.
        do {
            _ = try await SwiftToolDispatcher(dataRoot: root)
                .dispatch(tool: "parked_tool", input: [:], surface: "chat")
            Issue.record("expected parked_tool to throw")
        } catch let error as ToolRunError {
            guard case .toolNotActive(let id, let status) = error else {
                Issue.record("expected toolNotActive, got \(error)"); return
            }
            #expect(id == "parked_tool")
            #expect(status == "proposed")
        }
    }

    @Test func unknownToolStillFailsHonestlyAsNotInDispatchTable() async throws {
        let root = try makeRoot()
        do {
            _ = try await SwiftToolDispatcher(dataRoot: root)
                .dispatch(tool: "no_such_tool_anywhere", input: [:], surface: "chat")
            Issue.record("expected unknown tool to throw")
        } catch let error as AutonomyGateError {
            guard case .toolDenied(let reason) = error else {
                Issue.record("expected toolDenied, got \(error)"); return
            }
            #expect(reason.contains("not in the dispatch table"))
        }
    }

    @Test func activeRegistryToolRunsEndToEndThroughDispatch() async throws {
        let root = try makeRoot()
        try seedFullMac(root)
        let body = """
        print("{\\"ok\\":true,\\"tool\\":\\"echo_tool\\"}")
        """
        let fp = try seedActiveTool(root, id: "echo_tool", entrypointBody: body)
        try writeRegistry(root, records: [
            ["id": "echo_tool", "name": "echo_tool", "status": "active", "createdAt": "2026-07-01T00:00:00Z", "codeFingerprint": fp],
        ])
        let result = try await SwiftToolDispatcher(dataRoot: root)
            .dispatch(tool: "echo_tool", input: [:], surface: "chat")
        guard case .object(let obj) = result else {
            Issue.record("expected object envelope, got \(result)"); return
        }
        #expect(String(describing: obj).contains("echo_tool"))
        #expect(obj["status"] != nil)
    }

    @Test func swappedEntrypointAfterAdmissionFailsAsFingerprintMismatch() async throws {
        let root = try makeRoot()
        try seedFullMac(root)
        let fp = try seedActiveTool(root, id: "echo_tool", entrypointBody: "print(\"{}\")")
        try writeRegistry(root, records: [
            ["id": "echo_tool", "name": "echo_tool", "status": "active",
             "createdAt": "2026-07-01T00:00:00Z", "codeFingerprint": fp],
        ])
        // Simulate the TOCTOU: the code changes between the dispatcher's
        // fingerprint admission and the run. The admitted fingerprint is
        // threaded through, so the run must fail as a mismatch — never
        // execute the swapped code.
        let entrypoint = activeToolDir(root, id: "echo_tool").appendingPathComponent("tool.swift")
        try Data("print(\"{\\\"evil\\\":true}\")".utf8).write(to: entrypoint)
        do {
            _ = try await SwiftToolDispatcher(dataRoot: root)
                .dispatch(tool: "echo_tool", input: [:], surface: "chat")
            Issue.record("expected fingerprintMismatch")
        } catch let error as ToolRunError {
            guard case .fingerprintMismatch = error else {
                Issue.record("expected fingerprintMismatch, got \(error)"); return
            }
        }
    }

    // MARK: catalog + schema agreement

    @Test func registryNamesSurfaceInCatalog() async throws {
        let root = try makeRoot()
        try writeRegistry(root, records: [
            ["id": "echo_tool", "name": "echo_tool", "status": "active", "createdAt": "2026-07-01T00:00:00Z"],
            ["id": "parked_tool", "name": "parked_tool", "status": "proposed", "createdAt": "2026-07-01T00:00:00Z"],
        ])
        let names = try await SwiftToolDispatcher(dataRoot: root).listAvailableTools()
        #expect(names.contains("echo_tool"))
        #expect(names.contains("parked_tool"))
    }

    @Test func activeRegistryToolSurfacesManifestSchema() async throws {
        let root = try makeRoot()
        _ = try seedActiveTool(root, id: "echo_tool", entrypointBody: nil)
        try writeRegistry(root, records: [
            ["id": "echo_tool", "name": "echo_tool", "status": "active", "createdAt": "2026-07-01T00:00:00Z"],
            ["id": "parked_tool", "name": "parked_tool", "status": "proposed", "createdAt": "2026-07-01T00:00:00Z"],
        ])
        let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()
        let echo = try #require(schemas.first { $0.name == "echo_tool" })
        #expect(echo.description == "Echoes its input back.")
        let params = try JSONSerialization.jsonObject(with: echo.parametersJSON) as? [String: Any]
        #expect((params?["type"] as? String) == "object")
        #expect((params?["properties"] as? [String: Any])?["message"] != nil)
        // Non-active entries stay name-only — no schema for a tool that will
        // refuse to run.
        #expect(!schemas.contains { $0.name == "parked_tool" })
    }

    @Test func registrySchemasAreLazyInActiveToolsOverload() async throws {
        let root = try makeRoot()
        _ = try seedActiveTool(root, id: "echo_tool", entrypointBody: nil)
        try writeRegistry(root, records: [["id": "echo_tool", "name": "echo_tool", "status": "active", "createdAt": "2026-07-01T00:00:00Z"]])
        let d = SwiftToolDispatcher(dataRoot: root)
        let unloaded = try await d.listAvailableToolSchemas(activeTools: [])
        #expect(!unloaded.contains { $0.name == "echo_tool" })
        let loaded = try await d.listAvailableToolSchemas(activeTools: ["echo_tool"])
        #expect(loaded.contains { $0.name == "echo_tool" })
    }

    @Test func registryToolMayNeverShadowReservedBuiltInName() async throws {
        let root = try makeRoot()
        // A malicious/confused registry entry named "shell" with its own
        // manifest must never publish a schema — the dispatch switch matches
        // the built-in case first, so the schema would lie.
        _ = try seedActiveTool(root, id: "shell", entrypointBody: nil)
        try writeRegistry(root, records: [["id": "shell", "name": "shell", "status": "active", "createdAt": "2026-07-01T00:00:00Z"]])
        let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()
        // Full Mac is off in this root, so no built-in shell schema either —
        // and the registry copy must not sneak in as a stand-in.
        #expect(!schemas.contains { $0.name == "shell" })
    }
}

import Testing
import Foundation
@testable import ToolExecution
import NativeAgentCore
import PersistenceCore

// MARK: - factory routing

@Test func placeholderFactoryReturnsSwiftNativeByDefault() async throws {
    let impl = makeToolExecution()
    #expect(impl is SwiftNativeToolExecution)
}

@Test func placeholderFactoryReturnsSwiftNativeWhenEnabled() async throws {
    let impl = makeToolExecution()
    #expect(impl is SwiftNativeToolExecution)
}

// MARK: - ProposalRecord Codable round-trip

@Test func proposalRecord_roundtripsViaCodable_withExtras() throws {
    let rec = ProposalRecord(
        id: "tool-1",
        name: "Demo",
        description: "A test tool",
        manifest: .object(["entrypoint": .string("main.swift"), "language": .string("swift")]),
        riskClass: "low",
        permissions: ["app_data_read"],
        status: "proposed",
        createdAt: "2026-05-31T00:00:00+00:00",
        validatedAt: nil,
        validationErrors: nil,
        extras: .object(["autoCreated": .bool(true), "sourceRunId": .string("run-42")])
    )
    let encoder = JSONEncoder()
    let data = try encoder.encode(rec)
    let decoded = try JSONDecoder().decode(ProposalRecord.self, from: data)
    #expect(decoded == rec)
}

// MARK: - SwiftNative: disk read/write

private func seedActiveTool(
    root: URL,
    id: String,
    entrypointBody: String,
    activePathOverride: String? = nil
) throws -> String {
    let activeDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    let manifest: JSONValue = .object([
        "id": .string(id),
        "name": .string(id),
        "entrypoint": .string("tool.swift"),
        "timeoutSeconds": .int(10),
    ])
    try manifest.serializedData(pretty: true).write(to: activeDir.appendingPathComponent("manifest.json"))
    try Data(entrypointBody.utf8).write(to: activeDir.appendingPathComponent("tool.swift"))
    try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8).write(to: activeDir.appendingPathComponent("tests.json"))
    let fingerprint = computeToolCodeFingerprint(toolRoot: activeDir, entrypointName: "tool.swift")
    let registryPath = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    let activePath = activePathOverride ?? activeDir.path
    let record: JSONValue = .object([
        "id": .string(id),
        "name": .string(id),
        "status": .string("active"),
        "createdAt": .string("2026-06-03T00:00:00+00:00"),
        "updatedAt": .string("2026-06-03T00:00:00+00:00"),
        "activePath": .string(activePath),
        "codeFingerprint": .string(fingerprint),
    ])
    try JSONValue.array([record]).serializedData(pretty: true).write(to: registryPath)
    return fingerprint
}

@Test func swiftNative_createProposal_writesManifestToDiskAtomically() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("toolexec-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    let rec = try await exec.createProposal(.object([
        "id": .string("write-test"),
        "name": .string("Write Test"),
        "description": .string("checks disk write"),
        "riskClass": .string("low"),
        "permissions": .array([.string("app_data_read")]),
    ]))
    #expect(rec.id == "write-test")
    #expect(rec.status == "proposed")
    #expect(rec.description == "checks disk write")
    let manifestPath = tmp
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("proposals", isDirectory: true)
        .appendingPathComponent("write-test", isDirectory: true)
        .appendingPathComponent("manifest.json")
    #expect(FileManager.default.fileExists(atPath: manifestPath.path))
    let data = try Data(contentsOf: manifestPath)
    let parsed = try JSONValue.parse(data)
    guard case .object(let obj) = parsed,
          case .string(let id) = obj["id"] ?? .null else {
        Issue.record("manifest.json not parseable")
        return
    }
    #expect(id == "write-test")
}

@Test func swiftNative_listProposals_readsDataToolsProposalsDirectory() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("toolexec-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    _ = try await exec.createProposal(.object([
        "id": .string("alpha"), "name": .string("Alpha"),
    ]))
    _ = try await exec.createProposal(.object([
        "id": .string("beta"), "name": .string("Beta"),
    ]))
    let all = try await exec.listProposals()
    #expect(all.count == 2)
    #expect(Set(all.map(\.id)) == Set(["alpha", "beta"]))
    let one = try await exec.getProposal(id: "alpha")
    #expect(one?.name == "Alpha")
    let miss = try await exec.getProposal(id: "ghost")
    #expect(miss == nil)
}

// MARK: - Promoted tool run

@Test func runTool_activeRegistryRecord_executesSwiftTool() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecRun-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let body = """
    import Foundation
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "{}"
    print("{\\"ok\\":true,\\"result\\":{\\"echo\\":\\(raw)}}")
    """
    _ = try seedActiveTool(root: tmp, id: "echo_tool", entrypointBody: body)
    let exec = SwiftNativeToolExecution(root: tmp)
    let result = try await exec.runTool(
        id: "echo_tool",
        input: .object(["name": .string("Agent")])
    )
    guard case .object(let obj) = result else {
        Issue.record("runTool result was not an object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(obj["toolId"] == .string("echo_tool"))
    guard case .object(let runResult)? = obj["result"],
          case .object(let echo)? = runResult["echo"] else {
        Issue.record("runTool result did not expose parsed tool output")
        return
    }
    #expect(echo["name"] == .string("Agent"))
}

@Test func runTool_fingerprintDriftFailsClosed() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecRun-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    _ = try seedActiveTool(root: tmp, id: "drift_tool", entrypointBody: "print(\"{}\")\n")
    let entrypoint = tmp
        .appendingPathComponent("tools/active/drift_tool/tool.swift")
    try Data("print(\"{\\\"changed\\\":true}\")\n".utf8).write(to: entrypoint)
    let exec = SwiftNativeToolExecution(root: tmp)
    do {
        _ = try await exec.runTool(id: "drift_tool", input: .object([:]))
        Issue.record("expected fingerprint mismatch")
    } catch ToolRunError.fingerprintMismatch {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func runTool_rejectsActivePathEscape() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecRun-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecOutside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(at: outside)
    }
    _ = try seedActiveTool(
        root: tmp,
        id: "escape_tool",
        entrypointBody: "print(\"{}\")\n",
        activePathOverride: outside.path
    )
    let exec = SwiftNativeToolExecution(root: tmp)
    do {
        _ = try await exec.runTool(id: "escape_tool", input: .object([:]))
        Issue.record("expected activePath rejection")
    } catch let ToolExecutionError.underlying(message) {
        #expect(message.contains("activePath"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func runTool_unknownToolThrowsProposalNotFound() async throws {
    let exec = SwiftNativeToolExecution(root: URL(fileURLWithPath: "/tmp"))
    do {
        _ = try await exec.runTool(id: "x", input: .object([:]))
        Issue.record("expected throw")
    } catch ToolExecutionError.proposalNotFound {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}
@Test func promote_unknownProposal_mapsTo_proposalNotFound() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecPromoteWire-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    do {
        _ = try await exec.promote(id: "does-not-exist", allowRisky: false)
        Issue.record("expected throw")
    } catch ToolExecutionError.proposalNotFound {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func promote_traversalId_rejected_beforeAnyPathConstruction() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecPromoteTraversal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    // Plant a live "active" tool that a traversal id would resolve to —
    // pre-guard, promote("../active/x") removeItem'd this directory.
    let activeDir = tmp
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent("x", isDirectory: true)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    try Data("{\"id\":\"x\",\"name\":\"x\"}".utf8)
        .write(to: activeDir.appendingPathComponent("manifest.json"))
    let exec = SwiftNativeToolExecution(root: tmp)
    for evil in ["../active/x", "a/b", "..", "a\\b"] {
        do {
            _ = try await exec.promote(id: evil, allowRisky: true)
            Issue.record("expected invalidProposal for id \(evil)")
        } catch ToolExecutionError.invalidProposal {
            // ok
        } catch {
            Issue.record("wrong error for id \(evil): \(error)")
        }
    }
    // The planted active tool must have survived every attempt.
    #expect(FileManager.default.fileExists(atPath: activeDir.appendingPathComponent("manifest.json").path))
}

// MARK: - U5 W-B — validateProposal wired to the real SwiftToolValidator
//
// Pre-U5 this was a permissive stub: ANY readable manifest came back
// valid + autoPromotable. These tests pin the honest wiring.

/// Seed a proposal via createProposal, then stage entrypoint + tests.json
/// files into the proposal dir (createProposal only writes manifest.json).
private func seedValidatableProposal(
    exec: SwiftNativeToolExecution,
    root: URL,
    id: String,
    permissions: [String],
    entrypointBody: String = "print(\"{}\")\n",
    includeEntrypoint: Bool = true,
    includeTests: Bool = true
) async throws {
    _ = try await exec.createProposal(.object([
        "id": .string(id),
        "name": .string(id),
        "permissions": .array(permissions.map { .string($0) }),
    ]))
    let dir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("proposals", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    if includeEntrypoint {
        try Data(entrypointBody.utf8).write(to: dir.appendingPathComponent("tool.swift"))
    }
    if includeTests {
        try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8)
            .write(to: dir.appendingPathComponent("tests.json"))
    }
}

@Test func validateProposal_safeTool_valid_and_autoPromotable() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    try await seedValidatableProposal(exec: exec, root: tmp, id: "v_safe", permissions: ["app_data_read"])
    let result = try await exec.validateProposal(id: "v_safe", promote: false)
    #expect(result.valid)
    #expect(result.autoPromotable)
    #expect(result.errors.isEmpty)
}

@Test func validateProposal_missingTestsJson_invalid() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_no_tests",
        permissions: ["app_data_read"], includeTests: false
    )
    let result = try await exec.validateProposal(id: "v_no_tests", promote: false)
    #expect(!result.valid)
    #expect(!result.autoPromotable)
    #expect(result.errors.contains { $0.contains("tests.json") })
}

@Test func validateProposal_dangerousImport_invalid() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_danger",
        permissions: ["app_data_read"],
        entrypointBody: "import subprocess\nprint(\"{}\")\n"
    )
    let result = try await exec.validateProposal(id: "v_danger", promote: false)
    #expect(!result.valid)
    #expect(!result.autoPromotable)
    #expect(result.errors.contains { $0.contains("subprocess") })
}

@Test func validateProposal_unknownPermission_invalid() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_unknown_perm", permissions: ["root_everything"]
    )
    let result = try await exec.validateProposal(id: "v_unknown_perm", promote: false)
    #expect(!result.valid)
    #expect(!result.autoPromotable)
    #expect(result.errors.contains { $0.contains("unknown permissions") })
}

@Test func validateProposal_riskyKnownPermission_valid_but_not_autoPromotable() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    try await seedValidatableProposal(exec: exec, root: tmp, id: "v_shell", permissions: ["shell"])
    let result = try await exec.validateProposal(id: "v_shell", promote: false)
    #expect(result.valid)
    #expect(!result.autoPromotable)
}

@Test func validateProposal_unknownId_throws_proposalNotFound() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    do {
        _ = try await exec.validateProposal(id: "ghost", promote: false)
        Issue.record("expected proposalNotFound")
    } catch ToolExecutionError.proposalNotFound {
        // ok
    }
}

@Test func createProposal_traversalId_rejected() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecCreateTraversal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    do {
        _ = try await exec.createProposal(.object([
            "id": .string("../../escaped"),
            "name": .string("evil"),
        ]))
        Issue.record("expected invalidProposal")
    } catch ToolExecutionError.invalidProposal {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - Audit fix 2026-07-21 — Swift-shaped dangerous-symbol scan
//
// The validator's scan was Python-syntax-only while ToolRunSandbox executes
// `tool.swift` via /usr/bin/swift with NO sandbox-exec confinement. These
// tests pin the Swift rules (Python rules are covered above and unchanged).

@Test func validateProposal_swiftProcessSpawn_invalid() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_swift_spawn",
        permissions: ["app_data_read"],
        entrypointBody: "import Foundation\nlet p = Process()\nprint(\"{}\")\n"
    )
    let result = try await exec.validateProposal(id: "v_swift_spawn", promote: false)
    #expect(!result.valid)
    #expect(!result.autoPromotable)
    #expect(result.errors.contains { $0.contains("Process(") })
}

@Test func validateProposal_swiftDlopenAndDarwinImport_invalid() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_swift_dlopen",
        permissions: ["app_data_read"],
        entrypointBody: "import Darwin\nlet h = dlopen(\"/usr/lib/libc.dylib\", RTLD_NOW)\nprint(\"{}\")\n"
    )
    let result = try await exec.validateProposal(id: "v_swift_dlopen", promote: false)
    #expect(!result.valid)
    #expect(result.errors.contains { $0.contains("Darwin") })
    #expect(result.errors.contains { $0.contains("dlopen(") })
}

@Test func validateProposal_swiftFileManagerWrite_requiresWritePermission() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    let body = "import Foundation\ntry FileManager.default.removeItem(atPath: \"/tmp/x\")\nprint(\"{}\")\n"
    // Read-only permission set → the write must fail validation.
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_swift_write_denied",
        permissions: ["app_data_read"],
        entrypointBody: body
    )
    let denied = try await exec.validateProposal(id: "v_swift_write_denied", promote: false)
    #expect(!denied.valid)
    #expect(denied.errors.contains { $0.contains("removeItem(") })
    // A declared write permission clears the gate.
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_swift_write_allowed",
        permissions: ["app_data_write"],
        entrypointBody: body
    )
    let allowed = try await exec.validateProposal(id: "v_swift_write_allowed", promote: false)
    #expect(allowed.valid)
}

@Test func validateProposal_swiftLineComment_notScanned() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecValidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let exec = SwiftNativeToolExecution(root: tmp)
    // The old '#' -only comment strip left Swift `//` comments live in the
    // scan — a commented-out Process() must NOT fail validation.
    try await seedValidatableProposal(
        exec: exec, root: tmp, id: "v_swift_comment",
        permissions: ["app_data_read"],
        entrypointBody: "// let p = Process() // dlopen(\"x\", 0)\nprint(\"{}\")\n"
    )
    let result = try await exec.validateProposal(id: "v_swift_comment", promote: false)
    #expect(result.valid)
}

@Test func validator_containsSymbol_respectsWordBoundaries() {
    // `Subprocess(` must not match `Process(`; `Foundation.Process(` must.
    #expect(SwiftToolValidator.containsSymbol("let p = Process()", "Process("))
    #expect(SwiftToolValidator.containsSymbol("Foundation.Process()", "Process("))
    #expect(!SwiftToolValidator.containsSymbol("let s = Subprocess()", "Process("))
    #expect(!SwiftToolValidator.containsSymbol("print(\"{}\")", "Process("))
    #expect(SwiftToolValidator.containsSymbol("try FileManager.default.removeItem(atPath: p)", ".removeItem("))
}

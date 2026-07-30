import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

private func makeFullMacPathTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("full-mac-path-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFullMacPathTestPolicy(_ dataRoot: URL) throws {
    let trustDir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
    let policy: JSONValue = .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "allowDestructiveActions": .bool(true),
        ]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "accessibility_allowed": .bool(true),
            "remote_from_ios_allowed": .bool(true),
            "approval_required_for": .array([]),
        ]),
    ])
    try policy.serializedData(pretty: false)
        .write(to: trustDir.appendingPathComponent("policy.json"))
}

@Test func fullMacPathArgumentDocumentsAliasUsesCurrentHome() throws {
    let root = try makeFullMacPathTempRoot("alias")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)

    #expect(
        SwiftToolDispatcher.normalizeFullMacPathArgument(
            "/documents/agent subconscious",
            homeDirectory: home
        )
        == home.appendingPathComponent("Documents/agent subconscious").path
    )
    #expect(
        SwiftToolDispatcher.normalizeFullMacPathArgument("/Documents", homeDirectory: home)
        == home.appendingPathComponent("Documents", isDirectory: true).path
    )
    #expect(
        SwiftToolDispatcher.normalizeFullMacPathArgument("~/Desktop/note.txt", homeDirectory: home)
        == home.appendingPathComponent("Desktop/note.txt").path
    )
}

@Test func workspaceAliasAlwaysResolvesInsideCanonicalRoot() throws {
    let root = try makeFullMacPathTempRoot("workspace-alias")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)

    #expect(
        SwiftToolDispatcher.normalizeWorkspaceAlias(
            "workspace/demo/project.txt",
            workspaceRoot: workspace
        ) == workspace.appendingPathComponent("demo/project.txt").path
    )
    #expect(
        SwiftToolDispatcher.normalizeWorkspaceAlias(
            "~/Documents/project.txt",
            workspaceRoot: workspace
        ) == "~/Documents/project.txt"
    )
}

@Test func ordinaryRelativeWritePathDefaultsToCanonicalWorkspace() async throws {
    let dataRoot = try makeFullMacPathTempRoot("relative-workspace")
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot)

    let resolved = try await dispatcher.resolveTrustedFilePath(
        "project/output.txt",
        includeRepoSandbox: false
    )

    #expect(
        resolved.path
            == dataRoot.appendingPathComponent("workspace/project/output.txt").path
    )
}

@Test func fullMacPathCorrectionSuggestsCurrentHomeAndDropsFolderDescriptor() throws {
    let root = try makeFullMacPathTempRoot("suggestion")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("current-user", isDirectory: true)
    let actual = home
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("agent subconscious", isDirectory: true)
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)

    let suggested = SwiftToolDispatcher.suggestedFullMacPathCorrection(
        for: "/Users/legacy-user/Documents/agent subconscious folder",
        homeDirectory: home
    )

    #expect(suggested == actual.path)
}

@Test func fullMacReadFilePathMissReturnsStructuredResultNotTrustDenial() async throws {
    let root = try makeFullMacPathTempRoot("miss")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    try writeFullMacPathTestPolicy(dataRoot)
    let tools = SwiftToolDispatcher(dataRoot: dataRoot)

    let result = try await tools.dispatch(
        tool: "read_file",
        input: ["path": .string(root.appendingPathComponent("missing.txt").path)],
        surface: "chat"
    )

    guard case .object(let obj) = result else {
        Issue.record("expected structured file_not_found object")
        return
    }
    #expect(obj["ok"] == .bool(false))
    #expect(obj["error_code"] == .string("file_not_found"))
    #expect(obj["permission_denied"] == .bool(false))
    if case .string(let hint)? = obj["hint"] {
        #expect(hint.contains("not a Full Mac or Trust Center denial"))
    } else {
        Issue.record("expected path miss hint")
    }
}

@Test func personaPathMissRoutesToCanonicalPersonaToolWithoutWideningFileAccess() async throws {
    let root = try makeFullMacPathTempRoot("persona-hint")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let tools = SwiftToolDispatcher(dataRoot: dataRoot)

    let result = try await tools.dispatch(
        tool: "read_file",
        input: ["path": .string("persona/SOUL.md")],
        surface: "chat"
    )

    guard case .object(let object) = result else {
        Issue.record("expected structured file_not_found object")
        return
    }
    #expect(object["error_code"] == .string("file_not_found"))
    #expect(object["permission_denied"] == .bool(false))
    #expect(object["suggested_tool"] == .string("get_persona_doc"))
    #expect(object["suggested_input"] == .object(["doc": .string("SOUL")]))
    guard case .string(let hint)? = object["hint"] else {
        Issue.record("expected persona routing hint")
        return
    }
    #expect(hint.contains("do not retry read_file"))
    #expect(!FileManager.default.fileExists(
        atPath: dataRoot.appendingPathComponent("workspace/persona/SOUL.md").path
    ))
}

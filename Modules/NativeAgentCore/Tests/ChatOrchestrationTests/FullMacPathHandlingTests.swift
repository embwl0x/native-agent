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

@Test func internalMacToolsRemainDiscoverableButAreNotOfferedUnderFullMac() async throws {
    let root = try makeFullMacPathTempRoot("internal-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFullMacPathTestPolicy(root)
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let names = try await dispatcher.listAvailableTools()
    #expect(names.contains("mac_ax_tree"))
    #expect(names.contains("mac_attention"))
    #expect(SwiftToolDispatcher.modelVisibleCatalogToolNames(Set(names))
        .isDisjoint(with: SwiftToolDispatcher.legacyMacModelToolNames))
    #expect(names.contains("act") && names.contains("go") && names.contains("screen"))
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

@Test func fullMacReadFileExposesCompactContinuationAndPreservesCeiling() async throws {
    let root = try makeFullMacPathTempRoot("read-continuation")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    try writeFullMacPathTestPolicy(dataRoot)
    let tools = SwiftToolDispatcher(dataRoot: dataRoot)
    let handoff = root.appendingPathComponent("HANDOFF_CURRENT.md")
    let text = String(repeating: "handoff 🙂 line\n", count: 3_000)
    try Data(text.utf8).write(to: handoff)
    guard case .object(let first) = try await tools.impl_full_mac_read_file(
        input: ["path": .string(handoff.path)], surface: "chat"
    ), case .string(let head)? = first["content"], case .object(let next)? = first["next"] else {
        Issue.record("Missing Full Mac continuation metadata"); return
    }
    #expect(first["truncated"] == .bool(true))
    #expect(head.utf8.count <= 12_000)
    #expect(next["max_bytes"] == .int(12_000))
    var input = next
    var combined = head
    for _ in 0..<10 {
        guard case .object(let page) = try await tools.impl_full_mac_read_file(input: input, surface: "chat"),
              case .string(let content)? = page["content"] else { Issue.record("Missing Full Mac page"); return }
        combined += content
        guard case .object(let following)? = page["next"] else { break }
        input = following
    }
    #expect(combined == text)
    try Data("changed".utf8).write(to: handoff, options: .atomic)
    guard case .object(let changed) = try await tools.impl_full_mac_read_file(input: next, surface: "chat") else {
        Issue.record("Missing version refusal"); return
    }
    #expect(changed["error_code"] == .string("file_changed"))
    let large = root.appendingPathComponent("large.txt")
    try Data(repeating: 0x61, count: 220_000).write(to: large)
    guard case .object(let capped) = try await tools.impl_full_mac_read_file(
        input: ["path": .string(large.path), "max_bytes": .int(500_000)], surface: "chat"
    ) else { Issue.record("Missing capped window"); return }
    #expect(capped["returned_bytes"] == .int(200_000))
    #expect(capped["has_more"] == .bool(true))
}

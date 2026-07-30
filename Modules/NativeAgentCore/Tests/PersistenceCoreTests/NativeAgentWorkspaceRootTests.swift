import Foundation
import Testing
@testable import PersistenceCore

private func workspaceTestRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeWorkspaceTestRepo() throws -> (repo: URL, data: URL) {
    let repo = try workspaceTestRoot("NativeAgentWorkspaceRepo")
    let data = repo.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("persona", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("script", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try "fixture".write(
        to: repo.appendingPathComponent("persona/SOUL.template.md"),
        atomically: true,
        encoding: .utf8
    )
    try "fixture".write(
        to: repo.appendingPathComponent("script/init_persona.sh"),
        atomically: true,
        encoding: .utf8
    )
    try "// fixture".write(
        to: repo.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
    return (repo, data)
}

@Test func nativeAgentWorkspace_publicInstallLivesInsideDataRoot() throws {
    let dataRoot = try workspaceTestRoot("NativeAgentPublicData")
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    let resolved = NativeAgentWorkspaceRoot.resolve(
        dataRoot: dataRoot,
        environment: [:]
    )

    #expect(resolved == dataRoot.appendingPathComponent("workspace", isDirectory: true))
}

@Test func nativeAgentWorkspace_sourceInstallUsesRepoWorkspace() throws {
    let fixture = try makeWorkspaceTestRepo()
    defer { try? FileManager.default.removeItem(at: fixture.repo) }

    let resolved = NativeAgentWorkspaceRoot.resolve(
        dataRoot: fixture.data,
        environment: [:]
    )

    #expect(resolved == fixture.repo.appendingPathComponent("workspace", isDirectory: true))
}

@Test func nativeAgentWorkspace_explicitOverrideWinsAndExpandsTilde() throws {
    let dataRoot = try workspaceTestRoot("NativeAgentOverrideData")
    defer { try? FileManager.default.removeItem(at: dataRoot) }

    let resolved = NativeAgentWorkspaceRoot.resolve(
        dataRoot: dataRoot,
        environment: ["NATIVE_AGENT_WORKSPACE_ROOT": "~/NativeAgent Override"]
    )

    #expect(resolved.path == FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("NativeAgent Override", isDirectory: true).path)
}

@Test func nativeAgentWorkspace_prepareCreatesPrivateDirectory() throws {
    let parent = try workspaceTestRoot("NativeAgentPreparedDataParent")
    let dataRoot = parent.appendingPathComponent("NativeAgent", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let resolved = try NativeAgentWorkspaceRoot.prepare(
        dataRoot: dataRoot,
        environment: [:]
    )
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func nativeAgentWorkspace_prepareTightensExistingDirectory() throws {
    let dataRoot = try workspaceTestRoot("NativeAgentExistingWorkspace")
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let workspace = dataRoot.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(
        at: workspace,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: workspace.path
    )

    _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot, environment: [:])

    let attributes = try FileManager.default.attributesOfItem(atPath: workspace.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

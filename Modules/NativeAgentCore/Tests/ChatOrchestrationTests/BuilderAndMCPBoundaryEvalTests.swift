import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

private func boundaryTempRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func boundaryObject(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let object) = value else {
        throw BoundaryEvalError.expectedObject
    }
    return object
}

private enum BoundaryEvalError: Error { case expectedObject }

@Test func mcpForwardingStripsOnlyTheChatSessionMarker() {
    let ordinary: [String: JSONValue] = [
        "query": .string("weather"),
        "limit": .int(3),
        "nested": .object(["keep": .bool(true)]),
    ]
    var input = ordinary
    input["__session_id"] = .string("private-chat-routing-id")

    let forwarded = SwiftToolDispatcher.forwardedMCPArguments(input)

    #expect(forwarded["__session_id"] == nil)
    #expect(forwarded == ordinary)
}

@Test func builderAuditCoversNormalPreSpawnAndWriteFailure() async throws {
    let root = try boundaryTempRoot("builder-audit")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])

    let normal = try boundaryObject(await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/echo", args: ["ok"],
        cwd: workspace.path, timeoutSeconds: 10, dataRoot: root
    ))
    let normalRunID = try #require(normal["runId"]?.stringValue)
    let normalAudit = root.appendingPathComponent("builder_audit/\(normalRunID).json")
    #expect(normal["status"] == .string("completed"))
    #expect(FileManager.default.fileExists(atPath: normalAudit.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: normalAudit.deletingLastPathComponent().path) == ["\(normalRunID).json"])

    let outside = try boundaryTempRoot("outside-workspace")
    defer { try? FileManager.default.removeItem(at: outside) }
    let rejected = try boundaryObject(await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/echo", args: ["never"],
        cwd: outside.path, timeoutSeconds: 10, dataRoot: root
    ))
    let rejectedRunID = try #require(rejected["runId"]?.stringValue)
    let rejectedAudit = root.appendingPathComponent("builder_audit/\(rejectedRunID).json")
    let rejectedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: rejectedAudit)) as? [String: Any]
    #expect(rejectedJSON?["status"] as? String == "failed_pre_spawn")
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: rejectedAudit.deletingLastPathComponent().path)) == Set(["\(normalRunID).json", "\(rejectedRunID).json"]))

    let blockedRoot = try boundaryTempRoot("blocked-audit")
    defer { try? FileManager.default.removeItem(at: blockedRoot) }
    let blockedWorkspace = try NativeAgentWorkspaceRoot.prepare(dataRoot: blockedRoot, environment: [:])
    try Data("not a directory".utf8).write(to: blockedRoot.appendingPathComponent("builder_audit"))
    let auditFailure = try boundaryObject(await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/echo", args: ["still runs"],
        cwd: blockedWorkspace.path, timeoutSeconds: 10, dataRoot: blockedRoot
    ))
    #expect(auditFailure["status"] == .string("completed"))
    #expect(auditFailure["audit_error"]?.stringValue?.isEmpty == false)
}

@Test func swiftPMShimIsPrivateExecutableRepairingAndIdempotent() throws {
    let root = try boundaryTempRoot("swiftpm-shim")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try #require(SwiftToolDispatcher.builderSwiftPMShimDirectory(baseDirectory: root))
    let shim = directory.appendingPathComponent("swift")

    func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    #expect(try permissions(directory) & 0o777 == 0o700)
    #expect(try permissions(shim) & 0o777 == 0o755)
    #expect(FileManager.default.isExecutableFile(atPath: shim.path))

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    _ = try #require(SwiftToolDispatcher.builderSwiftPMShimDirectory(baseDirectory: root))
    #expect(try permissions(directory) & 0o777 == 0o700)

    try "stale".write(to: shim, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    _ = try #require(SwiftToolDispatcher.builderSwiftPMShimDirectory(baseDirectory: root))
    #expect(String(decoding: try Data(contentsOf: shim), as: UTF8.self).contains("--disable-sandbox"))

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: shim.path)
    let repairedDirectory = try #require(SwiftToolDispatcher.builderSwiftPMShimDirectory(baseDirectory: root))
    let repaired = try Data(contentsOf: repairedDirectory.appendingPathComponent("swift"))
    #expect(FileManager.default.isExecutableFile(atPath: shim.path))
    #expect(String(decoding: repaired, as: UTF8.self).contains("--disable-sandbox"))

    let secondDirectory = try #require(SwiftToolDispatcher.builderSwiftPMShimDirectory(baseDirectory: root))
    #expect(secondDirectory == repairedDirectory)
    #expect(try Data(contentsOf: shim) == repaired)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("swift.staged-") }
    #expect(leftovers.isEmpty)
}

@Test func builderTimeoutClampIsVisibleInTheReceipt() async throws {
    #expect(SwiftToolDispatcher.builderEffectiveTimeoutSeconds(-10) == 1)
    #expect(SwiftToolDispatcher.builderEffectiveTimeoutSeconds(7_200) == 3_600)

    let root = try boundaryTempRoot("builder-timeout")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])
    let envelope = try boundaryObject(await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/echo", args: ["clamp"],
        cwd: workspace.path, timeoutSeconds: 7_200, dataRoot: root
    ))
    #expect(envelope["timeout_seconds_effective"] == .int(3_600))
}

@Test(.timeLimit(.minutes(1)))
func builderTimeoutReapsTheBackgroundProcessGroup() async throws {
    let root = try boundaryTempRoot("builder-process-group")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeAgentWorkspaceRoot.prepare(dataRoot: root, environment: [:])
    // Full Mac disables the outer sandbox but does not change the watchdog;
    // that keeps this proof hermetic and focused on process-group cleanup.
    try await SwiftNativePersistenceCore().writeJSON(.object([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
    ]), to: root.appendingPathComponent("trust/policy.json"))
    let pidFile = workspace.appendingPathComponent("background.pid")
    let command = "sleep 60 & child=$!; echo $child > '\(pidFile.path)'; wait $child"
    let envelope = try boundaryObject(await SwiftToolDispatcher.runShellLikeProcess(
        toolName: "shell", executable: "/bin/sh", args: ["-c", command],
        cwd: workspace.path, timeoutSeconds: 1, dataRoot: root
    ))
    #expect(envelope["timeout_seconds_effective"] == .int(1))
    #expect(envelope["status"] == .string("timed_out"))
    #expect(envelope["timed_out"] == .bool(true))
    #expect(envelope["reason"] == .string("watchdog_timeout"))
    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(Int32(pidText))
    let deadline = Date().addingTimeInterval(5)
    while kill(pid, 0) == 0 && Date() < deadline { usleep(25_000) }
    #expect(kill(pid, 0) != 0, "background descendant \(pid) survived the watchdog")
}

private extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

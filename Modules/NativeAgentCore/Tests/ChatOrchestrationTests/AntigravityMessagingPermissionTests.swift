import Foundation
import Testing
@testable import ChatOrchestration

@Suite struct AntigravityMessagingPermissionTests {
    private func fixture(_ body: String) throws -> (URL, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings.json")
        try Data(body.utf8).write(to: file)
        return (root, file.path, root.appendingPathComponent("receipt.json"))
    }

    @Test func scopedGrantAndDisconnectRestoreExactOriginalBytes() throws {
        let original = "{\n // retain\n \"permissions\": {\"allow\": [\"command(git)\"], \"deny\": [\"command(rm)\"]}, \"theme\":\"dark\"\n}"
        let (root, path, record) = try fixture(original)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try AgentHostConfigWriter.grantAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written.contains("mcp(nativeagent/agent_message)"))
        #expect(written.contains("mcp(nativeagent/agent_reply)"))
        #expect(!written.contains("mcp(*)"))
        #expect(written.contains("\"deny\": [\"command(rm)\"]"))
        try AgentHostConfigWriter.removeAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
    }

    @Test func preexistingGrantAndLaterUnrelatedEditsSurviveDisconnect() throws {
        let (root, path, record) = try fixture("{\"permissions\":{\"allow\":[\"mcp(nativeagent/agent_message)\"]},\"theme\":\"dark\"}")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try AgentHostConfigWriter.grantAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        var value = try String(contentsOfFile: path, encoding: .utf8)
        value = value.replacingOccurrences(of: "\"theme\":\"dark\"", with: "\"theme\":\"light\"")
        try Data(value.utf8).write(to: URL(fileURLWithPath: path))
        try AgentHostConfigWriter.removeAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        let remaining = try String(contentsOfFile: path, encoding: .utf8)
        #expect(remaining.contains("mcp(nativeagent/agent_message)"))
        #expect(!remaining.contains("mcp(nativeagent/agent_reply)"))
        #expect(remaining.contains("\"theme\":\"light\""))
    }

    @Test(arguments: ["{\"permissions\":{\"allow\":42}}", "{\"permissions\":{\"ask\":[\"mcp(*)\"]}}", "{\"permissions\":{\"deny\":[\"mcp(nativeagent/*)\"]}}", "{\"permissions\":{\"allow\":[],\"allow\":[]}}"])
    func malformedOrConflictingAuthorityRemainsBytePreserved(body: String) throws {
        let (root, path, record) = try fixture(body)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Error.self) {
            try AgentHostConfigWriter.grantAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == body)
    }

    @Test(arguments: ["*", "mcp", "mcp(nativeagent)"])
    func ambiguousBroadRulesAreNotAssumedHarmless(rule: String) throws {
        let body = "{\"permissions\":{\"ask\":[\"\(rule)\"]}}"
        let (root, path, record) = try fixture(body)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Error.self) {
            try AgentHostConfigWriter.grantAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == body)
    }

    @Test(arguments: ["{", "{}", "{\"permissions\":{\"allow\":[],\"deny\":[\"mcp(*)\"]}}", "deleted"])
    func ownedPermissionsAreRevalidatedWithoutResurrectingChanges(replacement: String) throws {
        let (root, path, record) = try fixture("{}")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try AgentHostConfigWriter.grantAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        if replacement == "deleted" { try FileManager.default.removeItem(atPath: path) }
        else { try Data(replacement.utf8).write(to: URL(fileURLWithPath: path)) }
        #expect(throws: Error.self) {
            try AgentHostConfigWriter.grantAntigravityMessaging(path: path, server: "nativeagent", peerID: "peer", recordURL: record)
        }
        if replacement == "deleted" { #expect(!FileManager.default.fileExists(atPath: path)) }
        else { #expect(try String(contentsOfFile: path, encoding: .utf8) == replacement) }
    }
}

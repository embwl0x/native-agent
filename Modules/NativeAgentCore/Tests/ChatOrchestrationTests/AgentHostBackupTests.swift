import Darwin
import Foundation
import Testing
@testable import ChatOrchestration

@Suite struct AgentHostBackupTests {
    @Test func namedPipeSettingsAreRejectedWithoutWaitingForAWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(throws: (any Error).self) {
            try AgentHostConfigWriter.writeJSONEntry(path: file.path, name: "nativeagent",
                entryJSON: "{}", backupRecordURL: root.appendingPathComponent("receipt.json"))
        }
        var info = stat()
        #expect(lstat(file.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFIFO)
    }

    @Test(arguments: [false, true])
    func removalClaimsFileBeforeInspectingAndPreservesLaterSave(displacedHostSave: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let record = root.appendingPathComponent("receipt.json")
        let entry = AgentHostDirectory.jsonEntry(command: "/fixture/link", peerID: "ours", secret: "fixture", descriptorPath: "/fixture/bridge")
        _ = try AgentHostConfigWriter.writeJSONEntry(path: file.path, name: "nativeagent", entryJSON: entry, backupRecordURL: record)
        let displaced = Data(("{\"theme\":\"displaced\",\"mcpServers\":{\"nativeagent\":" + entry + "}}").utf8)
        let latest = Data(("{\"theme\":\"latest\",\"mcpServers\":{\"nativeagent\":" + entry + "}}").utf8)
        _ = try AgentHostConfigWriter.$beforeRemovalHookForTests.withValue({
            if displacedHostSave { try! displaced.write(to: file, options: .atomic) }
        }) {
            try AgentHostConfigWriter.$afterRemovalRenameHookForTests.withValue({
                try! latest.write(to: file, options: .atomic)
            }) {
                try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "ours")
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"theme\":\"latest\",\"mcpServers\":{}}")
        let retained = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".nativeagent-removal-") }
        #expect(retained.count == (displacedHostSave ? 1 : 0))
        if let saved = retained.first {
            #expect(try String(contentsOf: saved, encoding: .utf8) == "{\"theme\":\"displaced\",\"mcpServers\":{}}")
        }
    }

    @Test(arguments: [false, true])
    func absentFileRemovalPreservesConcurrentHostSave(hostSaves: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let record = root.appendingPathComponent("receipt.json")
        let entry = AgentHostDirectory.jsonEntry(command: "/fixture/link", peerID: "ours", secret: "fixture", descriptorPath: "/fixture/bridge")
        _ = try AgentHostConfigWriter.writeJSONEntry(path: file.path, name: "nativeagent", entryJSON: entry, backupRecordURL: record)
        let saved = Data(("{\"theme\":\"new\",\"mcpServers\":{\"nativeagent\":" + entry + "}}").utf8)
        _ = try AgentHostConfigWriter.$beforeRemovalHookForTests.withValue({
            if hostSaves { try! saved.write(to: file, options: .atomic) }
        }) {
            try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "ours")
        }
        if hostSaves {
            #expect(try String(contentsOf: file, encoding: .utf8) == "{\"theme\":\"new\",\"mcpServers\":{}}")
        } else {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func jsonRestoresCompleteMemberBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.jsonc")
        let record = root.appendingPathComponent("receipt.json")
        let member = #""native\u0061gent" /* key */  : /* keep */ { "command" : "original" }"#
        try Data(("{\"mcpServers\":{" + member + "},\"theme\":\"old\"}").utf8).write(to: file)
        let entry = AgentHostDirectory.jsonEntry(command: "/fixture/link", peerID: "ours", secret: "fixture", descriptorPath: "/fixture/bridge")
        _ = try AgentHostConfigWriter.writeJSONEntry(path: file.path, name: "nativeagent", entryJSON: entry, backupRecordURL: record, comments: true)
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "old", with: "new")
        try Data(edited.utf8).write(to: file)
        _ = try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record, comments: true, peerID: "ours")
        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result.contains(member))
        #expect(result.contains("\"theme\":\"new\""))
    }

    @Test(arguments: [false, true])
    func tomlDisconnectFollowsOwnershipAndRestoresOriginal(replaced: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.toml")
        let record = root.appendingPathComponent("receipt.json")
        let original = replaced ? "[mcp_servers.nativeagent]\ncommand = 'original' # keep\n" : ""
        try Data(original.utf8).write(to: file)
        let entry = AgentHostDirectory.codexEntry(command: "/fixture/link", peerID: "ours",
            secret: "fixture", descriptorPath: "/fixture/bridge")
        _ = try AgentHostConfigWriter.writeTOMLEntry(path: file.path, name: "nativeagent", entryTOML: entry, backupRecordURL: record)
        let renamed = entry.replacingOccurrences(of: "mcp_servers.nativeagent", with: "mcp_servers.renamed")
        let foreign = replaced ? "" : "[mcp_servers.nativeagent]\ncommand = 'foreign'\n[mcp_servers.nativeagent.env]\n\(AgentHostDirectory.peerIDVariable) = 'ours'\n"
        try Data(("theme = 'new'\n" + foreign + renamed + "\n").utf8).write(to: file)
        _ = try AgentHostConfigWriter.removeTOMLEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "ours")
        #expect(try String(contentsOf: file, encoding: .utf8) == "theme = 'new'\n" + foreign + original)
        let before = try Data(contentsOf: file)
        _ = try AgentHostConfigWriter.removeTOMLEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "ours")
        #expect(try Data(contentsOf: file) == before)
        #expect(throws: (any Error).self) {
            try AgentHostConfigWriter.removeTOMLEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "other")
        }
    }

    @Test func ownedEntryMovesAndOriginalSurvivesUnrelatedEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let record = root.appendingPathComponent("receipt.json")
        let original = #"{"mcpServers":{"nativeagent":{"command":"original","args":["keep"]}},"theme":"old"}"#
        try Data(original.utf8).write(to: file)
        let entry = AgentHostDirectory.jsonEntry(command: "/fixture/nativeagent-link", peerID: "connection-1",
            secret: "fixture", descriptorPath: "/fixture/bridge.json")
        _ = try AgentHostConfigWriter.writeJSONEntry(path: file.path, name: "nativeagent", entryJSON: entry, backupRecordURL: record)
        // The person moved and renamed our entry and changed their theme.
        let edited = "{\"mcpServers\":{},\"projects\":{\"example\":{\"renamed\":\(entry)}},\"theme\":\"new\"}"
        try Data(edited.utf8).write(to: file)
        _ = try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "connection-1")
        let result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(result["theme"] as? String == "new")
        let servers = try #require(result["mcpServers"] as? [String: [String: Any]])
        #expect(servers["nativeagent"]?["command"] as? String == "original")
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("connection-1"))
        // Retry after a key-store failure is safe and retains the original.
        let before = try Data(contentsOf: file)
        _ = try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "connection-1")
        #expect(try Data(contentsOf: file) == before)
        #expect(throws: (any Error).self) {
            try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "other-connection")
        }
    }

    @Test func sameNameForeignEntryIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let record = root.appendingPathComponent("receipt.json")
        let entry = AgentHostDirectory.jsonEntry(command: "/fixture/nativeagent-link", peerID: "ours",
            secret: "fixture", descriptorPath: "/fixture/bridge.json")
        _ = try AgentHostConfigWriter.writeJSONEntry(path: file.path, name: "nativeagent", entryJSON: entry, backupRecordURL: record)
        let foreign = #"{"mcpServers":{"nativeagent":{"command":"foreign","env":{"NATIVE_AGENT_PEER_ID":"ours"}}}}"#
        try Data(foreign.utf8).write(to: file)
        _ = try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record, peerID: "ours")
        #expect(try String(contentsOf: file, encoding: .utf8) == foreign)
    }

    @Test(arguments: [false, true])
    func rotatesAndRemovesOnlyOurBackups(toml: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(toml ? "config.toml" : "config.json")
        let record = root.appendingPathComponent("app/backup.json")
        let original = toml ? "model = \"other\"\n" : "{\"other\": 42}"
        try Data(original.utf8).write(to: file)
        let foreign = file.path + ".backup"
        let similar = file.path + ".nativeagent-backup-personal"
        let collision = file.path + ".nativeagent-backup-19700101T000000Z"
        for path in [foreign, similar, collision] { try Data("keep".utf8).write(to: URL(fileURLWithPath: path)) }
        func write(_ secret: String) throws -> AgentHostConfigWriter.Outcome {
            if toml {
                return try AgentHostConfigWriter.writeTOMLEntry(path: file.path, name: "nativeagent",
                    entryTOML: "[mcp_servers.nativeagent]\ncommand = \"\(secret)\"\n", backupRecordURL: record)
            }
            return try AgentHostConfigWriter.writeJSONEntry(path: file.path, name: "nativeagent",
                entryJSON: "{\"command\":\"\(secret)\"}", backupRecordURL: record)
        }
        func remove() throws -> AgentHostConfigWriter.Outcome {
            if toml { return try AgentHostConfigWriter.removeTOMLEntry(path: file.path, name: "nativeagent", backupRecordURL: record) }
            return try AgentHostConfigWriter.removeJSONEntry(path: file.path, name: "nativeagent", backupRecordURL: record)
        }
        let first = try AgentHostConfigWriter.$backupDateForTests.withValue(Date(timeIntervalSince1970: 0)) {
            try write("old-key")
        }
        #expect(first.backupPath == collision + "-1")
        let before = try Data(contentsOf: file)
        let second = try write("new-key")
        #expect(!FileManager.default.fileExists(atPath: try #require(first.backupPath)))
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(second.backupPath))) == before)
        #expect(try remove().backupPath == nil)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("key"))
        // An unrecorded timestamped backup is never ours to delete.
        let legacy = file.path + ".nativeagent-backup-20260901T120000Z"
        try before.write(to: URL(fileURLWithPath: legacy))
        #expect(try remove().removed == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: legacy)) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 6)
        for path in [foreign, similar, collision] {
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
        }
        // A clean no-op disconnect still clears a recorded backup.
        let third = try write("third-key")
        try Data(original.utf8).write(to: file)
        #expect(try remove().removed == false)
        #expect(!FileManager.default.fileExists(atPath: try #require(third.backupPath)))

        // Someone replacing a recorded file does not give us their new file.
        let fourth = try write("fourth-key")
        let replaced = URL(fileURLWithPath: try #require(fourth.backupPath))
        try Data("foreign replacement".utf8).write(to: replaced, options: .atomic)
        _ = try remove()
        #expect(try String(contentsOf: replaced, encoding: .utf8) == "foreign replacement")
    }
}

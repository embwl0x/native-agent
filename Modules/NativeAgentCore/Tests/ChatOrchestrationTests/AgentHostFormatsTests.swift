import Foundation
import Testing
import NativeAgentCore
import Yams
@testable import ChatOrchestration

/// Vendor-format copies with invented values; never copied from personal state.
/// Sources fetched 2026-09-19 are recorded on the rows and below.
@Suite struct AgentHostFormatsTests {
    @Test func knownHostsHaveIndividualPlainDescriptions() {
        let descriptions = AgentHostDirectory.rows.map(\.description)
        #expect(descriptions.allSatisfy { !$0.isEmpty && !$0.contains("\n") })
        #expect(Set(descriptions).count == AgentHostDirectory.rows.count)
        #expect(AgentHostDirectory.row(named: "LM Studio")?.description.contains("local models") == true)
        #expect(AgentHostDirectory.row(named: "Claude Desktop")?.description.contains("chat app") == true)
    }

    static let fixtures: [(String, String)] = [
        ("Antigravity CLI", """
        {"mcpServers":{"existing":{"command":"node","args":["server.js"],"env":{"EXAMPLE":"fixture"}}},"future":{"preserve":true}}
        """),
        ("Claude Desktop", """
        {
          "preferences": {"quickEntryShortcut": "off", "futureOption": [1, true]},
          "mcpServers": {
            "filesystem": {"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp/example"],"env":{}}
          },
          "unknown": "keep café and \\u2603"
        }
        """),
        ("LM Studio", """
        {
          "mcpServers": {
            "hf-mcp-server": {"url":"https://huggingface.co/mcp","headers":{"X-Example":"placeholder"}}
          },
          "future": {"nested":[{"keep":true}]}
        }
        """),
        ("Cursor", """
        {
          "mcpServers": {
            "example": {"type":"stdio","command":"node","args":["example.js"],"env":{"EXAMPLE":"${env:EXAMPLE}"}}
          },
          "unknown": {"order":"last"}
        }
        """),
        ("Cursor Workspace", """
        {"projectNote":"keep", "mcpServers":{"project-tools":{"command":"node","args":["${workspaceFolder}/tools.js"]}}, "unknown":42}
        """),
        ("Gemini CLI", """
        {
          // Keep the chosen sign-in method and this comment.
          "security": {"auth":{"selectedType":"oauth-personal"}},
          "mcpServers": {
            "example": {"command":"node","args":["server.js"],"timeout":30000,"trust":false,"includeTools":["read"]}
          },
          "ui": {"theme":"Default"}, "future": [null, {"x":2}]
        }
        """),
        ("Zed", """
        // User settings; keep this comment and order.
        {
          "theme": "One Dark",
          "context_servers": {
            // Existing connection
            "example": {"command":"node","args":["server.js"],"env":{},}, // keep trailing note
          },
          /* An unknown setting containing punctuation. */
          "future": {"text":"https://example.test/*literal*/", "list":[1,2,],},
        }
        """),
        ("VS Code", """
        {
          // A saved input must not move or be rewritten.
          "inputs": [{"id":"example","type":"promptString","description":"Example","password":true}],
          "servers": {
            "playwright": {"type":"stdio","command":"npx","args":["-y","@playwright/mcp"],},
          },
          "unknown": {"order":"last"},
        }
        """),
        ("Goose", """
        # Provider choices and extension order belong to the person.
        GOOSE_PROVIDER: openai
        GOOSE_MODEL: example-model
        extensions:
          # Keep the existing helper.
          developer:
            enabled: true
            name: developer
            type: builtin
            timeout: 300
          filesystem:
            type: stdio
            name: filesystem
            enabled: true
            cmd: npx
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
            env_keys: []
            envs: {}
        unknown:
          description: |
            A multiline value with café.
            extensions: is only text here.
          keep: true

        """)
    ].filter { AgentHostDirectory.row(named: $0.0)?.settingsSupported == true }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ row: AgentHostRow, path: String, record: URL, secret: String = "fixture-key") throws -> AgentHostConfigWriter.Outcome {
        let entry = AgentHostDirectory.jsonEntry(command: "/tmp/Example App/nativeagent-link", peerID: "fixture-peer",
            secret: secret, descriptorPath: "/tmp/Example App/bridge.json", format: row.format)
        if row.format == .gooseYAML {
            return try AgentHostConfigWriter.writeGooseEntry(path: path, name: AgentHostDirectory.entryName,
                entryJSON: entry, backupRecordURL: record)
        }
        return try AgentHostConfigWriter.writeJSONEntry(path: path, name: AgentHostDirectory.entryName,
            entryJSON: entry, backupRecordURL: record, containerKey: row.format.containerKey, comments: row.format.comments,
            trailingCommas: row.format.trailingCommas)
    }

    private func disconnect(_ row: AgentHostRow, path: String, record: URL) throws {
        if row.format == .gooseYAML {
            _ = try AgentHostConfigWriter.removeGooseEntry(path: path, name: AgentHostDirectory.entryName, backupRecordURL: record)
        } else {
            _ = try AgentHostConfigWriter.removeJSONEntry(path: path, name: AgentHostDirectory.entryName,
                backupRecordURL: record, containerKey: row.format.containerKey, comments: row.format.comments,
                trailingCommas: row.format.trailingCommas)
        }
    }

    @Test(arguments: fixtures.map(\.0))
    func vendorFileRoundTrip(name: String) throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        try AgentHostDirectory.$homeForTests.withValue(home.path) {
            let row = try #require(AgentHostDirectory.row(named: name))
            let original = Data(try #require(Self.fixtures.first { $0.0 == name }).1.utf8)
            let workspace = home.appendingPathComponent("Projects/Example Folder")
            let path = row.requiresWorkspace ? workspace.appendingPathComponent(row.configPath).path : row.expandedConfigPath
            #expect(path.hasPrefix(home.path + "/"))
            let file = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: file)
            let record = home.appendingPathComponent("test-app/backups.json")
            let outcome = try write(row, path: path, record: record)
            #expect(!outcome.replacedExistingEntry)
            #expect(try Data(contentsOf: URL(fileURLWithPath: #require(outcome.backupPath))) == original)
            let added = try Data(contentsOf: file)
            // Removing our exact range without the backup must itself preserve
            // every original byte: comments, ordering, unknown nested values.
            let removed = row.format == .gooseYAML
                ? try GooseEntrySplice.edit(added, name: AgentHostDirectory.entryName, entry: nil)?.data
                : try JSONEntrySplice.remove(added, name: AgentHostDirectory.entryName,
                    containerKey: row.format.containerKey, comments: row.format.comments)?.data
            #expect(removed == original)
            if row.format == .gooseYAML {
                let object = try #require(Yams.load(yaml: String(decoding: added, as: UTF8.self)) as? [String: Any])
                let entries = try #require(object["extensions"] as? [String: Any])
                let ours = try #require(entries[AgentHostDirectory.entryName] as? [String: Any])
                #expect(ours["cmd"] as? String == "/tmp/Example App/nativeagent-link")
                #expect((ours["envs"] as? [String: String])?[AgentHostDirectory.peerSecretVariable] == "fixture-key")
            } else {
                let object = try #require(JSONSerialization.jsonObject(with: Data(JSONEntrySplice.validatedBytes(added, comments: row.format.comments))) as? [String: Any])
                let entries = try #require(object[row.format.containerKey] as? [String: Any])
                let ours = try #require(entries[AgentHostDirectory.entryName] as? [String: Any])
                #expect(ours["command"] as? String == "/tmp/Example App/nativeagent-link")
                #expect(ours["args"] as? [String] == ["mcp"])
                #expect((ours["env"] as? [String: String])?[AgentHostDirectory.peerSecretVariable] == "fixture-key")
            }
            try disconnect(row, path: path, record: record)
            #expect(try Data(contentsOf: file) == original)
            #expect(!FileManager.default.fileExists(atPath: try #require(outcome.backupPath)))

            // Both setup and disconnect refuse a malformed complete file, even
            // when its target section precedes the broken unrelated setting.
            let malformed = row.format == .gooseYAML
                ? Data("extensions:\n  other: {type: builtin}\nbroken: [unterminated\n".utf8)
                : Data(("{\"\(row.format.containerKey)\":{},\"broken\":[true,}").utf8)
            try malformed.write(to: file)
            #expect(throws: (any Error).self) { try write(row, path: path, record: record) }
            #expect(throws: (any Error).self) { try disconnect(row, path: path, record: record) }
            #expect(try Data(contentsOf: file) == malformed)
        }
    }

    @Test(arguments: fixtures.map(\.0))
    func emptyAndMissingSettingsRestore(name: String) throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        let row = try #require(AgentHostDirectory.row(named: name))
        let file = home.appendingPathComponent("new/settings")
        let record = home.appendingPathComponent("backups.json")
        _ = try write(row, path: file.path, record: record)
        try disconnect(row, path: file.path, record: record)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let originals = row.format == .gooseYAML ? ["extensions: {} # keep\n", "other: true\n"]
            : ["{}", "{\"other\":42}", "{\"\(row.format.containerKey)\": {  }}"]
        for original in originals {
            try Data(original.utf8).write(to: file)
            _ = try write(row, path: file.path, record: record)
            try disconnect(row, path: file.path, record: record)
            #expect(try String(contentsOf: file, encoding: .utf8) == original)
        }
    }

    @Test func workspaceIdentityAndCard() throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        let row = try #require(AgentHostDirectory.row(named: "Cursor Workspace"))
        #expect(throws: AgentHostConnection.Refusal.workspaceRequired) {
            try AgentHostConnection.workspaceFolder(row: row, workspace: nil)
        }
        let folder = try #require(try AgentHostConnection.workspaceFolder(row: row, workspace: home.path))
        var resolved = row
        resolved.configPath = folder + "/" + row.configPath
        let proposal = AgentHostConnection.Proposal(row: resolved, command: "/tmp/nativeagent-link",
            descriptorPath: "/tmp/bridge.json", existing: nil, workspace: folder)
        let card = AgentHostConnection.cardText(proposal, appName: "Example")
        #expect(card.contains(folder + "/.cursor/mcp.json"))
        #expect(card.contains(row.restartNote))
        var first = AgentPeerContact(name: row.displayName, endpoint: URL(string: "mcp://cursor-workspace")!, transport: .mcpHost)
        first.hostWorkspace = folder
        var second = first
        second.id = UUID().uuidString.lowercased()
        second.hostWorkspace = folder + "/second"
        #expect(!AgentPeerStore.sameRoute(first, second))
        let store = AgentPeerStore(dataRoot: home.appendingPathComponent("test-app"))
        _ = try store.upsert(first)
        _ = try store.upsert(second)
        #expect(try store.list().map(\.hostWorkspace) == [first.hostWorkspace, second.hostWorkspace])
        #expect(AgentHostConnection.settingsPath(contact: first) == folder + "/.cursor/mcp.json")
    }

    @Test func documentedCommandArgumentsKeepMessagesLiteral() throws {
        let text = "--help ; $(touch nope)\nsecond line"
        for id in ["claude-code", "codex", "antigravity-cli"] {
            let line = try #require(AgentHostCommandLines.byHostID[id])
            let args = line.argv(message: text, session: nil, resuming: false, replyFilePath: nil)
            #expect(args.last == text || args.last?.hasSuffix("=" + text) == true)
            #expect(!args.contains("--help"))
            #expect(!args.joined().contains("{{message}}"))
        }
        let studio = try #require(AgentHostDirectory.row(named: "LM Studio"))
        #expect(studio.settingsSupported)
        #expect(studio.commandLine == nil)
        #expect(studio.outboundRoute == "none")
        #expect(AgentHostDirectory.row(named: "Grok Bot")?.commandLine == nil)
        #expect(AgentHostDirectory.row(named: "Grok Bot")?.outboundRoute == "grok-webhook")
        for id in ["gemini-cli", "goose", "cursor-cli"] {
            let row = try #require(AgentHostDirectory.row(named: id))
            #expect(row.outboundRoute == "acp")
            #expect(row.commandLine == nil)
        }
        #expect(AgentHostDirectory.row(named: "Cursor")?.outboundRoute == "none")
        #expect(AgentHostDirectory.row(named: "Claude Desktop")?.commandLine == nil)
        // OpenCode currently publishes incompatible v1 and v2 section shapes;
        // do not guess a version by a product name or rewrite the wrong file.
        #expect(AgentHostDirectory.row(named: "OpenCode") == nil)
        #expect(AgentHostDirectory.row(named: "VS Code") == nil)
    }

    @Test(arguments: fixtures.map(\.0))
    func preservesHostEditsAfterSetup(name: String) throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        let row = try #require(AgentHostDirectory.row(named: name))
        let original = try #require(Self.fixtures.first { $0.0 == name }).1
        let file = home.appendingPathComponent("settings")
        let record = home.appendingPathComponent("backups.json")
        try Data(original.utf8).write(to: file)
        _ = try write(row, path: file.path, record: record)
        let addition = row.format == .gooseYAML ? "\nnew_setting: true\n" : "\n  "
        let edited = try String(contentsOf: file, encoding: .utf8) + addition
        try Data(edited.utf8).write(to: file)
        try disconnect(row, path: file.path, record: record)
        #expect(try String(contentsOf: file, encoding: .utf8) == original + addition)
    }

    @Test func malformedJSONCIsNeverRepairedByMasking() throws {
        for text in ["{\"x\":[,]}", "{\"x\":{,}}", "{\"x\":[1,,]}", "{} trailing", "{} /* unfinished",
                     "{\"servers\":{},\"other\":{\"x\":nope}}"] {
            #expect(throws: (any Error).self) {
                try JSONEntrySplice.upsert(Data(text.utf8), name: "nativeagent", entryJSON: "{}", comments: true)
            }
        }
        #expect(throws: (any Error).self) {
            try JSONEntrySplice.validatedBytes(Data("{\"x\":[1,]}".utf8), comments: false)
        }
        #expect(throws: (any Error).self) {
            try JSONEntrySplice.validatedBytes(Data("{/*note*/\"x\":[1,]}".utf8), comments: true, trailingCommas: false)
        }
    }

    @Test(arguments: ["Gemini CLI", "Goose", "Cursor CLI"])
    func acpUsesSessionToolsInsteadOfSettings(name: String) throws {
        let row = try #require(AgentHostDirectory.row(named: name))
        #expect(!row.settingsSupported)
        #expect(row.configPath.isEmpty)
        #expect(row.format == .sessionMCP)
        #expect(row.acp != nil)
        #expect(row.outboundRoute == "acp")
    }
}

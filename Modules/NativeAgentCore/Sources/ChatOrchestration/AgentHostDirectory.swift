import Darwin
import CoreServices
import Foundation
import NativeAgentCore
import PersistenceCore

/// KNOWN AGENTS ARE DATA.
///
/// One row per agent host on this Mac: what it is called, how to see that it is
/// installed, where it keeps its MCP servers, which FORMAT that file is, the
/// entry it expects, and whether it has to be restarted to notice one. No
/// routing code anywhere branches on a row's id — the writers below are chosen
/// by `format`, and everything else on the row is text the card shows the
/// person.
///
/// Rows are checked against vendor documentation and realistic isolated file
/// fixtures. No personal settings are read during development. An unsupported
/// host has no row, and the honest answer for a
/// name that has no row is "I don't know how to set that one up yet" — never a
/// guess at somebody else's configuration format.
public struct AgentHostRow: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable {
        /// `{ "mcpServers": { "<name>": { … } } }`
        case jsonMCPServers
        case jsonBareMCPServers
        case jsonContextServers
        case jsonServers
        case gooseYAML
        /// `[mcp_servers.<name>]`
        case codexTOML
        /// Reply tools supplied to session/new; no settings file is edited.
        case sessionMCP

        var containerKey: String {
            switch self {
            case .jsonContextServers: "context_servers"
            case .jsonServers: "servers"
            default: "mcpServers"
            }
        }
        var comments: Bool { self == .jsonBareMCPServers || self == .jsonContextServers || self == .jsonServers }
        var trailingCommas: Bool { self == .jsonContextServers || self == .jsonServers }
    }

    public let id: String
    public let displayName: String
    public let description: String
    /// Matched case-insensitively, alongside `id` and `displayName`.
    public let aliases: [String]
    /// Historical setup markers; discovery uses executable files and Launch Services only.
    public let installMarkers: [String]
    public var configPath: String
    public let format: Format
    /// Whether the host must be restarted before the entry is live, and what
    /// that means for the person, in one sentence for the card.
    public let restartRequired: Bool
    public let restartNote: String
    /// The documentation this row's path and entry shape were checked against.
    public let documentation: String
    public var requiresWorkspace: Bool = false
    public var settingsSupported: Bool = true
    public var declaredRoute: Route? = nil
    public var outboundRoute: String { route == .grokBot ? "grok-webhook" : acpLaunch == nil ? (commandLine == nil ? "none" : "command") : "acp" }
    /// Compatibility projection of the transport's single launch declaration.
    public var acpLaunch: (executable: String, arguments: [String], version: String)? {
        acp.map { ($0.executable, $0.arguments, $0.referenceVersion) }
    }
    /// Launch Services finds applications outside the usual Applications folders too.
    public var bundleIDs: [String] = []
    /// Only documented A2A listening ports belong here; neither current CLI advertises one.
    public var a2aPorts: [Int] = []

    /// The command-line half of this row, or nil when this host has none.
    /// Absent means there is no way to push a message into it from here, and
    /// the result says exactly that rather than reaching for its window. The
    /// table lives in `AgentHostCommandLines` so the Trust boundary can read
    /// the same one rather than a second copy.
    public var commandLine: AgentHostCommandLine? { AgentHostCommandLines.byHostID[id] }
    public var acp: AgentHostACP? { AgentHostACP.byHostID[id] }
    public enum Route: String, Sendable { case acp, a2a, grokBot = "grok-bot", commandLine = "command-line", mcpSettingsOnly = "mcp-settings-only" }
    public var route: Route { declaredRoute ?? (acp != nil ? .acp : commandLine != nil ? .commandLine : .mcpSettingsOnly) }

    public func matches(_ name: String) -> Bool {
        let wanted = AgentHostDirectory.normalize(name)
        guard !wanted.isEmpty else { return false }
        return ([id, displayName] + aliases).contains { AgentHostDirectory.normalize($0) == wanted }
    }

    public var isInstalled: Bool {
        isInstalled(applicationExists: { id in
            guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL] else { return false }
            return urls.contains { FileManager.default.fileExists(atPath: $0.path) }
        }, executable: AgentHostCommandLines.resolveExecutable)
    }

    func isInstalled(applicationExists: (String) -> Bool, executable: (String) -> String?) -> Bool {
        if let acp { return executable(acp.executable) != nil }
        return bundleIDs.contains(where: applicationExists)
            || commandLine.map { executable($0.executable) != nil } == true
    }

    public var expandedConfigPath: String { AgentHostDirectory.expand(configPath) }
}

public enum AgentHostDirectory {
    @TaskLocal static var homeForTests: String?
    /// The name this app's entry carries in another agent's configuration. One
    /// fixed product name, never a persona name, so a person reading their own
    /// settings file can tell which app put it there.
    public static var entryName: String { InstallPaths.current.agentHostEntryName }

    /// The environment variables the entry sets and `nativeagent-link` reads.
    /// The secret is an ENVIRONMENT value and never a command-line argument:
    /// arguments are world-readable in the process table.
    public static let peerIDVariable = "NATIVE_AGENT_PEER_ID"
    public static let peerSecretVariable = "NATIVE_AGENT_PEER_SECRET"
    /// WHICH INSTALL THE ENTRY TALKS TO. Without it the link command falls back
    /// to the machine-wide rendezvous, which belongs to whichever install owns
    /// it — so an entry written by a second install, or by one on its own data
    /// root, would hand this connection's key to an install that has never
    /// heard of it. The entry therefore names THIS install's descriptor file
    /// explicitly, owner included, so it keeps meaning the same thing if
    /// ownership later changes. A path, not a secret.
    public static let bridgeDescriptorVariable = "NATIVE_AGENT_BRIDGE_DESCRIPTOR"

    public static func bridgeDiscoveryDirectory(dataRoot: URL) -> URL {
        InstallPaths.current.bridgeDiscoveryDirectory(dataRoot: dataRoot)
    }

    public static func bridgeDescriptorPath(dataRoot: URL) -> String {
        bridgeDiscoveryDirectory(dataRoot: dataRoot).appendingPathComponent("bridge.json").path
    }

    /// What the entry actually exposes, said plainly on the card. These are the
    /// two tools `/agent/mcp` serves and nothing else.
    public static let accessSummary =
        "two tools, agent_message and agent_reply, over this Mac's loopback interface only. "
        + "These are messaging tools, not restrictions on what the other program can do itself. "
        + "This app applies its own permission settings when it handles a request."

    // Vendor evidence fetched 2026-09-19 (restart notes below are plain-language
    // instructions, not a promise that a saved entry is already connected):
    // Claude Desktop: https://modelcontextprotocol.io/docs/develop/connect-local-servers
    // "The application needs to restart to load the new configuration"
    // Shape also confirmed by Anthropic's own code.claude.com/docs/en/mcp.
    // LM Studio: https://lmstudio.ai/blog/lmstudio-v0.3.17
    // "LM Studio will automatically load the MCP servers defined in it."
    // Cursor: https://cursor.com/docs/mcp
    // "For custom servers, update your local files and restart Cursor."
    // Gemini: https://geminicli.com/docs/tools/mcp-server/ describes discovery
    // at startup; starting a new session is the conservative reload instruction.
    // Comments (but not trailing commas) confirmed in vendor settings.ts:
    // https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/config/settings.ts
    // Zed: https://zed.dev/docs/ai/mcp says to check Settings → AI → MCP Servers
    // and return to the Agent Panel. No app restart is prescribed in that flow;
    // that is the basis of the note, not tools/list_changed (a different event).
    // Path/comments: https://github.com/zed-industries/zed/blob/main/docs/src/configuring-zed.md
    // VS Code: https://code.visualstudio.com/docs/agent-customization/mcp-servers
    // prescribes inline start actions, not an app restart. macOS User directory:
    // https://code.visualstudio.com/docs/configure/settings
    // Goose: https://github.com/block/goose/blob/main/documentation/docs/guides/config-files.md
    // "Direct edits to config files usually require restarting goose"
    // OpenCode is deliberately omitted: /docs/mcp-servers uses mcp.<name>, while
    // /v2/docs/mcp-servers uses mcp.servers.<name> and different enablement keys.
    // A version-free name does not establish which published contract to write.
    public static let rows: [AgentHostRow] = [
        AgentHostRow(id: "grok-bot", displayName: "Grok Bot",
            description: "A cloud assistant that answers through its desktop app.", aliases: ["grok"],
            installMarkers: [], configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "Grok Bot asks before running the local reply command under its current policy.",
            documentation: "https://cursor.com/help/grok-bot/routines", settingsSupported: false,
            declaredRoute: .grokBot, bundleIDs: ["com.anysphere.sand"]),
        AgentHostRow(
            id: "claude-code",
            displayName: "Claude Code",
            description: "A coding assistant that works in the terminal.",
            aliases: ["claude code", "claude-code", "claudecode", "claude cli", "cc"],
            installMarkers: ["~/.claude", "~/.local/bin/claude", "/opt/homebrew/bin/claude",
                             "/usr/local/bin/claude", "~/.claude/local/claude"],
            configPath: "~/.claude.json",
            format: .jsonMCPServers,
            restartRequired: true,
            restartNote: "required — it reads this file when a session starts, so a session that is "
                + "already open keeps its current servers until it is restarted.",
            documentation: "https://code.claude.com/docs/en/mcp"
        ),
        AgentHostRow(
            id: "codex",
            displayName: "Codex",
            description: "A coding agent that can work on projects on this Mac.",
            aliases: ["codex cli", "codex-cli", "openai codex"],
            installMarkers: ["~/.codex", "~/.local/bin/codex", "/opt/homebrew/bin/codex",
                             "/usr/local/bin/codex"],
            configPath: "~/.codex/config.toml",
            format: .codexTOML,
            restartRequired: true,
            restartNote: "required — its documentation says a change to this file is picked up when "
                + "Codex restarts.",
            documentation: "https://learn.chatgpt.com/docs/extend/mcp?surface=cli",
            bundleIDs: ["com.openai.codex"]
        ),
        AgentHostRow(
            id: "claude-desktop", displayName: "Claude Desktop", description: "A chat app for talking with Claude.", aliases: ["claude app"],
            installMarkers: ["/Applications/Claude.app", "~/Applications/Claude.app", "~/Library/Application Support/Claude"],
            configPath: "~/Library/Application Support/Claude/claude_desktop_config.json", format: .jsonMCPServers,
            restartRequired: true, restartNote: "Quit Claude Desktop completely and reopen it to load the new connection.",
            documentation: "https://code.claude.com/docs/en/mcp", bundleIDs: ["com.anthropic.claudefordesktop"]),
        AgentHostRow(
            id: "lm-studio", displayName: "LM Studio", description: "An app for running and chatting with local models.", aliases: ["lmstudio"],
            installMarkers: ["/Applications/LM Studio.app", "~/.lmstudio"],
            configPath: "~/.lmstudio/mcp.json", format: .jsonMCPServers,
            restartRequired: false, restartNote: "No restart needed; LM Studio loads connections when this file is saved.",
            documentation: "https://lmstudio.ai/blog/lmstudio-v0.3.17", bundleIDs: ["ai.elementlabs.lmstudio"]),
        AgentHostRow(
            id: "cursor", displayName: "Cursor", description: "A code editor with an AI assistant.", aliases: ["cursor global"],
            installMarkers: ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.cursor"],
            configPath: "~/.cursor/mcp.json", format: .jsonMCPServers,
            restartRequired: true, restartNote: "Restart Cursor to load the new connection.",
            documentation: "https://cursor.com/docs/mcp", bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        AgentHostRow(
            id: "cursor-workspace", displayName: "Cursor Workspace", description: "An AI coding assistant connected to one project folder.", aliases: ["cursor project"],
            installMarkers: ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.cursor"],
            configPath: ".cursor/mcp.json", format: .jsonMCPServers,
            restartRequired: true, restartNote: "Reopen the selected folder in Cursor to load the new connection.",
            documentation: "https://cursor.com/docs/mcp", requiresWorkspace: true, bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        AgentHostRow(
            id: "cursor-cli", displayName: "Cursor CLI", description: "A terminal coding assistant from Cursor.", aliases: ["cursor-agent"],
            installMarkers: ["~/.local/bin/cursor-agent"],
            configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
            documentation: "https://github.com/agentclientprotocol/registry/blob/main/cursor/agent.json",
            settingsSupported: false),
        AgentHostRow(
            id: "gemini-cli", displayName: "Gemini CLI", description: "A terminal assistant powered by Gemini.", aliases: ["gemini"],
            installMarkers: ["~/.gemini", "/opt/homebrew/bin/gemini", "~/.local/bin/gemini"],
            configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
            documentation: "https://geminicli.com/docs/tools/mcp-server/", settingsSupported: false),
        AgentHostRow(
            id: "zed", displayName: "Zed", description: "A code editor with a built-in agent panel.", aliases: [],
            installMarkers: ["/Applications/Zed.app", "~/.config/zed"],
            configPath: "~/.config/zed/settings.json", format: .jsonContextServers,
            restartRequired: false, restartNote: "No app restart is needed; check the connection in Zed's AI settings.",
            documentation: "https://zed.dev/docs/ai/mcp", bundleIDs: ["dev.zed.Zed"]),
        AgentHostRow(
            id: "goose", displayName: "Goose", description: "A local assistant for coding and other tasks.", aliases: ["goose cli"],
            installMarkers: ["/Applications/Goose.app", "~/.config/goose", "~/.local/bin/goose"],
            configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
            documentation: "https://github.com/agentclientprotocol/registry/blob/main/goose/agent.json",
            settingsSupported: false),
    ]

    /// THE PROBE THAT PROVES THE ROUND TRIP. Sent once at connect time to a
    /// host that has a command line: it asks the other agent to answer through
    /// the entry that was just written, and the contact becomes connected only
    /// when that inbound request actually arrives carrying this connection's
    /// key and the one-time nonce. The probe asks for nothing to be read, changed or run.
    public static let probeToken = "bridge-handshake"

    public static func probeText(appName: String, nonce: String = probeToken) -> String {
        "Connection check from \(appName). Please call your \(entryName) MCP tool agent_message once "
            + "with the text \"\(nonce)\" and nothing else. Do not read, change or run anything."
    }

    public static func row(named name: String) -> AgentHostRow? {
        rows.first { $0.matches(name) }
    }

    /// Every row, for an honest "I don't know that one" result.
    public static var knownNames: [String] { rows.map(\.displayName) }

    // MARK: - The entry, per format

    /// The entry text spliced into a JSON host's `mcpServers` object. Authored
    /// here rather than serialised from a dictionary so the key order on the
    /// person's disk is stable and readable.
    public static func jsonEntry(command: String, peerID: String, secret: String,
                                 descriptorPath: String, format: AgentHostRow.Format = .jsonMCPServers) -> String {
        let entry = """
        {
          "type": "stdio",
          "command": \(JSONEntrySplice.quoted(command)),
          "args": ["mcp"],
          "env": {
            \(JSONEntrySplice.quoted(bridgeDescriptorVariable)): \(JSONEntrySplice.quoted(descriptorPath)),
            \(JSONEntrySplice.quoted(peerIDVariable)): \(JSONEntrySplice.quoted(peerID)),
            \(JSONEntrySplice.quoted(peerSecretVariable)): \(JSONEntrySplice.quoted(secret))
          }
        }
        """
        if format == .jsonBareMCPServers || format == .jsonContextServers {
            return entry.replacingOccurrences(of: "  \"type\": \"stdio\",\n", with: "")
        }
        if format == .gooseYAML {
            let object: [String: Any] = ["type": "stdio", "name": entryName, "enabled": true,
                "cmd": command, "args": ["mcp"], "env_keys": [String](),
                "envs": [bridgeDescriptorVariable: descriptorPath, peerIDVariable: peerID, peerSecretVariable: secret],
                "timeout": 300]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return entry
    }

    public static func codexEntry(command: String, peerID: String, secret: String,
                                  descriptorPath: String) -> String {
        """
        [mcp_servers.\(entryName)]
        command = \(TOMLEntrySplice.quoted(command))
        args = ["mcp"]

        [mcp_servers.\(entryName).env]
        \(bridgeDescriptorVariable) = \(TOMLEntrySplice.quoted(descriptorPath))
        \(peerIDVariable) = \(TOMLEntrySplice.quoted(peerID))
        \(peerSecretVariable) = \(TOMLEntrySplice.quoted(secret))
        """
    }

    /// The `Changes:` line: exactly where, and exactly what, with the secret's
    /// VALUE never in it.
    public static func changesLine(row: AgentHostRow, command: String) -> String {
        let what = "One connection named \"\(entryName)\""
        return "\(what) in \(row.expandedConfigPath), running \(command) mcp. "
            + "Everything else in that file is left byte for byte as it is, and one timestamped "
            + "backup is kept beside it, replaced on the next edit and removed on disconnect. Because the entry holds this connection's key, that file "
            + "and its backup are made readable by you alone."
    }

    // MARK: - Paths

    static func expand(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if let homeForTests, path.hasPrefix("~/") { return homeForTests + String(path.dropFirst()) }
        return NSString(string: path).expandingTildeInPath
    }

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// The installed `nativeagent-link`, beside this app's own executable. Nil
    /// when it is not there, which is an honest refusal rather than an entry
    /// pointing at a command that does not exist.
    public static func linkCommandPath() -> String? {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let candidate = executable.appendingPathComponent("nativeagent-link").path
        var info = stat()
        guard stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return candidate
    }
}

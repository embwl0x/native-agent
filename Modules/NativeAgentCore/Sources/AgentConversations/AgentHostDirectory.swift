import Darwin
import CoreServices
import Foundation
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `AgentHostDirectory.swift` | `AgentHostDirectory` enum; `bridgeDiscoveryDirectory`, `peerDescriptorDirectory`; `installation.evidence` is discovery/Connect/verify's one installation check; install markers must resolve to executable files or app bundles with executable programs, never profiles; recipe `executables`, `discoveryWords`, `searchPaths` and `messagingPermissionsPath` replace inferred program names, fixed discovery words, ambient path additions and a hardcoded host permission file |

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
///
/// A row is one host's recipe (`AgentRecipeStore`, agents/recipes/<id>.json):
/// the table below only seeds those files.
public struct AgentHostRow: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Equatable, Codable {
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
        /// NativeAgent-owned credentials sourced by an inbound command-line contact.
        case shellEnvironment

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
    /// Program or application paths, never profile directories.
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
    public var outboundRoute: String { route == .dotIPC ? "chatgpt-dot-ipc" : route == .desktopChat ? "desktop-chat" : route == .grokBot ? "grok-webhook" : acp == nil ? (commandLine == nil ? "none" : "command") : "acp" }
    /// Launch Services finds applications outside the usual Applications folders too.
    public var bundleIDs: [String] = []
    /// Only documented A2A listening ports belong here; neither current CLI
    /// advertises one. An A2A contact's recipe carries its card's own.
    public var a2aPorts: [Int] = []
    /// MCP settings files whose presence says this host is set up here.
    /// Discovery only checks that they exist; it never reads them. Optional
    /// so a recipe file written before it existed still reads (none).
    public var configPaths: [String]? = nil
    /// The command-line half of this row, or nil when this host has none.
    /// Absent means there is no way to push a message into it from here, and
    /// the result says exactly that rather than reaching for its window.
    public var commandLine: AgentHostCommandLine? = nil
    public var acp: AgentHostACP? = nil
    /// An A2A contact's recipe (route a2a, keyed by the contact's id).
    public var a2a: A2A? = nil
    /// Where its program is looked for, in order (`resolveExecutable`).
    public var searchPaths: [String] = []
    /// Additional program names used as installation evidence, never launched.
    public var executables: [String]? = nil
    public var discoveryWords: [String]? = nil
    /// Host settings that allow only this connection's two messaging tools.
    public var messagingPermissionsPath: String? = nil
    /// The window labels a desktop chat is driven by (`DesktopChatRoute`).
    public var desktopChat: DesktopChat? = nil
    /// The labels Grok Bot's routine import is driven by.
    public var grokRoutine: GrokRoutine? = nil
    public enum Route: String, Sendable, Codable { case acp, a2a, dotIPC = "chatgpt-dot-ipc", grokBot = "grok-bot", desktopChat = "desktop-chat", commandLine = "command-line", mcpSettingsOnly = "mcp-settings-only" }
    public var route: Route { declaredRoute ?? (acp != nil ? .acp : commandLine != nil ? .commandLine : .mcpSettingsOnly) }

    public struct Installation: Sendable {
        public let applicationURL: URL?
        public let executables: [String: String]
        public let environment: [String: String]
        public let transports: [Route]
        public let evidence: [String]
        public let locations: [URL]
        public let failure: ToolFailureError?

        public func launchEnvironment() throws -> [String: String] {
            if let failure { throw failure }
            return environment
        }
    }

    private struct InstallationInput: Sendable, Equatable {
        let path: String
        let resolved: String
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modified, changed: timespec

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.path == rhs.path && lhs.resolved == rhs.resolved && lhs.device == rhs.device
                && lhs.inode == rhs.inode && lhs.mode == rhs.mode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private static let installations = OSAllocatedUnfairLock(initialState: [String: (AgentHostRow, Installation, [InstallationInput])]())
    static func installationsChanged() { installations.withLock { $0.removeAll() } }

    /// Directory metadata changes for unrelated programs do not invalidate a binding.
    static func refreshInstallations() -> Bool {
        installations.withLock { cache in
            let changed = cache.keys.filter { id in
                let (row, binding, inputs) = cache[id]!
                return row.installationInputs(binding) != inputs
            }
            for id in changed { cache.removeValue(forKey: id) }
            return !changed.isEmpty
        }
    }

    private func installationInputs(_ binding: Installation) -> [InstallationInput] {
        var paths = Set(binding.locations + bundleIDs.compactMap(Self.applicationURL))
        for app in paths where app.pathExtension == "app" {
            let info = app.appendingPathComponent("Contents/Info.plist")
            paths.insert(info)
            if let name = NSDictionary(contentsOf: info)?["CFBundleExecutable"] as? String {
                paths.insert(app.appendingPathComponent("Contents/MacOS/" + name))
            }
        }
        return paths.sorted { $0.path < $1.path }.map { url in
            var info = stat()
            _ = stat(url.path, &info)
            let directory = info.st_mode & S_IFMT == S_IFDIR
            return InstallationInput(path: url.path, resolved: url.resolvingSymlinksInPath().path,
                device: info.st_dev, inode: info.st_ino, mode: info.st_mode,
                size: directory ? 0 : info.st_size, modified: directory ? timespec() : info.st_mtimespec,
                changed: directory ? timespec() : info.st_ctimespec)
        }
    }

    /// One binding for discovery, connection and launch, until its installation changes.
    public var installation: Installation {
        Self.installations.withLock { cache in
            if let (row, binding, _) = cache[id], row == self { return binding }
            let markers = installMarkers.map(AgentHostDirectory.expand)
            let apps = bundleIDs.compactMap(Self.applicationURL)
                + markers.filter { $0.hasSuffix(".app") && Self.isInstalledProgram($0) }.map { URL(fileURLWithPath: $0) }
            let directories = (searchPaths + (acp?.environment["PATH"] ?? "").components(separatedBy: ":").filter { !$0.isEmpty }).map(AgentHostDirectory.expand) + markers.filter {
                programNames.contains(URL(fileURLWithPath: $0).lastPathComponent)
            }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            var environment: [String: String]
            switch AgentHostCommandLines.loginEnvironment {
            case .success(let login):
                environment = login.merging(acp?.environment ?? [:]) { _, declared in declared }
                environment["PATH"] = (directories + (login["PATH"] ?? "").components(separatedBy: ":")).joined(separator: ":")
            case .failure: environment = [:]
            }
            let programs = Dictionary(uniqueKeysWithValues: programNames.compactMap { name in
                AgentHostCommandLines.resolveExecutable(name, directories: directories,
                    home: FileManager.default.homeDirectoryForCurrentUser.path).map { (name, $0) }
            })
            let evidence = apps.map { "application: " + $0.path } + programs.values.sorted().map { "executable: " + $0 }
                + markers.filter(Self.isInstalledProgram).map { "installMarkers: " + $0 }
            let required = acp?.executable ?? commandLine?.executable
            let failure: ToolFailureError?
            if case .failure(let error) = AgentHostCommandLines.loginEnvironment, !programNames.isEmpty { failure = error }
            else if let required, programs[required] == nil {
                failure = ToolFailureError("\(displayName)'s \(route.rawValue) transport needs the missing command \(required).",
                    effects: .none, owner: "\(displayName) installation",
                    tap: "Install \(required) (\(documentation)), then Agents > \(displayName) > Verify", personDecides: true)
            } else { failure = nil }
            let paths = (environment["PATH"] ?? "").components(separatedBy: ":") + directories
            var locations = (paths + paths.flatMap { directory in programNames.map { directory + "/" + $0 } }
                + markers + apps.map(\.path) + Array(programs.values)
                + programs.values.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
                .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
            for var entry in locations {
                while entry.path != "/" {
                    var info = stat()
                    if lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { locations.append(entry.deletingLastPathComponent()) }
                    entry.deleteLastPathComponent()
                }
            }
            let binding = Installation(applicationURL: apps.first, executables: programs, environment: environment,
                transports: failure == nil && (route != .mcpSettingsOnly || settingsSupported) ? [route] : [],
                evidence: evidence, locations: locations, failure: failure)
            cache[id] = (self, binding, installationInputs(binding))
            return binding
        }
    }

    public var isInstalled: Bool { !installation.evidence.isEmpty }

    private static func isInstalledProgram(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        if info.st_mode & S_IFMT == S_IFREG { return FileManager.default.isExecutableFile(atPath: url.path) }
        guard info.st_mode & S_IFMT == S_IFDIR, url.pathExtension == "app",
              let bundle = Bundle(url: url), bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
              let program = bundle.executableURL else { return false }
        return stat(program.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && FileManager.default.isExecutableFile(atPath: program.path)
    }

    var programNames: [String] { Array(Set((executables ?? []) + [acp?.executable, commandLine?.executable].compactMap { $0 })).sorted() }

    public var installationCheck: String {
        installation.failure?.message ?? ("agents/recipes/\(id).json host: bundleIDs=\(bundleIDs), executables=\(programNames), installMarkers=\(installMarkers)"
            + "; searchPaths=\(searchPaths). Install a declared program/app or correct these fields with agent.recipe_write, then agent.verify."
        )
    }

    /// The named program, found in this recipe's program folders.
    public func resolveExecutable(_ name: String) -> String? {
        installation.executables[name]
    }

    static func applicationURL(_ id: String) -> URL? {
        (LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL])?
            .first { isInstalledProgram($0.path) }
    }

    public var expandedConfigPath: String { AgentHostDirectory.expand(configPath) }

    /// Every selector in one place: the labels the app's window exposes. When
    /// the app changes them, its recipe changes; anything unmatched fails with
    /// a plain blocker, never a guess. `alternates` are other labels she knows
    /// for a selector, by its key ("newChat": ["New chat"]): a repair tries
    /// them when the label misses and writes the one that matches.
    public struct DesktopChat: Codable, Sendable, Equatable {
        public var newChat, backToMain, chatsButton, chatsPanel, log, composerCore: String
        public var userPrefix, assistantPrefix, userLabel, assistantMarker, stop: String
        public var unreadSuffix, actionsSuffix, current, currentValue: String
        public var alternates: [String: [String]]? = nil
    }

    public struct GrokRoutine: Codable, Sendable, Equatable {
        public var mainChat, routines, webhookURL, webhookKey: String
        public var list, pause: Control?
        public var navigation: [Step]?
        public var copyURL, copyKey: String?

        public struct Control: Codable, Sendable, Equatable {
            public var roles: [String]
            public var label, subrole: String?
        }
        public struct Step: Codable, Sendable, Equatable {
            public enum Scope: String, Codable, Sendable { case window, routineRow, menu }
            public enum Action: String, Codable, Sendable { case press = "AXPress", showMenu = "AXShowMenu", cancel = "AXCancel" }
            public var name: String
            public var scope: Scope
            public var control: Control
            public var action: Action
            public var alreadyOpen: Control?
            public var dismissal: Dismissal?
        }
        public struct Dismissal: Codable, Sendable, Equatable {
            public var control: Control
            public var action: Step.Action
            /// A menu disappears when an item is selected.
            public var ifPresent: Bool
        }

        // Old recipe fields remain decodable so the existing seed merge can
        // remove unchanged fields while preserving an owner's edited copy.
        public var details, openRoutine, deleteRoutine: String?
        public var backToRoutines, backToDetails, closeDetails, close, scrollToBottom: String?
    }

    /// Where an A2A contact's card is, its credential by reference only (the
    /// contact's key name, never a value), and what the card offered when a
    /// send or dry run last read it (`AgentPeerDiscovery.a2aCheck`): nil
    /// until then. A send is held to `read`; a dry run learns a change into it.
    public struct A2A: Codable, Sendable, Equatable {
        public var card: String
        public var credential: String?
        public var read: Card? = nil

        /// Selected effective-card fields and digest, including an authenticated extended card; no raw card is retained.
        /// Extensions are those it declares; required ones are not spoken here (`protocol_mismatch`).
        public struct Card: Codable, Sendable, Equatable {
            public var endpoint, version, binding: String
            public var tenant: String?
            /// "<scheme name>: <its declaration>" for each scheme a requirement names; [] is none.
            public var auth: [String]
            public var streaming, pushNotifications, extendedCard: Bool
            public var skills, extensions: [String]
            public var digest: String

            /// Every field two reads differ in, with both values.
            public static func drift(_ recorded: Card, _ now: Card) -> [String] {
                guard case .object(let old)? = try? JSONValue.fromEncodable(recorded),
                      case .object(let new)? = try? JSONValue.fromEncodable(now) else { return [] }
                func shown(_ value: JSONValue?) -> String { value.flatMap { try? $0.serialize(pretty: false) } ?? "none" }
                return Set(old.keys).union(new.keys).sorted().compactMap { key in
                    old[key] == new[key] ? nil : "\(key): recipe had \(shown(old[key])), card now \(shown(new[key]))"
                }
            }
        }
    }
}

public enum AgentHostDirectory {
    /// The name this app's entry carries in another agent's configuration. One
    /// fixed product name, never a persona name, so a person reading their own
    /// settings file can tell which app put it there.
    public static var entryName: String { InstallPaths.current.agentHostEntryName() }

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

    /// Peers use their own secret and URL-only descriptors outside `claude-bridge/`, never the bridge bearer.
    public static func peerDescriptorDirectory(dataRoot: URL) -> URL {
        bridgeDiscoveryDirectory(dataRoot: dataRoot).deletingLastPathComponent()
            .appendingPathComponent("nativeagent-link", isDirectory: true)
    }

    public static func bridgeDescriptorPath(dataRoot: URL) -> String {
        peerDescriptorDirectory(dataRoot: dataRoot).appendingPathComponent("bridge.json").path
    }

    /// What the entry actually exposes, said plainly on the card. These are the
    /// two tools `/agent/mcp` serves and nothing else.
    public static let accessSummary =
        "two tools, agent_message and agent_reply, over this Mac's loopback interface only. "
        + "These are messaging tools, not restrictions on what the other program can do itself. "
        + "This app applies its own permission settings when it handles a request."

    // Restart notes describe reload steps, not proof that a saved entry is connected.
    // The seed omits OpenCode because its published configuration contracts conflict.
    /// THE SEED, and only that: `AgentRecipeStore` writes each row into
    /// agents/recipes/<id>.json, and every reader takes `rows`, the recipes.
    static let seed: [AgentHostRow] = [
        AgentHostRow(id: "omp", displayName: "OMP", description: "The local OMP bridge lane.",
            aliases: ["oh-my-pi"], installMarkers: [], configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "The running bridge binds this lane to its contact; no restart is needed.",
            documentation: "", executables: ["omp"]),
        AgentHostRow(id: "chatgpt-dot", displayName: "ChatGPT Dot",
            description: "Your ChatGPT agent, distinct from Codex. In-house messaging checks the running app and Dot's current conversation before sending.",
            aliases: ["dot", "openai dot", "chatgpt agent"], installMarkers: [],
            configPath: "~/.config/nativeagent-link/contacts/chatgpt-dot.env", format: .shellEnvironment,
            restartRequired: false, restartNote: "Nothing to restart. Give Dot the local message command.",
            documentation: "", settingsSupported: false,
            declaredRoute: .dotIPC, bundleIDs: ["com.openai.codex"], discoveryWords: ["dot"]),
        AgentHostRow(id: "grok-bot", displayName: "Grok Bot",
            description: "A cloud assistant that answers through its desktop app.", aliases: ["grok"],
            installMarkers: [], configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "Grok Bot asks before running the local reply command under its current policy.",
            documentation: "https://cursor.com/help/grok-bot/routines", settingsSupported: false,
            declaredRoute: .grokBot, bundleIDs: ["com.anysphere.sand"], discoveryWords: ["grok"]),
        AgentHostRow(id: "muse", displayName: "Muse",
            description: "Meta's assistant, reached through its Mac app in a chat of its own.", aliases: ["meta muse", "meta ai"],
            installMarkers: [], configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "Nothing to restart.",
            documentation: "https://muse.meta.com", settingsSupported: false,
            declaredRoute: .desktopChat, bundleIDs: ["com.meta.endo"], discoveryWords: ["muse", "endo"],
            // The labels Muse's window exposes.
            desktopChat: .init(
                newChat: "New side chat",            // button, and a new chat's title
                backToMain: "Back to main chat",     // header button; the title follows it
                chatsButton: "Chats",                // prefix of "Chats Open chat and side chats"
                chatsPanel: "Side chats",            // AXLandmarkNavigation
                log: "Chat messages", composerCore: "Attach file Dictate a message",
                userPrefix: "User message: ", assistantPrefix: "Assistant message: ",
                userLabel: "You:", assistantMarker: "Copy response", stop: "Stop",
                // Side-chat entries are labelled "<title> Unread updates" or
                // "<title> 18m More thread actions"; the open one has aria-current=page.
                unreadSuffix: " Unread updates", actionsSuffix: " More thread actions",
                current: "AXARIACurrent", currentValue: "page")),
        AgentHostRow(
            id: "claude-code",
            displayName: "Claude Code",
            description: "A coding assistant that works in the terminal.",
            aliases: ["claude code", "claude-code", "claudecode", "claude cli", "cc"],
            installMarkers: ["~/.local/bin/claude", "/opt/homebrew/bin/claude",
                             "/usr/local/bin/claude", "~/.claude/local/claude"],
            configPath: "~/.claude.json",
            format: .jsonMCPServers,
            restartRequired: true,
            restartNote: "required — it reads this file when a session starts, so a session that is "
                + "already open keeps its current servers until it is restarted.",
            documentation: "https://code.claude.com/docs/en/mcp",
            configPaths: ["~/.claude.json"],
            commandLine: AgentHostCommandLine(
                executable: "claude",
                arguments: ["-p", "--output-format", "json", "--name", AgentHostCommandLine.sessionNamePlaceholder,
                            "--", AgentHostCommandLine.messagePlaceholder],
                continuation: ["-p", "--output-format", "json", "--resume", AgentHostCommandLine.sessionPlaceholder,
                               "--", AgentHostCommandLine.messagePlaceholder],
                capturesThreadID: true, jsonResultReply: true,
                resultFields: ["reply": "result", "session": "session_id", "status": "subtype", "success": "success", "error": "is_error", "errors": "errors"],
                automaticMCPProbe: false, permissionFlags: .claude, timeoutSeconds: 300,
                documentation: "https://code.claude.com/docs/en/headless", minimumVersion: "2.1.76"),
            executables: ["claude"], discoveryWords: ["claude"]
        ),
        AgentHostRow(
            id: "codex",
            displayName: "Codex",
            description: "A coding agent that can work on projects on this Mac.",
            aliases: ["codex cli", "codex-cli", "openai codex"],
            installMarkers: ["~/.local/bin/codex", "/opt/homebrew/bin/codex",
                             "/usr/local/bin/codex"],
            configPath: "~/.codex/config.toml",
            format: .codexTOML,
            restartRequired: true,
            restartNote: "required — its documentation says a change to this file is picked up when "
                + "Codex restarts.",
            documentation: "https://learn.chatgpt.com/docs/extend/mcp?surface=cli",
            bundleIDs: ["com.openai.codex"], configPaths: ["~/.codex/config.toml"],
            // Resume uses the CLI-minted thread.started UUID.
            commandLine: AgentHostCommandLine(
                executable: "codex",
                arguments: ["exec", "--json", "--skip-git-repo-check", "-o", AgentHostCommandLine.replyFilePlaceholder,
                            "--", AgentHostCommandLine.messagePlaceholder],
                continuation: ["exec", "resume", "--json", "--skip-git-repo-check",
                               "-o", AgentHostCommandLine.replyFilePlaceholder,
                               "--", AgentHostCommandLine.sessionPlaceholder, AgentHostCommandLine.messagePlaceholder],
                replyFileName: "reply.txt",
                capturesThreadID: true, stream: .codex, permissionFlags: .codex,
                timeoutSeconds: 300,
                documentation: "https://learn.chatgpt.com/docs/non-interactive-mode"),
            discoveryWords: ["codex"]
        ),
        AgentHostRow(
            id: "antigravity-cli", displayName: "Antigravity CLI", description: "Google's current terminal agent for Gemini with continuing conversations.", aliases: ["antigravity", "agy", "gemini"],
            installMarkers: [], configPath: "~/.gemini/config/mcp_config.json", format: .jsonMCPServers,
            restartRequired: false, restartNote: "Each message starts the CLI with the current connection settings and resumes the requested conversation.",
            documentation: "https://www.antigravity.google/docs/mcp",
            commandLine: AgentHostCommandLine(
                executable: "agy",
                arguments: ["--mode", "plan", "--sandbox", "--disable-slash-commands", "--output-format", "stream-json",
                            "--print=" + AgentHostCommandLine.messagePlaceholder],
                continuation: ["--mode", "plan", "--sandbox", "--disable-slash-commands", "--output-format", "stream-json",
                               "--conversation", AgentHostCommandLine.sessionPlaceholder,
                               "--print=" + AgentHostCommandLine.messagePlaceholder],
                capturesThreadID: true, jsonResultReply: true,
                resultFields: ["reply": "response", "session": "conversation_id", "status": "status", "success": "SUCCESS"],
                automaticMCPProbe: false, stream: .antigravity, timeoutSeconds: 300,
                documentation: "https://www.antigravity.google/docs/cli/headless/"),
            discoveryWords: ["antigravity"], messagingPermissionsPath: "~/.gemini/antigravity-cli/settings.json"),
        AgentHostRow(
            id: "claude-desktop", displayName: "Claude Desktop", description: "A chat app for talking with Claude.", aliases: ["claude app"],
            installMarkers: ["/Applications/Claude.app", "~/Applications/Claude.app"],
            configPath: "~/Library/Application Support/Claude/claude_desktop_config.json", format: .jsonMCPServers,
            restartRequired: true, restartNote: "Quit Claude Desktop completely and reopen it to load the new connection.",
            documentation: "https://code.claude.com/docs/en/mcp", bundleIDs: ["com.anthropic.claudefordesktop"],
            configPaths: ["~/Library/Application Support/Claude/claude_desktop_config.json"]),
        AgentHostRow(
            id: "lm-studio", displayName: "LM Studio", description: "An app for running and chatting with local models.", aliases: ["lmstudio"],
            installMarkers: ["/Applications/LM Studio.app"],
            configPath: "~/.lmstudio/mcp.json", format: .jsonMCPServers,
            restartRequired: false, restartNote: "No restart needed; LM Studio loads connections when this file is saved.",
            documentation: "https://lmstudio.ai/blog/lmstudio-v0.3.17", bundleIDs: ["ai.elementlabs.lmstudio"], discoveryWords: ["lmstudio", "ollama"]),
        AgentHostRow(
            id: "cursor", displayName: "Cursor", description: "A code editor with an AI assistant.", aliases: ["cursor global"],
            installMarkers: ["/Applications/Cursor.app", "~/Applications/Cursor.app"],
            configPath: "~/.cursor/mcp.json", format: .jsonMCPServers,
            restartRequired: true, restartNote: "Restart Cursor to load the new connection.",
            documentation: "https://cursor.com/docs/mcp", bundleIDs: ["com.todesktop.230313mzl4w4u92"], configPaths: ["~/.cursor/mcp.json"], discoveryWords: ["cursor"]),
        AgentHostRow(
            id: "cursor-workspace", displayName: "Cursor Workspace", description: "An AI coding assistant connected to one project folder.", aliases: ["cursor project"],
            installMarkers: ["/Applications/Cursor.app", "~/Applications/Cursor.app"],
            configPath: ".cursor/mcp.json", format: .jsonMCPServers,
            restartRequired: true, restartNote: "Reopen the selected folder in Cursor to load the new connection.",
            documentation: "https://cursor.com/docs/mcp", requiresWorkspace: true, bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        AgentHostRow(
            id: "cursor-cli", displayName: "Cursor CLI", description: "A terminal coding assistant from Cursor.", aliases: ["cursor-agent"],
            installMarkers: ["~/.local/bin/cursor-agent"],
            configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
            documentation: "https://github.com/agentclientprotocol/registry/blob/main/cursor/agent.json",
            settingsSupported: false,
            acp: AgentHostACP(executable: "cursor-agent", arguments: ["acp", "--mode=ask", "--sandbox=enabled"],
                              documentation: "https://cursor.com/docs/cli/acp",
                              permissionMode: "ask", referenceVersion: "2026.09.15", protocolVersion: 1)),
        AgentHostRow(
            id: "gemini-cli", displayName: "Gemini CLI (Legacy)", description: "The older Gemini CLI connection. Use Antigravity CLI for Gemini.", aliases: ["Gemini CLI"],
            installMarkers: ["/opt/homebrew/bin/gemini", "~/.local/bin/gemini"],
            configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
            documentation: "https://geminicli.com/docs/tools/mcp-server/", settingsSupported: false,
            configPaths: ["~/.gemini/settings.json"],
            acp: AgentHostACP(executable: "gemini", arguments: ["--acp", "--approval-mode=plan", "--sandbox"],
                              documentation: "https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/acp-mode.md",
                              permissionMode: "plan", referenceVersion: "0.60.0", protocolVersion: 1),
            discoveryWords: ["gemini"]),
        AgentHostRow(
            id: "zed", displayName: "Zed", description: "A code editor with a built-in agent panel.", aliases: [],
            installMarkers: ["/Applications/Zed.app"],
            configPath: "~/.config/zed/settings.json", format: .jsonContextServers,
            restartRequired: false, restartNote: "No app restart is needed; check the connection in Zed's AI settings.",
            documentation: "https://zed.dev/docs/ai/mcp", bundleIDs: ["dev.zed.Zed"], configPaths: ["~/.config/zed/settings.json"], discoveryWords: ["zed"]),
        AgentHostRow(
            id: "goose", displayName: "Goose", description: "A local assistant for coding and other tasks.", aliases: ["goose cli"],
            installMarkers: ["/Applications/Goose.app", "~/.local/bin/goose"],
            configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
            documentation: "https://github.com/agentclientprotocol/registry/blob/main/goose/agent.json",
            settingsSupported: false,
            acp: AgentHostACP(executable: "goose", arguments: ["acp"],
                              documentation: "https://block-goose.mintlify.app/advanced/acp-protocol",
                              permissionMode: "chat", referenceVersion: "1.51.0", environment: ["GOOSE_MODE": "chat"], protocolVersion: 1),
            discoveryWords: ["goose"]),
        // Nous Research Hermes. Nothing of its own is written: the connection
        // starts `hermes acp`, which runs the person's own Hermes with its
        // memory, provider and model as they are.
        AgentHostRow(
            id: "hermes", displayName: "Hermes", description: "A local agent with its own memory, tools and models.",
            aliases: ["hermes agent", "nous hermes"],
            installMarkers: ["/Applications/Hermes.app", "~/.local/bin/hermes"],
            configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "No restart needed; connection starts an ACP session with reply tools.",
            documentation: "https://hermes-agent.nousresearch.com/docs/user-guide/features/acp",
            settingsSupported: false, bundleIDs: ["com.nousresearch.hermes"],
            // Hermes' default session mode asks before edits and supports continuing its sessions.
            acp: AgentHostACP(executable: "hermes", arguments: ["acp"],
                              documentation: "https://hermes-agent.nousresearch.com/docs/user-guide/features/acp",
                              permissionMode: "default", referenceVersion: "0.21.3", protocolVersion: 1,
                              modes: ["default", "accept_edits", "dont_ask"], supportsLoad: true, supportsResume: true),
            discoveryWords: ["hermes"]),
    ]

    /// An A2A contact's seed: its card, and its port when that is on this Mac
    /// (the local scan looks there). What the card offers is read later.
    static func seed(_ peer: AgentPeerContact) -> AgentHostRow {
        var row = AgentHostRow(id: peer.id, displayName: peer.name, description: "An agent reached over A2A at its card.",
            aliases: [], installMarkers: [], configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "Nothing to restart.",
            documentation: "https://a2a-protocol.org/latest/specification/", settingsSupported: false, declaredRoute: .a2a)
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(peer.endpoint.host ?? ""), let port = peer.endpoint.port { row.a2aPorts = [port] }
        row.a2a = .init(card: peer.endpoint.absoluteString, credential: peer.credentialKey)
        return row
    }

    /// Every known agent host, as its recipe says now. An A2A contact's
    /// recipe is its own, not a host to connect by name.
    public static var rows: [AgentHostRow] { AgentRecipeStore.rows.filter { $0.route != .a2a } }

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

    public static func row(named name: String) -> AgentHostRow? { named(name, in: rows) { $0 } }

    /// THE ONE LOOKUP BY NAME: an exact id first, then a display name, then an
    /// alias, so one host's alias never shadows another host's id.
    static func named<Item>(_ name: String, in items: [Item], _ host: (Item) -> AgentHostRow) -> Item? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        return items.first { normalize(host($0).id) == wanted }
            ?? items.first { normalize(host($0).displayName) == wanted }
            ?? items.first { host($0).aliases.contains { normalize($0) == wanted } }
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

    package static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func expand(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
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

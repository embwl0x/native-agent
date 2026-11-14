import Darwin
import AppKit
import Foundation
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `AgentHostDirectory.swift` | `AgentHostDirectory`, `bridgeDiscoveryDirectory`, `peerDescriptorDirectory`, `installation.evidence`, `executables`, `discoveryWords`, `searchPaths`, `messagingPermissionsPath`, `messagingPermissionSyntax` |

/// Host recipes own configuration and discovery data; the shipped Resources/agent-hosts.json only seeds them. Select writers by format, never host ID, and
/// refuse unsupported configuration shapes rather than guessing.
public struct AgentHostRow: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Equatable, Codable, CaseIterable {
        case jsonMCPServers
        case jsonBareMCPServers
        case jsonContextServers
        case jsonServers
        case gooseYAML
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
    public let aliases: [String]
    /// Program or application paths, never profile directories.
    public let installMarkers: [String]
    public var configPath: String
    public let format: Format
    /// Disclose required restart steps without claiming they prove connection.
    public let restartRequired: Bool
    public let restartNote: String
    public let documentation: String
    public var requiresWorkspace: Bool = false
    public var settingsSupported: Bool = true
    public var declaredRoute: Route? = nil
    public var outboundRoute: String { route == .dotIPC ? "chatgpt-dot-ipc" : route == .desktopChat ? "desktop-chat" : route == .grokBot
        ? "grok-webhook" : acp == nil ? (commandLine == nil ? "none" : "command") : "acp" }
    /// Launch Services finds applications outside the usual Applications folders too.
    public var bundleIDs: [String] = []
    /// Only documented listening ports belong in seeds; contacts retain their card’s own port.
    public var a2aPorts: [Int] = []
    /// Settings-file presence proves setup only; discovery must not read the file here.
    public var configPaths: [String]? = nil
    /// An absent command route cannot be replaced by a guessed window route.
    public var commandLine: AgentHostCommandLine? = nil
    public var acp: AgentHostACP? = nil
    public var a2a: A2A? = nil
    public var searchPaths: [String] = []
    /// Additional program names used as installation evidence, never launched.
    public var executables: [String]? = nil
    public var discoveryWords: [String]? = nil
    /// Messaging allowances must scope only this connection’s two tools.
    public var messagingPermissionsPath: String? = nil
    public var messagingPermissionSyntax: MessagingPermissionSyntax? = nil
    public enum MessagingPermissionSyntax: String, Sendable, Equatable, Codable, CaseIterable {
        case mcpCall, doubleUnderscore, toolDefaults

        func rule(server: String, tool: String) -> String {
            switch self {
            case .mcpCall: "mcp(\(server)/\(tool))"
            case .doubleUnderscore: "mcp__\(server)__\(tool)"
            case .toolDefaults: "mcp:\(server):\(tool)"
            }
        }
    }
    public var desktopChat: DesktopChat? = nil
    public var grokRoutine: GrokRoutine? = nil
    public enum Route: String, Sendable, Codable, CaseIterable { case acp, a2a, dotIPC = "chatgpt-dot-ipc", grokBot = "grok-bot",
        desktopChat = "desktop-chat", commandLine = "command-line", mcpSettingsOnly = "mcp-settings-only" }
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
            let directories = (searchPaths + (acp?.environment["PATH"] ?? "").components(separatedBy: ":").filter { !$0.isEmpty }).map(
                AgentHostDirectory.expand) + markers.filter {
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
        installation.failure?.message ?? (
            "agents/recipes/\(id).json host: bundleIDs=\(bundleIDs), executables=\(programNames), installMarkers=\(installMarkers)"
            + "; searchPaths=\(searchPaths). Install a declared program/app or correct these fields with agent.recipe_write, then agent.verify."
        )
    }

    public func resolveExecutable(_ name: String) -> String? {
        installation.executables[name]
    }

    static func applicationURL(_ id: String) -> URL? {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .first { isInstalledProgram($0.path) }
    }

    public var expandedConfigPath: String { AgentHostDirectory.expand(configPath) }

    /// Recipes own exact window labels; unmatched selectors fail plainly and verification cannot guess replacements.
    public struct DesktopChat: Codable, Sendable, Equatable {
        public var newChat, backToMain, chatsButton, chatsPanel, log, composerCore: String
        public var userPrefix, assistantPrefix, userLabel, assistantMarker, stop: String
        public var unreadSuffix, actionsSuffix, current, currentValue: String
        /// A nil region explicitly selects the whole native window; otherwise the first matching region owns controls and log.
        public var contentRole: String? = nil
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
            public enum Scope: String, Codable, Sendable, CaseIterable { case window, routineRow, menu }
            public enum Action: String, Codable, Sendable, CaseIterable { case press = "AXPress", showMenu = "AXShowMenu", cancel = "AXCancel" }
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
            /// Selection dismisses the menu, so later actions cannot assume it remains open.
            public var ifPresent: Bool
        }


    }

    /// Credentials stay references; sends enforce saved card evidence and only dry runs learn changes.
    public struct A2A: Codable, Sendable, Equatable {
        public var card: String
        public var credential: String?
        public var read: Card? = nil

        /// Retain effective-card fields and digest without raw cards; required unsupported extensions are protocol mismatches.
        public struct Card: Codable, Sendable, Equatable {
            public var endpoint, version, binding: String
            public var tenant: String?
            public var auth: [String]
            public var streaming, pushNotifications, extendedCard: Bool
            public var skills, extensions: [String]
            public var digest: String

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
    /// Use a fixed product entry name so settings identify the app independently of its persona.
    public static var entryName: String { InstallPaths.current.agentHostEntryName() }

    /// Secrets belong in environment values because command-line arguments are world-readable in the process table.
    public static let peerIDVariable = "NATIVE_AGENT_PEER_ID"
    public static let peerSecretVariable = "NATIVE_AGENT_PEER_SECRET"
    /// Name this install’s descriptor explicitly so changing machine-wide ownership cannot redirect the connection’s key.
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

    /// Disclose exactly the tools this entry serves.
    public static let accessSummary =
        "three tools over this Mac's loopback interface only: agent_message and agent_reply, and agent_desk, which reads my Desk only once you "
        + "bring this agent to my table. "
        + "These are tools to message and read me, not restrictions on what the other program can do itself. "
        + "This app applies its own permission settings when it handles a request."

    /// Seed only card location and local scan port; read its offers later.
    static func seed(_ peer: AgentPeerContact) -> AgentHostRow {
        var row = AgentHostRow(id: peer.id, displayName: peer.name, description: "An agent reached over A2A at its card.",
            aliases: [], installMarkers: [], configPath: "", format: .sessionMCP,
            restartRequired: false, restartNote: "Nothing to restart.",
            documentation: "https://a2a-protocol.org/latest/specification/", settingsSupported: false, declaredRoute: .a2a)
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(peer.endpoint.host ?? ""), let port = peer.endpoint.port { row.a2aPorts = [port] }
        row.a2a = .init(card: peer.endpoint.absoluteString, credential: peer.credentialKey)
        return row
    }

    /// A contact’s A2A recipe cannot double as a host connected by name.
    public static var rows: [AgentHostRow] { AgentRecipeStore.rows.filter { $0.route != .a2a } }

    /// Only an inbound request with this connection’s key and one-time nonce proves the setup round trip. The fixed probe asks for no reads, changes or
    /// execution.
    public static let probeToken = "bridge-handshake"

    public static func probeText(appName: String, nonce: String = probeToken) -> String {
        "Connection check from \(appName). Please call your \(entryName) MCP tool agent_message once "
            + "with the text \"\(nonce)\" and nothing else. Do not read, change or run anything."
    }

    public static func row(named name: String) -> AgentHostRow? { named(name, in: rows) { $0 } }

    /// Match exact IDs before display names and aliases so aliases cannot shadow another host’s identity.
    static func named<Item>(_ name: String, in items: [Item], _ host: (Item) -> AgentHostRow) -> Item? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        return items.first { normalize(host($0).id) == wanted }
            ?? items.first { normalize(host($0).displayName) == wanted }
            ?? items.first { host($0).aliases.contains { normalize($0) == wanted } }
    }

    public static var knownNames: [String] { rows.map(\.displayName) }

    // MARK: - The entry, per format

    /// Author JSON entry order explicitly so the person’s settings stay stable and readable.
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
        default_tools_approval_mode = "approve"

        [mcp_servers.\(entryName).env]
        \(bridgeDescriptorVariable) = \(TOMLEntrySplice.quoted(descriptorPath))
        \(peerIDVariable) = \(TOMLEntrySplice.quoted(peerID))
        \(peerSecretVariable) = \(TOMLEntrySplice.quoted(secret))
        """
    }

    /// Describe exact changes without disclosing secret values.
    public static func changesLine(row: AgentHostRow, command: String) -> String {
        let what = "One connection named \"\(entryName)\""
        return "\(what) in \(row.expandedConfigPath), running \(command) mcp. "
            + "Settings outside this connection are left byte for byte as they are. Each owned edit keeps a timestamped "
            + """
                backup beside the file, replaced when that section next changes and removed on disconnect. Because the entry holds this \
                connection's key, that file\u{20}
                """
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

    /// Refuse absent installed link commands instead of writing entries that point nowhere.
    public static func linkCommandPath() -> String? {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let candidate = executable.appendingPathComponent("nativeagent-link").path
        var info = stat()
        guard stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return candidate
    }
}

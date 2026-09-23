import Foundation
import CryptoKit
import NativeAgentCore
import Security
import PersistenceCore

/// THE AGENT DOES THE SETUP ITSELF — narrowly, reversibly, and behind one card.
///
/// Given a NAME, this finds the row, checks the host is really on this Mac,
/// mints a key for THIS connection, and writes exactly one entry into that
/// host's own configuration. Nothing here runs before the person has pressed
/// the button on the card `cardText` composes: `agent_connect` is a confirm-tier
/// tool, so the approval membrane files the card and the tool body only ever
/// executes on the approved replay.
///
/// The key is minted per connection, stored through the existing peer-credential
/// path, and written ONLY into that host's entry as an environment variable.
/// It is never a command-line argument, never a tool result, never a log line
/// and never a conversation row.
public enum AgentHostConnection {
    @TaskLocal static var personApproved = false

    static func isNamedConnect(tool: String, input: [String: JSONValue]) -> Bool {
        func absent(_ key: String) -> Bool {
            input[key] == nil || input[key] == .null || input[key] == .string("")
        }
        return tool == "agent_connect" && absent("endpoint") && absent("app_bundle_id")
            && (absent("transport") || input["transport"] == .string("auto"))
            && (absent("disconnect") || input["disconnect"] == .bool(false))
    }

    public enum Refusal: Error, LocalizedError, Equatable {
        case unknownHost(String)
        case notInstalled(String)
        case linkCommandMissing
        case notInApplications
        case alreadyConnected(String)
        case workspaceRequired

        public var errorDescription: String? {
            switch self {
            case .workspaceRequired:
                return "Name an existing workspace folder for this connection. Nothing was changed."
            case .unknownHost(let name):
                return "I don't know how to set up \"\(name)\" yet. I know: "
                    + AgentHostDirectory.knownNames.joined(separator: ", ")
                    + ". Nothing was changed."
            case .notInstalled(let name):
                return "\(name) does not look installed on this Mac, so there is nothing to write into. Nothing was changed."
            case .linkCommandMissing:
                return "The nativeagent-link command is not installed beside this app, so an entry would point at a command that does not exist. Nothing was changed."
            case .notInApplications:
                return "Move NativeAgent to Applications first. Run from a disk image or quarantined copy, its link path would not last. Nothing was changed."
            case .alreadyConnected(let name):
                return "\(name) is already connected. Disconnect it first if you want a new key."
            }
        }
    }

    /// Everything the card and the result need, worked out BEFORE anything is
    /// written. Carries no secret.
    public struct Proposal: Sendable {
        public let row: AgentHostRow
        public let command: String
        /// THIS install's descriptor file, written into the entry so the other
        /// agent reaches the install that minted its key rather than whichever
        /// one happens to own the machine-wide rendezvous. A path, not a secret.
        public let descriptorPath: String
        public let existing: AgentPeerContact?
        public var workingDirectory: URL = FileManager.default.temporaryDirectory
        public var contactID: String = UUID().uuidString.lowercased()
        public var executable: AgentACPExecutable? = nil
        public var workspace: String? = nil
        public var executablePath: String? = nil
    }

    // MARK: - Look it up

    public static func propose(name: String, store: AgentPeerStore, dataRoot: URL, workspace: String? = nil, workingDirectory: String? = nil) throws -> Proposal {
        guard var row = AgentHostDirectory.row(named: name) else { throw Refusal.unknownHost(name) }
        guard row.settingsSupported || row.acp != nil || row.route == .grokBot else { throw Refusal.unknownHost(name) }
        let folder = try workspaceFolder(row: row, workspace: workspace)
        if let folder { row.configPath = folder + "/" + row.configPath }
        guard row.isInstalled else { throw Refusal.notInstalled(row.displayName) }
        guard let command = AgentHostDirectory.linkCommandPath() else { throw Refusal.linkCommandMissing }
        // A translocated or mounted copy's path vanishes; the entry would point nowhere.
        guard !command.contains("/AppTranslocation/"), !command.hasPrefix("/Volumes/") else { throw Refusal.notInApplications }
        let existing = try store.list().first {
            row.route == .grokBot ? $0.transport == .grokBot : row.acp != nil
                ? $0.transport == .acp && AgentPeerStore.hostRowID($0.endpoint) == row.id
                : $0.transport == .mcpHost && settingsPath(contact: $0) == row.expandedConfigPath
        }
        let contactID = existing?.id ?? UUID().uuidString.lowercased()
        let directory: URL
        if let workingDirectory {
            guard row.acp != nil, workingDirectory.hasPrefix("/") else { throw Refusal.unknownHost("ACP requires an absolute project folder") }
            directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Refusal.notInstalled("Project folder \(directory.path)")
            }
        } else if let saved = existing?.acpWorkingDirectory {
            directory = URL(fileURLWithPath: saved)
        } else {
            directory = SwiftToolDispatcher.builderWorkspaceRoot(dataRoot: dataRoot)
                .appendingPathComponent("agent-bridge-runs/" + (row.acp != nil ? row.id : contactID))
        }
        let executable = try row.acp.map { line in
            guard let path = AgentHostCommandLines.resolveExecutable(line.executable) else { throw Refusal.notInstalled(row.displayName) }
            return try AgentACPExecutable.capture(path: path)
        }
        return Proposal(row: row, command: command,
                        descriptorPath: AgentHostDirectory.bridgeDescriptorPath(dataRoot: dataRoot),
                        existing: existing, workingDirectory: directory, contactID: contactID, executable: executable,
                        workspace: folder,
                        executablePath: executable?.path ?? row.commandLine.flatMap { AgentHostCommandLines.resolveExecutable($0.executable) })
    }

    static func workspaceFolder(row: AgentHostRow, workspace: String?) throws -> String? {
        guard row.requiresWorkspace else {
            guard workspace == nil else { throw Refusal.workspaceRequired }
            return nil
        }
        guard let workspace else { throw Refusal.workspaceRequired }
        let expanded = AgentHostDirectory.expand(workspace)
        var directory: ObjCBool = false
        guard expanded.hasPrefix("/"), !expanded.contains("\0"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &directory), directory.boolValue else {
            throw Refusal.workspaceRequired
        }
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func settingsPath(contact: AgentPeerContact) -> String? {
        guard let row = AgentHostDirectory.rows.first(where: { $0.id == AgentPeerStore.hostRowID(contact.endpoint) }) else { return nil }
        guard row.settingsSupported else { return nil }
        return row.requiresWorkspace ? contact.hostWorkspace.map { $0 + "/" + row.configPath } : row.expandedConfigPath
    }

    // MARK: - The card

    /// The disclosed setup, and nothing else. Line one is the card's title and
    /// the rest is its detail, so the wording below is the wording the person
    /// reads.
    public static func cardText(_ proposal: Proposal, appName: String) -> String {
        let row = proposal.row
        if row.route == .grokBot {
            return """
            Connect to Grok Bot?
            I'll create a routine named for NativeAgent in Grok Bot's current chat, using its desktop app. Keep the chat you want open; I will stop if it is ambiguous or has a draft.
            Grok Bot will ask you to approve running a small local reply command each time, unless you have chosen otherwise in Grok Bot. Ask-every-time means this is not unattended. I will not change that policy; it is independent of NativeAgent Full Mac.
            Reply command: \(proposal.command) reply
            I'll read the routine's webhook URL and key directly into Keychain through Accessibility. If that cannot be done safely, this card offers one secure paste field. Never paste credentials in chat.
            Nothing of this app is opened to the network. Replies use this Mac's existing loopback connection and only answer this contact's pending messages. Disconnect revokes the keys and asks Grok Bot to delete only this app's routine.
            """
        }
        if row.acp != nil {
            return """
            Connect \(row.displayName) to \(appName)?
            Connecting lets \(row.displayName) run on this Mac as you. It can read and change files itself within the access it is allowed, and may send data to its provider using its own account.
            This app asks you only when \(row.displayName) asks it for permission. Our approval cards do not control everything that program can do.
            Starting folder: \(proposal.workingDirectory.path)
            Program: \(proposal.executable?.path ?? "unavailable")
            The program at this path is what will be run. Its absolute path, file identity and digest are re-checked before every launch. If they change, nothing runs until you review a fresh approval. This uses the same trust in files in your folders as any app launch on a Mac.
            \(executableChanges(proposal))
            Reported version: \(proposal.executable?.version ?? "not reported")
            \(row.acp!.versionNote(proposal.executable?.version))
            Requested mode: \(row.acp!.permissionMode). This is the program's own restriction, not an enforcement guarantee from this app.
            Its conversations get two tools to message this agent and read the answer, with a key belonging only to this connection.
            This app does not edit its settings, restart an existing session, or open network access for this connection. You can disconnect later to revoke its messaging key.
            """
        }
        return """
        Connect \(row.displayName) to \(appName)?
        I'll add a messaging connection to \(row.displayName)'s settings so we can exchange messages on this Mac. Existing settings will be preserved.
        Changes: \(AgentHostDirectory.changesLine(row: row, command: proposal.command))\(row.id == "antigravity-cli" ? "\nAntigravity permissions: allow only this connection's agent_message and agent_reply MCP tools. Disconnect removes only allowances added here; existing Ask/Deny rules are never overridden." : "")
        Access: \(AgentHostDirectory.accessSummary)
        Restart: \(row.restartNote)\(Self.probeLine(proposal))
        You can disconnect later. This does not open access from the network.
        """
    }

    private static func executableChanges(_ proposal: Proposal) -> String {
        guard let old = proposal.existing?.acpExecutable else { return "" }
        guard let new = proposal.executable else {
            return "Changed: the approved program at \(old.path) is missing or cannot be verified."
        }
        var changes: [String] = []
        if old.path != new.path { changes.append("Path: \(old.path) → \(new.path)") }
        if old.device != new.device || old.inode != new.inode {
            changes.append("File identity: \(old.device):\(old.inode) → \(new.device):\(new.inode)")
        }
        if old.digest != new.digest { changes.append("Digest: \(old.digest) → \(new.digest)") }
        return changes.isEmpty ? "" : "Changed since approval:\n" + changes.joined(separator: "\n")
    }

    /// The probe is part of the disclosed setup, so the card says it before
    /// anything runs: one run of that agent's own command line, with a fixed
    /// message that asks for nothing to be read, changed or run.
    private static func probeLine(_ proposal: Proposal) -> String {
        let row = proposal.row
        guard let executable = proposal.executablePath else { return "\nCheck: no executable found; nothing will run." }
        if row.commandLine?.automaticMCPProbe == false {
            return "\nExecutable: \(executable)\nCheck: send a message after setup to verify the connection; setup itself does not run this agent."
        }
        return "\nExecutable: \(executable)\nCheck: once, right after the entry is written, this exact path is run with a fixed "
            + "message asking \(row.displayName) to answer back through the entry, so \"connected\" means "
            + "a message really crossed rather than a file having been written. It runs under your "
            + "ordinary permission for running a command, in an empty directory of its own, and it asks "
            + "for nothing to be read, changed or run."
    }

    // MARK: - Do it

    /// Mint, store, write, save — in that order, and every step undone if a
    /// later one fails. The returned projection never contains the key.
    public static func connect(proposal: Proposal, store: AgentPeerStore) throws
        -> (contact: AgentPeerContact, outcome: AgentHostConfigWriter.Outcome) {
        if proposal.row.route == .grokBot {
            if let existing = proposal.existing {
                return (existing, .init(path: "", backupPath: nil, replacedExistingEntry: false, removed: false))
            }
            var contact = AgentPeerContact(id: proposal.contactID, name: proposal.row.displayName,
                endpoint: URL(string: "grok://grok-bot")!, transport: .grokBot)
            contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
            contact.approvedExecutablePath = proposal.command
            contact.grokSetup = "creating"
            let secret = try mintKey()
            try AgentPeerCredentials.write(secret, peerID: contact.id)
            do {
                try GrokLinkCredential(descriptorPath: proposal.descriptorPath, replyToken: secret).write(peer: contact.id, helperPath: proposal.command)
                _ = try store.upsert(contact)
            } catch {
                try? GrokLinkCredential.delete(peer: contact.id)
                try? AgentPeerCredentials.delete(peerID: contact.id)
                throw error
            }
            return (contact, .init(path: "", backupPath: nil, replacedExistingEntry: false, removed: false))
        }
        if proposal.row.acp != nil {
            guard proposal.executable?.isCurrent == true,
                  proposal.executablePath == nil || proposal.executablePath == proposal.executable?.path
            else { throw Refusal.notInstalled("The approved executable changed; connect again") }
            if var contact = proposal.existing {
                contact.acpExecutable = proposal.executable
                contact.approvedExecutablePath = proposal.executable?.path
                contact.acpWorkingDirectory = proposal.workingDirectory.path
                contact = try store.upsert(contact, resetProof: true)
                return (contact, AgentHostConfigWriter.Outcome(path: "", backupPath: nil, replacedExistingEntry: false, removed: false))
            }
        } else {
            guard proposal.existing == nil else { throw Refusal.alreadyConnected(proposal.row.displayName) }
        }
        let row = proposal.row
        guard row.settingsSupported || row.acp != nil else { throw Refusal.unknownHost(row.displayName) }
        guard let endpoint = URL(string: (row.acp == nil ? "mcp://" : "acp://") + row.id) else { throw Refusal.unknownHost(row.id) }
        var contact = AgentPeerContact(id: proposal.contactID, name: row.displayName, endpoint: endpoint, transport: row.acp == nil ? .mcpHost : .acp)
        if row.acp != nil {
            contact.acpWorkingDirectory = proposal.workingDirectory.path
            contact.acpExecutable = proposal.executable
            try FileManager.default.createDirectory(at: proposal.workingDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        contact.hostWorkspace = proposal.workspace
        contact.approvedExecutablePath = proposal.executable?.path ?? proposal.executablePath
        contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
        try AgentPeerStore.validate(contact)

        let secret = try mintKey()
        try AgentPeerCredentials.write(secret, peerID: contact.id)
        do {
            let outcome: AgentHostConfigWriter.Outcome
            if row.acp != nil {
                outcome = AgentHostConfigWriter.Outcome(path: "", backupPath: nil, replacedExistingEntry: false, removed: false)
            } else {
            switch row.format {
            case .sessionMCP:
                outcome = AgentHostConfigWriter.Outcome(path: "", backupPath: nil, replacedExistingEntry: false, removed: false)
            case .jsonMCPServers, .jsonBareMCPServers, .jsonContextServers, .jsonServers:
                outcome = try AgentHostConfigWriter.writeJSONEntry(
                    path: row.expandedConfigPath,
                    name: AgentHostDirectory.entryName,
                    entryJSON: AgentHostDirectory.jsonEntry(
                        command: proposal.command, peerID: contact.id, secret: secret,
                        descriptorPath: proposal.descriptorPath, format: row.format),
                    backupRecordURL: backupRecordURL(row: row, store: store),
                    containerKey: row.format.containerKey, comments: row.format.comments, trailingCommas: row.format.trailingCommas)
            case .gooseYAML:
                outcome = try AgentHostConfigWriter.writeGooseEntry(
                    path: row.expandedConfigPath, name: AgentHostDirectory.entryName,
                    entryJSON: AgentHostDirectory.jsonEntry(command: proposal.command, peerID: contact.id,
                        secret: secret, descriptorPath: proposal.descriptorPath, format: row.format),
                    backupRecordURL: backupRecordURL(row: row, store: store))
            case .codexTOML:
                outcome = try AgentHostConfigWriter.writeTOMLEntry(
                    path: row.expandedConfigPath,
                    name: AgentHostDirectory.entryName,
                    entryTOML: AgentHostDirectory.codexEntry(
                        command: proposal.command, peerID: contact.id, secret: secret,
                        descriptorPath: proposal.descriptorPath),
                    backupRecordURL: backupRecordURL(row: row, store: store))
            }
            }
            do {
                _ = try ensureMessagingPermissions(contact: contact, store: store)
                _ = try store.upsert(contact)
            }
            catch {
                // Undo only our entry using its ownership receipt, which also
                // restores any entry it replaced. A whole-file backup would
                // overwrite settings the host saved after our write.
                if row.acp != nil || row.format == .sessionMCP {
                    // No settings were changed.
                } else {
                    try? removeMessagingPermissions(contact: contact, store: store)
                    try? removeEntry(row: row, store: store, peerID: contact.id)
                }
                throw error
            }
            return (contact, outcome)
        } catch {
            try? AgentPeerCredentials.delete(peerID: contact.id)
            throw error
        }
    }

    /// Disconnect removes exactly our entry and revokes that connection's key.
    public static func disconnect(contact: AgentPeerContact, store: AgentPeerStore) throws
        -> AgentHostConfigWriter.Outcome? {
        guard let id = AgentPeerStore.hostRowID(contact.endpoint),
              var row = AgentHostDirectory.rows.first(where: { $0.id == id }) else { return nil }
        if contact.transport == .acp {
            try AgentPeerCredentials.delete(peerID: contact.id)
            _ = try store.remove(contact.id)
            return AgentHostConfigWriter.Outcome(path: "", backupPath: nil, replacedExistingEntry: false, removed: true)
        }
        guard row.settingsSupported else { throw Refusal.unknownHost(row.displayName) }
        if let path = settingsPath(contact: contact) { row.configPath = path }
        // Keep the contact and ownership receipt until revocation succeeds,
        // so a failed removal or key deletion can be retried.
        try removeMessagingPermissions(contact: contact, store: store)
        let outcome = try removeEntry(row: row, store: store, peerID: contact.id)
        try AgentPeerCredentials.delete(peerID: contact.id)
        _ = try store.remove(contact.id)
        try AgentHostConfigWriter.removeBackups(path: row.expandedConfigPath,
            recordURL: backupRecordURL(row: row, store: store))
        return outcome
    }

    static func ensureMessagingPermissions(contact: AgentPeerContact, store: AgentPeerStore) throws -> Bool {
        guard AgentPeerStore.hostRowID(contact.endpoint) == "antigravity-cli" else { return false }
        let outcome = try AgentHostConfigWriter.grantAntigravityMessaging(
            path: AgentHostDirectory.expand("~/.gemini/antigravity-cli/settings.json"),
            server: AgentHostDirectory.entryName, peerID: contact.id, recordURL: permissionRecord(contact, store))
        return outcome.backupPath != nil
    }

    private static func removeMessagingPermissions(contact: AgentPeerContact, store: AgentPeerStore) throws {
        guard AgentPeerStore.hostRowID(contact.endpoint) == "antigravity-cli" else { return }
        try AgentHostConfigWriter.removeAntigravityMessaging(
            path: AgentHostDirectory.expand("~/.gemini/antigravity-cli/settings.json"),
            server: AgentHostDirectory.entryName, peerID: contact.id, recordURL: permissionRecord(contact, store))
    }

    private static func permissionRecord(_ contact: AgentPeerContact, _ store: AgentPeerStore) -> URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("antigravity-\(contact.id)-permission-backups.json")
    }

    private static func backupRecordURL(row: AgentHostRow, store: AgentPeerStore) -> URL {
        let scope = row.requiresWorkspace ? "-" + SHA256.hash(data: Data(row.expandedConfigPath.utf8))
            .map { String(format: "%02x", $0) }.joined() : ""
        return store.fileURL.deletingLastPathComponent().appendingPathComponent("\(row.id)\(scope)-config-backups.json")
    }

    private static func removeEntry(row: AgentHostRow, store: AgentPeerStore, peerID: String? = nil) throws -> AgentHostConfigWriter.Outcome {
        switch row.format {
        case .sessionMCP:
            return AgentHostConfigWriter.Outcome(path: "", backupPath: nil, replacedExistingEntry: false, removed: true)
        case .jsonMCPServers, .jsonBareMCPServers, .jsonContextServers, .jsonServers:
            return try AgentHostConfigWriter.removeJSONEntry(
                path: row.expandedConfigPath, name: AgentHostDirectory.entryName,
                backupRecordURL: backupRecordURL(row: row, store: store),
                containerKey: row.format.containerKey, comments: row.format.comments, trailingCommas: row.format.trailingCommas, peerID: peerID)
        case .gooseYAML:
            return try AgentHostConfigWriter.removeGooseEntry(path: row.expandedConfigPath,
                name: AgentHostDirectory.entryName, backupRecordURL: backupRecordURL(row: row, store: store))
        case .codexTOML:
            return try AgentHostConfigWriter.removeTOMLEntry(
                path: row.expandedConfigPath, name: AgentHostDirectory.entryName,
                backupRecordURL: backupRecordURL(row: row, store: store), peerID: peerID)
        }
    }

    /// 256 bits from the system generator, in the printable-ASCII alphabet the
    /// bearer validator already enforces.
    private static func mintKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AgentPeerCredentials.CredentialError.unavailable
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

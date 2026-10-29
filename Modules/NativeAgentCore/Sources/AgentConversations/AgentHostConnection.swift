import AgentLinkTransport
import AgentWorkspace
import Foundation
import CryptoKit
import NativeAgentCore
import Security
import PersistenceCore
import Experiences
// Blueprint: | `AgentHostConnection.swift` | `AgentHostConnection` enum; `builderWorkspaceRoot`, `isNamedConnect`; Connect resolves host or exact peer identity (a peer only in its own workspace; another folder is that folder's own contact), re-mints a missing key on the same contact, retires proof and rewrites only its connector entry under the settings lock; elevation remains store-owned; disconnect revokes before settings cleanup and keeps failed cleanup owed to the person through RepairOwed and fileRepairInstruction; missing helpers and secure-random failures name the defect and person; `verifySetup` stays read-only |

/// One reversible setup path for discovery and the person's Connect action.
///
/// Given a NAME, this finds the row, checks the host is really on this Mac,
/// mints a key for THIS connection, and writes exactly one entry into that
/// host's own configuration. Discovery connects settings-file hosts without
/// running them or granting authority. Other routes keep their approval cards.
///
/// The key is minted per connection, stored through the existing peer-credential
/// path, and written ONLY into that host's entry as an environment variable.
/// It is never a command-line argument, never a tool result, never a log line
/// and never a conversation row.
public enum AgentHostConnection {
    package static func builderWorkspaceRoot(dataRoot: URL) -> URL {
        NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    @TaskLocal package static var personApproved = false

    package static func isNamedConnect(tool: String, input: [String: JSONValue]) -> Bool {
        func absent(_ key: String) -> Bool {
            input[key] == nil || input[key] == .null || input[key] == .string("")
        }
        return tool == "agent_connect" && absent("endpoint") && absent("app_bundle_id")
            && (absent("transport") || input["transport"] == .string("auto"))
            && (absent("disconnect") || input["disconnect"] == .bool(false)) && absent("ability")
    }

    public enum Refusal: Error, LocalizedError, Equatable {
        case unknownHost(String)
        case notInstalled(String)
        case linkCommandMissing
        case notInApplications
        case workspaceRequired(String)

        public var errorDescription: String? {
            switch self {
            case .workspaceRequired(let checked):
                return "Workspace check failed: \(checked). Supply an existing absolute directory when host.requiresWorkspace is true; omit workspace when false. Nothing was changed."
            case .unknownHost(let name):
                return "No supported host matches \"\(name)\" in agents/recipes (host.id, displayName, aliases and route). Read agent.recipe, then correct a matching recipe or create one with a new host.id using agent.recipe_write. Known hosts: "
                    + AgentHostDirectory.knownNames.joined(separator: ", ")
                    + ". Nothing was changed."
            case .notInstalled(let name):
                return "Installation check failed: \(name). Nothing was changed."
            case .linkCommandMissing:
                return "Helper check failed: \(Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("nativeagent-link").path ?? "app executable unavailable") must be a regular installed nativeagent-link file. Tell the person this copy of NativeAgent has a missing or invalid contact helper. Nothing was changed."
            case .notInApplications:
                return "Helper path \(AgentHostDirectory.linkCommandPath() ?? "missing") is under /Volumes or /AppTranslocation. Move the complete app to Applications so its connector path persists, then agent.verify. Nothing was changed."
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
        public var existing: AgentPeerContact?
        public var workingDirectory: URL = FileManager.default.temporaryDirectory
        public var contactID: String = UUID().uuidString.lowercased()
        public var executable: AgentACPExecutable? = nil
        public var workspace: String? = nil
        public var executablePath: String? = nil
    }

    // MARK: - Look it up

    public static func propose(name: String, store: AgentPeerStore, dataRoot: URL, workspace: String? = nil, workingDirectory: String? = nil) throws -> Proposal {
        var named = try store.list().first { $0.id == name || "peer:" + $0.id == name }
        guard var row = AgentHostDirectory.row(named: named.flatMap { AgentPeerStore.hostRowID($0.endpoint) } ?? name) else { throw Refusal.unknownHost(name) }
        guard row.settingsSupported || row.format == .shellEnvironment || row.acp != nil || row.route == .grokBot else { throw Refusal.unknownHost(name) }
        let folder = try workspaceFolder(row: row, workspace: workspace ?? named?.hostWorkspace)
        // A contact's key never leaves its own workspace: another folder is that folder's own contact.
        if folder != named?.hostWorkspace { named = nil }
        if let folder { row.configPath = folder + "/" + row.configPath }
        if let failure = row.installation.failure { throw failure }
        guard row.isInstalled else { throw Refusal.notInstalled(row.installationCheck) }
        guard let command = AgentHostDirectory.linkCommandPath() else { throw Refusal.linkCommandMissing }
        // A translocated or mounted copy's path vanishes; the entry would point nowhere.
        guard !command.contains("/AppTranslocation/"), !command.hasPrefix("/Volumes/") else { throw Refusal.notInApplications }
        let existing = try named ?? store.list().first {
            row.route == .grokBot ? $0.transport == .grokBot : row.acp != nil
                ? $0.transport == .acp && AgentPeerStore.hostRowID($0.endpoint) == row.id
                : $0.transport == .mcpHost && settingsPath(contact: $0) == row.expandedConfigPath
        }
        let contactID = existing?.id ?? UUID().uuidString.lowercased()
        let directory: URL
        if let workingDirectory {
            guard row.acp != nil, workingDirectory.hasPrefix("/") else { throw Refusal.workspaceRequired("host.acp and working_directory=\(workingDirectory); ACP needs an existing absolute project directory") }
            directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Refusal.notInstalled("working_directory=\(directory.path) must exist and be a directory; supply that folder to agent.connect")
            }
        } else if let saved = existing?.acpWorkingDirectory {
            directory = URL(fileURLWithPath: saved)
        } else {
            directory = builderWorkspaceRoot(dataRoot: dataRoot)
                .appendingPathComponent("agent-bridge-runs/" + (row.acp != nil ? row.id : contactID))
        }
        let executable = try row.acp.map { line in
            guard let path = row.resolveExecutable(line.executable) else { throw Refusal.notInstalled(row.installationCheck) }
            return try AgentACPExecutable.capture(path: path)
        }
        return Proposal(row: row, command: command,
                        descriptorPath: AgentHostDirectory.bridgeDescriptorPath(dataRoot: dataRoot),
                        existing: existing, workingDirectory: directory, contactID: contactID, executable: executable,
                        workspace: folder,
                        executablePath: executable?.path ?? row.commandLine.flatMap { row.resolveExecutable($0.executable) })
    }

    static func workspaceFolder(row: AgentHostRow, workspace: String?) throws -> String? {
        let checked = "agents/recipes/\(row.id).json host.requiresWorkspace=\(row.requiresWorkspace), workspace=\(workspace ?? "missing")"
        guard row.requiresWorkspace else {
            guard workspace == nil else { throw Refusal.workspaceRequired(checked) }
            return nil
        }
        guard let workspace else { throw Refusal.workspaceRequired(checked) }
        let expanded = AgentHostDirectory.expand(workspace)
        var directory: ObjCBool = false
        guard expanded.hasPrefix("/"), !expanded.contains("\0"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &directory), directory.boolValue else {
            throw Refusal.workspaceRequired(checked)
        }
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func settingsPath(contact: AgentPeerContact) -> String? {
        guard let row = AgentHostDirectory.rows.first(where: { $0.id == AgentPeerStore.hostRowID(contact.endpoint) }) else { return nil }
        guard row.settingsSupported || row.format == .shellEnvironment else { return nil }
        return row.requiresWorkspace ? contact.hostWorkspace.map { $0 + "/" + row.configPath } : row.expandedConfigPath
    }

    // MARK: - The card

    /// The disclosed setup, and nothing else. Line one is the card's title and
    /// the rest is its detail, so the wording below is the wording the person
    /// reads.
    public static func cardText(_ proposal: Proposal, appName: String) -> String {
        let row = proposal.row
        if row.format == .shellEnvironment {
            return """
            Connect \(row.displayName) to \(appName)?
            I'll create this contact's own messaging key and a private (0600) environment file at \(row.expandedConfigPath). No ChatGPT settings are edited.
            Dot can message me through this Mac's installed nativeagent-link command and read my answer in the same command, or use reply if the answer is enqueued. I can message Dot in its current ChatGPT conversation after checking the running app and conversation.
            Dot is an outside agent. Its Trust switch starts off; requests use the normal per-agent permission checks.
            Disconnect removes the environment file, revokes the key and removes the contact. This does not open network access.
            """
        }
        if row.route == .grokBot {
            return """
            Connect to Grok Bot?
            I'll create a routine named for NativeAgent in this connection's selected Bot chat, using its desktop app. Setup stops if that chat is ambiguous or has a draft.
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
            Version: read from its --version only after you approve. Written against \(row.acp!.referenceVersion) (ACP registry pin).
            Requested mode: \(row.acp!.permissionMode). This is the program's own restriction, not an enforcement guarantee from this app.
            Its conversations get two tools to message this agent and read the answer, with a key belonging only to this connection.
            This app does not edit its settings, restart an existing session, or open network access for this connection. You can disconnect later to revoke its messaging key.
            """
        }
        return """
        Connect \(row.displayName) to \(appName)?
        I'll add a messaging connection to \(row.displayName)'s settings so we can exchange messages on this Mac. Existing settings will be preserved.
        Changes: \(AgentHostDirectory.changesLine(row: row, command: proposal.command))\(row.messagingPermissionsPath != nil ? "\nMessaging permissions (host.messagingPermissionsPath=\(row.messagingPermissionsPath!)): allow only this connection's agent_message and agent_reply MCP tools. Disconnect removes only allowances added here; existing Ask/Deny rules are never overridden." : "")
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
        guard let executable = proposal.executablePath else { return "\nCheck: host.commandLine in agents/recipes/\(row.id).json supplies no executable. agent.verify checks host.configPath=\(row.expandedConfigPath); an inbound message through its connector proves the connection. Nothing will run." }
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
        -> (contact: AgentPeerContact, outcome: AgentHostConfigWriter.Outcome, permissionsChanged: Bool) {
        // Both doors hold the settings path through mint, splice, receipts and save.
        try CredentialFileLock.withLock(URL(fileURLWithPath: proposal.row.expandedConfigPath.isEmpty
            ? backupRecordURL(row: proposal.row, store: store).path : proposal.row.expandedConfigPath)) {
            var proposal = proposal
            proposal.existing = try store.list().first {
                if let existing = proposal.existing { return $0.endpoint == existing.endpoint && $0.id == existing.id }
                return AgentPeerStore.hostRowID($0.endpoint) == proposal.row.id && $0.hostWorkspace == proposal.workspace
            }
            if proposal.row.route == .grokBot {
                if let existing = proposal.existing {
                    return (existing, .init(path: "", backupPath: nil, replacedExistingEntry: false, removed: false), false)
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
                return (contact, .init(path: "", backupPath: nil, replacedExistingEntry: false, removed: false), false)
            }
            if proposal.row.acp != nil {
                guard proposal.executable?.isCurrent == true,
                      proposal.executablePath == nil || proposal.executablePath == proposal.executable?.path
                else { throw Refusal.notInstalled("ACP receipt at \(proposal.executable?.path ?? "missing") failed its file identity/digest check against host.acp.executable; connect again to approve the installed program. \(proposal.row.installationCheck)") }
                if var contact = proposal.existing {
                    contact.acpExecutable = proposal.executable
                    contact.approvedExecutablePath = proposal.executable?.path
                    contact.acpWorkingDirectory = proposal.workingDirectory.path
                    contact = try store.upsert(contact, resetProof: true)
                    return (contact, AgentHostConfigWriter.Outcome(path: "", backupPath: nil, replacedExistingEntry: false, removed: false), false)
                }
            } else if var contact = proposal.existing {
                let saved = try AgentPeerCredentials.read(peerID: contact.id)
                // Retire old proof before a replacement key can authenticate.
                // The store preserves the contact's identity and elevation; a
                // contact saved before it had a key gets its own key slot here.
                if saved == nil || contact.credentialKey == nil {
                    contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
                    contact = try store.upsert(contact, resetProof: true)
                }
                let secret = try saved ?? mintKey()
                if saved == nil { try AgentPeerCredentials.write(secret, peerID: contact.id) }
                var permissionsChanged = false
                do {
                    permissionsChanged = try ensureMessagingPermissions(contact: contact, store: store)
                    let outcome = try AgentHostConfigWriter.$repairingPeer.withValue(contact.id) {
                        try writeEntry(proposal, secret: secret, store: store)
                    }
                    if saved != nil, outcome.backupPath != nil { contact = try store.upsert(contact, resetProof: true) }
                    return (contact, outcome, permissionsChanged)
                }
                catch {
                    if saved == nil { try AgentPeerCredentials.delete(peerID: contact.id) }
                    if permissionsChanged { try removeMessagingPermissions(contact: contact, store: store) }
                    throw error
                }
            }
            let row = proposal.row
            guard row.settingsSupported || row.format == .shellEnvironment || row.acp != nil else { throw Refusal.unknownHost(row.displayName) }
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
            // A command contact's receipt: the file a Full Mac launch of it may run.
            if row.acp == nil, row.commandLine != nil, let path = contact.approvedExecutablePath {
                contact.acpExecutable = try? AgentACPExecutable.capture(path: path)
            }
            contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
            try AgentPeerStore.validate(contact)

            let secret = try mintKey()
            try AgentPeerCredentials.write(secret, peerID: contact.id)
            do {
                let outcome = try writeEntry(proposal, secret: secret, store: store)
                do {
                    let permissionsChanged = try ensureMessagingPermissions(contact: contact, store: store)
                    _ = try store.upsert(contact)
                    return (contact, outcome, permissionsChanged)
                }
                catch {
                    if row.acp == nil, row.format != .sessionMCP {
                        try? removeMessagingPermissions(contact: contact, store: store)
                        try? removeEntry(row: row, store: store, peerID: contact.id)
                    }
                    throw error
                }
            } catch {
                try? AgentPeerCredentials.delete(peerID: contact.id)
                if let decided = error as? ToolFailureError, decided.personDecides { throw decided }
                throw AgentHostConfigWriter.Failure.unreadable("host.configPath=\(row.expandedConfigPath), host.format=\(row.format.rawValue): \(error.localizedDescription). Correct that file or those recipe fields, then agent.verify")
            }
        }
    }

    private static func writeEntry(_ proposal: Proposal, secret: String, store: AgentPeerStore) throws -> AgentHostConfigWriter.Outcome {
        let row = proposal.row
        let peerID = proposal.existing?.id ?? proposal.contactID
        if row.acp != nil { return .init(path: "", backupPath: nil, replacedExistingEntry: false, removed: false) }
        switch row.format {
            case .shellEnvironment:
                return try AgentHostConfigWriter.writeEnvironment(path: row.expandedConfigPath,
                    descriptorPath: proposal.descriptorPath, peerID: peerID, secret: secret)
            case .sessionMCP:
                return .init(path: "", backupPath: nil, replacedExistingEntry: false, removed: false)
            case .jsonMCPServers, .jsonBareMCPServers, .jsonContextServers, .jsonServers:
                return try AgentHostConfigWriter.writeJSONEntry(
                    path: row.expandedConfigPath,
                    name: AgentHostDirectory.entryName,
                    entryJSON: AgentHostDirectory.jsonEntry(
                        command: proposal.command, peerID: peerID, secret: secret,
                        descriptorPath: proposal.descriptorPath, format: row.format),
                    backupRecordURL: backupRecordURL(row: row, store: store),
                    containerKey: row.format.containerKey, comments: row.format.comments, trailingCommas: row.format.trailingCommas)
            case .gooseYAML:
                return try AgentHostConfigWriter.writeGooseEntry(
                    path: row.expandedConfigPath, name: AgentHostDirectory.entryName,
                    entryJSON: AgentHostDirectory.jsonEntry(command: proposal.command, peerID: peerID,
                        secret: secret, descriptorPath: proposal.descriptorPath, format: row.format),
                    backupRecordURL: backupRecordURL(row: row, store: store))
            case .codexTOML:
                return try AgentHostConfigWriter.writeTOMLEntry(
                    path: row.expandedConfigPath,
                    name: AgentHostDirectory.entryName,
                    entryTOML: AgentHostDirectory.codexEntry(
                        command: proposal.command, peerID: peerID, secret: secret,
                        descriptorPath: proposal.descriptorPath),
                    backupRecordURL: backupRecordURL(row: row, store: store))
        }
    }

    /// The same proposal and splice as Connect, stopping before any write or mint.
    package static func verifySetup(name: String, store: AgentPeerStore, dataRoot: URL, workspace: String? = nil) -> JSONValue {
        var checked = "agents/recipes/\(name).json host.id/displayName/aliases"
        var host = name
        do {
            let proposal = try propose(name: name, store: store, dataRoot: dataRoot, workspace: workspace)
            host = proposal.existing.map { "peer:" + $0.id } ?? proposal.row.id
            checked = "agents/recipes/\(proposal.row.id).json host.configPath=\(proposal.row.expandedConfigPath), host.format=\(proposal.row.format.rawValue)"
            return try CredentialFileLock.withLock(URL(fileURLWithPath: proposal.row.expandedConfigPath)) {
                let secret: String
                if let peer = proposal.existing {
                    guard let saved = try AgentPeerCredentials.read(peerID: peer.id) else {
                        return .object(["status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false), "changed": .bool(false),
                            "detail": .string("This contact's Keychain key is missing. Connect repairs this same contact and rewrites its connector entry; no disconnect is needed."),
                            "remedy": Repair.remedy(owner: "Keychain peer:" + peer.id, nextCall: .object(["tool": .string("app"),
                                "input": .object(["action": .string("agent.connect"), "args": .object(["name": .string("peer:" + peer.id)])])]), tap: nil)])
                    }
                    secret = saved
                } else { secret = "dry-run" }
                _ = try AgentHostConfigWriter.$checking.withValue(proposal.existing != nil) {
                    _ = try writeEntry(proposal, secret: secret, store: store)
                    let peer = proposal.existing ?? AgentPeerContact(id: proposal.contactID, name: proposal.row.displayName,
                        endpoint: URL(string: "mcp://" + proposal.row.id)!, transport: .mcpHost)
                    _ = try ensureMessagingPermissions(contact: peer, store: store)
                }
                return .object(["status": .string("passed"), "dry_run": .bool(true), "sent": .bool(false), "changed": .bool(false),
                    "detail": .string("Checked \(proposal.row.installationCheck) host.configPath=\(proposal.row.expandedConfigPath), host.format=\(proposal.row.format.rawValue), helper=\(proposal.command). \(proposal.existing == nil ? "The Connect splice accepts these settings; agent.connect will mint its credential and save its peer." : "The settings match this contact's helper, descriptor, peer ID and credential.") No message crossed, so readiness stays as it was (unverified since the recipe changed until a message crosses on it; send one to prove the door). Restart: \(proposal.row.restartNote)")])
            }
        } catch AgentHostConfigWriter.Failure.staleEntry(let at, let helper, let gone) {
            // Not a recipe fault: the entry is another install's, and connect is the lever.
            return .object(["status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false), "changed": .bool(false),
                "reason": .string("stale_entry"),
                "detail": .string(AgentHostConfigWriter.Failure.staleEntry(at: at, helper: helper, gone: gone).localizedDescription),
                "remedy": Repair.remedy(owner: checked, nextCall: .object(["tool": .string("app"), "input": .object([
                    "action": .string("agent.connect"), "args": .object(["name": .string(host)])])]), tap: nil)])
        } catch let failure as ToolFailureError where failure.owner != nil {
            return .object(failure.failureEvidence(defaultCode: "agent_verify_failed").merging([
                "status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false), "changed": .bool(false),
                "detail": .string(failure.localizedDescription)]) { _, delivery in delivery })
        } catch {
            return .object(["status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false), "changed": .bool(false),
                "detail": .string("Checked \(checked): \(error.localizedDescription) Read agent.recipe, correct its host fields with agent.recipe_write or the named file, then agent.verify.")])
        }
    }

    package static func ensureEnvironment(proposal: Proposal, store: AgentPeerStore) throws
        -> (contact: AgentPeerContact, repaired: Bool) {
        guard let contact = proposal.existing, proposal.row.format == .shellEnvironment else {
            throw Refusal.unknownHost(proposal.row.displayName)
        }
        let saved = try AgentPeerCredentials.read(peerID: contact.id)
        let secret = try saved ?? mintKey()
        if saved == nil { try AgentPeerCredentials.write(secret, peerID: contact.id) }
        do {
            let repaired = try AgentHostConfigWriter.ensureEnvironment(path: proposal.row.expandedConfigPath,
                descriptorPath: proposal.descriptorPath, peerID: contact.id, secret: secret)
            let settled = saved == nil ? try store.upsert(contact, resetProof: true) : contact
            return (settled, repaired || saved == nil)
        } catch {
            if saved == nil { try? AgentPeerCredentials.delete(peerID: contact.id) }
            throw error
        }
    }

    /// Disconnect removes exactly our entry and revokes that connection's key.
    public static func disconnect(contact: AgentPeerContact, store: AgentPeerStore) throws
        -> AgentHostConfigWriter.Outcome? {
        guard let id = AgentPeerStore.hostRowID(contact.endpoint),
              var row = AgentHostDirectory.rows.first(where: { $0.id == id }) else {
            try AgentPeerCredentials.delete(peerID: contact.id)
            _ = try store.remove(contact.id)
            return nil
        }
        if contact.transport == .acp {
            try AgentPeerCredentials.delete(peerID: contact.id)
            _ = try store.remove(contact.id)
            return AgentHostConfigWriter.Outcome(path: "", backupPath: nil, replacedExistingEntry: false, removed: true)
        }
        guard row.settingsSupported || row.format == .shellEnvironment else { throw Refusal.unknownHost(row.displayName) }
        if let path = settingsPath(contact: contact) { row.configPath = path }
        // Keep the person's no before revoking anything. Discovery and dismissal
        // use this same lock, so an in-flight scan cannot erase the decision.
        let root = store.fileURL.deletingLastPathComponent().deletingLastPathComponent()
        try CredentialFileLock.withLock(AgentDiscoveryOffer.url(root)) {
            guard var offers = AgentDiscoveryOffer.read(root) else { throw AgentHostConfigWriter.Failure.unreadable(AgentDiscoveryOffer.url(root).path) }
            var entry = offers[id] ?? AgentDiscoveryOffer(name: row.displayName)
            entry.declinedAt = Date()
            offers[id] = entry
            try AgentDiscoveryOffer.write(offers, root)
        }
        // Revoking our credential never depends on proving ownership of
        // another application's bytes. Keep the contact for cleanup recovery.
        return try CredentialFileLock.withLock(URL(fileURLWithPath: row.expandedConfigPath.isEmpty
            ? backupRecordURL(row: row, store: store).path : row.expandedConfigPath)) {
            try AgentPeerCredentials.delete(peerID: contact.id)
            let operation = "peer.cleanup:" + contact.id
            let outcome: AgentHostConfigWriter.Outcome
            do {
                try removeMessagingPermissions(contact: contact, store: store)
                outcome = try removeEntry(row: row, store: store, peerID: contact.id)
            } catch {
                let id = "peer-cleanup:" + UUID().uuidString.lowercased()
                let detail = "Credential revoked for peer:\(contact.id). Configuration removal failed: \(error.localizedDescription)."
                let repair = ToolFailureError.fileRepairInstruction(URL(fileURLWithPath: row.expandedConfigPath),
                    shape: "Contact configuration removal failed: \(error.localizedDescription). Inspect its ownership receipt at \(backupRecordURL(row: row, store: store).path) and named displaced paths. Preserve every displaced version, other contact's entry and secret value; never print secrets, invent ownership or delete an unproven file.")
                RepairOwed.owe(root, id: id, kind: .act, operation: operation,
                    owner: row.expandedConfigPath, words: detail, tap: repair)
                throw ToolFailureError(detail, effects: .partial, owner: row.expandedConfigPath,
                    tap: repair,
                    code: "agent_configuration_removal_failed",
                    instruction: repair, recovery: .repair)
            }
            _ = try store.remove(contact.id)
            if row.format != .shellEnvironment {
                try AgentHostConfigWriter.removeBackups(path: row.expandedConfigPath,
                    recordURL: backupRecordURL(row: row, store: store))
            }
            RepairOwed.settle(root, operation: operation, evidence: .init(source: row.expandedConfigPath, id: contact.id))
            return outcome
        }
    }

    private static func ensureMessagingPermissions(contact: AgentPeerContact, store: AgentPeerStore) throws -> Bool {
        guard let id = AgentPeerStore.hostRowID(contact.endpoint),
              let path = AgentHostDirectory.row(named: id)?.messagingPermissionsPath else { return false }
        let outcome = try AgentHostConfigWriter.grantAntigravityMessaging(
            path: AgentHostDirectory.expand(path),
            server: AgentHostDirectory.entryName, peerID: contact.id, recordURL: permissionRecord(contact, store))
        return outcome.backupPath != nil
    }

    private static func removeMessagingPermissions(contact: AgentPeerContact, store: AgentPeerStore) throws {
        guard let id = AgentPeerStore.hostRowID(contact.endpoint),
              let path = AgentHostDirectory.row(named: id)?.messagingPermissionsPath else { return }
        try AgentHostConfigWriter.removeAntigravityMessaging(
            path: AgentHostDirectory.expand(path),
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
        case .shellEnvironment:
            guard let peerID else { throw Refusal.unknownHost(row.displayName) }
            return try AgentHostConfigWriter.removeEnvironment(path: row.expandedConfigPath, peerID: peerID)
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
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ToolFailureError("Contact credential generation failed: macOS secure random generator returned \(status).", effects: .none,
                owner: "macOS secure random generator",
                tap: "Tell the person: macOS secure random generation failed with status \(status) while creating a contact credential; no credential was created.",
                code: "agent_credential_generation_failed", instruction: "Report the macOS random-generator failure to the person before connecting; no credential was created.", recovery: .repair)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

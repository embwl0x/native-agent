import AgentLinkTransport
import Darwin
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentHostConfigWriter.swift` | `AgentHostConfigWriter`, `edit`, `grantMessaging`, `removeMessaging`, `checkEntry`, `writeEnvironment`, `ensureEnvironment`, `checking` |

/// Splice only owned entry bytes; preserve foreign formatting and refuse configuration that cannot be understood.
public enum AgentHostConfigWriter {
    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String)
        case unparsable(String)
        case tooLarge
        case backupFailed
        case writeFailed
        case receiptFailed(path: String, detail: String)
        case cleanupFailed(path: String, detail: String)
        case removalFailed(path: String, displaced: String, detail: String)
        case publicationUnconfirmed(String)
        case changedUnderneath
        case entryExists(String)
        /// Connect may replace this product’s entry from another install.
        case staleEntry(at: String, helper: String, gone: Bool)

        public var errorDescription: String? {
            switch self {
            case .staleEntry(let at, let helper, let gone):
                return """
                    The entry at \(at) was written by another install of this app (its helper is \
                    \(helper)\(gone ? ", which no longer exists" : "")). agent.connect replaces it with this app's entry and keeps a backup beside \
                    the file; nothing was changed.
                    """
            case .entryExists(let at):
                return """
                    Connector collision at \(at). The existing entry belongs to another contact or has no peer ID. Review its ownership or change \
                    the recipe's configPath/format; it was left unchanged.
                    """
            case .changedUnderneath:
                return "The settings file changed while I was working; nothing was written."
            case .unreadable(let detail): return "The configuration file could not be read safely: \(detail)."
            case .unparsable(let detail): return "The configuration file could not be parsed: \(detail). Existing bytes were preserved and nothing was changed."
            case .tooLarge: return "The configuration file exceeds the bounded size this writer will edit. Nothing was changed."
            case .backupFailed: return "A timestamped backup could not be written beside the configuration file, so the file was left untouched."
            case .writeFailed: return "The configuration replacement failed. Inspect the configuration and its recorded backup before another change."
            case .receiptFailed(let path, let detail): return """
                The configuration was saved, but its ownership receipt or backup cleanup failed at \(path): \(detail). Inspect the settings, \
                receipt and retained backups before another change.
                """
            case .cleanupFailed(let path, let detail): return """
                The configuration was saved, but its previous file remains at \(path): \(detail). Inspect both files before removing the previous \
                file.
                """
            case .removalFailed(let path, let displaced, let detail):
                return """
                    Configuration removal failed: \(detail). The file was moved from \(path) to \(displaced); either path may now exist. Inspect \
                    both paths before another change.
                    """
            case .publicationUnconfirmed(let path): return """
                The configuration replacement was published, but a concurrent host save could not be reconciled. Both versions are preserved, \
                including \(path). Inspect both files and repair the current configuration before another change.
                """
            }
        }
    }

    /// Bound settings reads to the peer store’s order of magnitude.
    public static let maximumConfigurationBytes = 4 * 1_048_576
    final class Replaced: @unchecked Sendable { var helper: String? }

    /// One config edit's check mode, repair identity and replacement receipt.
    public struct Operation: Sendable {
        let checking: Bool?
        let repairingPeer: String?
        let replaced = Replaced()
        public init(checking: Bool? = nil, repairingPeer: String? = nil) {
            self.checking = checking
            self.repairingPeer = repairingPeer
        }
    }

    static func checkEntry(configuration: AgentHostConfigWriter.Operation, _ existing: String?, expected: String, json: Bool, at: String) throws -> Bool {
        guard let existing else {
            if configuration.checking == true { throw Failure.unparsable(
                "missing connector at \(at); connect this host after reviewing host.configPath/format with agent.recipe") }
            return false
        }
        // An exact entry needs no write; ownership permits reconciling a moved installation.
        let a = json ? try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? NSDictionary : nil
        let b = json ? try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary : nil
        let same = json ? a != nil && a == b
            : existing.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if same { return true }
        func identity(_ text: String, value: NSDictionary?) throws -> (command: String?, peerID: String?) {
            if json {
                return ((value?["command"] ?? value?["cmd"]) as? String,
                        ((value?["envs"] ?? value?["env"]) as? [String: Any])?[AgentHostDirectory.peerIDVariable] as? String)
            }
            return try TOMLEntrySplice.fields(Data(text.utf8), name: AgentHostDirectory.entryName)
        }
        let old = try identity(existing, value: a), new = try identity(expected, value: b)
        // Connect may replace another install's helper, never a foreign helper.
        if let helper = old.command, let ours = new.command,
           URL(fileURLWithPath: helper).lastPathComponent == URL(fileURLWithPath: ours).lastPathComponent,
           URL(fileURLWithPath: helper).resolvingSymlinksInPath() != URL(fileURLWithPath: ours).resolvingSymlinksInPath() {
            guard configuration.checking == nil else {
                throw Failure.staleEntry(at: at, helper: helper, gone: !FileManager.default.isExecutableFile(atPath: helper))
            }
            configuration.replaced.helper = helper
            return false
        }
        guard let peer = new.peerID, !peer.isEmpty, old.peerID == peer,
              configuration.repairingPeer == nil || configuration.repairingPeer == peer else { throw Failure.entryExists(at) }
        if configuration.checking != nil {
            throw ToolFailureError("This contact's connector at \(at) needs reconciliation. Connect it again to update its owned entry.",
                effects: .none, owner: at, nextCall: ToolFailureError.call("app", ["action": .string("agent.connect"),
                    "args": .object(["name": .string("peer:" + peer)])]))
        }
        return false
    }

    /// Write receipts must never carry file content.
    public struct Outcome: Sendable, Equatable {
        public let path: String
        public let backupPath: String?
        public let replacedExistingEntry: Bool
        public let removed: Bool
        public var replacedInstall: String? = nil
    }

    // MARK: - The two formats

    static func writeEnvironment(configuration: AgentHostConfigWriter.Operation, path: String, descriptorPath: String, peerID: String,
        secret: String) throws -> Outcome {
        if configuration.checking != nil {
            let expected = environmentData(descriptorPath: descriptorPath, peerID: peerID, secret: secret)
            if FileManager.default.fileExists(atPath: path) {
                guard configuration.checking == true, try read(path: path).0 == expected else { throw Failure.entryExists(path) }
            } else if configuration.checking == true { throw Failure.unparsable("missing environment file \(path); reconnect this host") }
            return .init(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Create-exclusive and 0600 from the first byte; never replace an existing file.
        try replaceAtomically(path: path, data: environmentData(descriptorPath: descriptorPath, peerID: peerID, secret: secret), unchangedSince: nil)
        return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
    }

    static func ensureEnvironment(configuration: AgentHostConfigWriter.Operation, path: String, descriptorPath: String, peerID: String,
        secret: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) != 0, errno == ENOENT {
            _ = try writeEnvironment(configuration: configuration, path: path, descriptorPath: descriptorPath, peerID: peerID, secret: secret)
            return true
        }
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw Failure.unreadable("it is not a regular file owned by you")
        }
        let identity = FileIdentity(info)
        let expected = environmentData(descriptorPath: descriptorPath, peerID: peerID, secret: secret)
        let (current, readIdentity) = try read(path: path)
        guard readIdentity == identity else { throw Failure.changedUnderneath }
        if info.st_mode & 0o7777 == 0o600 {
            if current == expected { return false }
        }
        try replaceAtomically(path: path, data: expected, unchangedSince: identity, original: current)
        return true
    }

    private static func environmentData(descriptorPath: String, peerID: String, secret: String) -> Data {
        let values = [(AgentHostDirectory.bridgeDescriptorVariable, descriptorPath),
                      (AgentHostDirectory.peerIDVariable, peerID), (AgentHostDirectory.peerSecretVariable, secret)]
        return Data((values.map { $0.0 + "=" + AgentHostDirectory.shellQuoted($0.1) }.joined(separator: "\n") + "\n").utf8)
    }

    static func removeEnvironment(path: String, peerID: String) throws -> Outcome {
        var info = stat()
        if lstat(path, &info) != 0, errno == ENOENT {
            return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: true)
        }
        let (data, identity) = try read(path: path)
        let ownership = AgentHostDirectory.peerIDVariable + "=" + AgentHostDirectory.shellQuoted(peerID)
        guard String(decoding: data, as: UTF8.self).split(separator: "\n").contains(Substring(ownership)),
              lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, FileIdentity(info) == identity else {
            throw Failure.changedUnderneath
        }
        try FileManager.default.removeItem(atPath: path)
        return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: true)
    }

    /// Only this connection's two conversation tools, never an MCP wildcard.
    static func messagingRules(server: String, syntax: AgentHostRow.MessagingPermissionSyntax) throws -> [String] {
        guard !server.isEmpty, server.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw Failure.unparsable("invalid messaging server name")
        }
        return ["agent_message", "agent_reply"].map { syntax.rule(server: server, tool: $0) }
    }

    static func grantMessaging(configuration: AgentHostConfigWriter.Operation, path: String, server: String, syntax: AgentHostRow.MessagingPermissionSyntax,
        peerID: String,
                                          recordURL: URL) throws -> Outcome {
        let rules = try messagingRules(server: server, syntax: syntax)
        let allowanceOwner = path + " " + (syntax == .toolDefaults ? toolPermissionPath.joined(separator: ".") : "permissions.allow")
        // Ownership receipts are an on-disk protocol, not a host selector; ownership cannot override later person-authored edits.
        if let owner = try backupRecords(at: recordURL).last?.jsonOwnership {
            guard owner.command == "antigravity-messaging", owner.peerID == peerID, owner.name == server else {
                throw Failure.unparsable("messaging permission ownership belongs to another connection")
            }
            let (current, _) = try read(path: path)
            try checkMessagingConflicts(current, server: server, syntax: syntax, rules: rules, path: path)
            let allowed = try messagingAllow(current, rules: rules, syntax: syntax).rules
            guard rules.allSatisfy(allowed.contains) else {
                throw Failure.unparsable(
                    "this connection's messaging allowances were changed or removed; review \(allowanceOwner). They were not restored automatically")
            }
            return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        return try edit(configuration: configuration, path: path, backupRecordURL: recordURL, initial: Data("{}".utf8), ownership: { data in
            let original = try messagingAllow(data, rules: rules, syntax: syntax)
            return JSONOwnership(command: "antigravity-messaging", peerID: peerID, name: server,
                original: original.value, originalMember: original.member)
        }) { data, configuration in
            try checkMessagingConflicts(data, server: server, syntax: syntax, rules: rules, path: path)
            let existing = try messagingAllow(data, rules: rules, syntax: syntax).rules
            let added = rules.filter { !existing.contains($0) }
            guard !added.isEmpty else { return nil }
            if configuration.checking == true {
                throw ToolFailureError("This contact's messaging allowances in \(path) need reconciliation. Connect it again to add its two messaging tools.",
                    effects: .none, owner: allowanceOwner, nextCall: ToolFailureError.call("app", [
                        "action": .string("agent.connect"), "args": .object(["name": .string("peer:" + peerID)])]))
            }
            return try spliceMessagingAllow(data, rules: rules, allowed: existing + added, syntax: syntax)
        }
    }

    static func removeMessaging(configuration: AgentHostConfigWriter.Operation, path: String, server: String, syntax: AgentHostRow.MessagingPermissionSyntax,
        peerID: String,
                                           recordURL: URL) throws {
        guard let owner = try backupRecords(at: recordURL).last?.jsonOwnership else { return }
        guard owner.command == "antigravity-messaging", owner.peerID == peerID, owner.name == server else {
            throw Failure.unparsable("messaging permission ownership does not match this connection")
        }
        let baseline = try permissionArray(owner.original)
        let rules = try messagingRules(server: server, syntax: syntax)
        let added = rules.filter { !baseline.contains($0) }
        _ = try edit(configuration: configuration, path: path, backupRecordURL: recordURL, removing: true) { data, _ in
            let current = try messagingAllow(data, rules: rules, syntax: syntax).rules
            let retained = current.filter { !added.contains($0) }
            guard current != retained else { return nil }
            return try spliceMessagingAllow(data, rules: rules, allowed: retained, syntax: syntax,
                removeEmpty: owner.original == nil, originalMember: retained == baseline ? owner.originalMember : nil)
        }
        try removeBackups(path: path, recordURL: recordURL)
    }

    private static let toolPermissionPath = ["agent", "tool_permissions", "tools"]
    private static let toolAllowance = "{\"default\":\"allow\"}"

    private static func messagingAllow(_ data: Data, rules: [String], syntax: AgentHostRow.MessagingPermissionSyntax) throws
        -> (value: String?, member: String?, rules: [String]) {
        if syntax == .toolDefaults {
            var allowed: [String] = []
            for rule in rules {
                if let value = try JSONEntrySplice.member(data, path: toolPermissionPath + [rule]),
                   try isToolAllowance(value) { allowed.append(rule) }
            }
            let value = String(decoding: try JSONSerialization.data(withJSONObject: allowed), as: UTF8.self)
            return (value, nil, allowed)
        }
        let entry = try JSONEntrySplice.entry(data, name: "allow", containerKey: "permissions", comments: true, trailingCommas: true)
        return (entry?.value, entry?.member, try permissionArray(entry?.value))
    }

    private static func spliceMessagingAllow(_ data: Data, rules: [String], allowed: [String],
        syntax: AgentHostRow.MessagingPermissionSyntax, removeEmpty: Bool = false, originalMember: String? = nil) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        if syntax == .toolDefaults {
            var output = data
            for rule in rules {
                let path = toolPermissionPath + [rule]
                let current = try JSONEntrySplice.member(output, path: path)
                if allowed.contains(rule) {
                    if current == nil { output = try JSONEntrySplice.setMember(output, path: path, value: toolAllowance) }
                } else if let current, try isToolAllowance(current) {
                    output = try JSONEntrySplice.setMember(output, path: path, value: nil)
                }
            }
            return output == data ? nil : (output, false, allowed.isEmpty)
        }
        if allowed.isEmpty && removeEmpty {
            return try JSONEntrySplice.remove(data, name: "allow", containerKey: "permissions", comments: true, trailingCommas: true)
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: allowed, options: [.withoutEscapingSlashes]), as: UTF8.self)
        return try JSONEntrySplice.upsert(data, name: "allow", entryJSON: json,
            containerKey: "permissions", comments: true, trailingCommas: true, originalMember: originalMember, fragment: true)
    }

    private static func isToolAllowance(_ value: String) throws -> Bool {
        let bytes = try JSONEntrySplice.validatedBytes(Data(value.utf8), comments: true, trailingCommas: true)
        _ = try JSONEntrySplice.member(Data(value.utf8), path: ["default"])
        let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? NSDictionary
        return object == ["default": "allow"] as NSDictionary
    }

    private static func permissionEntry(_ data: Data, _ key: String) throws -> String? {
        try JSONEntrySplice.entry(data, name: key, containerKey: "permissions", comments: true, trailingCommas: true)?.value
    }

    private static func checkMessagingConflicts(_ data: Data, server: String,
        syntax: AgentHostRow.MessagingPermissionSyntax, rules: [String], path: String) throws {
        if syntax == .toolDefaults {
            // Per-tool defaults override the host’s global default; preserve restrictions on the tools themselves.
            for rule in rules {
                if let value = try JSONEntrySplice.member(data, path: toolPermissionPath + [rule]),
                   try !isToolAllowance(value) {
                    throw ToolFailureError("""
                        An existing tool permission for \(rule) in \(path) constrains this connection's messaging. It was left intact and nothing \
                        was connected.
                        """,
                        effects: .none, owner: path + " agent.tool_permissions.tools." + rule,
                        tap: "Zed settings › agent › tool_permissions › tools (\(path))", personDecides: true)
                }
            }
            return
        }
        for key in ["deny", "ask"] {
            let blocked = try permissionRules(data, key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // The documented wildcards are mcp(*) and mcp(server/*). Refuse ambiguous broad spellings too, rather than assume they do not constrain this
            // connection on a different CLI version.
            guard !blocked.contains(where: { rule in
                switch syntax {
                case .mcpCall:
                    return ["*", "mcp", "mcp(\(server))", "mcp(*)", "mcp(\(server)/*)"].contains(rule) || rules.contains(rule)
                case .doubleUnderscore:
                    // Ask/Deny accept full-name globs, including partial server and tool names. Bare server rules cover all its tools.
                    let tool = String(rule.prefix { $0 != "(" })
                    let pattern = "^" + NSRegularExpression.escapedPattern(for: tool)
                        .replacingOccurrences(of: "\\*", with: ".*") + "$"
                    return rules.contains { name in
                        name.range(of: pattern, options: .regularExpression) != nil
                            || (tool.hasPrefix("mcp__") && name.hasPrefix(tool + "__"))
                    }
                case .toolDefaults: return false // Checked above, at its per-tool owner.
                }
            }) else {
                // The person’s Ask/Deny rules are decisions, not repair debt.
                throw ToolFailureError("""
                    An existing \(key) rule in \(path) covers or ambiguously constrains this connection's messaging tools. That rule is the \
                    person's decision; it was left intact and nothing was connected.
                    """,
                    effects: .none, owner: path + " permissions." + key,
                    tap: "Settings › permissions › \(key) (\(path))", personDecides: true)
            }
        }
    }

    private static func permissionRules(_ data: Data, _ key: String) throws -> [String] {
        try permissionArray(permissionEntry(data, key))
    }

    private static func permissionArray(_ value: String?) throws -> [String] {
        guard let value else { return [] }
        let bytes = try JSONEntrySplice.validatedBytes(Data(("{\"value\":" + value + "}").utf8), comments: true, trailingCommas: true)
        guard let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let array = object["value"] as? [String] else {
            throw Failure.unparsable("permission rules must be an array of strings")
        }
        return array
    }

    public static func writeJSONEntry(configuration: AgentHostConfigWriter.Operation,
        path: String, name: String, entryJSON: String, backupRecordURL: URL,
        containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true
    ) throws -> Outcome {
        let object = try JSONSerialization.jsonObject(with: Data(entryJSON.utf8)) as? [String: Any]
        let command = object?["command"] as? String
        let peerID = (object?["env"] as? [String: Any])?[AgentHostDirectory.peerIDVariable] as? String
        return try edit(configuration: configuration, path: path, backupRecordURL: backupRecordURL, initial: Data("{}".utf8),
            ownership: { data in
                guard let command, let peerID else { return nil }
                return JSONOwnership(command: command, peerID: peerID, name: name,
                    original: nil, originalMember: nil)
            }) { data, configuration in
            if try checkEntry(configuration: configuration, JSONEntrySplice.entry(data, name: name, containerKey: containerKey,
                comments: comments, trailingCommas: trailingCommas)?.value, expected: entryJSON, json: true, at: path + ":" + containerKey + "."
                    + name) { return nil }
            return try JSONEntrySplice.upsert(data, name: name, entryJSON: entryJSON, containerKey: containerKey, comments: comments,
                trailingCommas: trailingCommas)
        }
    }

    public static func removeJSONEntry(configuration: AgentHostConfigWriter.Operation, path: String, name: String, backupRecordURL: URL,
                                       containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true,
                                       peerID: String? = nil) throws -> Outcome {
        let owner = try backupRecords(at: backupRecordURL).last?.jsonOwnership
        if let peerID {
            guard let owner, owner.peerID == peerID else {
                throw Failure.unparsable("ownership receipt \(backupRecordURL.path) is missing or names another peer; settings at \(path) were preserved")
            }
        }
        return try edit(configuration: configuration, path: path, backupRecordURL: backupRecordURL, removing: true, cleanupBackups: peerID == nil) { data, _ in
            if let owner {
                return try JSONEntrySplice.disconnect(data, owner: owner, containerKey: containerKey,
                comments: comments, trailingCommas: trailingCommas)
            }
            return try JSONEntrySplice.remove(data, name: name, containerKey: containerKey, comments: comments, trailingCommas: trailingCommas)
        }
    }

    public static func writeTOMLEntry(configuration: AgentHostConfigWriter.Operation,
        path: String, name: String, entryTOML: String, backupRecordURL: URL
    ) throws -> Outcome {
        let identity = try TOMLEntrySplice.identity(Data(entryTOML.utf8), name: name)
        return try edit(configuration: configuration, path: path, backupRecordURL: backupRecordURL, initial: Data(), tomlOwnership: { data in
            guard let identity else { return nil }
            return JSONOwnership(command: identity.command, peerID: identity.peerID, name: name,
                original: nil)
        }) { data, configuration in
            if try checkEntry(configuration: configuration, TOMLEntrySplice.entry(data, name: name), expected: entryTOML, json: false, at: path
                + ":mcp_servers." + name) { return nil }
            return try TOMLEntrySplice.upsert(data, name: name, entryTOML: entryTOML)
        }
    }

    public static func removeTOMLEntry(configuration: AgentHostConfigWriter.Operation, path: String, name: String, backupRecordURL: URL,
        peerID: String? = nil) throws -> Outcome {
        let owner = try backupRecords(at: backupRecordURL).last?.tomlOwnership
        if let peerID {
            guard let owner, owner.peerID == peerID else {
                throw Failure.unparsable("ownership receipt \(backupRecordURL.path) is missing or names another peer; settings at \(path) were preserved")
            }
        }
        return try edit(configuration: configuration, path: path, backupRecordURL: backupRecordURL, removing: true, cleanupBackups: peerID == nil) { data, _ in
            if let owner { return try TOMLEntrySplice.disconnect(data, owner: owner) }
            return try TOMLEntrySplice.remove(data, name: name)
        }
    }

    // MARK: - Read, splice, back up, replace

    static func edit(configuration: AgentHostConfigWriter.Operation,
        path: String, backupRecordURL: URL, removing: Bool = false, initial: Data? = nil, cleanupBackups: Bool = true,
        ownership: ((Data) throws -> JSONOwnership?)? = nil,
        tomlOwnership: ((Data) throws -> JSONOwnership?)? = nil,
        _ splice: (Data, Operation) throws -> (data: Data, replaced: Bool, removed: Bool)?
    ) throws -> Outcome {
        if configuration.checking != nil { _ = try backupRecords(at: backupRecordURL) }
        var info = stat()
        let missing = lstat(path, &info) != 0 && errno == ENOENT
        if missing && removing { return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false) }
        let existing: Data
        let identity: FileIdentity?
        if missing, let initial { existing = initial; identity = nil }
        else { (existing, identity) = try read(path: path) }
        // Each edit owns its replacement receipt, even when one connection edits several files.
        let configuration = Operation(checking: configuration.checking, repairingPeer: configuration.repairingPeer)
        let replacing = configuration.replaced
        guard var result = try splice(existing, configuration) else {
            if removing && cleanupBackups { try removeBackups(path: path, recordURL: backupRecordURL) }
            return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        guard result.data.count <= maximumConfigurationBytes else { throw Failure.tooLarge }
        if configuration.checking != nil { return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false) }
        // Restore exact original spacing (including an originally absent section) only while the file still matches our write. Later host edits win.
        var restoreAbsence = false
        if removing, let record = try backupRecords(at: backupRecordURL).last,
           record.restoresOriginal == true, record.writtenDigest == digest(existing), record.path.hasPrefix(path + ".") {
            let (original, identity) = try read(path: record.path)
            if identity == record.identity {
                result.data = original
                restoreAbsence = record.originallyAbsent == true
            }
        }
        if missing {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Retain the connect receipt until removal commits, including retries.
        let backup = removing ? nil : try writeBackup(path: path, data: existing, written: result.data,
                                     originallyAbsent: missing, restoresOriginal: !result.replaced,
                                     jsonOwnership: try ownership?(existing), tomlOwnership: try tomlOwnership?(existing), recordURL: backupRecordURL)
        // Recheck identity and bytes before rename so concurrent host or editor saves cannot be silently overwritten.
        if restoreAbsence {
            // Claim a private name BEFORE inspecting. Never unlink the host's pathname: it may already name a newer save by the time we delete.
            let claimed = path + ".nativeagent-removal-" + UUID().uuidString
            guard renamex_np(path, claimed, UInt32(RENAME_EXCL)) == 0 else { throw Failure.changedUnderneath }
            let current: Data
            let currentIdentity: FileIdentity
            do { (current, currentIdentity) = try read(path: claimed) }
            catch {
                // Exclusive restoration cannot overwrite a concurrent host save.
                if renamex_np(claimed, path, UInt32(RENAME_EXCL)) != 0 {
                    throw Failure.removalFailed(path: path, displaced: claimed,
                        detail: "Read failed: \(error.localizedDescription); restoring the original path failed: \(String(cString: strerror(errno))).")
                }
                throw error
            }
            do {
                if currentIdentity == identity, current == existing {
                    guard Darwin.unlink(claimed) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                } else if renamex_np(claimed, path, UInt32(RENAME_EXCL)) != 0 {
                    guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    // Both versions belong to the host. Keep both files and splice only our entry out of the displaced version as well.
                    if let fresh = try splice(current, configuration) {
                        try replaceAtomically(path: claimed, data: fresh.data, unchangedSince: currentIdentity, original: current)
                    }
                }
                var now = stat()
                if lstat(path, &now) == 0 {
                    let (latest, latestIdentity) = try read(path: path)
                    if let fresh = try splice(latest, configuration) {
                        try replaceAtomically(path: path, data: fresh.data, unchangedSince: latestIdentity, original: latest)
                    }
                } else if errno != ENOENT {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } catch {
                throw Failure.removalFailed(path: path, displaced: claimed, detail: error.localizedDescription)
            }
        } else {
            do {
                try replaceAtomically(path: path, data: result.data, unchangedSince: identity, original: existing)
            } catch let failure as Failure {
                // This error occurs after the validated swap committed; its displaced-file cleanup failed. Publish that committed write.
                if case .cleanupFailed = failure, let backup {
                    try commitBackup(backup, path: path, recordURL: backupRecordURL)
                }
                throw failure
            }
        }
        if let backup { try commitBackup(backup, path: path, recordURL: backupRecordURL) }
        if removing && cleanupBackups { try removeBackups(path: path, recordURL: backupRecordURL) }
        return Outcome(path: path, backupPath: backup?.record.path,
                       replacedExistingEntry: result.replaced, removed: result.removed, replacedInstall: replacing.helper)
    }

    /// Compare both file identity and bytes immediately before rename.
    private struct FileIdentity: Equatable, Codable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    /// Edit only regular files owned by the person; refuse symlinks, devices, directories and foreign owners.
    private static func read(path: String) throws -> (Data, FileIdentity) {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw errno == ENOENT
                ? Failure.unreadable("it does not exist")
                : Failure.unreadable("it could not be opened")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw Failure.unreadable("it is not a regular file owned by you")
        }
        guard info.st_size <= off_t(maximumConfigurationBytes) else { throw Failure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65_536) }
            if count == 0 { break }
            // A read error cannot mean EOF, or a truncated configuration could replace the complete file.
            guard count > 0 || errno == EINTR else {
                throw Failure.unreadable("it could not be read to the end")
            }
            if count < 0 { continue }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maximumConfigurationBytes else { throw Failure.tooLarge }
        }
        guard data.count == Int(info.st_size) else {
            throw Failure.unreadable("it changed size while it was being read")
        }
        return (data, FileIdentity(info))
    }

    /// Keep undo beside the settings so the person can find it.
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private struct PreparedBackup {
        let record: BackupRecord
        let previous: [BackupRecord]
    }

    private static func writeBackup(path: String, data: Data, written: Data, originallyAbsent: Bool,
                                    restoresOriginal: Bool, jsonOwnership: JSONOwnership? = nil,
                                    tomlOwnership: JSONOwnership? = nil, recordURL: URL) throws -> PreparedBackup {
        let records = try backupRecords(at: recordURL)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        // Create the newest undo before removing older ones, including writes in the same second. Never overwrite a colliding file.
        let stem = path + "." + InstallPaths.current.name("nativeagent-backup") + "-" + formatter.string(from: Date())
        for attempt in 0..<64 {
            let backup = attempt == 0 ? stem : "\(stem)-\(attempt)"
            if write(data, to: backup) {
                do {
                    let (_, identity) = try read(path: backup)
                    let record = BackupRecord(path: backup, identity: identity, writtenDigest: digest(written),
                                                originallyAbsent: originallyAbsent, restoresOriginal: restoresOriginal,
                                                jsonOwnership: jsonOwnership, tomlOwnership: tomlOwnership)
                    return PreparedBackup(record: record, previous: records)
                } catch {
                    _ = Darwin.unlink(backup)
                    throw error
                }
            }
        }
        throw Failure.backupFailed
    }

    private static func commitBackup(_ backup: PreparedBackup, path: String, recordURL: URL) throws {
        // Publish ownership only after replacement commits; failed replacement preserves prior receipts and prepared undo.
        do {
            try saveBackupRecords(backup.previous + [backup.record], at: recordURL)
            try removeBackups(path: path, recordURL: recordURL, keeping: backup.record.path)
        } catch {
            throw Failure.receiptFailed(path: recordURL.path, detail: error.localizedDescription)
        }
    }

    struct JSONOwnership: Codable {
        let command: String
        let peerID: String
        let name: String
        let original: String?
        var originalMember: String? = nil
    }

    private struct BackupRecord: Codable {
        let path: String
        let identity: FileIdentity
        var writtenDigest: String?
        var originallyAbsent: Bool?
        var restoresOriginal: Bool?
        var jsonOwnership: JSONOwnership?
        var tomlOwnership: JSONOwnership?
    }

    private static func backupRecords(at url: URL) throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([BackupRecord].self, from: Data(contentsOf: url)) }
        catch { throw Failure.unreadable("""
            ownership receipt \(url.path) must read as a BackupRecord array: \(error.localizedDescription). Restore that receipt before connecting \
            or verifying
            """) }
    }

    private static func saveBackupRecords(_ records: [BackupRecord], at url: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(records), to: url)
    }

    static func removeBackups(path: String, recordURL: URL, keeping: String? = nil) throws {
        let records = try backupRecords(at: recordURL)
        let prefix = path + "." + InstallPaths.current.name("nativeagent-backup") + "-"
        for record in records {
            guard record.path != keeping, record.path.hasPrefix(prefix),
                  String(record.path.dropFirst(prefix.count)).range(
                    of: #"^\d{8}T\d{6}Z(?:-[1-9]\d?)?$"#, options: .regularExpression
                  ) != nil else { continue }
            // A matching name is not ownership. Delete only a file we recorded creating, and leave replacements, symlinks and directories alone.
            var info = stat()
            guard lstat(record.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  FileIdentity(info) == record.identity else { continue }
            try FileManager.default.removeItem(atPath: record.path)
        }
        try saveBackupRecords(records.filter { $0.path == keeping }, at: recordURL)
    }

    private static func replaceAtomically(path: String, data: Data, unchangedSince identity: FileIdentity?, original: Data? = nil) throws {
        var now = stat()
        let status = lstat(path, &now)
        guard identity == nil ? (status != 0 && errno == ENOENT)
                : (status == 0 && now.st_mode & S_IFMT == S_IFREG && FileIdentity(now) == identity) else {
            throw Failure.changedUnderneath
        }
        let temporary = path + ".nativeagent-tmp-" + UUID().uuidString
        guard write(data, to: temporary) else { throw Failure.writeFailed }
        var removeTemporary = true
        defer { if removeTemporary { _ = Darwin.unlink(temporary) } }
        guard let identity else {
            // A new destination must never replace a file another app just created.
            guard Darwin.link(temporary, path) == 0 else { throw Failure.changedUnderneath }
            return
        }
        // Swap keeps the host pathname present, including across a crash. The displaced file stays beside it until checked publication settles.
        let (beforeSwap, beforeSwapIdentity) = try read(path: path)
        guard beforeSwapIdentity == identity, original == nil || beforeSwap == original else { throw Failure.changedUnderneath }
        guard renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 else { throw Failure.changedUnderneath }
        removeTemporary = false
        do {
            let (current, currentIdentity) = try read(path: temporary)
            guard currentIdentity == identity, original == nil || current == original else { throw Failure.changedUnderneath }
        } catch {
            // Publication already happened. Keep both generations; never swap old bytes over a current or concurrently saved configuration.
            throw Failure.publicationUnconfirmed(temporary)
        }
        guard Darwin.unlink(temporary) == 0 else {
            throw Failure.cleanupFailed(path: temporary, detail: String(cString: strerror(errno)))
        }
    }

    /// Create-exclusive, owner-only and flushed before naming prevents truncated configuration after a crash. Settings and backups carry a connection key, so
    /// both require 0600 even if the original was readable by others.
    private static func write(_ data: Data, to path: String) -> Bool {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var written = 0
        let ok: Bool = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if count <= 0 { if errno == EINTR { continue }; return false }
                written += count
            }
            return true
        }
        let flushed = fsync(fd) == 0
        Darwin.close(fd)
        if ok && flushed { return true }
        _ = path.withCString { Darwin.unlink($0) }
        return false
    }

}

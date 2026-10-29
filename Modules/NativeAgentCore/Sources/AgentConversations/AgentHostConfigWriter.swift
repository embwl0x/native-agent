import AgentLinkTransport
import Darwin
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentHostConfigWriter.swift` | `AgentHostConfigWriter` enum; `edit` owns file transactions, backups and replacement; `checkEntry`, `writeEnvironment`, `ensureEnvironment`; absent/exact entries, same-peer reconciliation and stale-install helper replacement; foreign-entry refusal; `checking` validates without writing; removal names missing ownership receipts and preserves unproven bytes |

/// Write one owned entry into another program's configuration file.
/// JSON, TOML and YAML splicers replace only the entry's bytes; foreign bytes,
/// key order, indentation and comments survive unchanged.
///
/// A configuration that cannot be understood is refused with a reason.
public enum AgentHostConfigWriter {
    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String)
        case unparsable(String)
        case tooLarge
        case backupFailed
        case writeFailed
        case cleanupFailed(path: String, detail: String)
        case removalFailed(path: String, displaced: String, detail: String)
        case rollbackFailed(String)
        case changedUnderneath
        case entryExists(String)
        /// This app's entry name, written by another install of it (a copy since
        /// moved, deleted or run from elsewhere): connect owns it and replaces it.
        case staleEntry(at: String, helper: String, gone: Bool)

        public var errorDescription: String? {
            switch self {
            case .staleEntry(let at, let helper, let gone):
                return "The entry at \(at) was written by another install of this app (its helper is \(helper)\(gone ? ", which no longer exists" : "")). agent.connect replaces it with this app's entry and keeps a backup beside the file; nothing was changed."
            case .entryExists(let at):
                return "Connector collision at \(at). The existing entry belongs to another contact or has no peer ID. Review its ownership or change the recipe's configPath/format; it was left unchanged."
            case .changedUnderneath:
                return "The settings file changed while I was working; nothing was written."
            case .unreadable(let detail): return "The configuration file could not be read safely: \(detail)."
            case .unparsable(let detail): return "The configuration file could not be parsed: \(detail). Existing bytes were preserved and nothing was changed."
            case .tooLarge: return "The configuration file exceeds the bounded size this writer will edit. Nothing was changed."
            case .backupFailed: return "A timestamped backup could not be written beside the configuration file, so the file was left untouched."
            case .writeFailed: return "The configuration replacement failed. Inspect the configuration and its recorded backup before another change."
            case .cleanupFailed(let path, let detail): return "The configuration was saved, but its previous file remains at \(path): \(detail). Inspect both files before removing the previous file."
            case .removalFailed(let path, let displaced, let detail):
                return "Configuration removal failed: \(detail). The file was moved from \(path) to \(displaced); either path may now exist. Inspect both paths before another change."
            case .rollbackFailed(let path): return "The settings changed during replacement and could not be restored safely. The displaced file was preserved at \(path); review both files before retrying."
            }
        }
    }

    /// Bounded by the same order of magnitude as the peer store's own limit.
    public static let maximumConfigurationBytes = 4 * 1_048_576
    /// nil writes; false checks an unconnected host; true requires its saved entry.
    @TaskLocal static var checking: Bool? = nil
    @TaskLocal static var repairingPeer: String? = nil
    /// The helper of a stale entry a write is replacing, for its receipt.
    final class Replaced: @unchecked Sendable { var helper: String? }
    @TaskLocal static var replaced: Replaced? = nil

    static func checkEntry(_ existing: String?, expected: String, json: Bool, at: String) throws -> Bool {
        guard let existing else {
            if checking == true { throw Failure.unparsable("missing connector at \(at); connect this host after reviewing host.configPath/format with agent.recipe") }
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
            guard checking == nil else {
                throw Failure.staleEntry(at: at, helper: helper, gone: !FileManager.default.isExecutableFile(atPath: helper))
            }
            replaced?.helper = helper
            return false
        }
        guard let peer = new.peerID, !peer.isEmpty, old.peerID == peer,
              repairingPeer == nil || repairingPeer == peer else { throw Failure.entryExists(at) }
        if checking != nil {
            throw ToolFailureError("This contact's connector at \(at) needs reconciliation. Connect it again to update its owned entry.",
                effects: .none, owner: at, nextCall: ToolFailureError.call("app", ["action": .string("agent.connect"),
                    "args": .object(["name": .string("peer:" + peer)])]))
        }
        return false
    }

    /// What a write did, for an honest tool result. Never carries file content.
    public struct Outcome: Sendable, Equatable {
        public let path: String
        public let backupPath: String?
        public let replacedExistingEntry: Bool
        public let removed: Bool
        /// The helper of another install's entry this write replaced.
        public var replacedInstall: String? = nil
    }

    // MARK: - The two formats

    static func writeEnvironment(path: String, descriptorPath: String, peerID: String, secret: String) throws -> Outcome {
        if checking != nil {
            let expected = environmentData(descriptorPath: descriptorPath, peerID: peerID, secret: secret)
            if FileManager.default.fileExists(atPath: path) {
                guard checking == true, try read(path: path).0 == expected else { throw Failure.entryExists(path) }
            } else if checking == true { throw Failure.unparsable("missing environment file \(path); reconnect this host") }
            return .init(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Create-exclusive and 0600 from the first byte; never replace an existing file.
        try replaceAtomically(path: path, data: environmentData(descriptorPath: descriptorPath, peerID: peerID, secret: secret), unchangedSince: nil)
        return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
    }

    static func ensureEnvironment(path: String, descriptorPath: String, peerID: String, secret: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) != 0, errno == ENOENT {
            _ = try writeEnvironment(path: path, descriptorPath: descriptorPath, peerID: peerID, secret: secret)
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
    static func antigravityMessagingRules(server: String) throws -> [String] {
        guard !server.isEmpty, server.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw Failure.unparsable("invalid messaging server name")
        }
        return ["mcp(\(server)/agent_message)", "mcp(\(server)/agent_reply)"]
    }

    static func grantAntigravityMessaging(path: String, server: String, peerID: String,
                                          recordURL: URL) throws -> Outcome {
        let rules = try antigravityMessagingRules(server: server)
        // Existing ownership is not a reason to undo a person's later edit.
        if let owner = try backupRecords(at: recordURL).last?.jsonOwnership {
            guard owner.command == "antigravity-messaging", owner.peerID == peerID, owner.name == server else {
                throw Failure.unparsable("messaging permission ownership belongs to another connection")
            }
            let (current, _) = try read(path: path)
            try checkMessagingConflicts(current, server: server, rules: rules, path: path)
            let allowed = try permissionRules(current, "allow")
            guard rules.allSatisfy(allowed.contains) else {
                throw Failure.unparsable("this connection's messaging allowances were changed or removed; review them in Antigravity. They were not restored automatically")
            }
            return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        return try edit(path: path, backupRecordURL: recordURL, initial: Data("{}".utf8), ownership: { data in
            let original = try JSONEntrySplice.entry(data, name: "allow", containerKey: "permissions",
                comments: true, trailingCommas: true)
            return JSONOwnership(command: "antigravity-messaging", peerID: peerID, name: server,
                original: original?.value, originalMember: original?.member)
        }) { data in
            try checkMessagingConflicts(data, server: server, rules: rules, path: path)
            let existing = try permissionRules(data, "allow")
            let added = rules.filter { !existing.contains($0) }
            guard !added.isEmpty else { return nil }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: existing + added, options: [.withoutEscapingSlashes]), as: UTF8.self)
            return try JSONEntrySplice.upsert(data, name: "allow", entryJSON: json,
                containerKey: "permissions", comments: true, trailingCommas: true, fragment: true)
        }
    }

    static func removeAntigravityMessaging(path: String, server: String, peerID: String,
                                           recordURL: URL) throws {
        guard let owner = try backupRecords(at: recordURL).last?.jsonOwnership else { return }
        guard owner.command == "antigravity-messaging", owner.peerID == peerID, owner.name == server else {
            throw Failure.unparsable("messaging permission ownership does not match this connection")
        }
        let baseline = try permissionArray(owner.original)
        let added = try antigravityMessagingRules(server: server).filter { !baseline.contains($0) }
        _ = try edit(path: path, backupRecordURL: recordURL, removing: true) { data in
            let current = try permissionRules(data, "allow")
            let retained = current.filter { !added.contains($0) }
            guard current != retained else { return nil }
            if retained.isEmpty, owner.original == nil {
                return try JSONEntrySplice.remove(data, name: "allow", containerKey: "permissions", comments: true, trailingCommas: true)
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: retained, options: [.withoutEscapingSlashes]), as: UTF8.self)
            return try JSONEntrySplice.upsert(data, name: "allow", entryJSON: json,
                containerKey: "permissions", comments: true, trailingCommas: true,
                originalMember: retained == baseline ? owner.originalMember : nil, fragment: true)
        }
        try removeBackups(path: path, recordURL: recordURL)
    }

    private static func permissionEntry(_ data: Data, _ key: String) throws -> String? {
        try JSONEntrySplice.entry(data, name: key, containerKey: "permissions", comments: true, trailingCommas: true)?.value
    }

    private static func checkMessagingConflicts(_ data: Data, server: String, rules: [String], path: String) throws {
        for key in ["deny", "ask"] {
            let blocked = try permissionRules(data, key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // The documented wildcards are mcp(*) and mcp(server/*). Refuse
            // ambiguous broad spellings too, rather than assume they do not
            // constrain this connection on a different CLI version.
            guard !blocked.contains(where: {
                ["*", "mcp", "mcp(\(server))", "mcp(*)", "mcp(\(server)/*)"].contains($0) || rules.contains($0)
            }) else {
                // The person's own Ask/Deny rule is his decision, never a repair of ours.
                throw ToolFailureError("An existing \(key) rule in \(path) covers or ambiguously constrains this connection's messaging tools. That rule is the person's decision; it was left intact and nothing was connected.",
                    effects: .none, owner: path + " permissions." + key,
                    tap: "Antigravity settings › permissions › \(key) (\(path))", personDecides: true)
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

    /// `{ "mcpServers": { "<name>": { … } } }` — Claude Code's `~/.claude.json`,
    /// Claude Desktop's `claude_desktop_config.json`, and every host that copied
    /// that shape.
    public static func writeJSONEntry(
        path: String, name: String, entryJSON: String, backupRecordURL: URL,
        containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true
    ) throws -> Outcome {
        let object = try JSONSerialization.jsonObject(with: Data(entryJSON.utf8)) as? [String: Any]
        let command = object?["command"] as? String
        let peerID = (object?["env"] as? [String: Any])?[AgentHostDirectory.peerIDVariable] as? String
        return try edit(path: path, backupRecordURL: backupRecordURL, initial: Data("{}".utf8),
            ownership: { data in
                guard let command, let peerID else { return nil }
                return JSONOwnership(command: command, peerID: peerID, name: name,
                    original: nil, originalMember: nil)
            }) { data in
            if try checkEntry(JSONEntrySplice.entry(data, name: name, containerKey: containerKey,
                comments: comments, trailingCommas: trailingCommas)?.value, expected: entryJSON, json: true, at: path + ":" + containerKey + "." + name) { return nil }
            return try JSONEntrySplice.upsert(data, name: name, entryJSON: entryJSON, containerKey: containerKey, comments: comments, trailingCommas: trailingCommas)
        }
    }

    public static func removeJSONEntry(path: String, name: String, backupRecordURL: URL,
                                       containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true,
                                       peerID: String? = nil) throws -> Outcome {
        let owner = try backupRecords(at: backupRecordURL).last?.jsonOwnership
        if let peerID {
            guard let owner, owner.peerID == peerID else {
                throw Failure.unparsable("ownership receipt \(backupRecordURL.path) is missing or names another peer; settings at \(path) were preserved")
            }
        }
        return try edit(path: path, backupRecordURL: backupRecordURL, removing: true, cleanupBackups: peerID == nil) { data in
            if let owner {
                return try JSONEntrySplice.disconnect(data, owner: owner, containerKey: containerKey,
                    comments: comments, trailingCommas: trailingCommas)
            }
            return try JSONEntrySplice.remove(data, name: name, containerKey: containerKey, comments: comments, trailingCommas: trailingCommas)
        }
    }

    /// `[mcp_servers.<name>]` — Codex's `~/.codex/config.toml`.
    public static func writeTOMLEntry(
        path: String, name: String, entryTOML: String, backupRecordURL: URL
    ) throws -> Outcome {
        let identity = try TOMLEntrySplice.identity(Data(entryTOML.utf8), name: name)
        return try edit(path: path, backupRecordURL: backupRecordURL, initial: Data(), tomlOwnership: { data in
            guard let identity else { return nil }
            return JSONOwnership(command: identity.command, peerID: identity.peerID, name: name,
                original: nil)
        }) { data in
            if try checkEntry(TOMLEntrySplice.entry(data, name: name), expected: entryTOML, json: false, at: path + ":mcp_servers." + name) { return nil }
            return try TOMLEntrySplice.upsert(data, name: name, entryTOML: entryTOML)
        }
    }

    public static func removeTOMLEntry(path: String, name: String, backupRecordURL: URL, peerID: String? = nil) throws -> Outcome {
        let owner = try backupRecords(at: backupRecordURL).last?.tomlOwnership
        if let peerID {
            guard let owner, owner.peerID == peerID else {
                throw Failure.unparsable("ownership receipt \(backupRecordURL.path) is missing or names another peer; settings at \(path) were preserved")
            }
        }
        return try edit(path: path, backupRecordURL: backupRecordURL, removing: true, cleanupBackups: peerID == nil) { data in
            if let owner { return try TOMLEntrySplice.disconnect(data, owner: owner) }
            return try TOMLEntrySplice.remove(data, name: name)
        }
    }

    // MARK: - Read, splice, back up, replace

    static func edit(
        path: String, backupRecordURL: URL, removing: Bool = false, initial: Data? = nil, cleanupBackups: Bool = true,
        ownership: ((Data) throws -> JSONOwnership?)? = nil,
        tomlOwnership: ((Data) throws -> JSONOwnership?)? = nil,
        _ splice: (Data) throws -> (data: Data, replaced: Bool, removed: Bool)?
    ) throws -> Outcome {
        if checking != nil { _ = try backupRecords(at: backupRecordURL) }
        var info = stat()
        let missing = lstat(path, &info) != 0 && errno == ENOENT
        if missing && removing { return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false) }
        let existing: Data
        let identity: FileIdentity?
        if missing, let initial { existing = initial; identity = nil }
        else { (existing, identity) = try read(path: path) }
        let replacing = Replaced()
        guard var result = try $replaced.withValue(replacing, operation: { try splice(existing) }) else {
            // Nothing to do — an absent entry a disconnect was asked to remove.
            if removing && cleanupBackups { try removeBackups(path: path, recordURL: backupRecordURL) }
            return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        guard result.data.count <= maximumConfigurationBytes else { throw Failure.tooLarge }
        if checking != nil { return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false) }
        // Restore exact original spacing (including an originally absent section)
        // only while the file still matches our write. Later host edits win.
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
        // THE FILE IS SOMEBODY ELSE'S. Between the read above and the rename
        // below, the other agent — or the person in an editor — may have saved
        // its own change, and renaming our splice of the OLD bytes over it
        // would throw that away silently. So: look again, and abort if it is
        // not the same file with the same bytes. Not a lock, a check.
        if restoreAbsence {
            // Claim a private name BEFORE inspecting. Never unlink the host's
            // pathname: it may already name a newer save by the time we delete.
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
                    // Both versions belong to the host. Keep both files and splice
                    // only our entry out of the displaced version as well.
                    if let fresh = try splice(current) {
                        try replaceAtomically(path: claimed, data: fresh.data, unchangedSince: currentIdentity, original: current)
                    }
                }
                var now = stat()
                if lstat(path, &now) == 0 {
                    let (latest, latestIdentity) = try read(path: path)
                    if let fresh = try splice(latest) {
                        try replaceAtomically(path: path, data: fresh.data, unchangedSince: latestIdentity, original: latest)
                    }
                } else if errno != ENOENT {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } catch {
                throw Failure.removalFailed(path: path, displaced: claimed, detail: error.localizedDescription)
            }
        } else {
            try replaceAtomically(path: path, data: result.data, unchangedSince: identity, original: existing)
        }
        if removing && cleanupBackups { try removeBackups(path: path, recordURL: backupRecordURL) }
        return Outcome(path: path, backupPath: removing ? nil : backup,
                       replacedExistingEntry: result.replaced, removed: result.removed, replacedInstall: replacing.helper)
    }

    /// Which exact file, with which exact contents, we read. Compared again
    /// immediately before the rename.
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

    /// The file's current bytes and its identity. A symlink, a directory, a
    /// device or somebody else's file is refused rather than followed: this
    /// writer only ever edits a regular file the person owns.
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
            // A READ ERROR IS NOT END OF FILE. Swallowing it here would back up
            // and then write a TRUNCATED copy over a complete configuration.
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

    /// The person's own undo, beside the file they can already find.
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func writeBackup(path: String, data: Data, written: Data, originallyAbsent: Bool,
                                    restoresOriginal: Bool, jsonOwnership: JSONOwnership? = nil,
                                    tomlOwnership: JSONOwnership? = nil, recordURL: URL) throws -> String {
        var records = try backupRecords(at: recordURL)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        // Create the newest undo before removing older ones, including writes
        // in the same second. Never overwrite a colliding file.
        let stem = path + "." + InstallPaths.current.name("nativeagent-backup") + "-" + formatter.string(from: Date())
        for attempt in 0..<64 {
            let backup = attempt == 0 ? stem : "\(stem)-\(attempt)"
            if write(data, to: backup) {
                do {
                    let (_, identity) = try read(path: backup)
                    records.append(BackupRecord(path: backup, identity: identity, writtenDigest: digest(written),
                                                originallyAbsent: originallyAbsent, restoresOriginal: restoresOriginal,
                                                jsonOwnership: jsonOwnership, tomlOwnership: tomlOwnership))
                    try saveBackupRecords(records, at: recordURL)
                } catch {
                    _ = Darwin.unlink(backup)
                    throw error
                }
                try removeBackups(path: path, recordURL: recordURL, keeping: backup)
                return backup
            }
        }
        throw Failure.backupFailed
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
        catch { throw Failure.unreadable("ownership receipt \(url.path) must read as a BackupRecord array: \(error.localizedDescription). Restore that receipt before connecting or verifying") }
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
            // A matching name is not ownership. Delete only a file we recorded
            // creating, and leave replacements, symlinks and directories alone.
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
        // Swap keeps the host pathname present, including across a crash.
        // The displaced file stays beside it until validation or rollback.
        let (_, replacementIdentity) = try read(path: temporary)
        let (beforeSwap, beforeSwapIdentity) = try read(path: path)
        guard beforeSwapIdentity == identity, original == nil || beforeSwap == original else { throw Failure.changedUnderneath }
        guard renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 else { throw Failure.changedUnderneath }
        removeTemporary = false
        do {
            let (current, currentIdentity) = try read(path: temporary)
            guard currentIdentity == identity, original == nil || current == original else { throw Failure.changedUnderneath }
        } catch {
            // Check before and after rollback; a host can save between them.
            // A collision retains both versions for explicit recovery.
            guard let (published, publishedIdentity) = try? read(path: path),
                  publishedIdentity == replacementIdentity, published == data,
                  renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.rollbackFailed(temporary)
            }
            guard let (rolledBack, rolledBackIdentity) = try? read(path: temporary),
                  rolledBackIdentity == replacementIdentity, rolledBack == data else {
                // Restore the detected newer save with one compensating swap.
                // Even if another save races this swap, delete neither version.
                _ = renamex_np(temporary, path, UInt32(RENAME_SWAP))
                throw Failure.rollbackFailed(temporary)
            }
            removeTemporary = true
            throw error
        }
        guard Darwin.unlink(temporary) == 0 else {
            throw Failure.cleanupFailed(path: temporary, detail: String(cString: strerror(errno)))
        }
    }

    /// Create-exclusive, OWNER-ONLY, flushed before it is named: a crash
    /// mid-write can leave a stray temp file, never a truncated configuration.
    ///
    /// 0600 whatever the original was. This file now carries a connection key,
    /// and so does every backup of it; a configuration that used to be
    /// group-readable must not keep that permission once we have put a secret
    /// in it.
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

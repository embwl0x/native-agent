import Darwin
import CryptoKit
import Foundation
import PersistenceCore

/// Writing ONE entry into somebody else's configuration file.
///
/// The file belongs to another program and to the person, not to this app. So
/// the contract here is narrow and it is about what is NOT touched: every byte
/// outside our own entry survives the write exactly as it was — not re-encoded,
/// not reordered, not reindented, not stripped of its comments. That rules out
/// "parse, mutate, re-serialise", which is why both writers below are SPLICERS:
/// they locate the byte range our entry occupies (or the point it should be
/// inserted at) and replace only those bytes.
///
/// A file this cannot understand is REFUSED with a reason. Overwriting somebody
/// else's settings with our best guess at what they meant is the one outcome
/// worth more than a failed connection.
public enum AgentHostConfigWriter {
    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String)
        case unparsable(String)
        case tooLarge
        case backupFailed
        case writeFailed
        case changedUnderneath

        public var errorDescription: String? {
            switch self {
            case .changedUnderneath:
                return "The settings file changed while I was working; nothing was written."
            case .unreadable(let detail): return "The configuration file could not be read safely: \(detail). Nothing was changed."
            case .unparsable(let detail): return "The configuration file could not be parsed: \(detail). Existing bytes were preserved and nothing was changed."
            case .tooLarge: return "The configuration file exceeds the bounded size this writer will edit. Nothing was changed."
            case .backupFailed: return "A timestamped backup could not be written beside the configuration file, so the file was left untouched."
            case .writeFailed: return "The configuration file could not be replaced atomically. Nothing was changed."
            }
        }
    }

    /// Bounded by the same order of magnitude as the peer store's own limit.
    public static let maximumConfigurationBytes = 4 * 1_048_576

    /// Test-scoped seam for the one thing that cannot be provoked from outside:
    /// another program saving this file between our read and our rename. Runs
    /// exactly where that write would land. Always nil in production, and
    /// task-local so nothing can race it. Mirrors `AgentPeerHTTP`.
    @TaskLocal static var concurrentSaveHookForTests: (@Sendable () -> Void)?
    @TaskLocal static var beforeRemovalHookForTests: (@Sendable () -> Void)?
    @TaskLocal static var afterRemovalRenameHookForTests: (@Sendable () -> Void)?
    @TaskLocal static var backupDateForTests: Date?

    /// What a write did, for an honest tool result. Never carries file content.
    public struct Outcome: Sendable, Equatable {
        public let path: String
        public let backupPath: String?
        public let replacedExistingEntry: Bool
        public let removed: Bool
    }

    // MARK: - The two formats

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
            try checkMessagingConflicts(current, server: server, rules: rules)
            let allowed = try permissionRules(current, "allow")
            guard rules.allSatisfy(allowed.contains) else {
                throw Failure.unparsable("this connection's messaging allowances were changed or removed; review them in Antigravity. They were not restored automatically")
            }
            return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        return try edit(path: path, backupRecordURL: recordURL, initial: Data("{}".utf8), ownership: { data in
            JSONOwnership(command: "antigravity-messaging", peerID: peerID, name: server,
                original: try permissionEntry(data, "allow"),
                originalMember: try JSONEntrySplice.entry(data, name: "allow", containerKey: "permissions",
                    comments: true, trailingCommas: true, wholeMember: true))
        }) { data in
            try checkMessagingConflicts(data, server: server, rules: rules)
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
        try JSONEntrySplice.entry(data, name: key, containerKey: "permissions", comments: true, trailingCommas: true)
    }

    private static func checkMessagingConflicts(_ data: Data, server: String, rules: [String]) throws {
        for key in ["deny", "ask"] {
            let blocked = try permissionRules(data, key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // The documented wildcards are mcp(*) and mcp(server/*). Refuse
            // ambiguous broad spellings too, rather than assume they do not
            // constrain this connection on a different CLI version.
            guard !blocked.contains(where: {
                ["*", "mcp", "mcp(\(server))", "mcp(*)", "mcp(\(server)/*)"].contains($0) || rules.contains($0)
            }) else {
                throw Failure.unparsable("an existing \(key) rule covers or ambiguously constrains this connection's messaging tools; leave that rule intact and review it in Antigravity")
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
                    original: try JSONEntrySplice.entry(data, name: name, containerKey: containerKey,
                        comments: comments, trailingCommas: trailingCommas),
                    originalMember: try JSONEntrySplice.entry(data, name: name, containerKey: containerKey,
                        comments: comments, trailingCommas: trailingCommas, wholeMember: true))
            }) { data in
            try JSONEntrySplice.upsert(data, name: name, entryJSON: entryJSON, containerKey: containerKey, comments: comments, trailingCommas: trailingCommas)
        }
    }

    public static func removeJSONEntry(path: String, name: String, backupRecordURL: URL,
                                       containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true,
                                       peerID: String? = nil) throws -> Outcome {
        let owner = try backupRecords(at: backupRecordURL).last?.jsonOwnership
        if let peerID {
            guard let owner, owner.peerID == peerID else {
                throw Failure.unparsable("the connection's ownership receipt is missing; retain the key and contact for recovery")
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
                original: try TOMLEntrySplice.entry(data, name: name))
        }) { data in
            try TOMLEntrySplice.upsert(data, name: name, entryTOML: entryTOML)
        }
    }

    public static func removeTOMLEntry(path: String, name: String, backupRecordURL: URL, peerID: String? = nil) throws -> Outcome {
        let owner = try backupRecords(at: backupRecordURL).last?.tomlOwnership
        if let peerID {
            guard let owner, owner.peerID == peerID else {
                throw Failure.unparsable("the connection's ownership receipt is missing; retain the key and contact for recovery")
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
        var info = stat()
        let missing = lstat(path, &info) != 0 && errno == ENOENT
        if missing && removing { return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false) }
        let existing: Data
        let identity: FileIdentity?
        if missing, let initial { existing = initial; identity = nil }
        else { (existing, identity) = try read(path: path) }
        guard var result = try splice(existing) else {
            // Nothing to do — an absent entry a disconnect was asked to remove.
            if removing && cleanupBackups { try removeBackups(path: path, recordURL: backupRecordURL) }
            return Outcome(path: path, backupPath: nil, replacedExistingEntry: false, removed: false)
        }
        guard result.data.count <= maximumConfigurationBytes else { throw Failure.tooLarge }
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
            beforeRemovalHookForTests?()
            let claimed = path + ".nativeagent-removal-" + UUID().uuidString
            guard renamex_np(path, claimed, UInt32(RENAME_EXCL)) == 0 else { throw Failure.changedUnderneath }
            afterRemovalRenameHookForTests?()
            let current: Data
            let currentIdentity: FileIdentity
            do { (current, currentIdentity) = try read(path: claimed) }
            catch {
                // Exclusive restoration cannot overwrite a concurrent host save.
                _ = renamex_np(claimed, path, UInt32(RENAME_EXCL))
                throw error
            }
            if currentIdentity == identity, current == existing {
                guard Darwin.unlink(claimed) == 0 else { throw Failure.writeFailed }
            } else if renamex_np(claimed, path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else { throw Failure.writeFailed }
                // Both versions belong to the host. Keep both files and splice
                // only our entry out of the displaced version as well.
                if let fresh = try splice(current) {
                    try replaceAtomically(path: claimed, data: fresh.data, unchangedSince: currentIdentity)
                }
            }
            var now = stat()
            if lstat(path, &now) == 0 {
                let (latest, latestIdentity) = try read(path: path)
                if let fresh = try splice(latest) {
                    try replaceAtomically(path: path, data: fresh.data, unchangedSince: latestIdentity)
                }
            } else if errno != ENOENT {
                throw Failure.writeFailed
            }
        } else {
            try replaceAtomically(path: path, data: result.data, unchangedSince: identity)
        }
        if removing && cleanupBackups { try removeBackups(path: path, recordURL: backupRecordURL) }
        return Outcome(path: path, backupPath: removing ? nil : backup,
                       replacedExistingEntry: result.replaced, removed: result.removed)
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
        let stem = path + "." + InstallPaths.current.name("nativeagent-backup") + "-" + formatter.string(from: backupDateForTests ?? Date())
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
        return try JSONDecoder().decode([BackupRecord].self, from: Data(contentsOf: url))
    }

    private static func saveBackupRecords(_ records: [BackupRecord], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

    private static func replaceAtomically(path: String, data: Data, unchangedSince identity: FileIdentity?) throws {
        concurrentSaveHookForTests?()
        var now = stat()
        let status = lstat(path, &now)
        guard identity == nil ? (status != 0 && errno == ENOENT)
                : (status == 0 && now.st_mode & S_IFMT == S_IFREG && FileIdentity(now) == identity) else {
            throw Failure.changedUnderneath
        }
        let temporary = path + ".nativeagent-tmp-\(getpid())"
        guard write(data, to: temporary) else { throw Failure.writeFailed }
        // A new destination must never replace a file another app just created.
        let replaced = identity == nil ? Darwin.link(temporary, path) : rename(temporary, path)
        if identity == nil { _ = Darwin.unlink(temporary) }
        guard replaced == 0 else {
            _ = temporary.withCString { Darwin.unlink($0) }
            throw Failure.writeFailed
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

// MARK: - JSON: replace exactly our member's bytes

/// A byte-offset scanner over a JSON object, used for one purpose: finding the
/// exact span of ONE member so it can be replaced without re-encoding the rest.
/// It validates as it goes, so a file it cannot walk is refused rather than
/// rewritten.
enum JSONEntrySplice {

    struct Member {
        let start: Int      // first byte of the key's opening quote
        let end: Int        // one past the last byte of the value
        let key: String
    }

    /// THE ONE member of this name, or none. JSON permits duplicate keys and
    /// readers disagree about which of them wins, so a file carrying two is
    /// ambiguous: we would edit the copy the host is going to ignore, and the
    /// person would see a connection that does not work. Refuse before
    /// splicing rather than guess which one is live.
    static func unique(_ members: [Member], named key: String, called what: String) throws -> Member? {
        let matches = members.filter { $0.key == key }
        guard matches.count <= 1 else {
            throw AgentHostConfigWriter.Failure.unparsable(
                "it has more than one \(what) named \"\(key)\", so which one the app actually uses is ambiguous")
        }
        return matches.first
    }

    static func upsert(_ data: Data, name: String, entryJSON: String,
                       containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true,
                       originalMember: String? = nil, fragment: Bool = false) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        _ = try validatedBytes(Data((fragment ? "{\"value\":" + entryJSON + "}" : entryJSON).utf8), comments: comments, trailingCommas: trailingCommas)
        let original = [UInt8](data)
        let root = try members(bytes, from: try objectStart(bytes))
        guard let container = try unique(root.members, named: containerKey, called: "section") else {
            // No servers configured yet: add the whole container as one new
            // top-level member, leaving every existing member untouched.
            let indent = indentation(bytes, memberStart: root.members.first?.start)
            let member = originalMember ?? (quoted(name) + ": " + reindented(entryJSON, by: indent + indent))
            let body = "\"\(containerKey)\": {\n\(indent)\(indent)" + member + "\n\(indent)}"
            return (insertMember(original, into: root, text: body, indent: indent), false, false)
        }
        let valueStart = try valueOffset(bytes, member: container)
        guard bytes[valueStart] == UInt8(ascii: "{") else {
            throw AgentHostConfigWriter.Failure.unparsable("\"\(containerKey)\" is not an object")
        }
        let inner = try members(bytes, from: valueStart)
        let indent = indentation(bytes, memberStart: inner.members.first?.start)
        if let existing = try unique(inner.members, named: name, called: "server") {
            let replacement = originalMember ?? (quoted(name) + ": " + reindented(entryJSON, by: indent))
            return (splice(original, range: existing.start..<existing.end, with: replacement), true, false)
        }
        let body = originalMember ?? (quoted(name) + ": " + reindented(entryJSON, by: indent))
        return (insertMember(original, into: inner, text: body, indent: indent), false, false)
    }

    static func remove(_ data: Data, name: String, containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        let root = try members(bytes, from: try objectStart(bytes))
        guard let container = try unique(root.members, named: containerKey, called: "section") else { return nil }
        let valueStart = try valueOffset(bytes, member: container)
        guard bytes[valueStart] == UInt8(ascii: "{") else { return nil }
        let inner = try members(bytes, from: valueStart)
        guard let existing = try unique(inner.members, named: name, called: "server") else { return nil }
        return (splice([UInt8](data), range: deletionRange(bytes, of: existing, in: inner), with: ""), false, true)
    }

    static func entry(_ data: Data, name: String, containerKey: String, comments: Bool,
                      trailingCommas: Bool, wholeMember: Bool = false) throws -> String? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        let root = try members(bytes, from: objectStart(bytes))
        guard let container = try unique(root.members, named: containerKey, called: "section") else { return nil }
        let start = try valueOffset(bytes, member: container)
        guard bytes[start] == 123 else { throw AgentHostConfigWriter.Failure.unparsable("server section is not an object") }
        guard let member = try unique(members(bytes, from: start).members, named: name, called: "server") else { return nil }
        let memberStart = wholeMember ? member.start : try valueOffset(bytes, member: member)
        return String(decoding: Array(data)[memberStart..<member.end], as: UTF8.self)
    }

    /// Find our command AND connection id throughout the document, including
    /// renamed or relocated members. A same-name foreign member is never ours.
    static func disconnect(_ data: Data, owner: AgentHostConfigWriter.JSONOwnership,
                           containerKey: String, comments: Bool, trailingCommas: Bool) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        var ranges: [Range<Int>] = []
        func walk(_ start: Int) throws {
            if bytes[start] == 123 {
                let scan = try members(bytes, from: start)
                for member in scan.members {
                    _ = try unique(scan.members, named: member.key, called: "member")
                    let value = try valueOffset(bytes, member: member)
                    let object = try? JSONSerialization.jsonObject(with: Data(bytes[value..<member.end])) as? [String: Any]
                    let env = object?["env"] as? [String: Any]
                    if object?["command"] as? String == owner.command,
                       env?[AgentHostDirectory.peerIDVariable] as? String == owner.peerID {
                        ranges.append(deletionRange(bytes, of: member, in: scan))
                    } else { try walk(value) }
                }
            } else if bytes[start] == 91 {
                var index = start + 1
                skipWhitespace(bytes, &index)
                while bytes[index] != 93 {
                    try walk(index)
                    try skipValue(bytes, &index)
                    skipWhitespace(bytes, &index)
                    if bytes[index] == 44 { index += 1; skipWhitespace(bytes, &index) }
                }
            }
        }
        try walk(objectStart(bytes))
        // Delete one member then rescan: adjacent members share separators.
        var output = data
        if let range = ranges.first {
            output = splice(Array(data), range: range, with: "")
            if ranges.count > 1 {
                output = try disconnect(output, owner: .init(command: owner.command, peerID: owner.peerID,
                    name: owner.name, original: nil), containerKey: containerKey,
                    comments: comments, trailingCommas: trailingCommas)?.data ?? output
            }
        }
        if let original = owner.original {
            if let current = try entry(output, name: owner.name, containerKey: containerKey,
                                       comments: comments, trailingCommas: trailingCommas) {
                let lhs = try JSONSerialization.jsonObject(with: Data(validatedBytes(Data(current.utf8), comments: comments, trailingCommas: trailingCommas))) as? NSDictionary
                let rhs = try JSONSerialization.jsonObject(with: Data(validatedBytes(Data(original.utf8), comments: comments, trailingCommas: trailingCommas))) as? NSDictionary
                guard lhs == rhs else { throw AgentHostConfigWriter.Failure.unparsable("the original entry's name is occupied; resolve the collision before disconnecting") }
            } else {
                output = try upsert(output, name: owner.name, entryJSON: original,
                    containerKey: containerKey, comments: comments, trailingCommas: trailingCommas,
                    originalMember: owner.originalMember)!.data
            }
        }
        return output == data ? nil : (output, false, !ranges.isEmpty)
    }

    // MARK: Scanning

    /// Mask JSONC trivia with spaces, keeping every byte offset into the original.
    /// Foundation validates the entire document, including nested values and EOF.
    static func validatedBytes(_ data: Data, comments: Bool, trailingCommas: Bool = true) throws -> [UInt8] {
        var bytes = [UInt8](data)
        guard String(data: data, encoding: .utf8) != nil else {
            throw AgentHostConfigWriter.Failure.unparsable("the file is not valid text")
        }
        if comments {
            var i = 0
            while i < bytes.count {
                if bytes[i] == 34 { _ = try string(bytes, &i); continue }
                if bytes[i] == 47, i + 1 < bytes.count, bytes[i + 1] == 47 {
                    while i < bytes.count, bytes[i] != 10, bytes[i] != 13 { bytes[i] = 32; i += 1 }
                } else if bytes[i] == 47, i + 1 < bytes.count, bytes[i + 1] == 42 {
                    bytes[i] = 32; bytes[i + 1] = 32; i += 2
                    var closed = false
                    while i < bytes.count {
                        if bytes[i] == 42, i + 1 < bytes.count, bytes[i + 1] == 47 {
                            bytes[i] = 32; bytes[i + 1] = 32; i += 2; closed = true; break
                        }
                        if bytes[i] != 10, bytes[i] != 13 { bytes[i] = 32 }
                        i += 1
                    }
                    guard closed else { throw AgentHostConfigWriter.Failure.unparsable("a comment is never closed") }
                } else { i += 1 }
            }
        }
        var i = 0
        while i < bytes.count {
            if bytes[i] == 34 { _ = try string(bytes, &i); continue }
            if bytes[i] == 44 {
                var next = i + 1
                skipWhitespace(bytes, &next)
                if next < bytes.count, bytes[next] == 125 || bytes[next] == 93 {
                    guard comments && trailingCommas else { throw AgentHostConfigWriter.Failure.unparsable("a trailing comma is not allowed") }
                    var previous = i - 1
                    while previous >= 0, [UInt8(32), 9, 10, 13].contains(bytes[previous]) { previous -= 1 }
                    guard previous >= 0, ![UInt8(123), 91, 44, 58].contains(bytes[previous]) else {
                        throw AgentHostConfigWriter.Failure.unparsable("a value is missing")
                    }
                    bytes[i] = 32
                }
            }
            i += 1
        }
        guard (try? JSONSerialization.jsonObject(with: Data(bytes))) is [String: Any] else {
            throw AgentHostConfigWriter.Failure.unparsable("the settings are not a complete object")
        }
        return bytes
    }

    private static func objectStart(_ bytes: [UInt8]) throws -> Int {
        var index = 0
        skipWhitespace(bytes, &index)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else {
            throw AgentHostConfigWriter.Failure.unparsable("its top level is not a JSON object")
        }
        return index
    }

    struct Scan { let members: [Member]; let open: Int; let close: Int }

    /// Members of the object beginning at `open`, with their byte spans.
    static func members(_ bytes: [UInt8], from open: Int) throws -> Scan {
        var index = open + 1
        var found: [Member] = []
        skipWhitespace(bytes, &index)
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            return Scan(members: [], open: open, close: index)
        }
        while true {
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw AgentHostConfigWriter.Failure.unparsable("an object member has no name")
            }
            let start = index
            let key = try string(bytes, &index)
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw AgentHostConfigWriter.Failure.unparsable("an object member has no value")
            }
            index += 1
            skipWhitespace(bytes, &index)
            try skipValue(bytes, &index)
            found.append(Member(start: start, end: index, key: key))
            skipWhitespace(bytes, &index)
            guard index < bytes.count else {
                throw AgentHostConfigWriter.Failure.unparsable("an object is never closed")
            }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") {
                return Scan(members: found, open: open, close: index)
            }
            throw AgentHostConfigWriter.Failure.unparsable("an object member is not followed by ',' or '}'")
        }
    }

    private static func valueOffset(_ bytes: [UInt8], member: Member) throws -> Int {
        var index = member.start
        _ = try string(bytes, &index)
        skipWhitespace(bytes, &index)
        index += 1 // ':'
        skipWhitespace(bytes, &index)
        return index
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
            || bytes[index] == 0x0a || bytes[index] == 0x0d { index += 1 }
    }

    static func string(_ bytes: [UInt8], _ index: inout Int) throws -> String {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
            throw AgentHostConfigWriter.Failure.unparsable("a string does not start with a quote")
        }
        var raw: [UInt8] = []
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                guard index + 1 < bytes.count else { break }
                raw.append(byte); raw.append(bytes[index + 1]); index += 2; continue
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                // Member names are compared, so the escapes have to come out.
                let literal = "\"" + String(decoding: raw, as: UTF8.self) + "\""
                guard let decoded = try? JSONSerialization.jsonObject(
                    with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String else {
                    throw AgentHostConfigWriter.Failure.unparsable("a member name is not valid JSON")
                }
                return decoded
            }
            raw.append(byte); index += 1
        }
        throw AgentHostConfigWriter.Failure.unparsable("a string is never closed")
    }

    private static func skipValue(_ bytes: [UInt8], _ index: inout Int) throws {
        guard index < bytes.count else {
            throw AgentHostConfigWriter.Failure.unparsable("a value is missing")
        }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            _ = try string(bytes, &index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { _ = try string(bytes, &index); continue }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1; index += 1
                    if depth == 0 { return }
                    continue
                }
                index += 1
            }
            throw AgentHostConfigWriter.Failure.unparsable("a container is never closed")
        default:
            let terminators: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                                           0x20, 0x09, 0x0a, 0x0d]
            let start = index
            while index < bytes.count, !terminators.contains(bytes[index]) { index += 1 }
            guard index > start else {
                throw AgentHostConfigWriter.Failure.unparsable("a value is empty")
            }
        }
    }

    // MARK: Splicing

    private static func splice(_ bytes: [UInt8], range: Range<Int>, with text: String) -> Data {
        var output = Data(bytes[bytes.startIndex..<range.lowerBound])
        output.append(contentsOf: Array(text.utf8))
        output.append(contentsOf: bytes[range.upperBound..<bytes.endIndex])
        return output
    }

    /// A removed member takes its own separating comma with it, so the object
    /// is still valid JSON and no other member's bytes move.
    private static func deletionRange(_ bytes: [UInt8], of member: Member, in scan: Scan) -> Range<Int> {
        guard let position = scan.members.firstIndex(where: { $0.start == member.start }) else {
            return member.start..<member.end
        }
        if position > 0 {
            // Take everything from the end of the previous member: the comma,
            // and the whitespace that belonged to this row.
            return scan.members[position - 1].end..<member.end
        }
        if scan.members.count > 1 {
            // First of several: take up to the start of the next member.
            return member.start..<scan.members[1].start
        }
        return member.start..<member.end
    }

    private static func insertMember(_ bytes: [UInt8], into scan: Scan, text: String, indent: String) -> Data {
        if let last = scan.members.last {
            return splice(bytes, range: last.end..<last.end, with: ",\n" + indent + text)
        }
        // An empty object: put the first member between its braces.
        return splice(bytes, range: (scan.open + 1)..<(scan.open + 1), with: text)
    }

    /// The indentation the file already uses for members of this object, so an
    /// inserted row looks like the rows around it. Two spaces when the object
    /// is empty or written on one line.
    private static func indentation(_ bytes: [UInt8], memberStart: Int?) -> String {
        guard let memberStart else { return "  " }
        var index = memberStart - 1
        var run: [UInt8] = []
        while index >= 0, bytes[index] == 0x20 || bytes[index] == 0x09 {
            run.append(bytes[index]); index -= 1
        }
        guard index >= 0, bytes[index] == 0x0a, !run.isEmpty else { return "  " }
        return String(decoding: run.reversed(), as: UTF8.self)
    }

    /// Our entry is authored with two-space indents at depth zero; push every
    /// line after the first out to where it is being pasted.
    private static func reindented(_ text: String, by indent: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { $0.offset == 0 ? String($0.element) : indent + $0.element }
            .joined(separator: "\n")
    }

    /// A JSON string literal. Slashes stay slashes: this file is one the person
    /// opens and reads, and a path written as `\/Users\/…` is legal JSON that
    /// looks like a mistake.
    static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\(text)\"" }
        return literal
    }
}

// MARK: - TOML: replace exactly our table's lines

/// TOML tables are line-delimited, which is what makes a splice possible
/// without a full parser: `[mcp_servers.<name>]` and every line up to the next
/// header at the start of a line is our block, and nothing else in the file is
/// read or rewritten.
///
/// The one construct that would break that reading is a multi-line string,
/// whose body can contain a line that LOOKS like a header. A file containing
/// one is refused rather than guessed at.
enum TOMLEntrySplice {
    static let tablePrefix = "mcp_servers"

    static func entry(_ data: Data, name: String) throws -> String? {
        let text = try readable(data)
        return try range(of: name, in: text).map { String(text[$0]) }
    }

    static func identity(_ data: Data, name: String) throws -> (command: String, peerID: String)? {
        guard let block = try entry(data, name: name) else { return nil }
        var section = ""
        var values: [String: String] = [:]
        for raw in block.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let wanted = (section == "[mcp_servers.\(name)]" && key == "command")
                || (section == "[mcp_servers.\(name).env]" && key == AgentHostDirectory.peerIDVariable)
            guard wanted else { continue }
            guard values[key] == nil else { throw AgentHostConfigWriter.Failure.unparsable("duplicate ownership field") }
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            // Decode the basic/literal strings used by these scalar fields,
            // allowing trailing TOML comments without interpreting their text.
            let pattern = #"^("(?:[^"\\]|\\.)*"|'[^']*')\s*(?:#.*)?$"#
            guard let match = value.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(value[match])
            if matched.first == "'", let end = matched.dropFirst().firstIndex(of: "'") {
                values[key] = String(matched[matched.index(after: matched.startIndex)..<end])
            } else {
                let bytes = Array(matched.utf8)
                var index = 0
                values[key] = try JSONEntrySplice.string(bytes, &index)
            }
        }
        guard let command = values["command"], let peerID = values[AgentHostDirectory.peerIDVariable] else { return nil }
        return (command, peerID)
    }

    static func disconnect(_ data: Data, owner: AgentHostConfigWriter.JSONOwnership) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let text = try readable(data)
        var names = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[mcp_servers."), line.hasSuffix("]") else { continue }
            let name = String(line.dropFirst("[mcp_servers.".count).dropLast())
            guard !name.contains(".") else { continue }
            guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw AgentHostConfigWriter.Failure.unparsable("a server table uses an unsupported spelling")
            }
            names.insert(name)
        }
        var output = data
        var removed = false
        for name in names.sorted() {
            if let identity = try identity(output, name: name),
               identity.command == owner.command, identity.peerID == owner.peerID {
                output = try remove(output, name: name)!.data
                removed = true
            }
        }
        if let original = owner.original {
            if let current = try entry(output, name: owner.name) {
                guard current == original else {
                    throw AgentHostConfigWriter.Failure.unparsable("the original entry's name is occupied; resolve the collision before disconnecting")
                }
            } else {
                output = try upsert(output, name: owner.name, entryTOML: original)!.data
            }
        }
        return output == data ? nil : (output, false, removed)
    }

    static func upsert(_ data: Data, name: String, entryTOML: String) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let text = try readable(data)
        let block = try range(of: name, in: text)
        let body = entryTOML.hasSuffix("\n") ? entryTOML : entryTOML + "\n"
        if let block {
            return (Data((text.replacingCharacters(in: block, with: body)).utf8), true, false)
        }
        // Append exactly the block and a closing newline, and nothing else: a
        // blank separator line would be a byte OUTSIDE our entry that a later
        // disconnect could not take back, so removing us would not restore the
        // file the person had.
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return (Data((text + separator + body).utf8), false, false)
    }

    static func remove(_ data: Data, name: String) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let text = try readable(data)
        guard let block = try range(of: name, in: text) else { return nil }
        return (Data(text.replacingCharacters(in: block, with: "").utf8), false, true)
    }

    private static func readable(_ data: Data) throws -> String {
        // THE RAW BYTES, before decoding: Foundation quietly drops a leading
        // byte-order mark, so a check on the decoded string sees nothing and
        // the mark would then vanish from what we write back — a byte changed
        // outside our own entry. It also means the first table header no longer
        // compares equal, so we would append a SECOND copy of our table beside
        // the one already there.
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw AgentHostConfigWriter.Failure.unparsable(
                "it starts with a byte-order mark, which this writer will not edit around")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentHostConfigWriter.Failure.unparsable("it is not valid UTF-8")
        }
        guard !text.contains("\"\"\""), !text.contains("'''") else {
            throw AgentHostConfigWriter.Failure.unparsable(
                "it contains a multi-line string, which this writer will not edit around")
        }
        return text
    }

    /// TOML spells one table many ways: `[mcp_servers."nativeagent"]`,
    /// `[ mcp_servers . nativeagent ]`, single quotes. This writer understands
    /// exactly ONE spelling, and a file using another would get a duplicate
    /// table appended beside the one it already has. So an equivalent header
    /// that is not our canonical spelling is REFUSED, not taught — the person
    /// reads why and decides what to do with their own file.
    private static func rejectEquivalentSpelling(_ line: String, name: String) throws {
        let canonical = "[\(tablePrefix).\(name)]"
        guard line != canonical, !line.hasPrefix("[\(tablePrefix).\(name).") else { return }
        let bare = line.filter { $0 != " " && $0 != "\t" && $0 != "\"" && $0 != "'" }
        let ours = "[\(tablePrefix).\(name)"
        guard bare == ours + "]" || bare.hasPrefix(ours + ".") else { return }
        throw AgentHostConfigWriter.Failure.unparsable(
            "it already names this app's table as \(line), which is the same table written a "
            + "different way; this writer only edits the plain \(canonical) form")
    }

    /// Our table header, plus its key/value lines and any nested
    /// `[mcp_servers.<name>.env]` sub-table, up to the next unrelated header.
    private static func range(of name: String, in text: String) throws -> Range<String.Index>? {
        let header = "[\(tablePrefix).\(name)]"
        let nested = "[\(tablePrefix).\(name)."
        var start: String.Index?
        var end = text.endIndex
        var cursor = text.startIndex
        var blocks = 0
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = text[cursor..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw AgentHostConfigWriter.Failure.unparsable("a table header is malformed")
                }
                try rejectEquivalentSpelling(line, name: name)
                let isOurs = line == header || line.hasPrefix(nested)
                if line == header { blocks += 1 }
                if isOurs, start == nil { start = cursor }
                if !isOurs, start != nil, end == text.endIndex { end = cursor }
            }
            cursor = lineEnd
        }
        // Every header is read to the end of the file, not just up to where our
        // block stops: an equivalent spelling — or a second copy of our own
        // table — further down must still be refused rather than left to become
        // a duplicate.
        guard blocks <= 1 else {
            throw AgentHostConfigWriter.Failure.unparsable(
                "it already has more than one \(header) table, so which one is live is ambiguous")
        }
        guard let start else { return nil }
        return start..<end
    }

    /// TOML basic-string escaping for a value this app puts in the file.
    static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 { output += String(format: "\\u%04X", scalar.value) }
                else { output.unicodeScalars.append(scalar) }
            }
        }
        return output + "\""
    }
}

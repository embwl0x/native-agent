import Foundation
import SQLite3
import NativeAgentShared
import PersistenceCore
import TrustCenter
import MemoryV2
import Privacy
import SystemOps
// Blueprint: | `TrustBackupOffDisk.swift` | Credential-filtered coherent copies; verify before retention. |

extension TrustBackupPersistence {
    private static let offDiskBackupKeepCount = 14

    private static func offDiskBackupFolderFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // UTC, so a time-zone change can never reorder versions or make an old one look newer.
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }

    /// iCloud Drive preserves the agent's backup when the Mac is lost or wiped.
    public static func offDiskBackupParent() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("NativeAgent-Backups", isDirectory: true)
    }

    /// List only automatic UTC folders so retention never prunes hand-made copies.
    public static func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)] {
        guard Self.pathEntryExists(parent) else { return [] }
        let formatter = Self.offDiskBackupFolderFormatter()
        return try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).compactMap { url -> (url: URL, date: Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("auto-"),
                  name.count == "auto-yyyy-MM-dd-HHmmss".count,
                  let date = formatter.date(from: String(name.dropFirst("auto-".count))),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return (url, date)
        }.sorted { $0.date > $1.date }
    }

    /// Seal locally with SQLite outside WAL, copy to the versioned destination, then verify before retention. VolumeIO owns iCloud access so slow storage
    /// cannot block the cooperative pool.
    public static func createOffDiskBackup(
        reason: String,
        dataRoot root: URL,
        parent: URL,
        now: Date = Date()
    ) async throws -> URL {
        let fm = FileManager.default
        let iCloudDrive = parent.deletingLastPathComponent()
        let name = "auto-" + Self.offDiskBackupFolderFormatter().string(from: now)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        try await VolumeIO.run {
            guard Self.pathEntryExists(iCloudDrive) else {
                throw Self.backupError(code: 503, "iCloud Drive is not available at \(iCloudDrive.path); no off-disk backup was written.")
            }
            if !Self.pathEntryExists(parent) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            }
            guard !Self.pathEntryExists(destination) else {
                throw Self.backupError(code: 409, "Off-disk backup \(name) already exists.")
            }
        }
        let staging = fm.temporaryDirectory
            .appendingPathComponent("NativeAgent-offdisk-\(UUID().uuidString.lowercased())", isDirectory: true)
        let partial = parent.appendingPathComponent(".\(name).partial", isDirectory: true)
        // Once queued, VolumeIO owns the staged source until the physical copy exits, even when Stop/deadline has already released this caller.
        var copyQueued = false
        defer { if !copyQueued { try? fm.removeItem(at: staging) } }
        let files = try await Self.writeBackupSnapshot(
            id: UUID().uuidString.lowercased(),
            reason: reason,
            createdAt: ISO8601DateFormatter().string(from: now),
            dataRoot: root,
            into: staging,
            offDisk: true
        ).files
        copyQueued = true
        try await VolumeIO.run(onFinish: {
            do { try FileManager.default.removeItem(at: staging) }
            catch { NSLog("[OffDiskBackup] staging cleanup unavailable: %@", error.localizedDescription) }
        }) {
            var committed = false
            defer {
                if !committed, Self.pathEntryExists(partial) {
                    do { try FileManager.default.removeItem(at: partial) }
                    catch { NSLog("[OffDiskBackup] partial copy retained: %@", error.localizedDescription) }
                }
            }
            try FileManager.default.copyItem(at: staging, to: partial)
            guard try Self.backupIntegrityFiles(in: partial.appendingPathComponent("data", isDirectory: true)) == files else {
                throw Self.backupError(code: 500, "Off-disk backup copy does not match its manifest.")
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            committed = true
        }
        try await VolumeIO.run {
            for stale in try Self.offDiskAutomaticBackups(in: parent).dropFirst(Self.offDiskBackupKeepCount) {
                try FileManager.default.removeItem(at: stale.url)
            }
        }
        return destination
    }

    /// The staged copy of the record keeps experiences and events and drops its detail grain: what the body noticed is private, two weeks deep and
    /// rebuilt by living; the restored store creates an empty detail table on first open. Only the staged copy changes, never the agent's store.
    static func dropRecordDetails(in dataDir: URL) throws {
        let record = dataDir.appendingNativeRelativePath("experiences/experiences.sqlite")
        guard Self.pathEntryExists(record) else { return }
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(record.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(db, "DROP TABLE IF EXISTS detail; VACUUM;", nil, nil, nil) == SQLITE_OK else {
            throw Self.backupError(code: 500, "The staged record copy could not drop its details: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// iCloud cannot open WAL-mode SQLite; fold sidecars into staged copies before hashing and shipping.
    static func convertSQLiteCopiesToRollbackJournal(in dataDir: URL) throws {
        var databases: [URL] = []
        for item in try Self.backupEntries(in: dataDir)
        where try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            if try Self.sqliteIsWALMode(item) != nil { databases.append(item) }
        }
        for database in databases {
            var db: OpaquePointer?
            defer { sqlite3_close_v2(db) }
            guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                throw Self.backupError(code: 500, "SQLite copy could not be opened: \(database.lastPathComponent)")
            }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "PRAGMA journal_mode=DELETE", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let mode = sqlite3_column_text(statement, 0),
                  String(cString: mode).lowercased() == "delete" else {
                throw Self.backupError(code: 500, "SQLite copy could not leave WAL mode: \(database.lastPathComponent)")
            }
            var check: OpaquePointer?
            defer { sqlite3_finalize(check) }
            guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK,
                  sqlite3_step(check) == SQLITE_ROW,
                  let result = sqlite3_column_text(check, 0),
                  String(cString: result) == "ok" else {
                throw Self.backupError(code: 500, "SQLite copy failed quick_check: \(database.lastPathComponent)")
            }
        }
        for database in databases {
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: database.path + suffix)
                if Self.pathEntryExists(sidecar) {
                    try FileManager.default.removeItem(at: sidecar)
                }
            }
        }
    }

    private static func sqliteIsWALMode(_ url: URL) throws -> Bool? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 20) ?? Data()
        guard header.count == 20, header.prefix(16) == Data("SQLite format 3\u{0}".utf8) else { return nil }
        return header[18] == 2
    }

    /// The agent's experiences travel (a restore keeps its life and what is still owed); the record's details stay home (`dropRecordDetails`).
    /// Retained trail paths stay excluded so a backup never reads their old bytes. Credential filtering applies everywhere else.
    private static let offDiskExcludedPaths: Set<String> = [
        "extras", "backups", "production", "chat/index", "activity_watch",
        "logs", "diagnostics", "crash_reports", "ui-frames", "mobile_snapshot_cache",
        "traces", "turn_traces", "body", "builder_audit", "memory/backups",
        "cognition/caring_appraisals.jsonl", "context/feedback.jsonl", "mac_control_audit.jsonl",
        "slack/receipts.jsonl", "scheduler/retired.jsonl", "mobile_push/apns_outcomes.jsonl", "doctor/repair_receipts.jsonl",
        "senses/ledger",
        "senses/news",
        "ability_fetches",
    ]

    /// Only model routing may leave providers; keys and OAuth tokens stay local.
    private static let offDiskProviderFiles: Set<String> = ["providers/active.json", "providers/surfaces.json"]

    private static let outgoingCredentialStores: Set<String> = [
        "security", "secrets", "oauth_tokens", "oauth_apps", "claude-bridge", "nextgen/remote",
    ]

    static func isOutgoingCredential(_ relative: String, _ url: URL) -> Bool {
        isCredentialFile(url)
            || outgoingCredentialStores.contains { NativeAgentWorkspaceRoot.relativePath(relative, under: $0) != nil }
            || (NativeAgentWorkspaceRoot.relativePath(relative, under: "providers").map({ !$0.isEmpty }) == true && !offDiskProviderFiles.contains(relative))
    }

    private static func isOffDiskExcluded(_ relative: String, _ url: URL) -> Bool {
        relative.hasSuffix(".lock")
            || Self.isOutgoingCredential(relative, url)
            || Self.offDiskExcludedPaths.contains { NativeAgentWorkspaceRoot.relativePath(relative, under: $0) != nil }
    }

    /// Copy feed and optional base together so traversal cannot replace half with a newer compaction epoch.
    static func copyOffDiskEntry(
        _ source: URL, relative: String, into dataDir: URL, dataRoot root: URL
    ) async throws -> [String] {
        guard !Self.isOffDiskExcluded(relative, source) else { return [] }
        let name = source.lastPathComponent
        if name.hasSuffix("_base.json"), Self.pathEntryExists(source.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropLast("_base.json".count)) + ".jsonl")) { return [] }
        guard source.pathExtension == "jsonl" else {
            return try await Self.copyOffDiskItem(source, relative: relative, into: dataDir, dataRoot: root) ? [relative] : []
        }
        // Lock even before the first base exists: compaction may create it while a backup is reading the original feed.
        return try await SwiftNativePersistenceCore.withFileLock(source) {
            var copied: [String] = []
            if try await Self.copyOffDiskItem(source, relative: relative, into: dataDir, dataRoot: root) {
                copied.append(relative)
            }
            let baseName = source.deletingPathExtension().lastPathComponent + "_base.json"
            let base = source.deletingLastPathComponent().appendingPathComponent(baseName)
            let baseRelative = String(relative.dropLast(name.count)) + baseName
            if Self.pathEntryExists(base),
               try await Self.copyOffDiskItem(base, relative: baseRelative, into: dataDir, dataRoot: root) {
                copied.append(baseRelative)
            }
            return copied
        }
    }

    /// Copy coherent SQLite images without live writes or raw sidecars; feed/base pairs share their writer's lock.
    static func copyOffDiskItem(
        _ source: URL,
        relative: String,
        into dataDir: URL,
        dataRoot root: URL
    ) async throws -> Bool {
        guard !Self.isOffDiskExcluded(relative, source) else { return false }
        let destination = dataDir.appendingNativeRelativePath(relative)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            // Preserve raw link targets in the manifest; never follow them while copying.
            try Self.copyBackupLink(from: source, to: destination)
            return true
        }
        if values.isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
                .sorted {
                    ($0.lastPathComponent == "sessions.jsonl" ? 0 : 1, $0.lastPathComponent)
                        < ($1.lastPathComponent == "sessions.jsonl" ? 0 : 1, $1.lastPathComponent)
                }
            let names = Set(children.map(\.lastPathComponent))
            for child in children {
                let name = child.lastPathComponent
                // Treat sidecars as database state only when the sibling really is SQLite.
                if ["-wal", "-shm", "-journal"].contains(where: { suffix in
                    let base = String(name.dropLast(suffix.count))
                    return name.hasSuffix(suffix) && names.contains(base)
                        && (try? Self.sqliteIsWALMode(source.appendingPathComponent(base))).flatMap { $0 } != nil
                }) { continue }
                if name.hasPrefix("."), name.hasSuffix(".tmp") { continue }
                _ = try await Self.copyOffDiskEntry(child, relative: relative + "/" + name, into: dataDir, dataRoot: root)
            }
            return true
        } else if values.isRegularFile != true {
            throw Self.backupError(code: 422, "Backup source contains a non-regular item: \(relative)")
        }
        if relative == "memory/memory.sqlite" {
            try Self.copyLiveSQLite(from: source, to: destination)
            return true
        }
        // Use read-only online backup for live databases; only staged copies may open for write during WAL conversion.
        if let walMode = try Self.sqliteIsWALMode(source),
           !walMode || Self.pathEntryExists(URL(fileURLWithPath: source.path + "-wal")) {
            try Self.copyLiveSQLite(from: source, to: destination)
            return true
        }
        let locked = relative.hasPrefix("memory/") || relative == "chat/sessions.json"
            || relative.hasPrefix("chat/messages/") || relative.hasPrefix("chat/session_state/")
            || relative.hasPrefix("chat/archive/")
        do {
            try await Self.copyLockedSnapshotFile(from: source, to: destination, locking: locked)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return false // deleted by its owner since the directory was listed
        }
        return true
    }

    /// Exclude secret-named files, private keys and configurations embedding credentials at every depth. Whole credential stores remain under
    /// outgoingCredentialStores.
    private static func isCredentialFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["auth.json", "oauth_app.json", "macctl_bridge.json", "browser_ipc.json"].contains(name)
            || ["token", "secret", "credential", "signing_key"].contains { name.contains($0) }
            || ["p8", "pem", "key", "p12", "pfx"].contains(url.pathExtension.lowercased())
            || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains { name.hasPrefix($0) }
            || ["/config/config.json", "/telegram/config.json", "/mcp/servers.json", "/agents/peers.json"]
                .contains { url.path.hasSuffix($0) }
    }
}

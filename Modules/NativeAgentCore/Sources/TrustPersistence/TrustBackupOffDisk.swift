import Foundation
import SQLite3
import NativeAgentShared
import PersistenceCore
import TrustCenter
import MemoryV2
import Privacy
import SystemOps
// Blueprint: | `TrustBackupOffDisk.swift` | TrustBackupPersistence off-disk copies; credential exclusions, SQLite journal conversion, landed integrity verification and automatic retention |

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

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/NativeAgent-Backups` — iCloud Drive, so a lost or wiped Mac does not
    /// take Agent with it.
    public static func offDiskBackupParent() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("NativeAgent-Backups", isDirectory: true)
    }

    /// Automatic folders only (`auto-YYYY-MM-DD-HHmmss`, UTC), newest first. Any other folder in the parent — a hand-made copy
    /// — is never listed, so it is never pruned.
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

    /// One versioned off-disk backup: the same snapshot `createBackup` seals, staged in a local temp directory (SQLite copies
    /// leave WAL mode there), copied into `parent/auto-<UTC time>`, re-verified against its manifest where it landed, then
    /// automatic folders beyond the newest `offDiskBackupKeepCount` are pruned. Every step that touches iCloud Drive runs on
    /// VolumeIO, never on the cooperative pool.
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
        defer { try? fm.removeItem(at: staging) }
        do {
            let files = try await Self.writeBackupSnapshot(
                id: UUID().uuidString.lowercased(),
                reason: reason,
                createdAt: ISO8601DateFormatter().string(from: now),
                dataRoot: root,
                into: staging,
                offDisk: true
            ).files
            try await VolumeIO.run {
                try FileManager.default.copyItem(at: staging, to: partial)
                guard try Self.backupIntegrityFiles(in: partial.appendingPathComponent("data", isDirectory: true)) == files else {
                    throw Self.backupError(code: 500, "Off-disk backup copy does not match its manifest.")
                }
                try FileManager.default.moveItem(at: partial, to: destination)
            }
        } catch {
            _ = try? await VolumeIO.run { try FileManager.default.removeItem(at: partial) }
            throw error
        }
        try await VolumeIO.run {
            for stale in try Self.offDiskAutomaticBackups(in: parent).dropFirst(Self.offDiskBackupKeepCount) {
                try FileManager.default.removeItem(at: stale.url)
            }
        }
        return destination
    }

    /// A WAL-mode SQLite file cannot be opened from iCloud Drive. Every SQLite copy in the staged snapshot is switched to a
    /// rollback journal (folding any copied `-wal` into the main file) before it is hashed and shipped.
    static func convertSQLiteCopiesToRollbackJournal(in dataDir: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: dataDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw Self.backupError(code: 422, "Backup contents could not be enumerated.")
        }
        var databases: [URL] = []
        for case let item as URL in enumerator
        where (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
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

    /// nil for a file that is not SQLite; otherwise whether its header is in WAL mode (format bytes 18/19 == 2).
    private static func sqliteIsWALMode(_ url: URL) throws -> Bool? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 20) ?? Data()
        guard header.count == 20, header.prefix(16) == Data("SQLite format 3\u{0}".utf8) else { return nil }
        return header[18] == 2
    }

    /// Off-disk leaves these data-root-relative paths behind: the model that ships in the DMG, local backups, past export and
    /// support bundles (copies of what the backup carries), the rebuildable history index, regenerable diagnostics, old
    /// pre-consolidation memory copies, and what PrivacyMap promises never leaves the Mac (usage history, sense ledger and
    /// news). Credential files anywhere else are `isCredentialFile`.
    private static let offDiskExcludedPaths: Set<String> = [
        "extras", "backups", "production", "chat/index", "activity_watch",
        "logs", "diagnostics", "crash_reports", "ui-frames", "mobile_snapshot_cache",
        "evals", "traces", "turn_traces", "harness", "builder_audit", "memory/backups",
        "senses/ledger",
        "senses/news",
    ]

    /// `providers/` holds API keys and OAuth tokens; only its model routing goes.
    private static let offDiskProviderFiles: Set<String> = ["providers/active.json", "providers/surfaces.json"]

    private static let outgoingCredentialStores: Set<String> = [
        "security", "secrets", "oauth_tokens", "oauth_apps", "claude-bridge", "nextgen/remote",
    ]

    static func isOutgoingCredential(_ relative: String, _ url: URL) -> Bool {
        isCredentialFile(url)
            || outgoingCredentialStores.contains { NativeAgentWorkspaceRoot.relativePath(relative, under: $0) != nil }
            || (NativeAgentWorkspaceRoot.relativePath(relative, under: "providers").map({ !$0.isEmpty }) == true && !offDiskProviderFiles.contains(relative))
    }

    /// True for a data-root-relative path an off-disk backup leaves behind.
    private static func isOffDiskExcluded(_ relative: String, _ url: URL) -> Bool {
        relative.hasSuffix(".lock")
            || Self.isOutgoingCredential(relative, url)
            || Self.offDiskExcludedPaths.contains { NativeAgentWorkspaceRoot.relativePath(relative, under: $0) != nil }
    }

    /// A feed and its optional compaction base are one copy, at any depth (REM's pair lives directly in the data root). Only
    /// the feed copies its base, so traversal cannot later replace half with a newer epoch.
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

    /// Copy one data-root item into an off-disk snapshot, returning false when it is left behind. Every SQLite database is
    /// copied as a coherent image without the backup ever opening live data for write; its `-wal`/`-shm`/`-journal` never
    /// travel raw. Snapshot/tail feeds copy their optional base and tail together under the feed writer's lock.
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
            // Never followed: recorded in the manifest as {path, target} by `takeBackupLinks`. The live one points into the
            // persona root, which this backup copies anyway.
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
                // A database's sidecars, only when that sibling really is SQLite.
                if ["-wal", "-shm", "-journal"].contains(where: { suffix in
                    let base = String(name.dropLast(suffix.count))
                    return name.hasSuffix(suffix) && names.contains(base)
                        && (try? Self.sqliteIsWALMode(source.appendingPathComponent(base))).flatMap { $0 } != nil
                }) { continue }
                // An atomic writer's in-flight temp file (`.<name>.<pid>...tmp`).
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
        // A database that may be live goes through a read-only online backup. A WAL database with no `-wal` has no open
        // connection; it is copied as bytes like any file, and only the staged copy is ever opened for write
        // (`convertSQLiteCopiesToRollbackJournal` converts and quick_checks it).
        if let walMode = try Self.sqliteIsWALMode(source),
           !walMode || Self.pathEntryExists(URL(fileURLWithPath: source.path + "-wal")) {
            try Self.copyLiveSQLite(from: source, to: destination)
            return true
        }
        // The paths the local backup copies under their writers' locks keep them.
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

    /// Secrets an off-disk backup never carries, wherever they sit: anything named for a token, secret, credential or signing
    /// key; connector `auth.json` and OAuth app secrets; private keys (`.p8`, `.pem`, `.key`, `.p12`, `.pfx`, SSH `id_*`); and
    /// the config files that embed a token or key — app config (Telegram token, X app secrets), Telegram config, MCP server
    /// commands, and the Mac-control / browser IPC bridge files. Whole credential stores are in `outgoingCredentialStores`.
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

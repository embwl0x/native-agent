import Foundation
import Darwin
import CryptoKit
import SQLite3
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Transcripts
import MemoryV2
import ApprovalInbox
import TrustCenter

private actor NativeBackupRestoreCoordinator {
    private var activeDataRoots: Set<String> = []

    func acquire(dataRoot: URL) -> Bool {
        activeDataRoots.insert(dataRoot.standardizedFileURL.path).inserted
    }

    func release(dataRoot: URL) {
        activeDataRoots.remove(dataRoot.standardizedFileURL.path)
    }
}

private let nativeBackupRestoreCoordinator = NativeBackupRestoreCoordinator()

private struct NativeBackupIntegrityFile: Codable, Equatable {
    let path: String
    let sizeBytes: Int64
    let sha256: String
}

/// A symlink in the data root, kept in a local backup's manifest as its raw
/// `readlink` target instead of bytes; restore recreates the link itself.
private struct NativeBackupLink: Equatable {
    let path: String
    let target: String
}

private struct NativeBackupRestoreIntent: Codable {
    enum State: String, Codable {
        case staged
        case applying
        case rollingBack
        case completed
    }

    let transactionID: String
    let targetID: String
    let targetManifestSHA256: String
    var safetyBackupID: String
    var safetyManifestSHA256: String
    let stagedAt: String
    var state: State
}

private struct NativeValidatedBackupSnapshot {
    let id: String
    let dataDirectory: URL
    let copied: [String]
    let files: [NativeBackupIntegrityFile]
    let links: [NativeBackupLink]
    let reason: String
    let createdAt: String
    let manifestSHA256: String
}

public enum TrustBackupPersistence {
    public static func createBackup(reason: String, dataRoot root: URL, host: TrustBackupHost) async throws -> BackupRecord {
        let now = Self.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let backupDir = backupRoot.appendingPathComponent(id, isDirectory: true)

        let fm = FileManager.default
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReason = cleanReason.isEmpty ? "manual backup" : cleanReason

        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: backupDir)
        do {
            let scope = try await Self.writeBackupSnapshot(
                id: id,
                reason: resolvedReason,
                createdAt: now,
                dataRoot: root,
                into: backupDir,
                offDisk: false,
                host: host
            ).scope
            let record = BackupRecord(
                id: id,
                reason: resolvedReason,
                scope: scope,
                path: backupDir.path,
                createdAt: now
            )
            // A backup is also the byte-preserving recovery path for damaged
            // authority state. Creation proves containment and integrity; only
            // a selected restore target must additionally prove that its
            // authority payload is safe to install.
            _ = try Self.validateBackupSnapshot(
                id: id,
                dataRoot: root,
                requireRestorableAuthority: false
            )
            try await Self.appendBackupRecord(record, backupRoot: backupRoot)
            return record
        } catch {
            try? fm.removeItem(at: backupDir)
            throw error
        }
    }

    /// Writes `<backupDir>/data` and its sealed `manifest.json`. `offDisk` is
    /// the copy that leaves this Mac: the whole data root minus
    /// `offDiskExcludedPaths` and credentials, plus the live persona root (the
    /// repo's `persona/`) as `persona`, with every SQLite copy out of WAL mode
    /// so it opens where it lands. The local scope is `backupRelativePaths`.
    private static func writeBackupSnapshot(
        id: String,
        reason: String,
        createdAt: String,
        dataRoot root: URL,
        into backupDir: URL,
        offDisk: Bool,
        host: TrustBackupHost
    ) async throws -> (scope: [String], files: [NativeBackupIntegrityFile]) {
        let fm = FileManager.default
        let dataDir = backupDir.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var copied: [String] = []
        if offDisk {
            let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: root)
            // Persona is the point of this copy: no SOUL.md fails the backup.
            guard Self.pathEntryExists(personaRoot.appendingPathComponent("SOUL.md")) else {
                throw Self.backupError(code: 422, "Live persona root has no SOUL.md: \(personaRoot.path)")
            }
            if try await Self.copyOffDiskItem(personaRoot, relative: "persona", into: dataDir, dataRoot: root) {
                copied.append("persona")
            }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            // `<dataRoot>/persona` never shadows the live persona root copied above.
            for child in children where child.lastPathComponent != "persona" {
                if try await Self.copyOffDiskItem(child, relative: child.lastPathComponent, into: dataDir, dataRoot: root) {
                    copied.append(child.lastPathComponent)
                }
            }
        } else {
            let ordinaryPaths = Self.backupRelativePaths.filter {
                $0 != "memory" && !$0.hasPrefix("chat/")
            }
            copied = try Self.copySelectedDataPaths(
                root: root,
                destinationRoot: dataDir,
                relativePaths: ordinaryPaths
            )
            let memorySource = root.appendingNativeRelativePath("memory")
            if Self.pathEntryExists(memorySource) {
                // A linked Memory root would aim the SQLite backup below through it.
                try Self.requireRegularDirectory(memorySource)
                let memoryDestination = dataDir.appendingNativeRelativePath("memory")
                try await Self.copyLockedSnapshotItem(
                    from: memorySource,
                    to: memoryDestination,
                    excludingSQLiteArtifacts: true
                )
                let liveDatabase = memorySource.appendingPathComponent("memory.sqlite")
                if Self.pathEntryExists(liveDatabase) {
                    try await MemoryStorage.createConsistentBackup(
                        dataRoot: root,
                        destinationDatabaseURL: memoryDestination
                            .appendingPathComponent("memory.sqlite")
                    )
                }
                copied.append("memory")
            }
            for relative in ["chat/sessions.json", "chat/messages", "chat/session_state"] {
                let source = root.appendingNativeRelativePath(relative)
                guard Self.pathEntryExists(source) else { continue }
                try await Self.copyLockedSnapshotItem(
                    from: source,
                    to: dataDir.appendingNativeRelativePath(relative),
                    excludingSQLiteArtifacts: false
                )
                copied.append(relative)
            }
            copied = Self.backupRelativePaths.filter { copied.contains($0) }
        }
        let scope = Self.scopeNames(for: copied)
        let links = try Self.takeBackupLinks(in: dataDir)
        // After the links are gone, so only staged regular files are opened.
        if offDisk {
            try Self.convertSQLiteCopiesToRollbackJournal(in: dataDir)
        }
        let files = try Self.backupIntegrityFiles(in: dataDir)
        let manifest: [String: JSONValue] = [
            "app": .string("NativeAgent"),
            "createdAt": .string(createdAt),
            "id": .string(id),
            "integrityVersion": .int(2),
            // An off-disk copy is never a restore target: its `data/persona` is
            // the live persona root, which a restore would write to
            // `<dataRoot>/persona` and so move Agent's persona root.
            "kind": .string(offDisk ? "offdisk_backup" : "backup"),
            "reason": .string(reason),
            "scope": .array(scope.map { .string($0) }),
            "copied": .array(copied.map { .string($0) }),
            "files": .array(files.map(Self.backupIntegrityFileJSON)),
            "links": .array(links.map(Self.backupLinkJSON)),
            "version": .string(host.applicationVersion()),
        ]
        try Self.writeJSONValue(.object(manifest), to: backupDir.appendingPathComponent("manifest.json"))
        return (scope, files)
    }

    private static let offDiskBackupKeepCount = 14

    private static func offDiskBackupFolderFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // UTC, so a time-zone change can never reorder versions or make an
        // old one look newer.
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }

    /// Automatic folders only (`auto-YYYY-MM-DD-HHmmss`, UTC), newest first. Any
    /// other folder in the parent — a hand-made copy — is never listed, so it
    /// is never pruned.
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

    /// One versioned off-disk backup: the same snapshot `createBackup` seals,
    /// staged in a local temp directory (SQLite copies leave WAL mode there),
    /// copied into `parent/auto-<UTC time>`, re-verified against its manifest
    /// where it landed, then automatic folders beyond the newest
    /// `offDiskBackupKeepCount` are pruned.
    public static func createOffDiskBackup(
        reason: String,
        dataRoot root: URL,
        parent: URL,
        now: Date = Date(),
        host: TrustBackupHost
    ) async throws -> URL {
        let fm = FileManager.default
        let iCloudDrive = parent.deletingLastPathComponent()
        guard Self.pathEntryExists(iCloudDrive) else {
            throw Self.backupError(code: 503, "iCloud Drive is not available at \(iCloudDrive.path); no off-disk backup was written.")
        }
        if !Self.pathEntryExists(parent) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let name = "auto-" + Self.offDiskBackupFolderFormatter().string(from: now)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard !Self.pathEntryExists(destination) else {
            throw Self.backupError(code: 409, "Off-disk backup \(name) already exists.")
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
                offDisk: true,
                host: host
            ).files
            try fm.copyItem(at: staging, to: partial)
            guard try Self.backupIntegrityFiles(in: partial.appendingPathComponent("data", isDirectory: true)) == files else {
                throw Self.backupError(code: 500, "Off-disk backup copy does not match its manifest.")
            }
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        for stale in try Self.offDiskAutomaticBackups(in: parent).dropFirst(Self.offDiskBackupKeepCount) {
            try fm.removeItem(at: stale.url)
        }
        return destination
    }

    /// A WAL-mode SQLite file cannot be opened from iCloud Drive. Every SQLite
    /// copy in the staged snapshot is switched to a rollback journal (folding
    /// any copied `-wal` into the main file) before it is hashed and shipped.
    private static func convertSQLiteCopiesToRollbackJournal(in dataDir: URL) throws {
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

    /// nil for a file that is not SQLite; otherwise whether its header is in
    /// WAL mode (format bytes 18/19 == 2).
    private static func sqliteIsWALMode(_ url: URL) throws -> Bool? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 20) ?? Data()
        guard header.count == 20, header.prefix(16) == Data("SQLite format 3\u{0}".utf8) else { return nil }
        return header[18] == 2
    }

    /// Off-disk leaves these data-root-relative paths behind: the model that
    /// ships in the DMG, local backups, regenerable diagnostics, old
    /// pre-consolidation memory copies, and credential stores. Credential files
    /// anywhere else are `isCredentialFile`.
    private static let offDiskExcludedPaths: Set<String> = [
        "extras", "backups",
        "logs", "diagnostics", "crash_reports", "ui-frames", "mobile_snapshot_cache",
        "evals", "traces", "turn_traces", "harness", "builder_audit", "memory/backups",
        "security", "secrets", "oauth_tokens", "oauth_apps", "claude-bridge", "nextgen/remote",
    ]

    /// `providers/` holds API keys and OAuth tokens; only its model routing goes.
    private static let offDiskProviderFiles: Set<String> = ["providers/active.json", "providers/surfaces.json"]

    /// True for a data-root-relative path an off-disk backup leaves behind.
    private static func isOffDiskExcluded(_ relative: String, _ url: URL) -> Bool {
        relative.hasSuffix(".lock")
            || Self.isCredentialFile(url)
            || Self.offDiskExcludedPaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
            || (relative.hasPrefix("providers/") && !Self.offDiskProviderFiles.contains(relative))
    }

    /// Copy one data-root item into an off-disk snapshot, returning false when
    /// it is left behind. Every SQLite database is copied as a coherent image
    /// without the backup ever opening live data for write; its
    /// `-wal`/`-shm`/`-journal` never travel raw.
    private static func copyOffDiskItem(
        _ source: URL,
        relative: String,
        into dataDir: URL,
        dataRoot root: URL
    ) async throws -> Bool {
        guard !Self.isOffDiskExcluded(relative, source) else { return false }
        let destination = dataDir.appendingNativeRelativePath(relative)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            // Never followed: recorded in the manifest as {path, target} by
            // `takeBackupLinks`. The live one points into the persona root,
            // which this backup copies anyway.
            try Self.copyBackupLink(from: source, to: destination)
            return true
        }
        if values.isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
                _ = try await Self.copyOffDiskItem(child, relative: relative + "/" + name, into: dataDir, dataRoot: root)
            }
            return true
        } else if values.isRegularFile != true {
            throw Self.backupError(code: 422, "Backup source contains a non-regular item: \(relative)")
        }
        if relative == "memory/memory.sqlite" {
            try await MemoryStorage.createConsistentBackup(dataRoot: root, destinationDatabaseURL: destination)
            return true
        }
        // A database that may be live goes through a read-only online backup.
        // A WAL database with no `-wal` has no open connection; it is copied as
        // bytes like any file, and only the staged copy is ever opened for write
        // (`convertSQLiteCopiesToRollbackJournal` converts and quick_checks it).
        if let walMode = try Self.sqliteIsWALMode(source),
           !walMode || Self.pathEntryExists(URL(fileURLWithPath: source.path + "-wal")) {
            try Self.copyLiveSQLite(from: source, to: destination)
            return true
        }
        // The paths the local backup copies under their writers' locks keep them.
        let locked = relative.hasPrefix("memory/") || relative == "chat/sessions.json"
            || relative.hasPrefix("chat/messages/") || relative.hasPrefix("chat/session_state/")
        do {
            try await Self.copyLockedSnapshotFile(from: source, to: destination, locking: locked)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return false // deleted by its owner since the directory was listed
        }
        return true
    }

    /// One read transaction over a possibly live database into a fresh file.
    /// Read-only: the backup never writes or checkpoints live data.
    private static func copyLiveSQLite(from source: URL, to destination: URL) throws {
        var src: OpaquePointer?
        var dst: OpaquePointer?
        defer {
            sqlite3_close_v2(src)
            sqlite3_close_v2(dst)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_busy_timeout(src, 10_000) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw Self.backupError(code: 500, "SQLite database could not be opened for backup: \(source.lastPathComponent)")
        }
        let step = sqlite3_backup_step(backup, -1)
        guard sqlite3_backup_finish(backup) == SQLITE_OK, step == SQLITE_DONE else {
            throw Self.backupError(code: 500, "SQLite online backup failed (\(step)): \(source.lastPathComponent)")
        }
    }

    public static func restoreBackup(id: String, dataRoot root: URL, host: TrustBackupHost) async throws -> BackupRestoreResult {
        guard await nativeBackupRestoreCoordinator.acquire(dataRoot: root) else {
            throw NSError(domain: "NativeAgentBackup", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "Another backup restore is already in progress for this data root."
            ])
        }

        do {
            let result = try await restoreBackupAfterAcquiringLock(id: id, dataRoot: root, host: host)
            await nativeBackupRestoreCoordinator.release(dataRoot: root)
            return result
        } catch {
            await nativeBackupRestoreCoordinator.release(dataRoot: root)
            throw error
        }
    }

    private static func restoreBackupAfterAcquiringLock(
        id: String,
        dataRoot root: URL,
        host: TrustBackupHost
    ) async throws -> BackupRestoreResult {
        let snapshot: NativeValidatedBackupSnapshot
        do {
            snapshot = try Self.validateBackupSnapshot(id: id, dataRoot: root)
        } catch {
            do {
                guard try Self.sealLegacyV1BackupForRestore(id: id, dataRoot: root) else {
                    throw error
                }
                snapshot = try Self.validateBackupSnapshot(id: id, dataRoot: root)
            } catch {
                throw NSError(domain: "NativeAgentBackup", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "Backup source, integrity, authority, or session state is invalid; restore was cancelled before current data changed: \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error,
                ])
            }
        }
        let intentPath = Self.backupRestoreIntentPath(dataRoot: root)
        guard !Self.pathEntryExists(intentPath) else {
            throw NSError(domain: "NativeAgentBackup", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "A staged backup restore already exists. Restart NativeAgent to finish or roll it back before staging another restore."
            ])
        }

        let safetyReason = "pre-restore safety backup before restoring \"\(snapshot.reason)\" from \(snapshot.createdAt) [\(snapshot.id)]"
        let safetyBackup: BackupRecord
        do {
            safetyBackup = try await createBackup(reason: safetyReason, dataRoot: root, host: host)
        } catch {
            throw NSError(domain: "NativeAgentBackup", code: 412, userInfo: [
                NSLocalizedDescriptionKey: "Safety backup failed; restore was cancelled before current data changed: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }
        let safetySnapshot: NativeValidatedBackupSnapshot
        do {
            safetySnapshot = try Self.validateBackupSnapshot(
                id: safetyBackup.id,
                dataRoot: root,
                requireRestorableAuthority: false
            )
        } catch {
            throw NSError(domain: "NativeAgentBackup", code: 412, userInfo: [
                NSLocalizedDescriptionKey: "Safety backup validation failed; restore was cancelled before current data changed: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }

        let intent = NativeBackupRestoreIntent(
            transactionID: UUID().uuidString.lowercased(),
            targetID: snapshot.id,
            targetManifestSHA256: snapshot.manifestSHA256,
            safetyBackupID: safetySnapshot.id,
            safetyManifestSHA256: safetySnapshot.manifestSHA256,
            stagedAt: Self.nativeArtifactTimestamp(),
            state: .staged
        )
        do {
            try Self.writeRestoreIntent(intent, to: intentPath)
        } catch {
            throw NSError(domain: "NativeAgentBackup", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Restore intent could not be made durable. Current data was not changed; safety backup \(safetyBackup.id) remains available: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }
        return BackupRestoreResult(
            id: id,
            restored: snapshot.copied,
            restoredAt: intent.stagedAt,
            requiresRestart: true,
            safetyBackupId: safetyBackup.id
        )
    }

    /// Runs before NativeAgentApp/AppModel construction, while no SQLite,
    /// TrustCenter, chat, cognition, or background-loop owner has opened the
    /// data root. A previous crash during target application never resumes the
    /// target over mixed bytes: it first restores the exact safety snapshot.
    public static func resumeStagedBackupRestoreAtLaunch(
        dataRoot root: URL,
        host: TrustBackupHost
    ) throws -> BackupRestoreResult? {
        let intentPath = Self.backupRestoreIntentPath(dataRoot: root)
        guard Self.pathEntryExists(intentPath) else { return nil }

        var intent = try Self.readRestoreIntent(at: intentPath)
        let target = try Self.validateBackupSnapshot(id: intent.targetID, dataRoot: root)
        var safety = try Self.validateBackupSnapshot(
            id: intent.safetyBackupID,
            dataRoot: root,
            requireRestorableAuthority: false
        )
        guard target.manifestSHA256 == intent.targetManifestSHA256,
              safety.manifestSHA256 == intent.safetyManifestSHA256 else {
            throw Self.backupError(
                code: 422,
                "A staged restore backup changed after approval. NativeAgent preserved the intent and refused to start."
            )
        }

        switch intent.state {
        case .staged:
            // Staging leaves runtime owners live until exit. Capture their final
            // writes now, before any owner opens, and bind this exact rollback
            // and effect-fence source before the first destructive copy.
            safety = try Self.createLaunchRestoreSafetySnapshot(dataRoot: root, host: host)
            intent.safetyBackupID = safety.id
            intent.safetyManifestSHA256 = safety.manifestSHA256
            intent.state = .applying
            try Self.writeRestoreIntent(intent, to: intentPath)
            do {
                try Self.applyBackupSnapshotPreservingEffectFences(
                    target: target,
                    safety: safety,
                    destinationRoot: root
                )
            } catch {
                intent.state = .rollingBack
                try Self.writeRestoreIntent(intent, to: intentPath)
                return try Self.rollbackInterruptedRestore(
                    intent: intent,
                    safety: safety,
                    intentPath: intentPath,
                    dataRoot: root,
                    originalError: error
                )
            }

        case .applying, .rollingBack:
            if intent.state == .applying {
                intent.state = .rollingBack
                try Self.writeRestoreIntent(intent, to: intentPath)
            }
            return try Self.rollbackInterruptedRestore(
                intent: intent,
                safety: safety,
                intentPath: intentPath,
                dataRoot: root,
                originalError: Self.backupError(
                    code: 500,
                    "NativeAgent detected an interrupted restore and restored the pre-restore safety snapshot."
                )
            )

        case .completed:
            // A crash after the completed marker but before intent removal is
            // still pre-owner. Reapplying the verified target plus the same
            // monotonic safety overlay is deterministic and idempotent.
            try Self.applyBackupSnapshotPreservingEffectFences(
                target: target,
                safety: safety,
                destinationRoot: root
            )
        }

        intent.state = .completed
        try Self.writeRestoreIntent(intent, to: intentPath)
        let result = BackupRestoreResult(
            id: target.id,
            restored: target.copied,
            restoredAt: Self.nativeArtifactTimestamp(),
            requiresRestart: false,
            safetyBackupId: safety.id
        )
        try Self.writeCodableJSON(result, to: Self.backupRestoreResultPath(dataRoot: root))
        try FileManager.default.removeItem(at: intentPath)
        return result
    }

    private static func rollbackInterruptedRestore(
        intent: NativeBackupRestoreIntent,
        safety: NativeValidatedBackupSnapshot,
        intentPath: URL,
        dataRoot root: URL,
        originalError: Error
    ) throws -> BackupRestoreResult? {
        do {
            let priorGenerations = Self.transcriptGenerations(in: root)
            try Self.applyBackupSnapshot(
                safety,
                destinationRoot: root,
                requireRestorableAuthority: false
            )
            try Self.verifyAppliedSnapshot(safety, destinationRoot: root)
            try Self.rollTranscriptGenerationsForward(
                in: root,
                priorGenerations: priorGenerations
            )
            let receipt: JSONValue = .object([
                "kind": .string("backup_restore_rollback"),
                "transactionId": .string(intent.transactionID),
                "targetId": .string(intent.targetID),
                "safetyBackupId": .string(safety.id),
                "status": .string("rolled_back"),
                "rolledBackAt": .string(Self.nativeArtifactTimestamp()),
            ])
            try Self.writeJSONValue(receipt, to: Self.backupRestoreResultPath(dataRoot: root))
            try FileManager.default.removeItem(at: intentPath)
        } catch {
            // Keep the rollingBack intent byte-for-byte available. The next
            // launch resumes this exact rollback before any state owner opens.
            throw Self.backupError(
                code: 503,
                "Backup restore and its safety rollback could not finish. NativeAgent preserved the rollback intent and refused to start: \(error.localizedDescription)"
            )
        }
        throw Self.backupError(
            code: 500,
            "Backup restore did not complete. The pre-restore safety snapshot was restored before NativeAgent started: \(originalError.localizedDescription)"
        )
    }

    /// Only called at pre-owner launch. SQLite and its WAL are quiescent here;
    /// copying both retains committed frames without opening a runtime store.
    private static func createLaunchRestoreSafetySnapshot(
        dataRoot root: URL,
        host: TrustBackupHost
    ) throws -> NativeValidatedBackupSnapshot {
        let id = UUID().uuidString.lowercased()
        let backupDir = root.appendingPathComponent("backups/\(id)", isDirectory: true)
        let dataDir = backupDir.appendingPathComponent("data", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            var copied: [String] = []
            for relative in Self.backupRelativePaths {
                let source = root.appendingNativeRelativePath(relative)
                guard Self.pathEntryExists(source) else { continue }
                try Self.copyQuiescentRestoreSafetyItem(
                    from: source,
                    to: dataDir.appendingNativeRelativePath(relative)
                )
                copied.append(relative)
            }
            let links = try Self.takeBackupLinks(in: dataDir)
            let files = try Self.backupIntegrityFiles(in: dataDir)
            let manifest: JSONValue = .object([
                "app": .string("NativeAgent"),
                "createdAt": .string(Self.nativeArtifactTimestamp()),
                "id": .string(id),
                "integrityVersion": .int(2),
                "kind": .string("backup"),
                "reason": .string("final pre-owner restore safety snapshot"),
                "scope": .array(Self.scopeNames(for: copied).map { .string($0) }),
                "copied": .array(copied.map { .string($0) }),
                "files": .array(files.map(Self.backupIntegrityFileJSON)),
                "links": .array(links.map(Self.backupLinkJSON)),
                "version": .string(host.applicationVersion()),
            ])
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                manifest.serializedData(pretty: true),
                to: backupDir.appendingPathComponent("manifest.json")
            )
            let snapshot = try Self.validateBackupSnapshot(id: id, dataRoot: root, requireRestorableAuthority: false)
            // Keep the final rollback point selectable in the same Backup UI
            // as the provisional staging backup. No registry writer is live.
            let record = BackupRecord(
                id: id, reason: snapshot.reason, scope: Self.scopeNames(for: copied),
                path: backupDir.path, createdAt: snapshot.createdAt
            )
            let records = [record] + (try Self.readBackupRecords(root: root))
            let catalog = try JSONValue.array(records.prefix(200).map(Self.backupRecordJSON))
                .serializedData(pretty: true)
            for name in ["index.json", "registry.json"] {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(
                    catalog, to: root.appendingPathComponent("backups/\(name)")
                )
            }
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: backupDir)
            throw error
        }
    }

    private static func copyQuiescentRestoreSafetyItem(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            try Self.copyBackupLink(from: source, to: destination)
            return
        }
        if values.isRegularFile == true {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                Data(contentsOf: source, options: [.mappedIfSafe]), to: destination
            )
            return
        }
        guard values.isDirectory == true else {
            throw Self.backupError(code: 422, "Restore safety source contains a non-regular item.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            guard !child.lastPathComponent.hasSuffix(".lock") else { continue }
            try Self.copyQuiescentRestoreSafetyItem(
                from: child, to: destination.appendingPathComponent(child.lastPathComponent)
            )
        }
    }

    private static func backupRestoreIntentPath(dataRoot root: URL) -> URL {
        root.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("restore-intent.json")
    }

    private static func backupRestoreResultPath(dataRoot root: URL) -> URL {
        root.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("last-restore-result.json")
    }

    private static func readRestoreIntent(at path: URL) throws -> NativeBackupRestoreIntent {
        try Self.requireRegularFile(path, maximumBytes: 64 * 1024)
        do {
            return try JSONDecoder.nativeAgent.decode(
                NativeBackupRestoreIntent.self,
                from: Data(contentsOf: path)
            )
        } catch {
            throw Self.backupError(
                code: 422,
                "The staged restore intent is unreadable. Its bytes were preserved and NativeAgent refused to start."
            )
        }
    }

    private static func writeRestoreIntent(
        _ intent: NativeBackupRestoreIntent,
        to path: URL
    ) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(intent), to: path)
    }

    private static func validateBackupSnapshot(
        id rawID: String,
        dataRoot root: URL,
        requireRestorableAuthority: Bool = true
    ) throws -> NativeValidatedBackupSnapshot {
        guard let uuid = UUID(uuidString: rawID) else {
            throw Self.backupError(code: 422, "Backup id is not a UUID.")
        }
        let id = uuid.uuidString.lowercased()
        guard rawID.lowercased() == id else {
            throw Self.backupError(code: 422, "Backup id is not canonical.")
        }

        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let backupDir = backupRoot.appendingPathComponent(id, isDirectory: true)
        let dataDir = backupDir.appendingPathComponent("data", isDirectory: true)
        let manifestPath = backupDir.appendingPathComponent("manifest.json")
        try Self.requireRegularDirectory(backupRoot)
        try Self.requireRegularDirectory(backupDir)
        try Self.requireRegularDirectory(dataDir)
        try Self.requireRegularFile(manifestPath, maximumBytes: 16 * 1024 * 1024)

        let manifestData = try Data(contentsOf: manifestPath, options: [.mappedIfSafe])
        let manifest = try JSONValue.parse(manifestData)
        guard case .object(let object) = manifest,
              object["app"] == .string("NativeAgent"),
              object["kind"] == .string("backup"),
              object["id"] == .string(id),
              object["integrityVersion"] == .int(2),
              case .string(let reason)? = object["reason"],
              case .string(let createdAt)? = object["createdAt"],
              case .array(let copiedValues)? = object["copied"],
              case .array(let fileValues)? = object["files"] else {
            throw Self.backupError(
                code: 422,
                "Backup manifest is missing its v2 identity or integrity contract. Older unsealed backups are not safe to restore."
            )
        }
        guard reason.utf8.count <= 1_000, createdAt.utf8.count <= 128 else {
            throw Self.backupError(code: 422, "Backup manifest metadata exceeds its bound.")
        }

        // Older manifests have no `links`: they recorded none.
        var linkValues: [JSONValue] = []
        if let value = object["links"] {
            guard case .array(let values) = value, values.count <= 10_000 else {
                throw Self.backupError(code: 422, "Backup manifest has an invalid link list.")
            }
            linkValues = values
        }
        var links: [NativeBackupLink] = []
        for value in linkValues {
            guard case .object(let link) = value,
                  case .string(let path)? = link["path"],
                  case .string(let target)? = link["target"],
                  Self.isValidBackupFilePath(path),
                  !target.isEmpty, target.utf8.count <= 4_096,
                  // Case-folded: on a case-insensitive volume `A` and `a/b`
                  // overlap, and recreating one would write through the other.
                  !links.contains(where: {
                      let (a, b) = ($0.path.lowercased(), path.lowercased())
                      return a == b || b.hasPrefix(a + "/") || a.hasPrefix(b + "/")
                  }) else {
                throw Self.backupError(code: 422, "Backup manifest has an invalid or overlapping link.")
            }
            links.append(NativeBackupLink(path: path, target: target))
        }

        let allowed = Set(Self.backupRelativePaths)
        var copied: [String] = []
        var copiedSet: Set<String> = []
        for value in copiedValues {
            guard case .string(let path) = value,
                  allowed.contains(path),
                  copiedSet.insert(path).inserted else {
                throw Self.backupError(code: 422, "Backup manifest has an invalid or duplicate scope member.")
            }
            let copiedSource = dataDir.appendingNativeRelativePath(path)
            guard Self.pathEntryExists(copiedSource) else {
                throw Self.backupError(code: 422, "Backup manifest names a scope member that is absent: \(path)")
            }
            let scopeValues = try copiedSource.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard scopeValues.isSymbolicLink != true,
                  scopeValues.isDirectory == true || scopeValues.isRegularFile == true else {
                throw Self.backupError(code: 422, "Backup manifest names a non-regular scope member: \(path)")
            }
            copied.append(path)
        }
        // Links live only below `memory/` (`memory/agent/notes.jsonl` points
        // into the persona root): restore's effect-fence overlays and
        // authority checks never touch Memory, so none reads or writes
        // through a recreated link.
        for link in links {
            guard link.path.hasPrefix("memory/"), copied.contains("memory"),
                  !Self.pathEntryExists(dataDir.appendingNativeRelativePath(link.path)),
                  Self.isBackupLinkTargetInside(link, dataRoot: root) else {
                throw Self.backupError(
                    code: 422,
                    "Backup link must sit under memory/ and point inside the data or persona root: \(link.path) -> \(link.target)"
                )
            }
        }

        guard fileValues.count <= 100_000 else {
            throw Self.backupError(code: 422, "Backup manifest contains too many files.")
        }
        var files: [NativeBackupIntegrityFile] = []
        var filePaths: Set<String> = []
        for value in fileValues {
            guard case .object(let file) = value,
                  case .string(let path)? = file["path"],
                  case .int(let sizeBytes)? = file["sizeBytes"],
                  case .string(let sha256)? = file["sha256"],
                  sizeBytes >= 0,
                  Self.isValidBackupFilePath(path),
                  Self.isValidSHA256(sha256),
                  copied.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  filePaths.insert(path).inserted else {
                throw Self.backupError(code: 422, "Backup manifest has an invalid file member.")
            }
            files.append(NativeBackupIntegrityFile(
                path: path,
                sizeBytes: sizeBytes,
                sha256: sha256
            ))
        }

        let actualFiles = try Self.backupIntegrityFiles(in: dataDir)
        guard actualFiles == files.sorted(by: { $0.path < $1.path }) else {
            throw Self.backupError(
                code: 422,
                "Backup file membership or SHA-256 integrity does not match its manifest."
            )
        }

        if requireRestorableAuthority {
            try Self.validateBackupChatSessionIndex(dataDir: dataDir)
            try Self.validateBackupTrustPolicy(dataDir: dataDir)
            try Self.validateBackupCapabilityAuthority(dataDir: dataDir)
        }
        return NativeValidatedBackupSnapshot(
            id: id,
            dataDirectory: dataDir,
            copied: copied,
            files: actualFiles,
            links: links,
            reason: reason,
            createdAt: createdAt,
            manifestSHA256: Self.sha256Hex(manifestData)
        )
    }

    /// Existing Swift backups predate file digests. On an explicit restore,
    /// migrate only the exact old NativeAgent manifest shape at its canonical
    /// UUID directory. The source is fully enumerated, symlink-free, bounded,
    /// authority-validated, and sealed before the restart intent can refer to
    /// it. A v2 manifest that fails validation is never resealed over tampering.
    private static func sealLegacyV1BackupForRestore(
        id rawID: String,
        dataRoot root: URL
    ) throws -> Bool {
        guard let uuid = UUID(uuidString: rawID) else { return false }
        let id = uuid.uuidString.lowercased()
        guard rawID.lowercased() == id else { return false }
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let backupDir = backupRoot.appendingPathComponent(id, isDirectory: true)
        let dataDir = backupDir.appendingPathComponent("data", isDirectory: true)
        let manifestPath = backupDir.appendingPathComponent("manifest.json")
        try Self.requireRegularDirectory(backupRoot)
        try Self.requireRegularDirectory(backupDir)
        try Self.requireRegularDirectory(dataDir)
        try Self.requireRegularFile(manifestPath, maximumBytes: 16 * 1024 * 1024)
        let legacyData = try Data(contentsOf: manifestPath, options: [.mappedIfSafe])
        let legacy = try JSONValue.parse(legacyData)
        guard case .object(let object) = legacy,
              object["app"] == .string("NativeAgent"),
              object["kind"] == .string("backup"),
              object["id"] == .string(id),
              object["integrityVersion"] == nil,
              case .string(let createdAt)? = object["createdAt"],
              case .array(let copiedValues)? = object["copied"] else {
            return false
        }
        guard createdAt.utf8.count <= 128 else { return false }

        let allowed = Set(Self.backupRelativePaths)
        var copied: [String] = []
        var copiedSet: Set<String> = []
        for value in copiedValues {
            guard case .string(let path) = value,
                  allowed.contains(path),
                  copiedSet.insert(path).inserted else { return false }
            let source = dataDir.appendingNativeRelativePath(path)
            guard Self.pathEntryExists(source) else { return false }
            let values = try source.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                return false
            }
            copied.append(path)
        }
        let files = try Self.backupIntegrityFiles(in: dataDir)
        guard files.allSatisfy({ file in
            copied.contains(where: { file.path == $0 || file.path.hasPrefix($0 + "/") })
        }) else { return false }
        try Self.validateBackupChatSessionIndex(dataDir: dataDir)
        try Self.validateBackupTrustPolicy(dataDir: dataDir)
        try Self.validateBackupCapabilityAuthority(dataDir: dataDir)

        let record = try Self.readBackupRecords(root: root).first { $0.id == id }
        let reasonCandidate = record?.reason.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = reasonCandidate.isEmpty
            ? "legacy NativeAgent backup"
            : String(reasonCandidate.prefix(1_000))
        let scope = Self.scopeNames(for: copied)
        let sealed: JSONValue = .object([
            "app": .string("NativeAgent"),
            "createdAt": .string(createdAt),
            "id": .string(id),
            "integrityVersion": .int(2),
            "kind": .string("backup"),
            "reason": .string(reason),
            "scope": .array(scope.map { .string($0) }),
            "copied": .array(copied.map { .string($0) }),
            "files": .array(files.map(Self.backupIntegrityFileJSON)),
            "version": object["version"] ?? .string("legacy"),
        ])
        let preserved = backupDir.appendingPathComponent("manifest.v1.json")
        if Self.pathEntryExists(preserved) {
            try Self.requireRegularFile(preserved, maximumBytes: 16 * 1024 * 1024)
            guard try Data(contentsOf: preserved) == legacyData else { return false }
        } else {
            try legacyData.write(to: preserved, options: [.atomic])
        }
        try Self.writeJSONValue(sealed, to: manifestPath)
        return true
    }

    private static func applyBackupSnapshot(
        _ snapshot: NativeValidatedBackupSnapshot,
        destinationRoot: URL,
        requireRestorableAuthority: Bool
    ) throws {
        _ = try Self.validateBackupSnapshot(
            id: snapshot.id,
            dataRoot: destinationRoot,
            requireRestorableAuthority: requireRestorableAuthority
        )
        let fm = FileManager.default
        for rel in Self.backupRelativePaths {
            let source = snapshot.dataDirectory.appendingNativeRelativePath(rel)
            let destination = destinationRoot.appendingNativeRelativePath(rel)
            if Self.pathEntryExists(destination) {
                try fm.removeItem(at: destination)
            }
            if Self.pathEntryExists(source) {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: source, to: destination)
            }
            // The scope was just replaced by real directories, so a recreated
            // link never lands on (or writes through) an existing entry.
            for link in snapshot.links where link.path == rel || link.path.hasPrefix(rel + "/") {
                let path = destinationRoot.appendingNativeRelativePath(link.path)
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: path.path, withDestinationPath: link.target)
            }
        }
    }

    private static func applyBackupSnapshotPreservingEffectFences(
        target: NativeValidatedBackupSnapshot,
        safety: NativeValidatedBackupSnapshot,
        destinationRoot: URL
    ) throws {
        // 2026-09-06: read BEFORE the copy overwrites the live index — see
        // `rollTranscriptGenerationsForward`.
        let priorGenerations = Self.transcriptGenerations(in: destinationRoot)
        try Self.applyBackupSnapshot(
            target,
            destinationRoot: destinationRoot,
            requireRestorableAuthority: true
        )
        // Prove the selected backup exactly before overlaying facts that are
        // intentionally newer than it.
        try Self.verifyAppliedSnapshot(target, destinationRoot: destinationRoot)
        try Self.rollTranscriptGenerationsForward(
            in: destinationRoot,
            priorGenerations: priorGenerations
        )
        try SwiftNativeApprovalInbox.mergeRestoreFences(
            safetyRoot: safety.dataDirectory,
            destinationRoot: destinationRoot
        )
        try Self.preserveSchedulerOccurrenceState(
            safetyRoot: safety.dataDirectory,
            destinationRoot: destinationRoot
        )
        try Self.preserveExternalSendReceipts(
            safetyRoot: safety.dataDirectory,
            destinationRoot: destinationRoot
        )
        // The merge changes only authority outcomes/fences; validate selected
        // restorable authority again after those monotonic overlays land.
        try Self.validateBackupChatSessionIndex(dataDir: destinationRoot)
        try Self.validateBackupTrustPolicy(dataDir: destinationRoot)
        try Self.validateBackupCapabilityAuthority(dataDir: destinationRoot)
    }

    /// Scheduler currently keeps configuration and occurrence claims in one
    /// checked file. Until that owner splits them, preserving the entire newer
    /// safety generation is the only restore that cannot resurrect an already
    /// claimed occurrence. This intentionally favors no duplicate effects over
    /// restoring older schedule configuration.
    private static func preserveSchedulerOccurrenceState(
        safetyRoot: URL,
        destinationRoot: URL
    ) throws {
        let source = safetyRoot.appendingNativeRelativePath("scheduler/jobs.json")
        guard Self.pathEntryExists(source) else { return }
        try Self.requireRegularFile(source, maximumBytes: 64 * 1024 * 1024)
        let raw = try JSONValue.parse(Data(contentsOf: source))
        guard case .array(let rows) = raw,
              rows.allSatisfy({ if case .object = $0 { return true }; return false }) else {
            throw Self.backupError(
                code: 422,
                "The pre-restore scheduler generation is malformed; current bytes were preserved and restore was rolled back."
            )
        }
        try Self.writeJSONValue(
            raw,
            to: destinationRoot.appendingNativeRelativePath("scheduler/jobs.json")
        )
    }

    private static func preserveExternalSendReceipts(
        safetyRoot: URL,
        destinationRoot: URL
    ) throws {
        let sourceDirectory = safetyRoot.appendingNativeRelativePath(
            "connectors/actions/external_send_receipts"
        )
        guard Self.pathEntryExists(sourceDirectory) else { return }
        try Self.requireRegularDirectory(sourceDirectory)
        let destinationDirectory = destinationRoot.appendingNativeRelativePath(
            "connectors/actions/external_send_receipts"
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true
        )
        guard let members = try? FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw Self.backupError(code: 422, "External-send receipt fences could not be enumerated.")
        }
        for source in members {
            if source.lastPathComponent.hasSuffix(".lock") { continue }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  source.pathExtension == "json",
                  let approvalID = UUID(uuidString: source.deletingPathExtension().lastPathComponent)?
                    .uuidString.lowercased(),
                  approvalID == source.deletingPathExtension().lastPathComponent.lowercased() else {
                throw Self.backupError(code: 422, "External-send receipt fence has an invalid member.")
            }
            let bytes = try Data(contentsOf: source)
            let value = try JSONValue.parse(bytes)
            guard case .object(let object) = value,
                  object["kind"] == .string("external_send_execution"),
                  object["approvalId"] == .string(approvalID),
                  case .string(let idempotency)? = object["idempotencyKey"], !idempotency.isEmpty,
                  case .string(let connector)? = object["connectorId"], !connector.isEmpty,
                  case .string(let action)? = object["actionId"], !action.isEmpty,
                  case .string(let status)? = object["status"], !status.isEmpty,
                  case .bool(_)? = object["didDispatch"] else {
                throw Self.backupError(
                    code: 422,
                    "A current external-send receipt is malformed; its bytes were preserved and restore was rolled back."
                )
            }
            try bytes.write(
                to: destinationDirectory.appendingPathComponent("\(approvalID).json"),
                options: .atomic
            )
        }
    }

    /// The transcript version each session's index row carries right now.
    private static func transcriptGenerations(in root: URL) -> [String: Int64] {
        let path = Self.chatSessionIndexPath(in: root)
        guard let rows = try? ChatSessionIndexFile.loadObjectRowsForMutation(at: path) else {
            return [:]
        }
        var out: [String: Int64] = [:]
        for row in rows {
            guard case .string(let id)? = row["id"],
                  let generation = ChatSessionIndexFile.transcriptGeneration(in: row) else { continue }
            out[id] = generation
        }
        return out
    }

    /// 2026-09-06: a restore copies `chat/sessions.json` back wholesale, which
    /// rolls every session's transcript version BACKWARD to whatever it was
    /// when the backup was taken. The phone keeps its own watermark across the
    /// restore, so every restored transcript then looked older than the copy it
    /// already held and was refused — the two surfaces disagreed about the
    /// conversation permanently.
    ///
    /// Each restored row's version is therefore raised to
    /// `max(restored, previous + 1)`: strictly newer than anything this Mac
    /// published before the restore, and never lowered. Runs AFTER
    /// `verifyAppliedSnapshot` — the snapshot is proven byte-exact first, and
    /// this is one of the facts deliberately overlaid on top of it.
    ///
    /// 2026-09-06: NOT best effort. A restore whose index could not be
    /// re-stamped leaves the phone refusing every restored transcript as older
    /// than the copy it holds, and reporting that restore as a success hides
    /// exactly that. A failed raise now fails the restore step (and the
    /// rollback path), which preserves the intent for the next launch.
    ///
    /// 2026-09-06: the floor is the restore EPOCH, not the per-session prior
    /// alone. A session absent from the pre-restore index — one the backup has
    /// and this Mac had already deleted, or one published from another surface
    /// — had no prior, was skipped outright, and came back carrying the
    /// backup's old counter. The epoch is a monotonic counter persisted OUTSIDE
    /// the index (a restore overwrites the index wholesale), raised past every
    /// generation the pre-restore index carried and bumped once per restore, so
    /// every restored row lands strictly above anything this Mac published
    /// before the restore.
    private static func rollTranscriptGenerationsForward(
        in root: URL,
        priorGenerations: [String: Int64]
    ) throws {
        let path = Self.chatSessionIndexPath(in: root)
        let epoch = try Self.bumpTranscriptRestoreEpoch(
            in: root,
            atLeast: priorGenerations.values.max() ?? 0
        )
        var rows: [[String: JSONValue]]
        do {
            rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
        } catch {
            throw Self.backupError(
                code: 500,
                "The restored session index could not be read to raise its transcript versions: \(error.localizedDescription)"
            )
        }
        var changed = false
        for index in rows.indices {
            guard case .string(let id)? = rows[index]["id"] else { continue }
            let floor = max(priorGenerations[id] ?? 0, epoch)
            guard floor < Int64.max else { continue }
            let restored = ChatSessionIndexFile.transcriptGeneration(in: rows[index]) ?? 0
            let forward = max(restored, floor + 1)
            guard forward != restored else { continue }
            rows[index][ChatSessionIndexFile.transcriptGenerationKey] = .int(forward)
            changed = true
        }
        guard changed else { return }
        do {
            let data = try ChatSessionIndexFile.serializedData(for: rows)
            try data.write(to: path, options: [.atomic])
        } catch {
            throw Self.backupError(
                code: 500,
                "The restored session index could not be re-stamped with newer transcript versions: \(error.localizedDescription)"
            )
        }
    }

    /// `<root>/chat/transcript_restore_epoch.json` — deliberately NOT one of
    /// `backupRelativePaths`, so a restore cannot roll it backward with the
    /// rest of `chat/`. Holds one integer: a floor every restored transcript
    /// version must clear.
    private static func transcriptRestoreEpochPath(in root: URL) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("transcript_restore_epoch.json")
    }

    /// Raise the epoch past `floor` and past its own last value, persist it,
    /// and return it. Throws if it cannot be persisted — an epoch that is not
    /// on disk would be handed out twice.
    private static func bumpTranscriptRestoreEpoch(
        in root: URL,
        atLeast floor: Int64
    ) throws -> Int64 {
        let path = Self.transcriptRestoreEpochPath(in: root)
        var stored: Int64 = 0
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONValue.parse(data),
           case .object(let object) = parsed,
           case .int(let value)? = object["epoch"] {
            stored = value
        }
        let raised = max(stored, floor)
        guard raised < Int64.max else { return raised }
        let next = raised + 1
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONValue.object(["epoch": .int(next)]).serialize(pretty: false)
            try Data(data.utf8).write(to: path, options: [.atomic])
        } catch {
            throw Self.backupError(
                code: 500,
                "The transcript restore epoch could not be recorded, so the restored transcripts could not be raised above what the phone already holds: \(error.localizedDescription)"
            )
        }
        return next
    }

    private static func chatSessionIndexPath(in root: URL) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private static func verifyAppliedSnapshot(
        _ snapshot: NativeValidatedBackupSnapshot,
        destinationRoot: URL
    ) throws {
        for rel in Self.backupRelativePaths where !snapshot.copied.contains(rel) {
            let destination = destinationRoot.appendingNativeRelativePath(rel)
            guard !Self.pathEntryExists(destination) else {
                throw Self.backupError(code: 500, "Restored scope contains an item absent from the selected snapshot: \(rel)")
            }
        }
        for file in snapshot.files {
            let destination = destinationRoot.appendingNativeRelativePath(file.path)
            try Self.requireRegularFile(destination, maximumBytes: nil)
            let measured = try Self.fileDigest(destination)
            guard measured.sizeBytes == file.sizeBytes,
                  measured.sha256 == file.sha256 else {
                throw Self.backupError(code: 500, "Restored file failed SHA-256 verification: \(file.path)")
            }
        }
        for link in snapshot.links {
            let path = destinationRoot.appendingNativeRelativePath(link.path)
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == link.target else {
                throw Self.backupError(code: 500, "Restored link failed verification: \(link.path)")
            }
        }
    }

    private static func backupIntegrityFiles(in root: URL) throws -> [NativeBackupIntegrityFile] {
        try Self.requireRegularDirectory(root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw Self.backupError(code: 422, "Backup contents could not be enumerated.")
        }
        var files: [NativeBackupIntegrityFile] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw Self.backupError(code: 422, "Backup contains a symbolic link: \(item.lastPathComponent)")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw Self.backupError(code: 422, "Backup contains a non-regular file: \(item.lastPathComponent)")
            }
            let rootPath = root.standardizedFileURL.path
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else {
                throw Self.backupError(code: 422, "Backup member escapes its data directory.")
            }
            let relative = String(itemPath.dropFirst(rootPath.count + 1))
            guard Self.isValidBackupFilePath(relative) else {
                throw Self.backupError(code: 422, "Backup contains an invalid relative path.")
            }
            let digest = try Self.fileDigest(item)
            files.append(NativeBackupIntegrityFile(
                path: relative,
                sizeBytes: digest.sizeBytes,
                sha256: digest.sha256
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func fileDigest(_ path: URL) throws -> (sizeBytes: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            size += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func backupIntegrityFileJSON(_ file: NativeBackupIntegrityFile) -> JSONValue {
        .object([
            "path": .string(file.path),
            "sizeBytes": .int(file.sizeBytes),
            "sha256": .string(file.sha256),
        ])
    }

    private static func backupLinkJSON(_ link: NativeBackupLink) -> JSONValue {
        .object(["path": .string(link.path), "target": .string(link.target)])
    }

    /// Copies a link as a link (its raw target, never its bytes);
    /// `takeBackupLinks` then moves it from `data/` into the manifest.
    private static func copyBackupLink(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: fm.destinationOfSymbolicLink(atPath: source.path)
        )
    }

    /// Removes every link copied into a backup's `data/` and returns
    /// them for the manifest, so the sealed bytes stay regular files only.
    private static func takeBackupLinks(in dataDir: URL) throws -> [NativeBackupLink] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dataDir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, _ in false }
        ) else {
            throw Self.backupError(code: 422, "Backup contents could not be enumerated.")
        }
        let rootPath = dataDir.standardizedFileURL.path
        var links: [NativeBackupLink] = []
        for case let item as URL in enumerator
        where try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else {
                throw Self.backupError(code: 422, "Backup link escapes its data directory.")
            }
            links.append(NativeBackupLink(
                path: String(itemPath.dropFirst(rootPath.count + 1)),
                target: try fm.destinationOfSymbolicLink(atPath: item.path)
            ))
        }
        for link in links {
            try fm.removeItem(atPath: rootPath + "/" + link.path)
        }
        return links.sorted { $0.path < $1.path }
    }

    /// A recorded link, resolved from where it lives in the data root, must
    /// land inside the data root or the live persona root.
    private static func isBackupLinkTargetInside(_ link: NativeBackupLink, dataRoot root: URL) -> Bool {
        let base = root.appendingNativeRelativePath(link.path).deletingLastPathComponent()
        let target = link.target.hasPrefix("/")
            ? URL(fileURLWithPath: link.target)
            : base.appendingPathComponent(link.target)
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
        return [root, PersistenceCore.defaultPersonaRoot(dataRoot: root)].contains {
            let allowed = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved == allowed || resolved.hasPrefix(allowed + "/")
        }
    }

    private static func requireRegularDirectory(_ path: URL) throws {
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw Self.backupError(code: 422, "Backup path is not a regular directory: \(path.lastPathComponent)")
        }
    }

    private static func pathEntryExists(_ path: URL) -> Bool {
        var info = stat()
        return lstat(path.path, &info) == 0
    }

    private static func requireRegularFile(_ path: URL, maximumBytes: Int?) throws {
        let values = try path.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw Self.backupError(code: 422, "Backup path is not a regular file: \(path.lastPathComponent)")
        }
        if let maximumBytes {
            guard let size = values.fileSize, size >= 0, size <= maximumBytes else {
                throw Self.backupError(code: 422, "Backup file exceeds its size bound: \(path.lastPathComponent)")
            }
        }
    }

    private static func isValidBackupFilePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              path.utf8.count <= 4_096 else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func backupError(code: Int, _ description: String) -> NSError {
        NSError(domain: "NativeAgentBackup", code: code, userInfo: [
            NSLocalizedDescriptionKey: description,
        ])
    }

    private static let backupRelativePaths: [String] = [
        "trust",
        "memory",
        "workshop",
        "chat/sessions.json",
        "chat/messages",
        "chat/session_state",
        "skills",
        "tools",
        "connectors",
        "scheduler/jobs.json",
        "improvements",
        "workflows",
        "catalog/registry.json",
        "catalog/sources/sources.json",
        "catalog/trust/roots.json",
        "capabilities",
        "graphs",
        "persona",
        "mcp/servers.json",
        "mcp/consent/ledger.json",
        "routing",
        "telegram",
        "dream_diary",
    ]

    public static func nativeArtifactTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    public static func copySelectedDataPaths(
        root: URL,
        destinationRoot: URL,
        relativePaths: [String]
    ) throws -> [String] {
        var copied: [String] = []
        for rel in relativePaths {
            let source = root.appendingNativeRelativePath(rel)
            let destination = destinationRoot.appendingNativeRelativePath(rel)
            if try copyExistingItem(from: source, to: destination) {
                copied.append(rel)
            }
        }
        return copied
    }

    public static func copyExistingItem(from source: URL, to destination: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return false }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        return true
    }

    /// Copy one mutable file tree while holding the same per-file lock its
    /// writers use. Lock sidecars are synchronization machinery, not state, and
    /// are never restored. Memory's canonical SQLite database is created by its
    /// online-backup owner instead of copying a live DB/WAL tuple. A link is
    /// kept as a link for the manifest (`takeBackupLinks`).
    private static func copyLockedSnapshotItem(
        from source: URL,
        to destination: URL,
        excludingSQLiteArtifacts: Bool
    ) async throws {
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        if values.isSymbolicLink == true {
            try Self.copyBackupLink(from: source, to: destination)
            return
        }
        if values.isRegularFile == true {
            try await Self.copyLockedSnapshotFile(from: source, to: destination)
            return
        }
        guard values.isDirectory == true else {
            throw Self.backupError(code: 422, "Backup source contains a non-regular item: \(source.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let name = child.lastPathComponent
            if name.hasSuffix(".lock") { continue }
            if excludingSQLiteArtifacts,
               name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal") || name.hasSuffix(".sqlite-shm") {
                continue
            }
            try await Self.copyLockedSnapshotItem(
                from: child,
                to: destination.appendingPathComponent(name),
                excludingSQLiteArtifacts: excludingSQLiteArtifacts
            )
        }
    }

    /// Secrets an off-disk backup never carries, wherever they sit: anything
    /// named for a token, secret, credential or signing key; connector
    /// `auth.json` and OAuth app secrets; private keys (`.p8`, `.pem`, `.key`,
    /// `.p12`, `.pfx`, SSH `id_*`);
    /// and the config files that embed a token or key — app config (Telegram
    /// token, X app secrets), Telegram config, MCP server commands, and the
    /// Mac-control / browser IPC bridge files. Whole credential stores are in
    /// `offDiskExcludedPaths`.
    private static func isCredentialFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["auth.json", "oauth_app.json", "macctl_bridge.json", "browser_ipc.json"].contains(name)
            || ["token", "secret", "credential", "signing_key"].contains { name.contains($0) }
            || ["p8", "pem", "key", "p12", "pfx"].contains(url.pathExtension.lowercased())
            || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains { name.hasPrefix($0) }
            || ["/config/config.json", "/telegram/config.json", "/mcp/servers.json", "/agents/peers.json"]
                .contains { url.path.hasSuffix($0) }
    }

    private static func copyLockedSnapshotFile(
        from source: URL,
        to destination: URL,
        locking: Bool = true
    ) async throws {
        let persistence = SwiftNativePersistenceCore()
        guard locking else {
            try await persistence.writeDataAtomicDurable(
                Data(contentsOf: source, options: [.mappedIfSafe]), to: destination
            )
            return
        }
        try await persistence.withFileLock(source) {
            let values = try source.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw Self.backupError(
                    code: 422,
                    "Backup source changed type while being copied: \(source.lastPathComponent)"
                )
            }
            let bytes = try Data(contentsOf: source, options: [.mappedIfSafe])
            try await persistence.writeDataAtomicDurable(bytes, to: destination)
        }
    }

    public static func scopeNames(for relativePaths: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for rel in relativePaths {
            guard let first = rel.split(separator: "/", maxSplits: 1).first else { continue }
            let scope = String(first)
            if seen.insert(scope).inserted {
                out.append(scope)
            }
        }
        return out
    }

    public static func writeCodableJSON<T: Encodable>(_ value: T, to path: URL) throws {
        let json = try JSONValue.fromEncodable(value)
        try writeJSONValue(json, to: path)
    }

    public static func writeJSONValue(_ value: JSONValue, to path: URL) throws {
        let data = try value.serializedData(pretty: true)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    private static func appendBackupRecord(_ record: BackupRecord, backupRoot: URL) async throws {
        let row = Self.backupRecordJSON(record)
        // Keep the two legacy registry projections until a release migration
        // can prove every installed shape has been imported. Restore identity
        // never trusts either path; it derives the UUID directory beneath the
        // validated backup root, so retaining compatibility adds no authority.
        // Snapshot directories have no automatic retention policy. Their
        // discoverability must not expire independently of their bytes.
        try await appendRegistryRow(row, path: backupRoot.appendingPathComponent("registry.json"), id: record.id, maxRows: nil)
        try await appendRegistryRow(row, path: backupRoot.appendingPathComponent("index.json"), id: record.id, maxRows: nil)
    }

    public static func appendRegistryRow(_ row: JSONValue, path: URL, id: String, maxRows: Int? = 200) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            // 2026-09-06: only absence bootstraps a registry. Preserve unreadable
            // or malformed existing bytes instead of replacing backup discovery.
            let existing: [JSONValue]
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw NSError(domain: "NativeAgentBackup", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Registry must be a regular file."
                    ])
                }
                let raw = try JSONValue.parse(Data(contentsOf: path))
                guard case .array(let rows) = raw else {
                    throw NSError(domain: "NativeAgentBackup", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Registry must contain an array."
                    ])
                }
                existing = rows
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                existing = []
            }
            var rows = existing.filter { Self.jsonObjectString($0, key: "id") != id }
            rows.append(row)
            if let maxRows, rows.count > maxRows {
                rows = Array(rows.suffix(maxRows))
            }
            try await persistence.writeJSON(.array(rows), to: path)
        }
    }

    public static func readBackupRecords(root: URL) throws -> [BackupRecord] {
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let paths = [
            backupRoot.appendingPathComponent("index.json"),
            backupRoot.appendingPathComponent("registry.json"),
        ]
        var byId: [String: BackupRecord] = [:]
        let fm = FileManager.default
        for path in paths {
            for record in try readBackupRecordsFile(path) {
                var normalized = record
                let localBackupDir = backupRoot.appendingPathComponent(record.id, isDirectory: true)
                if !fm.fileExists(atPath: record.path), fm.fileExists(atPath: localBackupDir.path) {
                    normalized.path = localBackupDir.path
                }
                byId[normalized.id] = normalized
            }
        }
        return byId.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    private static func readBackupRecordsFile(_ path: URL) throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let data = try? Data(contentsOf: path) else { return [] }
        let decoder = JSONDecoder.nativeAgent
        if let arr = try? decoder.decode([BackupRecord].self, from: data) {
            return arr
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let backups = obj["backups"],
           let backupsData = try? JSONSerialization.data(withJSONObject: backups),
           let arr = try? decoder.decode([BackupRecord].self, from: backupsData) {
            return arr
        }
        return []
    }

    private static func validateBackupChatSessionIndex(dataDir: URL) throws {
        let source = dataDir.appendingNativeRelativePath("chat/sessions.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        _ = try ChatSessionIndexFile.loadObjectRowsForMutation(at: source)
    }

    private static func validateBackupTrustPolicy(dataDir: URL) throws {
        let source = dataDir.appendingNativeRelativePath("trust/policy.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        // Fold before validation for the same reason as loadTrustPolicyChecked:
        // a future-spelled block must face the same nested type checks.
        let policy = WorkshopPolicyBlockVocabulary.foldToWireKey(
            try SwiftNativeTrustCenter.loadRawPolicyChecked(at: source))
        let defaults = SwiftNativeTrustCenter(dataRoot: dataDir).defaultTrustPolicy()
        try SwiftNativeTrustCenter.validateKnownAuthorityPolicyTypes(
            policy,
            against: defaults
        )
    }

    private static func validateBackupCapabilityAuthority(dataDir: URL) throws {
        guard FileManager.default.fileExists(atPath: dataDir.path) else { return }
        let sources = dataDir.appendingNativeRelativePath("catalog/sources/sources.json")
        let roots = dataDir.appendingNativeRelativePath("catalog/trust/roots.json")
        _ = try CapabilityCatalogStoreReader.loadCatalogSourcesChecked(at: sources)
        _ = try CapabilityCatalogStoreReader.loadCapabilityTrustRootsChecked(at: roots)
    }

    private static func backupRecordJSON(_ record: BackupRecord) -> JSONValue {
        .object([
            "id": .string(record.id),
            "reason": .string(record.reason),
            "scope": .array(record.scope.map { .string($0) }),
            "path": .string(record.path),
            "createdAt": .string(record.createdAt),
        ])
    }

    public static func jsonObjectString(_ value: JSONValue, key: String) -> String? {
        guard case .object(let obj) = value, case .string(let string)? = obj[key] else {
            return nil
        }
        return string
    }
}

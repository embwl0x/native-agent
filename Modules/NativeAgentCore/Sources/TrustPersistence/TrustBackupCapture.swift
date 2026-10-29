import Foundation
import GRDB
import NativeAgentShared
import PersistenceCore
import TrustCenter
import MemoryV2
import Privacy
import SystemOps
// Blueprint: | `TrustBackupCapture.swift` | TrustBackupPersistence capture and export copying; ordered scopes, writer locks, credential exclusions and read-only SQLite copies |

public enum TrustBackupPersistence {
    public static func createBackup(reason: String, dataRoot root: URL) async throws -> BackupRecord {
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
                offDisk: false
            ).scope
            let record = BackupRecord(
                id: id,
                reason: resolvedReason,
                scope: scope,
                path: backupDir.path,
                createdAt: now
            )
            // A backup is also the byte-preserving recovery path for damaged authority state. Creation proves containment and
            // integrity; only a selected restore target must additionally prove that its authority payload is safe to install.
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

    /// Writes `<backupDir>/data` and its sealed `manifest.json`. `offDisk` is the copy that leaves this Mac: the whole data
    /// root minus `offDiskExcludedPaths` and credentials, plus the live persona root (the repo's `persona/`) as `persona`, with
    /// every SQLite copy out of WAL mode so it opens where it lands. The local scope is `backupRelativePaths`.
    static func writeBackupSnapshot(
        id: String,
        reason: String,
        createdAt: String,
        dataRoot root: URL,
        into backupDir: URL,
        offDisk: Bool
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
                copied += try await Self.copyOffDiskEntry(child, relative: child.lastPathComponent, into: dataDir, dataRoot: root)
            }
        } else {
            let ordinaryPaths = Self.backupRelativePaths.filter {
                $0 != "memory" && !$0.hasPrefix("chat/")
            }
            for relative in ordinaryPaths {
                let source = root.appendingNativeRelativePath(relative)
                guard Self.pathEntryExists(source) else { continue }
                try await Self.copyLocalSnapshotItem(
                    from: source,
                    to: dataDir.appendingNativeRelativePath(relative),
                    relative: relative
                )
                copied.append(relative)
            }
            let memorySource = root.appendingNativeRelativePath("memory")
            if Self.pathEntryExists(memorySource) {
                // A linked Memory root would aim the SQLite backup below through it.
                try Self.requireRegularDirectory(memorySource)
                try await Self.copyLockedSnapshotItem(
                    from: memorySource,
                    to: dataDir.appendingNativeRelativePath("memory")
                )
                copied.append("memory")
            }
            // Retention publishes archive bytes and locators under the session index lock.
            copied += try await SwiftNativePersistenceCore.withFileLock(Self.chatSessionIndexPath(in: root)) {
                var paths: [String] = []
                for relative in Self.backupRelativePaths.filter({ $0.hasPrefix("chat/") }) {
                    let source = root.appendingNativeRelativePath(relative)
                    guard Self.pathEntryExists(source) else { continue }
                    try await Self.copyLockedSnapshotItem(
                        from: source,
                        to: dataDir.appendingNativeRelativePath(relative)
                    )
                    paths.append(relative)
                }
                return paths
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
            "scopeVersion": .int(2),
            "lifeID": .string(try DataRootLife.current(in: root)),
            // An off-disk copy is never a restore target: its `data/persona` is the live persona root, which a restore would
            // write to `<dataRoot>/persona` and so move Agent's persona root.
            "kind": .string(offDisk ? "offdisk_backup" : "backup"),
            "reason": .string(reason),
            "scope": .array(scope.map { .string($0) }),
            "copied": .array(copied.map { .string($0) }),
            "files": .array(files.map(Self.backupIntegrityFileJSON)),
            "links": .array(links.map(Self.backupLinkJSON)),
            "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
        ]
        try Self.writeJSONValue(.object(manifest), to: backupDir.appendingPathComponent("manifest.json"))
        return (scope, files)
    }

    /// One read transaction over a possibly live database into a fresh file. Read-only: the backup never writes or checkpoints
    /// live data.
    static func copyLiveSQLite(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(10)
        let sourceQueue = try DatabaseQueue(path: source.path, configuration: configuration)
        let destinationQueue = try DatabaseQueue(path: destination.path)
        try sourceQueue.backup(to: destinationQueue)
        try destinationQueue.close()
        try sourceQueue.close()
    }

    // Chat paths are restored only when carried by the snapshot; their absence in an older backup must not erase live
    // attachment or queue state. Capture queue references before the attachment tree: the queue owner durably writes each
    // attachment before publishing its lifecycle reference.
    static let backupRelativePaths = legacyBackupRelativePaths + [
        "abilities", "senses", "make", "chat/mac_turn_lifecycle.json", "chat/attachments",
    ]

    /// No backup carries the live sense ledger or unread news.
    static let unbackedSenseNames: Set<String> = ["ledger", "news"]

    static let legacyBackupRelativePaths: [String] = [
        "trust",
        "memory",
        "workshop",
        "chat/sessions.json",
        "chat/messages",
        "chat/session_state",
        "chat/archive",
        "skills",
        "tools",
        "connectors",
        "oauth_tokens/x.json",
        "scheduler/jobs.json",
        "improvements",
        "workflows",
        "catalog/registry.json",
        "catalog/installs.json",
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
        relativePaths: [String],
        excluded: inout [String]
    ) throws -> [String] {
        var copied: [String] = []
        for rel in relativePaths {
            let source = root.appendingNativeRelativePath(rel)
            let destination = destinationRoot.appendingNativeRelativePath(rel)
            if try copyExistingItem(from: source, to: destination, relative: rel, excluded: &excluded) {
                copied.append(rel)
            }
        }
        return copied
    }

    public static func copyExistingItem(
        from source: URL, to destination: URL, relative: String, excluded: inout [String]
    ) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return false }
        if isOutgoingCredential(relative, source)
            || (relative.hasPrefix("memory/") && [".lock", ".sqlite-wal", ".sqlite-shm", ".sqlite-journal"]
                .contains(where: { source.lastPathComponent.hasSuffix($0) })) {
            excluded.append(relative)
            return false
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                _ = try copyExistingItem(from: child, to: destination.appendingPathComponent(child.lastPathComponent),
                    relative: relative + "/" + child.lastPathComponent, excluded: &excluded)
            }
        } else {
            if relative.hasPrefix("memory/"), source.pathExtension == "sqlite", values.isSymbolicLink != true {
                try Self.copyLiveSQLite(from: source, to: destination)
            } else {
                try fm.copyItem(at: source, to: destination)
            }
        }
        return true
    }

    private static func copyLocalSnapshotItem(
        from source: URL,
        to destination: URL,
        relative: String
    ) async throws {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              ["workshop", "senses", "make"].contains(relative) else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            return
        }
        if !["workshop", "senses"].contains(relative) {
            let lock = relative == "make" ? source : source.appendingPathComponent("ops.jsonl")
            try await SwiftNativePersistenceCore.withFileLock(lock) {
                try await Self.copyLocalSnapshotDirectory(from: source, to: destination, relative: relative)
            }
        } else {
            try await Self.copyLocalSnapshotDirectory(from: source, to: destination, relative: relative)
        }
    }

    private static func copyLocalSnapshotDirectory(
        from source: URL,
        to destination: URL,
        relative: String
    ) async throws {
        let fm = FileManager.default
        try Self.requireRegularDirectory(source)
        guard let permissions = try fm.attributesOfItem(atPath: source.path)[.posixPermissions] else {
            throw Self.backupError(code: 422, "Backup source permissions are unavailable.")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let name = child.lastPathComponent
            if name.hasSuffix(".lock") || (relative == "senses" && Self.unbackedSenseNames.contains(name)) { continue }
            try await Self.copyLocalSnapshotItem(
                from: child,
                to: destination.appendingPathComponent(name),
                relative: relative + "/" + name
            )
        }
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
    }

    /// Copy one mutable file tree while holding the same per-file lock its writers use. Lock sidecars are synchronization
    /// machinery, not state, and are never restored. Every SQLite database uses the read-only backup owner; no live storage
    /// owner is opened. A link is kept as a link for the manifest (`takeBackupLinks`).
    private static func copyLockedSnapshotItem(
        from source: URL,
        to destination: URL
    ) async throws {
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        if values.isSymbolicLink == true {
            try Self.copyBackupLink(from: source, to: destination)
            return
        }
        if values.isRegularFile == true {
            if source.pathExtension == "sqlite" {
                try Self.copyLiveSQLite(from: source, to: destination)
            } else {
                try await Self.copyLockedSnapshotFile(from: source, to: destination)
            }
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
        ).sorted {
            // Freeze archive locators before walking their immutable transcripts.
            ($0.lastPathComponent == "sessions.jsonl" ? 0 : 1, $0.lastPathComponent)
                < ($1.lastPathComponent == "sessions.jsonl" ? 0 : 1, $1.lastPathComponent)
        }
        for child in children {
            let name = child.lastPathComponent
            if name.hasSuffix(".lock") { continue }
            if name.hasSuffix(".sqlite-wal")
                || name.hasSuffix(".sqlite-shm") || name.hasSuffix(".sqlite-journal") {
                continue
            }
            try await Self.copyLockedSnapshotItem(
                from: child,
                to: destination.appendingPathComponent(name)
            )
        }
    }

    static func copyLockedSnapshotFile(
        from source: URL,
        to destination: URL,
        locking: Bool = true
    ) async throws {
        guard locking else {
            try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(
                Data(contentsOf: source, options: [.mappedIfSafe]), to: destination
            )
            return
        }
        try await SwiftNativePersistenceCore.withFileLock(source) {
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
            try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(bytes, to: destination)
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
}

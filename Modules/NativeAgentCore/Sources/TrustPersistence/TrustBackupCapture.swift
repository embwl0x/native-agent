import Foundation
import GRDB
import NativeAgentShared
import PersistenceCore
import TrustCenter
import MemoryV2
import Privacy
import SystemOps
// Blueprint: | `TrustBackupCapture.swift` | Locked scope capture and read-only SQLite; canonical live persona. |

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
        guard !Self.pathEntryExists(backupDir) else {
            throw PersistenceCoreError.ioFailure("Backup \(id) already exists; its bytes were left in place.")
        }
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
            // Capture preserves damaged authority for recovery; containment and integrity precede restore-specific admission.
            _ = try Self.validateBackupSnapshot(
                id: id,
                dataRoot: root,
                requireRestorableAuthority: false
            )
            try await Self.appendBackupRecord(record, backupRoot: backupRoot)
            return record
        } catch {
            let captureError = error
            if Self.pathEntryExists(backupDir) {
                do { try fm.removeItem(at: backupDir) }
                catch {
                    throw PersistenceCoreError.ioFailure(
                        "Backup capture failed: \(captureError.localizedDescription). "
                            + "Removing incomplete backup \(id) also failed: \(error.localizedDescription)")
                }
            }
            throw captureError
        }
    }

    /// Local capture follows backupRelativePaths; off-disk capture excludes credentials and seals SQLite outside WAL mode.
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
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: root).standardizedFileURL
        try Self.requireRegularDirectory(personaRoot)
        try Self.requireRegularFile(personaRoot.appendingPathComponent("SOUL.md"), maximumBytes: nil)
        var copied: [String] = []
        if offDisk {
            if try await Self.copyOffDiskItem(personaRoot, relative: "persona", into: dataDir, dataRoot: root) {
                copied.append("persona")
            }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            // The data-root persona path cannot shadow the canonical live persona.
            for child in children where child.lastPathComponent != "persona" {
                let relative = child.lastPathComponent
                let copy: @Sendable () async throws -> [String] = {
                    try await Self.copyOffDiskEntry(child, relative: relative, into: dataDir, dataRoot: root)
                }
                switch relative {
                case "chat":
                    // Retention moves bytes between tiers while holding this lock; capture the entire group in that transaction.
                    copied += try await SwiftNativePersistenceCore.withFileLock(Self.chatSessionIndexPath(in: root), copy)
                case "clock":
                    copied += try await SwiftNativePersistenceCore.withFileLock(root.appendingNativeRelativePath("clock/times.json"), copy)
                default:
                    copied += try await copy()
                }
            }
        } else {
            let ordinaryPaths = Self.backupRelativePaths.filter {
                $0 != "memory" && $0 != "clock" && !$0.hasPrefix("chat/")
            }
            for relative in ordinaryPaths {
                let source = Self.backupDestination(relative, dataRoot: root)
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
            // Clock declarations share the times-file lock.
            copied += try await SwiftNativePersistenceCore.withFileLock(root.appendingNativeRelativePath("clock/times.json")) {
                // Capture the directory under the declarations' writer lock.
                try await Self.copyLockedSnapshotItem(from: root.appendingNativeRelativePath("clock"), to: dataDir.appendingNativeRelativePath("clock"))
                return ["clock"]
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
        // Open only staged regular files after removing links.
        if offDisk {
            try Self.dropRecordDetails(in: dataDir)
            try Self.convertSQLiteCopiesToRollbackJournal(in: dataDir)
        }
        let files = try Self.backupIntegrityFiles(in: dataDir)
        let manifest: [String: JSONValue] = [
            "app": .string("NativeAgent"),
            "createdAt": .string(createdAt),
            "id": .string(id),
            "integrityVersion": .int(2),
            "scopeVersion": .int(4),
            "personaRoot": .string(personaRoot.path),
            "lifeID": .string(try DataRootLife.current(in: root)),
            // Off-disk copies carry a broader, credential-excluded scope and are never local restore targets.
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

    /// Read one coherent live database transaction without writing or checkpointing its source.
    static func copyLiveSQLite(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .immediateError
        let sourceQueue = try DatabaseQueue(path: source.path, configuration: configuration)
        let destinationQueue = try DatabaseQueue(path: destination.path)
        try sourceQueue.backup(to: destinationQueue)
        try destinationQueue.close()
        try sourceQueue.close()
    }

    // Capture references before attachments because their owner durably writes attachments first. Restore replaces only validated captured members, never the
    // entire allowlist.
    static let backupRelativePaths: [String] = [
        "trust",
        "memory",
        "chat/sessions.json",
        "chat/messages",
        "chat/session_state",
        "chat/archive",
        "skills",
        "tools",
        "connectors",
        "oauth_tokens/x.json",
        "clock",
        "improvements",
        "workflows",
        "catalog/registry.json",
        "catalog/sources/sources.json",
        "catalog/trust/roots.json",
        "capabilities",
        "graphs",
        "persona",
        "routing",
        "telegram",
        "dream_diary",
        "abilities", "senses", "make", "chat/mac_turn_lifecycle.json", "chat/attachments",
        ".onboarded",
    ]

    /// No backup carries the live sense ledger or unread news.
    static let unbackedSenseNames: Set<String> = ["ledger", "news"]

    /// Snapshot paths stay relative to `data/`; persona lands at its one live owner.
    static func backupDestination(_ relative: String, dataRoot: URL) -> URL {
        if relative == "persona" { return PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot).standardizedFileURL }
        if relative.hasPrefix("persona/") {
            return PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot).appendingNativeRelativePath(String(relative.dropFirst("persona/".count)))
        }
        return dataRoot.appendingNativeRelativePath(relative)
    }

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
              ["senses", "make"].contains(relative) else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            return
        }
        if relative != "senses" {
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

    /// Copy under each writer's lock; sidecars are coordination, not restorable state. SQLite uses read-only backup without opening live storage owners; links
    /// retain raw manifest targets.
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

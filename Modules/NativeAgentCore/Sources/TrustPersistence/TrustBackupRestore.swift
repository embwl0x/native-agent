import Foundation
import Darwin
import NativeAgentShared
import PersistenceCore
import Transcripts
import ApprovalInbox
import TelegramBot
import AuthoredCapabilities
import TrustCenter
import MemoryV2
import Privacy
import SystemOps
// Blueprint: | `TrustBackupRestore.swift` | TrustBackupPersistence forward restore installation; durable intent and receipt, cataloged pre-restore backup, continuity fences and transcript version advancement |

actor RestoreExclusion {
    private var activeDataRoots: Set<String> = []

    func acquire(dataRoot: URL) -> Bool {
        activeDataRoots.insert(dataRoot.standardizedFileURL.path).inserted
    }

    func release(dataRoot: URL) {
        activeDataRoots.remove(dataRoot.standardizedFileURL.path)
    }
}

let nativeBackupRestoreCoordinator = RestoreExclusion()

struct NativeBackupRestoreIntent: Codable {
    enum State: String, Codable {
        case staged
        case applying
    }

    let transactionID: UUID
    let targetID: String
    let targetManifestSHA256: String
    var safetyBackupID: String?
    var safetyManifestSHA256: String?
    let stagedAt: String
    var state: State
}

extension TrustBackupPersistence {
    public static func restoreBackup(id: String, dataRoot root: URL) async throws -> BackupRestoreResult {
        guard await nativeBackupRestoreCoordinator.acquire(dataRoot: root) else {
            throw NSError(domain: "NativeAgentBackup", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "Another backup restore is already in progress for this data root."
            ])
        }

        do {
            let result = try await restoreBackupAfterAcquiringLock(id: id, dataRoot: root)
            await nativeBackupRestoreCoordinator.release(dataRoot: root)
            return result
        } catch {
            await nativeBackupRestoreCoordinator.release(dataRoot: root)
            throw error
        }
    }

    private static func restoreBackupAfterAcquiringLock(
        id: String,
        dataRoot root: URL
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
                NSLocalizedDescriptionKey: "A staged backup restore already exists. Restart NativeAgent to finish it before staging another restore."
            ])
        }

        let intent = NativeBackupRestoreIntent(
            transactionID: UUID(),
            targetID: snapshot.id,
            targetManifestSHA256: snapshot.manifestSHA256,
            safetyBackupID: nil,
            safetyManifestSHA256: nil,
            stagedAt: Self.nativeArtifactTimestamp(),
            state: .staged
        )
        do {
            try Self.writeRestoreIntent(intent, to: intentPath)
        } catch {
            throw NSError(domain: "NativeAgentBackup", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Restore intent could not be made durable. Current data was not changed: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }
        return BackupRestoreResult(
            id: id,
            restored: snapshot.copied,
            restoredAt: intent.stagedAt,
            requiresRestart: true
        )
    }

    /// Runs before NativeAgentApp/AppModel construction, while no SQLite, TrustCenter, chat, cognition, or background-loop
    /// owner has opened the data root. Preserve the life being left through the normal backup writer before replacing any
    /// scope, then install the approved backup forward.
    public static func resumeStagedBackupRestoreAtLaunch(
        dataRoot root: URL
    ) async throws -> BackupRestoreResult? {
        let intentPath = Self.backupRestoreIntentPath(dataRoot: root)
        _ = try DataRootLife.current(in: root)
        guard Self.pathEntryExists(intentPath) else { return nil }

        var intent = try Self.readRestoreIntent(at: intentPath)
        let target = try Self.validateBackupSnapshot(id: intent.targetID, dataRoot: root)
        guard target.manifestSHA256 == intent.targetManifestSHA256 else {
            throw Self.backupError(
                code: 422,
                "A staged restore backup changed after approval. NativeAgent preserved the intent and refused to start."
            )
        }

        if intent.state == .staged {
            do {
                let backup = try await Self.createBackup(reason: "before restore of \(target.id)", dataRoot: root)
                let kept = try Self.validateBackupSnapshot(id: backup.id, dataRoot: root, requireRestorableAuthority: false)
                intent.safetyBackupID = kept.id
                intent.safetyManifestSHA256 = kept.manifestSHA256
            } catch {
                throw Self.backupError(code: 500,
                    "NativeAgent could not keep the life before restore of \(target.id). No current data was replaced. Tell the person: the backup could not be written: \(error.localizedDescription)")
            }
        }
        intent.state = .applying
        try Self.writeRestoreIntent(intent, to: intentPath)
        var notes: [String] = []
        try await Self.applyBackupSnapshotPreservingEffectFences(
            target: target, intent: intent, destinationRoot: root, notes: &notes)

        let result = BackupRestoreResult(
            id: target.id,
            restored: target.copied,
            restoredAt: Self.nativeArtifactTimestamp(),
            requiresRestart: false,
            notCarried: notes
        )
        // Launch has no Backup UI owner yet. Keep the completed receipt on disk before removing the intent, so omissions remain
        // inspectable afterward.
        try SwiftNativePersistenceCore.writeDataAtomicDurable(
            JSONEncoder().encode(result), to: root.appendingPathComponent("backups/restore-receipt.json"))
        try FileManager.default.removeItem(at: intentPath)
        return result
    }

    static func backupRestoreIntentPath(dataRoot root: URL) -> URL {
        root.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("restore-intent.json")
    }

    static func readRestoreIntent(at path: URL) throws -> NativeBackupRestoreIntent {
        try Self.requireRegularFile(path, maximumBytes: 16 * 1024 * 1024)
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

    private static func applyBackupSnapshot(
        _ snapshot: NativeValidatedBackupSnapshot,
        destinationRoot: URL
    ) throws {
        _ = try Self.validateBackupSnapshot(
            id: snapshot.id,
            dataRoot: destinationRoot
        )
        let fm = FileManager.default
        for rel in snapshot.restorePaths {
            let source = snapshot.dataDirectory.appendingNativeRelativePath(rel)
            let destination = destinationRoot.appendingNativeRelativePath(rel)
            let kept = Self.unbackedChildren(of: rel, at: destination)
            if kept.isEmpty {
                if Self.pathEntryExists(destination) { try fm.removeItem(at: destination) }
            } else {
                for child in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                    where !kept.contains(child.lastPathComponent) {
                    try fm.removeItem(at: child)
                }
            }
            if Self.pathEntryExists(source) {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Into a kept scope directory child by child, never over what it keeps.
                let copies = kept.isEmpty ? [source] : try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for from in copies where kept.isEmpty || !from.lastPathComponent.hasSuffix(".lock") {
                    let to = kept.isEmpty ? destination : destination.appendingPathComponent(from.lastPathComponent)
                    try fm.copyItem(at: from, to: to)
                    // Sidecars are not snapshot data; live writers create their own.
                    if let copied = fm.enumerator(at: to, includingPropertiesForKeys: nil) {
                        for case let item as URL in copied where item.lastPathComponent.hasSuffix(".lock")
                            && (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                            try fm.removeItem(at: item)
                        }
                    }
                }
            }
            // The scope was just replaced by real directories, so a recreated link never lands on (or writes through) an
            // existing entry.
            for link in snapshot.links where NativeAgentWorkspaceRoot.relativePath(link.path, under: rel) != nil {
                let path = destinationRoot.appendingNativeRelativePath(link.path)
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: path.path, withDestinationPath: link.target)
            }
        }
    }

    private static func applyBackupSnapshotPreservingEffectFences(
        target: NativeValidatedBackupSnapshot,
        intent: NativeBackupRestoreIntent,
        destinationRoot: URL,
        notes: inout [String]
    ) async throws {
        guard let id = intent.safetyBackupID else {
            throw Self.backupError(code: 422, "The pre-restore backup is missing. Tell the person: NativeAgent cannot replace current data until its backup is kept.")
        }
        let kept = try Self.validateBackupSnapshot(id: id, dataRoot: destinationRoot, requireRestorableAuthority: false)
        guard kept.manifestSHA256 == intent.safetyManifestSHA256,
              kept.reason == "before restore of \(target.id)" else {
            throw Self.backupError(code: 422, "The pre-restore backup changed. Tell the person: NativeAgent kept the restore intent and refused to replace current data.")
        }
        var generationFloor: Int64 = 0
        do {
            generationFloor = try ChatSessionIndexFile.loadObjectRowsForMutation(at: Self.chatSessionIndexPath(in: kept.dataDirectory))
                .compactMap { ChatSessionIndexFile.transcriptGeneration(in: $0) }.max() ?? 0
        } catch {
            notes.append("chat/sessions.json: \(error.localizedDescription); current transcript-version counters were not kept.")
        }
        do {
            let epochPath = Self.transcriptRestoreEpochPath(in: destinationRoot)
            if Self.pathEntryExists(epochPath) {
                try Self.requireRegularFile(epochPath, maximumBytes: 1024)
                guard case .object(let object) = try JSONValue.parse(Data(contentsOf: epochPath)),
                      case .int(let value)? = object["epoch"], value >= 0 else {
                    throw Self.backupError(code: 422, "The transcript restore epoch is malformed.")
                }
                generationFloor = max(generationFloor, value)
            }
        } catch {
            notes.append("chat/transcript_restore_epoch.json: \(error.localizedDescription); current transcript version floor was not kept; readable carried/restored counters set the new floor.")
        }
        var carriedAbilities: [String: Data] = [:]
        if !target.restorePaths.contains("abilities") {
            let legacy = try AbilityStore(dataRoot: kept.dataDirectory).restoredLegacyCarry(backupRoot: target.dataDirectory)
            carriedAbilities = legacy.files
            notes += legacy.notes
        }
        try Self.applyBackupSnapshot(
            target,
            destinationRoot: destinationRoot
        )
        // Prove the selected backup exactly before overlaying facts that are intentionally newer than it.
        try Self.verifyAppliedSnapshot(target, destinationRoot: destinationRoot)
        // A backup older than abilities/ restored the tools and skills they became; what it never carried (senses, her turn)
        // stays.
        if !target.restorePaths.contains("abilities") {
            try AbilityStore(dataRoot: destinationRoot).installRestoredLegacy(carriedAbilities, backupRoot: target.dataDirectory)
        }
        if let cause = try TelegramConfig.preserveCredential(safetyRoot: kept.dataDirectory, destinationRoot: destinationRoot) {
            notes.append("telegram/config.json: \(cause); current credential grant was not kept.")
        }
        notes += try SwiftNativeApprovalInbox.mergeRestoreFences(
            safetyRoot: kept.dataDirectory, destinationRoot: destinationRoot)
        let schedulerPath = kept.dataDirectory.appendingNativeRelativePath("scheduler/jobs.json")
        if Self.pathEntryExists(schedulerPath) {
            let scheduler = try Data(contentsOf: schedulerPath)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(scheduler, to: destinationRoot.appendingNativeRelativePath("scheduler/jobs.json"))
        }
        try DataRootLife.begin(in: destinationRoot, id: intent.transactionID)
        // Raise the selected backup above the prior phone version floor.
        try Self.rollTranscriptGenerationsForward(
            in: destinationRoot,
            priorGenerationFloor: generationFloor
        )
    }

    /// Stamp the installed index above retained/readable version counters.
    private static func rollTranscriptGenerationsForward(
        in root: URL,
        priorGenerationFloor: Int64
    ) throws {
        let path = Self.chatSessionIndexPath(in: root)
        var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
        guard !rows.isEmpty else { return }
        let epoch = try Self.bumpTranscriptRestoreEpoch(in: root, atLeast: max(
            priorGenerationFloor,
            rows.compactMap { ChatSessionIndexFile.transcriptGeneration(in: $0) }.max() ?? 0))
        guard epoch < Int64.max else { return }
        var changed = false
        for index in rows.indices {
            guard case .string(_)? = rows[index]["id"] else { continue }
            let restored = ChatSessionIndexFile.transcriptGeneration(in: rows[index]) ?? 0
            let forward = max(restored, epoch + 1)
            guard forward != restored else { continue }
            rows[index][ChatSessionIndexFile.transcriptGenerationKey] = .int(forward)
            changed = true
        }
        guard changed else { return }
        do {
            try ChatSessionIndexFile.write(rows, to: path)
        } catch {
            throw Self.backupError(
                code: 500,
                "The restored session index could not be re-stamped with newer transcript versions: \(error.localizedDescription)"
            )
        }
    }

    /// The transcript version floor stays outside backupRelativePaths so a restore cannot lower it along with chat history.
    private static func transcriptRestoreEpochPath(in root: URL) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("transcript_restore_epoch.json")
    }

    /// Persist a new epoch above the readable floor before publishing it.
    private static func bumpTranscriptRestoreEpoch(
        in root: URL,
        atLeast floor: Int64
    ) throws -> Int64 {
        let path = Self.transcriptRestoreEpochPath(in: root)
        guard floor < Int64.max else { return floor }
        let next = floor + 1
        do {
            var info = stat()
            if lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
                try FileManager.default.removeItem(at: path)
            }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                JSONValue.object(["epoch": .int(next)]).serializedData(pretty: false), to: path)
        } catch {
            throw Self.backupError(
                code: 500,
                "The transcript restore epoch could not be recorded, so the restored transcripts could not be raised above what the phone already holds: \(error.localizedDescription)"
            )
        }
        return next
    }

    static func chatSessionIndexPath(in root: URL) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private static func verifyAppliedSnapshot(
        _ snapshot: NativeValidatedBackupSnapshot,
        destinationRoot: URL
    ) throws {
        for rel in snapshot.restorePaths where !snapshot.copied.contains(rel) {
            let destination = destinationRoot.appendingNativeRelativePath(rel)
            guard Self.pathEntryExists(destination) else { continue }
            // Only what no backup carries may remain.
            let kept = Self.unbackedChildren(of: rel, at: destination)
            guard !kept.isEmpty, try Set(FileManager.default.contentsOfDirectory(atPath: destination.path)) == kept else {
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

    /// The live children of a restore scope that no backup carries, kept in place.
    private static func unbackedChildren(of rel: String, at destination: URL) -> Set<String> {
        guard rel == "senses",
              let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return [] }
        return Self.unbackedSenseNames.filter { Self.pathEntryExists(destination.appendingPathComponent($0)) }
    }
}

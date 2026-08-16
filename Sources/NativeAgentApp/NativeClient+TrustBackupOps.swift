import Foundation
import Darwin
import AppKit
import CryptoKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

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
    let safetyBackupID: String
    let safetyManifestSHA256: String
    let stagedAt: String
    var state: State
}

private struct NativeValidatedBackupSnapshot {
    let id: String
    let dataDirectory: URL
    let copied: [String]
    let files: [NativeBackupIntegrityFile]
    let reason: String
    let createdAt: String
    let manifestSHA256: String
}

extension NativeClient {
    func saveTrustPolicy(permissionLevel: String, autonomyDefault: String, requireBackups: Bool, outsideDefault: String, developerMode: Bool = false, autonomousTraining: Bool? = nil, dreamScheduler: Bool? = nil, workshopExecutionEnabled: Bool? = nil, workshopExecutionShowTimeline: Bool? = nil) async throws -> TrustPolicy {
        var body: [String: Any] = [
            "permissionLevel": permissionLevel,
            "autonomyDefault": autonomyDefault,
            "developerMode": developerMode,
            "filePolicy": [
                "requireBackupBeforeWrite": requireBackups,
                "outsideWorkspaceDefault": outsideDefault
            ]
        ]
        // PATCH-2026-05-07: training-b1 ui Forward training trust toggles when set.
        if autonomousTraining != nil || dreamScheduler != nil {
            var training: [String: Any] = [:]
            if let value = autonomousTraining {
                training["autonomous_training"] = value
            }
            if let value = dreamScheduler {
                training["dream_scheduler"] = value
            }
            body["trainingPolicy"] = training
        }
        // PATCH-2026-05-07: executions-b Forward execution policy toggles when set.
        if workshopExecutionEnabled != nil || workshopExecutionShowTimeline != nil {
            var mp: [String: Any] = [:]
            if let v = workshopExecutionEnabled { mp["enabled"] = v }
            if let v = workshopExecutionShowTimeline { mp["showTimeline"] = v }
            // Wave 4 phase A: STILL the old key. The trust-write chokepoint
            // accepts `workshopPolicy` on the way in
            // (WorkshopPolicyBlockVocabulary.foldToWireKey in updateTrust), but
            // this writer keeps emitting `missionPolicy` so `trust/policy.json`
            // and every snapshot a 0.3.7 iOS install decodes stay byte-identical.
            body[WorkshopPolicyBlockVocabulary.wireKey] = mp
        }
        return try await postTrustWrite(body: body)
    }

    /// Single app chokepoint for every trust-policy write. Authority mutation
    /// belongs to SwiftNativeTrustCenter, which validates and deep-merges one
    /// locked generation and consumes Full Mac duration intent under that lock.
    func postTrustWrite(body: [String: Any]) async throws -> TrustPolicy {
        try await Self.applyTrustPolicyPatch(body: body, dataRoot: PersistenceCore.defaultDataRoot())
    }

    /// Root-injectable form of the single trust-write chokepoint —
    /// `postTrustWrite` delegates here with the production data root;
    /// tests exercise the SAME merge+normalize path against a tmp root
    /// (FullMacDurationAndExpiryTests). Not a second write path.
    static func applyTrustPolicyPatch(body: [String: Any], dataRoot root: URL) async throws -> TrustPolicy {
        let patch = JSONValue(fromFoundation: body)
        guard case .object(let patchObject) = patch else {
            throw TrustCenterError.invalidRequest
        }
        let updated = try await SwiftNativeTrustCenter(dataRoot: root)
            .applyPolicyPatchChecked(patchObject)
        let data = try JSONValue.object(updated).serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(TrustPolicy.self, from: data)
    }

    // DAEMON-KILL (2026-06-06): route policy preview through the SwiftNative
    // SecurityCenter. We model the action+path as a write-class tool invocation
    // and evaluate it WITHOUT recording a receipt (the security envelope is
    // for preview only). Mapping is direct: envelope.allowed/requiresApproval/
    // risk/reasons → PolicySimulation; `action` is echoed back so the UI shows
    // the same string the caller asked about. Autonomy is enforced (the same
    // way a real call would be) so the preview reflects the real gate.
    func simulatePolicy(action: String, path: String) async throws -> PolicySimulation {
        let securityCenter = SwiftNativeSecurityCenter()
        // Map the policy-preview action vocabulary to SecurityCenter's
        // builtin tool names. The UI uses verb-noun ("file_write");
        // SecurityCenter's catalog uses Swift function names
        // ("write_file"). Without this alias, an unknown tool name path
        // falls into the unsigned-tool risk class and the preview lies.
        // (gpt-5.5 review MEDIUM.)
        let raw = action.isEmpty ? "write_file" : action
        let toolName: String = {
            switch raw {
            case "file_write": return "write_file"
            case "file_read":  return "read_file"
            case "file_list":  return "list_dir"
            case "file_move":  return "move_file"
            case "file_trash": return "trash_file"
            default:           return raw
            }
        }()
        let envelope = await securityCenter.evaluateTool(
            tool: toolName,
            input: ["path": .string(path)],
            origin: SecurityOriginContext(surface: "mac_ui_policy_preview"),
            enforceAutonomy: true
        )
        return PolicySimulation(
            allowed: envelope.allowed,
            requiresApproval: envelope.requiresApproval,
            risk: envelope.risk,
            action: action,
            reasons: envelope.reasons
        )
    }

    func createBackup(reason: String) async throws -> BackupRecord {
        try await Self.createBackup(reason: reason, dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func createBackup(reason: String, dataRoot root: URL) async throws -> BackupRecord {
        let now = Self.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let backupDir = backupRoot.appendingPathComponent(id, isDirectory: true)
        let dataDir = backupDir.appendingPathComponent("data", isDirectory: true)

        let fm = FileManager.default
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReason = cleanReason.isEmpty ? "manual backup" : cleanReason

        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: backupDir)
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let ordinaryPaths = Self.backupRelativePaths.filter {
                $0 != "memory" && !$0.hasPrefix("chat/")
            }
            var copied = try Self.copySelectedDataPaths(
                root: root,
                destinationRoot: dataDir,
                relativePaths: ordinaryPaths
            )
            let memorySource = root.appendingNativeRelativePath("memory")
            if Self.pathEntryExists(memorySource) {
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
            let scope = Self.scopeNames(for: copied)
            let files = try Self.backupIntegrityFiles(in: dataDir)
            let record = BackupRecord(
                id: id,
                reason: resolvedReason,
                scope: scope,
                path: backupDir.path,
                createdAt: now
            )

            let manifest: JSONValue = .object([
                "app": .string("NativeAgent"),
                "createdAt": .string(now),
                "id": .string(id),
                "integrityVersion": .int(2),
                "kind": .string("backup"),
                "reason": .string(resolvedReason),
                "scope": .array(scope.map { .string($0) }),
                "copied": .array(copied.map { .string($0) }),
                "files": .array(files.map(Self.backupIntegrityFileJSON)),
                "version": .string(Self.nativeAppVersionString()),
            ])
            try Self.writeJSONValue(manifest, to: backupDir.appendingPathComponent("manifest.json"))
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

    func restoreBackup(id: String) async throws -> BackupRestoreResult {
        try await Self.restoreBackup(id: id, dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func restoreBackup(id: String, dataRoot root: URL) async throws -> BackupRestoreResult {
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
                NSLocalizedDescriptionKey: "A staged backup restore already exists. Restart NativeAgent to finish or roll it back before staging another restore."
            ])
        }

        let safetyReason = "pre-restore safety backup before restoring \"\(snapshot.reason)\" from \(snapshot.createdAt) [\(snapshot.id)]"
        let safetyBackup: BackupRecord
        do {
            safetyBackup = try await createBackup(reason: safetyReason, dataRoot: root)
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
    static func resumeStagedBackupRestoreAtLaunch(
        dataRoot root: URL
    ) throws -> BackupRestoreResult? {
        let intentPath = Self.backupRestoreIntentPath(dataRoot: root)
        guard Self.pathEntryExists(intentPath) else { return nil }

        var intent = try Self.readRestoreIntent(at: intentPath)
        let target = try Self.validateBackupSnapshot(id: intent.targetID, dataRoot: root)
        let safety = try Self.validateBackupSnapshot(
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
            try Self.applyBackupSnapshot(
                safety,
                destinationRoot: root,
                requireRestorableAuthority: false
            )
            try Self.verifyAppliedSnapshot(safety, destinationRoot: root)
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
        try Self.writeCodableJSON(intent, to: path)
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
        }
    }

    private static func applyBackupSnapshotPreservingEffectFences(
        target: NativeValidatedBackupSnapshot,
        safety: NativeValidatedBackupSnapshot,
        destinationRoot: URL
    ) throws {
        try Self.applyBackupSnapshot(
            target,
            destinationRoot: destinationRoot,
            requireRestorableAuthority: true
        )
        // Prove the selected backup exactly before overlaying facts that are
        // intentionally newer than it.
        try Self.verifyAppliedSnapshot(target, destinationRoot: destinationRoot)
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

    static let productionExportRelativePaths: [String] = [
        "trust",
        "memory",
        "workshop",
        "skills",
        "tools/registry.json",
        "tools/active",
        "tools/proposals",
        "workflows",
        "catalog/registry.json",
        "catalog/sources/sources.json",
        "catalog/trust/roots.json",
        "capabilities",
        "persona",
        "scheduler/jobs.json",
        "connectors/registry.json",
        "connectors/workspaces.json",
        "mcp/servers.json",
        "mcp/consent/ledger.json",
    ]

    static let supportBundleRelativePaths: [String] = [
        "doctor",
        "runtime",
        "release",
        "activity/events.jsonl",
        "harness/learning_receipts.jsonl",
        "improvements/gauntlet/runs.json",
        "mcp/cache/tools.json",
        "mcp/cache/resources.json",
        "mcp/consent/ledger.json",
        "telegram/state.json",
        "cutover",
    ]

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

    static let productionRedactions: [String] = [
        "config/*",
        "secrets/*",
        "oauth_tokens/*",
        "providers/*",
        "codex_home/*",
        "catalog/.pack_signing_key",
        "raw logs",
    ]

    static let supportRedactions: [String] = [
        "config/*",
        "secrets/*",
        "oauth_tokens/*",
        "providers/*",
        "codex_home/*",
        "catalog/.pack_signing_key",
        "chat transcripts",
        "memory database",
    ]

    static func nativeArtifactTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func nativeAppVersionString() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static func artifactManifest(
        id: String,
        kind: String,
        createdAt: String,
        scope: [String],
        copied: [String],
        redactions: [String]
    ) -> JSONValue {
        .object([
            "app": .string("NativeAgent"),
            "createdAt": .string(createdAt),
            "id": .string(id),
            "kind": .string(kind),
            "scope": .array(scope.map { .string($0) }),
            "copied": .array(copied.map { .string($0) }),
            "redactions": .array(redactions.map { .string($0) }),
            "version": .string(nativeAppVersionString()),
        ])
    }

    static func copySelectedDataPaths(
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

    static func copyExistingItem(from source: URL, to destination: URL) throws -> Bool {
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
    /// online-backup owner instead of copying a live DB/WAL tuple.
    private static func copyLockedSnapshotItem(
        from source: URL,
        to destination: URL,
        excludingSQLiteArtifacts: Bool
    ) async throws {
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw Self.backupError(code: 422, "Backup source contains a symbolic link: \(source.lastPathComponent)")
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

    private static func copyLockedSnapshotFile(from source: URL, to destination: URL) async throws {
        let persistence = SwiftNativePersistenceCore()
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

    static func scopeNames(for relativePaths: [String]) -> [String] {
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

    static func writeCodableJSON<T: Encodable>(_ value: T, to path: URL) throws {
        let data = try JSONEncoder().encode(value)
        let json = try JSONValue.parse(data)
        try writeJSONValue(json, to: path)
    }

    static func writeJSONValue(_ value: JSONValue, to path: URL) throws {
        let data = try value.serializedData(pretty: true)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    static func createTarGz(sourceDirectory: URL, archiveURL: URL) async throws {
        let result = try await runProcess(
            executable: "/usr/bin/tar",
            arguments: ["-czf", archiveURL.path, "-C", sourceDirectory.path, "."],
            currentDirectory: sourceDirectory.deletingLastPathComponent(),
            timeout: 180
        )
        guard result.status == 0 else {
            throw NSError(domain: "NativeAgentArtifact", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "tar failed: \(processDetail(result))"
            ])
        }
    }

    static func sha256Hex(ofFile file: URL, currentDirectory: URL) async throws -> String {
        let result = try await runProcess(
            executable: "/usr/bin/shasum",
            arguments: ["-a", "256", file.path],
            currentDirectory: currentDirectory,
            timeout: 60
        )
        guard result.status == 0 else {
            throw NSError(domain: "NativeAgentArtifact", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "shasum failed: \(processDetail(result))"
            ])
        }
        guard let first = result.stdout.split(whereSeparator: \.isWhitespace).first else {
            throw NSError(domain: "NativeAgentArtifact", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "shasum returned no checksum"
            ])
        }
        return String(first)
    }

    static func fileSizeBytes(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    static func appendProductionExport(_ record: ProductionExport, registryRoot: URL) async throws {
        let path = registryRoot.appendingPathComponent("registry.json")
        try await appendRegistryRow(Self.productionExportJSON(record), path: path, id: record.id)
    }

    static func appendBackupRecord(_ record: BackupRecord, backupRoot: URL) async throws {
        let row = Self.backupRecordJSON(record)
        // Keep the two legacy registry projections until a release migration
        // can prove every installed shape has been imported. Restore identity
        // never trusts either path; it derives the UUID directory beneath the
        // validated backup root, so retaining compatibility adds no authority.
        try await appendRegistryRow(row, path: backupRoot.appendingPathComponent("registry.json"), id: record.id)
        try await appendRegistryRow(row, path: backupRoot.appendingPathComponent("index.json"), id: record.id)
    }

    static func appendRegistryRow(_ row: JSONValue, path: URL, id: String, maxRows: Int = 200) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            var rows: [JSONValue]
            if case .array(let existing) = raw {
                rows = existing.filter { Self.jsonObjectString($0, key: "id") != id }
            } else {
                rows = []
            }
            rows.append(row)
            if rows.count > maxRows {
                rows = Array(rows.suffix(maxRows))
            }
            try await persistence.writeJSON(.array(rows), to: path)
        }
    }

    static func readBackupRecords(root: URL) throws -> [BackupRecord] {
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

    static func readBackupRecordsFile(_ path: URL) throws -> [BackupRecord] {
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

    static func productionExportJSON(_ record: ProductionExport) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(record.id),
            "path": .string(record.path),
            "scope": .array(record.scope.map { .string($0) }),
        ]
        if let kind = record.kind { obj["kind"] = .string(kind) }
        if let checksum = record.checksum { obj["checksum"] = .string(checksum) }
        if let sizeBytes = record.sizeBytes { obj["sizeBytes"] = .int(Int64(sizeBytes)) }
        if let createdAt = record.createdAt { obj["createdAt"] = .string(createdAt) }
        return .object(obj)
    }

    static func backupRecordJSON(_ record: BackupRecord) -> JSONValue {
        .object([
            "id": .string(record.id),
            "reason": .string(record.reason),
            "scope": .array(record.scope.map { .string($0) }),
            "path": .string(record.path),
            "createdAt": .string(record.createdAt),
        ])
    }

    static func jsonObjectString(_ value: JSONValue, key: String) -> String? {
        guard case .object(let obj) = value, case .string(let string)? = obj[key] else {
            return nil
        }
        return string
    }


}

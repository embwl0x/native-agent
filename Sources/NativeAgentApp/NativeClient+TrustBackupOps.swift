import Foundation
import Darwin
import AppKit
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
import CapabilityFoundry

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
        // PATCH-2026-05-07: missions-b Forward mission policy toggles when set.
        if workshopExecutionEnabled != nil || workshopExecutionShowTimeline != nil {
            var mp: [String: Any] = [:]
            if let v = workshopExecutionEnabled { mp["enabled"] = v }
            if let v = workshopExecutionShowTimeline { mp["showTimeline"] = v }
            body["missionPolicy"] = mp
        }
        return try await postTrustWrite(body: body)
    }

    /// Single chokepoint for every trust-policy write. The Swift-native writer
    /// deep-merges into `<dataRoot>/trust/policy.json` under the shared file lock
    /// and reloads through SwiftNativeTrustCenter so defaults stay normalized.
    func postTrustWrite(body: [String: Any]) async throws -> TrustPolicy {
        try await Self.applyTrustPolicyPatch(body: body, dataRoot: PersistenceCore.defaultDataRoot())
    }

    /// Root-injectable form of the single trust-write chokepoint —
    /// `postTrustWrite` delegates here with the production data root;
    /// tests exercise the SAME merge+normalize path against a tmp root
    /// (FullMacDurationAndExpiryTests). Not a second write path.
    static func applyTrustPolicyPatch(body: [String: Any], dataRoot root: URL) async throws -> TrustPolicy {
        // DAEMON-DEAD PORT (2026-06-02): native trust-write executor. Deep-merge
        // the patch into `<dataRoot>/trust/policy.json` under flock, then
        // reload+normalize via SwiftNativeTrustCenter so the returned policy
        // reflects defaults + backfills the daemon used to apply.
        let path = root
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let persistence = SwiftNativePersistenceCore()
        let patch = JSONValue(fromFoundation: body)
        let defaults = SwiftNativeTrustCenter(dataRoot: root).defaultTrustPolicy()
        try await persistence.withFileLock(path) {
            let current = try SwiftNativeTrustCenter.loadRawPolicyChecked(at: path)
            try SwiftNativeTrustCenter.validateKnownAuthorityPolicyTypes(
                current,
                against: defaults
            )
            var patchDict: [String: JSONValue] = [:]
            if case .object(let p) = patch { patchDict = p }
            // Review blocker fix (2026-06-10): the Full Mac duration picker's
            // >24h expiry derives HERE, from the on-disk confirmedAt read
            // under THIS lock — never from a stamp the caller read earlier
            // (a concurrent reconfirm would make the explicit expiry, which
            // has gate precedence, anchor to the OLD stamp). The intent key
            // is consumed either way and never persists.
            patchDict = Self.resolveFullMacExpiryIntent(patchDict, onDisk: current)
            let merged = Self._deepMergeTrustDict(current, patchDict)
            try SwiftNativeTrustCenter.validateAuthorityPolicyShape(merged)
            try SwiftNativeTrustCenter.validateKnownAuthorityPolicyTypes(
                merged,
                against: defaults
            )
            try await persistence.writeJSON(.object(merged), to: path)
        }
        let reloaded = try await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicyChecked()
        let data = try JSONValue.object(reloaded).serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(TrustPolicy.self, from: data)
    }

    static func _deepMergeTrustDict(
        _ base: [String: JSONValue],
        _ patch: [String: JSONValue]
    ) -> [String: JSONValue] {
        var out = base
        for (k, v) in patch {
            if case .object(let pNested) = v,
               case .object(let bNested)? = out[k] {
                out[k] = .object(_deepMergeTrustDict(bNested, pNested))
            } else {
                out[k] = v
            }
        }
        return out
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
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: backupDir)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let copied = try Self.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.backupRelativePaths
        )
        let scope = Self.scopeNames(for: copied)
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = BackupRecord(
            id: id,
            reason: cleanReason.isEmpty ? "manual backup" : cleanReason,
            scope: scope,
            path: backupDir.path,
            createdAt: now
        )

        let manifest: JSONValue = .object([
            "app": .string("NativeAgent"),
            "createdAt": .string(now),
            "id": .string(id),
            "kind": .string("backup"),
            "scope": .array(scope.map { .string($0) }),
            "copied": .array(copied.map { .string($0) }),
            "version": .string(Self.nativeAppVersionString()),
        ])
        try Self.writeJSONValue(manifest, to: backupDir.appendingPathComponent("manifest.json"))
        try await Self.appendBackupRecord(record, backupRoot: backupRoot)
        return record
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
        let backups = try Self.readBackupRecords(root: root)
        guard let record = backups.first(where: { $0.id == id }) else {
            throw NSError(domain: "NativeAgentBackup", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "backup id not found: \(id)"
            ])
        }

        let backupDir = URL(fileURLWithPath: record.path)
        let dataDir = backupDir.appendingPathComponent("data", isDirectory: true)
        do {
            try Self.validateBackupChatSessionIndex(backupDir: backupDir, dataDir: dataDir)
            try Self.validateBackupTrustPolicy(backupDir: backupDir, dataDir: dataDir)
            try Self.validateBackupCapabilityAuthority(dataDir: dataDir)
        } catch {
            throw NSError(domain: "NativeAgentBackup", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Backup authority or session state is invalid; restore was cancelled before current data changed: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }
        let safetyReason = "pre-restore safety backup before restoring \"\(record.reason)\" from \(record.createdAt) [\(record.id)]"
        let safetyBackup: BackupRecord
        do {
            safetyBackup = try await createBackup(reason: safetyReason, dataRoot: root)
        } catch {
            throw NSError(domain: "NativeAgentBackup", code: 412, userInfo: [
                NSLocalizedDescriptionKey: "Safety backup failed; restore was cancelled before current data changed: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }

        let restored: [String]
        do {
            if FileManager.default.fileExists(atPath: dataDir.path) {
                restored = try Self.restoreSelectedDataPaths(
                    backupDataRoot: dataDir,
                    destinationRoot: root,
                    relativePaths: Self.backupRelativePaths
                )
            } else {
                restored = try Self.restoreLegacyFlatBackup(backupDir: backupDir, destinationRoot: root)
            }
        } catch {
            throw NSError(domain: "NativeAgentBackup", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Restore failed after safety backup \(safetyBackup.id) was created: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }
        return BackupRestoreResult(id: id, restored: restored, restoredAt: Self.nativeArtifactTimestamp())
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

    static func restoreSelectedDataPaths(
        backupDataRoot: URL,
        destinationRoot: URL,
        relativePaths: [String]
    ) throws -> [String] {
        var restored: [String] = []
        for rel in relativePaths {
            let source = backupDataRoot.appendingNativeRelativePath(rel)
            let destination = destinationRoot.appendingNativeRelativePath(rel)
            if try copyExistingItem(from: source, to: destination) {
                restored.append(rel)
            }
        }
        return restored
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

    static func restoreLegacyFlatBackup(backupDir: URL, destinationRoot: URL) throws -> [String] {
        let mapping: [(String, String)] = [
            ("trust.json", "trust/policy.json"),
            ("missions.json", "workshop/legacy_executions.json"),
            ("chat_sessions.json", "chat/sessions.json"),
            ("improvements.json", "improvements/runs.json"),
            ("tools.json", "tools/registry.json"),
            ("connectors.json", "connectors/registry.json"),
            ("skills.json", "skills/registry.json"),
            ("jobs.json", "scheduler/jobs.json"),
            ("memory.json", "memory/memory.json"),
            ("workspaces.json", "connectors/workspaces.json"),
        ]
        var restored: [String] = []
        for (sourceName, destinationRel) in mapping {
            let source = backupDir.appendingPathComponent(sourceName)
            let destination = destinationRoot.appendingNativeRelativePath(destinationRel)
            if try copyExistingItem(from: source, to: destination) {
                restored.append(destinationRel)
            }
        }
        return restored
    }

    private static func validateBackupChatSessionIndex(backupDir: URL, dataDir: URL) throws {
        let source: URL
        if FileManager.default.fileExists(atPath: dataDir.path) {
            source = dataDir.appendingNativeRelativePath("chat/sessions.json")
        } else {
            source = backupDir.appendingPathComponent("chat_sessions.json")
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        _ = try ChatSessionIndexFile.loadObjectRowsForMutation(at: source)
    }

    private static func validateBackupTrustPolicy(backupDir: URL, dataDir: URL) throws {
        let source: URL
        if FileManager.default.fileExists(atPath: dataDir.path) {
            source = dataDir.appendingNativeRelativePath("trust/policy.json")
        } else {
            source = backupDir.appendingPathComponent("trust.json")
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let policy = try SwiftNativeTrustCenter.loadRawPolicyChecked(at: source)
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

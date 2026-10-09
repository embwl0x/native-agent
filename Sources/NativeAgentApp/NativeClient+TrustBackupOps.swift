import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
import TrustPersistence

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
    /// locked generation.
    func postTrustWrite(body: [String: Any]) async throws -> TrustPolicy {
        try await Self.applyTrustPolicyPatch(
            body: body,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    /// Root-injectable form of the single trust-write chokepoint —
    /// `postTrustWrite` delegates here with the production data root;
    /// tests exercise the SAME merge+normalize path against a tmp root
    /// (FullMacDurationAndExpiryTests). Not a second write path.
    static func applyTrustPolicyPatch(
        body: [String: Any],
        dataRoot root: URL,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: body, dataRoot: root, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    // DAEMON-KILL (2026-06-06): route policy preview through the SwiftNative
    // SecurityCenter. We model the action+path as a write-class tool invocation
    // and evaluate it WITHOUT recording a receipt (the security envelope is
    // for preview only). Mapping is direct: envelope.allowed/requiresApproval/
    // risk/reasons → PolicySimulation; `action` is echoed back so the UI shows
    // the same string the caller asked about. Autonomy is enforced (the same
    // way a real call would be) so the preview reflects the real gate.
    func simulatePolicy(action: String, path: String) async throws -> PolicySimulation {
        return try await Self.simulatePolicy(
            action: action,
            path: path,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    /// Root-injectable form of the Trust Center's policy preview. This is not
    /// a second evaluator: it builds the same SecurityCenter envelope the
    /// installed UI uses, while letting hermetic tests write/reopen authority
    /// state without ever consulting the developer's live policy.
    static func simulatePolicy(
        action: String,
        path: String,
        dataRoot: URL
    ) async throws -> PolicySimulation {
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
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
            reasons: envelope.reasons.map(\.sentence)
        )
    }

    func createBackup(reason: String) async throws -> BackupRecord {
        try await Self.createBackup(reason: reason, dataRoot: PersistenceCore.defaultDataRoot())
    }

    func restoreBackup(id: String) async throws -> BackupRestoreResult {
        try await Self.restoreBackup(id: id, dataRoot: PersistenceCore.defaultDataRoot())
    }

    private static var backupHost: TrustBackupHost {
        TrustBackupHost(applicationVersion: { nativeAppVersionString() })
    }

    static func createBackup(reason: String, dataRoot: URL) async throws -> BackupRecord {
        try await TrustBackupPersistence.createBackup(reason: reason, dataRoot: dataRoot, host: backupHost)
    }

    static func restoreBackup(id: String, dataRoot: URL) async throws -> BackupRestoreResult {
        try await TrustBackupPersistence.restoreBackup(id: id, dataRoot: dataRoot, host: backupHost)
    }

    /// The launch entry point calls this only after claiming the single app
    /// instance and preparing its root, before any persistence owner opens.
    static func resumeStagedBackupRestoreAtLaunch(dataRoot: URL) throws -> BackupRestoreResult? {
        try TrustBackupPersistence.resumeStagedBackupRestoreAtLaunch(dataRoot: dataRoot, host: backupHost)
    }

    static func createOffDiskBackup(
        reason: String,
        dataRoot: URL,
        parent: URL = offDiskBackupParent(),
        now: Date = Date()
    ) async throws -> URL {
        try await TrustBackupPersistence.createOffDiskBackup(
            reason: reason, dataRoot: dataRoot, parent: parent, now: now, host: backupHost
        )
    }

    static func readBackupRecords(root: URL) throws -> [BackupRecord] {
        try TrustBackupPersistence.readBackupRecords(root: root)
    }

    static func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)] {
        try TrustBackupPersistence.offDiskAutomaticBackups(in: parent)
    }

    static func nativeArtifactTimestamp() -> String {
        TrustBackupPersistence.nativeArtifactTimestamp()
    }

    static func copySelectedDataPaths(root: URL, destinationRoot: URL, relativePaths: [String]) throws -> [String] {
        try TrustBackupPersistence.copySelectedDataPaths(root: root, destinationRoot: destinationRoot, relativePaths: relativePaths)
    }

    static func copyExistingItem(from source: URL, to destination: URL) throws -> Bool {
        try TrustBackupPersistence.copyExistingItem(from: source, to: destination)
    }

    static func scopeNames(for relativePaths: [String]) -> [String] {
        TrustBackupPersistence.scopeNames(for: relativePaths)
    }

    static func writeCodableJSON<T: Encodable>(_ value: T, to path: URL) throws {
        try TrustBackupPersistence.writeCodableJSON(value, to: path)
    }

    static func writeJSONValue(_ value: JSONValue, to path: URL) throws {
        try TrustBackupPersistence.writeJSONValue(value, to: path)
    }

    static func appendRegistryRow(_ row: JSONValue, path: URL, id: String, maxRows: Int? = 200) async throws {
        try await TrustBackupPersistence.appendRegistryRow(row, path: path, id: id, maxRows: maxRows)
    }

    static func jsonObjectString(_ value: JSONValue, key: String) -> String? {
        TrustBackupPersistence.jsonObjectString(value, key: key)
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/NativeAgent-Backups` —
    /// iCloud Drive, so a lost or wiped Mac does not take Agent with it.
    static func offDiskBackupParent() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("NativeAgent-Backups", isDirectory: true)
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

    static let productionRedactions: [String] = [
        "senses/ledger/*",
        "senses/news/*",
        "mcp/servers.json",
        "config/*",
        "secrets/*",
        "oauth_tokens/*",
        "providers/*",
        "codex_home/*",
        "codex_child_home/*",
        "catalog/.pack_signing_key",
        "raw logs",
    ]

    static let supportRedactions: [String] = [
        "senses/ledger/*",
        "senses/news/*",
        "config/*",
        "secrets/*",
        "oauth_tokens/*",
        "providers/*",
        "codex_home/*",
        "codex_child_home/*",
        "catalog/.pack_signing_key",
        "chat transcripts",
        "memory database",
    ]

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

}

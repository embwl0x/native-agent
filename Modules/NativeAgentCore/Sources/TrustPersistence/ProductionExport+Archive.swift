import Foundation
import NativeAgentShared
import TrustCenter
import PersistenceCore
import MemoryV2
import Privacy
import SystemOps
// Blueprint: | `ProductionExport+Archive.swift` | Production archives consume PrivacyMap.productionExportRelativePaths; production, support and local backup input scopes are complete allowlists with unselected scopes excluded; the backup owner's recursive copier snapshots nested memory SQLite and omits lock/journal sidecars; canonical memory backup and persona root, credential exclusions with actual skipped paths; support bundles keep their separate selection and registry rows; staging is removed on return or failure and archives use the backup owner's streaming digest |

extension ProductionExport {
    public typealias ArtifactProcessRunner = @Sendable (String, [String], URL, TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String)

    /// A data export: hardening and privacy reports, the exportable stores
    /// (memory through a consistent SQLite backup), a manifest, as one
    /// checksummed tar.gz recorded in the export registry.
    public static func createArchive<Hardening: Encodable>(
        dataRoot root: URL, runProcess: ArtifactProcessRunner,
        hardening: () async throws -> Hardening
    ) async throws -> ProductionExport {
        let now = TrustBackupPersistence.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let exportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let stageDir = exportRoot.appendingPathComponent(id, isDirectory: true)
        let archiveURL = exportRoot.appendingPathComponent("\(id)-nativeagent-export.tar.gz")

        let fm = FileManager.default
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        try TrustBackupPersistence.writeCodableJSON(try await hardening(), to: stageDir.appendingPathComponent("production_hardening.json"))
        try TrustBackupPersistence.writeCodableJSON(PrivacyMap(dataRoot: root, generatedAt: SwiftNativeManifestSigner.isoTimestamp(Date())), to: stageDir.appendingPathComponent("privacy_map.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        var excluded: [String] = []
        var copied = try TrustBackupPersistence.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: PrivacyMap.productionExportRelativePaths.filter { $0 != "memory" && $0 != "persona" },
            excluded: &excluded
        )
        // The live persona root (`defaultPersonaRoot`: a checkout's sits beside data/).
        if try TrustBackupPersistence.copyExistingItem(
            from: PersistenceCore.defaultPersonaRoot(dataRoot: root),
            to: dataDir.appendingPathComponent("persona", isDirectory: true),
            relative: "persona", excluded: &excluded
        ) {
            copied.append("persona")
        }
        let memoryDir = root.appendingPathComponent("memory", isDirectory: true)
        if fm.fileExists(atPath: memoryDir.path) {
            let destination = dataDir.appendingPathComponent("memory", isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let databaseNames: Set<String> = ["memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm", "memory.sqlite-journal"]
            for source in try fm.contentsOfDirectory(at: memoryDir, includingPropertiesForKeys: nil)
                where !databaseNames.contains(source.lastPathComponent) {
                _ = try TrustBackupPersistence.copyExistingItem(from: source, to: destination.appendingPathComponent(source.lastPathComponent),
                    relative: "memory/" + source.lastPathComponent, excluded: &excluded)
            }
            if fm.fileExists(atPath: memoryDir.appendingPathComponent("memory.sqlite").path) {
                try await MemoryStorage.createConsistentBackup(
                    dataRoot: root, destinationDatabaseURL: destination.appendingPathComponent("memory.sqlite"))
            }
            copied.append("memory")
        }
        var scope = TrustBackupPersistence.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        return try await Self.createArchive(
            id: id, kind: "export", createdAt: now, scope: scope, copied: copied, redactions: excluded,
            sourceDirectory: stageDir, archiveURL: archiveURL, registryRoot: exportRoot, runProcess: runProcess
        )
    }

    /// A support bundle: diagnostics and health plus logs-and-state paths,
    /// with transcripts and the memory database left out.
    public static func createSupportBundle<Diagnostics: Encodable, Health: Encodable>(
        dataRoot root: URL, runProcess: ArtifactProcessRunner,
        diagnostics: () async throws -> Diagnostics, health: () throws -> Health
    ) async throws -> ProductionExport {
        let now = TrustBackupPersistence.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let supportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("support", isDirectory: true)
        let exportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let stageDir = supportRoot.appendingPathComponent(id, isDirectory: true)
        let archiveURL = supportRoot.appendingPathComponent("\(id)-nativeagent-support.tar.gz")

        let fm = FileManager.default
        try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        try TrustBackupPersistence.writeCodableJSON(try await diagnostics(), to: stageDir.appendingPathComponent("support_diagnostics.json"))
        try TrustBackupPersistence.writeCodableJSON(try health(), to: stageDir.appendingPathComponent("health.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        var excluded: [String] = []
        let copied = try TrustBackupPersistence.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.supportBundleRelativePaths,
            excluded: &excluded
        )
        var scope = TrustBackupPersistence.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        return try await Self.createArchive(
            id: id, kind: "support", createdAt: now, scope: scope, copied: copied, redactions: excluded,
            sourceDirectory: stageDir, archiveURL: archiveURL, registryRoot: exportRoot, runProcess: runProcess
        )
    }


    /// Complete support copy inputs: all unselected data-root scopes are
    /// excluded. Generated diagnostics/health reports are separate inputs.
    private static let supportBundleRelativePaths: [String] = [
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

    private static func createArchive(
        id: String,
        kind: String,
        createdAt: String,
        scope: [String],
        copied: [String],
        redactions: [String],
        sourceDirectory: URL,
        archiveURL: URL,
        registryRoot: URL,
        runProcess: ArtifactProcessRunner
    ) async throws -> ProductionExport {
        let manifest: JSONValue = .object([
            "app": .string("NativeAgent"),
            "createdAt": .string(createdAt),
            "id": .string(id),
            "kind": .string(kind),
            "scope": .array(scope.map { .string($0) }),
            "copied": .array(copied.map { .string($0) }),
            "redactions": .array(redactions.map { .string($0) }),
            "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
        ])
        try TrustBackupPersistence.writeJSONValue(manifest, to: sourceDirectory.appendingPathComponent("manifest.json"))
        let result = try await runProcess(
            "/usr/bin/tar",
            ["-czf", archiveURL.path, "-C", sourceDirectory.path, "."],
            sourceDirectory.deletingLastPathComponent(),
            180
        )
        guard result.status == 0 else {
            throw NSError(domain: "NativeAgentArtifact", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "tar failed: \(SystemGitActions.processDetail(result))"
            ])
        }
        let digest = try TrustBackupPersistence.fileDigest(archiveURL)
        let record = ProductionExport(
            id: id,
            kind: kind,
            path: archiveURL.path,
            scope: scope,
            checksum: digest.sha256,
            sizeBytes: Int(digest.sizeBytes),
            createdAt: createdAt
        )
        let path = registryRoot.appendingPathComponent("registry.json")
        try await TrustBackupPersistence.appendRegistryRow(record.row, path: path, id: record.id)
        return record
    }
}

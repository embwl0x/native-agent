import Desk
import ApprovalTransactions
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
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import TrustPersistence
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

extension ProductionExport {
    /// A data export: hardening and privacy reports, the exportable stores
    /// (memory through a consistent SQLite backup), a manifest, as one
    /// checksummed tar.gz recorded in the export registry.
    static func createArchive(dataRoot root: URL) async throws -> ProductionExport {
        let now = TrustBackupPersistence.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let exportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let stageDir = exportRoot.appendingPathComponent(id, isDirectory: true)
        let archiveURL = exportRoot.appendingPathComponent("\(id)-nativeagent-export.tar.gz")

        let fm = FileManager.default
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: stageDir)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        try TrustBackupPersistence.writeCodableJSON(try await DoctorStatusProjection.getProductionHardening(dataRoot: root), to: stageDir.appendingPathComponent("production_hardening.json"))
        try TrustBackupPersistence.writeCodableJSON(PrivacyMap(dataRoot: root), to: stageDir.appendingPathComponent("privacy_map.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        var copied = try TrustBackupPersistence.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.productionExportRelativePaths.filter { $0 != "memory" }
        )
        let memoryDir = root.appendingPathComponent("memory", isDirectory: true)
        if fm.fileExists(atPath: memoryDir.path) {
            let destination = dataDir.appendingPathComponent("memory", isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let databaseNames: Set<String> = ["memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm", "memory.sqlite-journal"]
            for source in try fm.contentsOfDirectory(at: memoryDir, includingPropertiesForKeys: nil)
                where !databaseNames.contains(source.lastPathComponent) {
                _ = try TrustBackupPersistence.copyExistingItem(from: source, to: destination.appendingPathComponent(source.lastPathComponent))
            }
            if fm.fileExists(atPath: memoryDir.appendingPathComponent("memory.sqlite").path) {
                try await MemoryStorage.createConsistentBackup(
                    dataRoot: root, destinationDatabaseURL: destination.appendingPathComponent("memory.sqlite"))
            }
            copied.append("memory")
        }
        var scope = TrustBackupPersistence.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        let manifest = Self.artifactManifest(
            id: id,
            kind: "export",
            createdAt: now,
            scope: scope,
            copied: copied,
            redactions: Self.productionRedactions
        )
        try TrustBackupPersistence.writeJSONValue(manifest, to: stageDir.appendingPathComponent("manifest.json"))

        try await Self.createTarGz(sourceDirectory: stageDir, archiveURL: archiveURL)
        let checksum = try await Self.sha256Hex(ofFile: archiveURL, currentDirectory: exportRoot)
        let sizeBytes = try Self.fileSizeBytes(archiveURL)
        let record = ProductionExport(
            id: id,
            kind: "export",
            path: archiveURL.path,
            scope: scope,
            checksum: checksum,
            sizeBytes: sizeBytes,
            createdAt: now
        )
        try await Self.appendProductionExport(record, registryRoot: exportRoot)
        return record
    }

    /// A support bundle: diagnostics and health plus logs-and-state paths,
    /// with transcripts and the memory database left out.
    static func createSupportBundle(dataRoot root: URL) async throws -> ProductionExport {
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
        try? fm.removeItem(at: stageDir)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        try TrustBackupPersistence.writeCodableJSON(try await SupportDiagnostics.read(), to: stageDir.appendingPathComponent("support_diagnostics.json"))
        try TrustBackupPersistence.writeCodableJSON(DoctorFacade(dataRoot: root).readHealth(), to: stageDir.appendingPathComponent("health.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        let copied = try TrustBackupPersistence.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.supportBundleRelativePaths
        )
        var scope = TrustBackupPersistence.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        let manifest = Self.artifactManifest(
            id: id,
            kind: "support",
            createdAt: now,
            scope: scope,
            copied: copied,
            redactions: Self.supportRedactions
        )
        try TrustBackupPersistence.writeJSONValue(manifest, to: stageDir.appendingPathComponent("manifest.json"))

        try await Self.createTarGz(sourceDirectory: stageDir, archiveURL: archiveURL)
        let checksum = try await Self.sha256Hex(ofFile: archiveURL, currentDirectory: supportRoot)
        let sizeBytes = try Self.fileSizeBytes(archiveURL)
        let record = ProductionExport(
            id: id,
            kind: "support",
            path: archiveURL.path,
            scope: scope,
            checksum: checksum,
            sizeBytes: sizeBytes,
            createdAt: now
        )
        try await Self.appendProductionExport(record, registryRoot: exportRoot)
        return record
    }

    private static let productionExportRelativePaths: [String] = [
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

    private static let productionRedactions: [String] = [
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

    private static let supportRedactions: [String] = [
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

    private static func artifactManifest(
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
            "version": .string(TrustBackupHost.app.applicationVersion()),
        ])
    }

    private static func createTarGz(sourceDirectory: URL, archiveURL: URL) async throws {
        let result = try await SystemProcessAdapter.runBounded(
            executable: "/usr/bin/tar",
            arguments: ["-czf", archiveURL.path, "-C", sourceDirectory.path, "."],
            currentDirectory: sourceDirectory.deletingLastPathComponent(),
            timeout: 180
        )
        guard result.status == 0 else {
            throw NSError(domain: "NativeAgentArtifact", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "tar failed: \(SystemGitActions.processDetail(result))"
            ])
        }
    }

    private static func sha256Hex(ofFile file: URL, currentDirectory: URL) async throws -> String {
        let result = try await SystemProcessAdapter.runBounded(
            executable: "/usr/bin/shasum",
            arguments: ["-a", "256", file.path],
            currentDirectory: currentDirectory,
            timeout: 60
        )
        guard result.status == 0 else {
            throw NSError(domain: "NativeAgentArtifact", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "shasum failed: \(SystemGitActions.processDetail(result))"
            ])
        }
        guard let first = result.stdout.split(whereSeparator: \.isWhitespace).first else {
            throw NSError(domain: "NativeAgentArtifact", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "shasum returned no checksum"
            ])
        }
        return String(first)
    }

    private static func fileSizeBytes(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func appendProductionExport(_ record: ProductionExport, registryRoot: URL) async throws {
        let path = registryRoot.appendingPathComponent("registry.json")
        try await TrustBackupPersistence.appendRegistryRow(record.row, path: path, id: record.id)
    }
}

import Foundation
import NativeAgentCore

/// Durable audit projection for destructive, mounted maintenance work.
///
/// The maintenance runner writes one row for every artifact it actually
/// removed, followed by one summary row for the pass. Paths are made relative
/// to the supplied data root so the operational feed remains useful without
/// exposing an installation-specific absolute path.
public enum MaintenanceSweepFeed {
    public static func append(
        traceReport: TurnTraceRetentionReport,
        lockReport: FileLockSidecarReapReport,
        dataRoot: URL,
        completedAt: Date = Date(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async throws {
        let path = dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("maintenance_sweep.jsonl")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let timestamp = ISO8601DateFormatter().string(from: completedAt)
        // Reports capture their root-relative identity before unlink. Do not
        // canonicalize a deleted path here: Foundation can no longer resolve a
        // symlinked ancestor reliably once the leaf is gone, which used to
        // leave a truthful summary with zero removal rows.
        let traceArtifacts = traceReport.removedArtifactPaths
            .compactMap(auditRelativePath)
            .sorted()
        let sidecarArtifacts = lockReport.reapedArtifactPaths
            .compactMap(auditRelativePath)
            .sorted()

        for artifact in traceArtifacts {
            try await appendJSONLCapped(
                .object([
                    "event": .string("maintenance_sweep.removed"),
                    "source": .string("turn_trace_retention"),
                    "path": .string(artifact),
                    "completedAt": .string(timestamp),
                ]),
                to: path,
                using: persistence,
                maxLines: JSONLLineCaps.maintenanceSweep,
                logLabel: "MaintenanceSweepFeed"
            )
        }
        for artifact in sidecarArtifacts {
            try await appendJSONLCapped(
                .object([
                    "event": .string("maintenance_sweep.removed"),
                    "source": .string("file_lock_sidecar_lifecycle"),
                    "path": .string(artifact),
                    "completedAt": .string(timestamp),
                ]),
                to: path,
                using: persistence,
                maxLines: JSONLLineCaps.maintenanceSweep,
                logLabel: "MaintenanceSweepFeed"
            )
        }

        let removedTotal = traceReport.removedDays + traceReport.removedLocks + lockReport.reaped
        let summaryFields: [String: JSONValue] = [
            "event": .string("maintenance_sweep.completed"),
            "source": .string("turn_trace_retention"),
            "completedAt": .string(timestamp),
            "removed": .int(Int64(removedTotal)),
            "turnTraceDaysRemoved": .int(Int64(traceReport.removedDays)),
            "turnTraceLocksRemoved": .int(Int64(traceReport.removedLocks)),
            "orphanLockSidecarsReaped": .int(Int64(lockReport.reaped)),
            "orphanLockSidecarsDeferred": .int(Int64(lockReport.deferred)),
            "orphanLockSidecarFailures": .int(Int64(lockReport.failures)),
        ]
        let summary = JSONValue.object(summaryFields)
        try await appendJSONLCapped(
            summary,
            to: path,
            using: persistence,
            maxLines: JSONLLineCaps.maintenanceSweep,
            logLabel: "MaintenanceSweepFeed"
        )
    }

    /// Durable receipts for the app-owned compaction-backup retention pass.
    /// Kept dependency-neutral: PersistenceCore records the supplied relative
    /// paths but does not import ChatOrchestration's report type.
    public static func appendCompactionBackupRetention(
        removedArtifactPaths: [String],
        sessionsScanned: Int,
        failures: Int,
        truncated: Bool,
        dataRoot: URL,
        completedAt: Date = Date(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async throws {
        let path = dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("maintenance_sweep.jsonl")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: completedAt)
        for artifact in removedArtifactPaths.compactMap(auditRelativePath).sorted() {
            try await appendJSONLCapped(
                .object([
                    "event": .string("maintenance_sweep.removed"),
                    "source": .string("chat_compaction_backup_retention"),
                    "path": .string(artifact),
                    "completedAt": .string(timestamp),
                ]),
                to: path,
                using: persistence,
                maxLines: JSONLLineCaps.maintenanceSweep,
                logLabel: "MaintenanceSweepFeed"
            )
        }
        try await appendJSONLCapped(
            .object([
                "event": .string("maintenance_sweep.completed"),
                "source": .string("chat_compaction_backup_retention"),
                "completedAt": .string(timestamp),
                "removed": .int(Int64(removedArtifactPaths.count)),
                "sessionsScanned": .int(Int64(sessionsScanned)),
                "failures": .int(Int64(failures)),
                "truncated": .bool(truncated),
            ]),
            to: path,
            using: persistence,
            maxLines: JSONLLineCaps.maintenanceSweep,
            logLabel: "MaintenanceSweepFeed"
        )
    }

    /// Durable receipts for the mounted legacy-context compatibility cleanup.
    /// Context supplies root-relative paths so PersistenceCore does not need a
    /// dependency on the Context module's report type.
    public static func appendLegacyContextReceiptRetention(
        removedArtifactPaths: [String],
        discovered: Int,
        protected: Int,
        failedRemovals: Int,
        unavailable: Bool,
        dataRoot: URL,
        completedAt: Date = Date(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async throws {
        let path = dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("maintenance_sweep.jsonl")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: completedAt)
        let artifacts = removedArtifactPaths.compactMap(auditRelativePath).sorted()
        for artifact in artifacts {
            try await appendJSONLCapped(
                .object([
                    "event": .string("maintenance_sweep.removed"),
                    "source": .string("legacy_context_receipt_retention"),
                    "path": .string(artifact),
                    "completedAt": .string(timestamp),
                ]),
                to: path,
                using: persistence,
                maxLines: JSONLLineCaps.maintenanceSweep,
                logLabel: "MaintenanceSweepFeed"
            )
        }
        try await appendJSONLCapped(
            .object([
                "event": .string("maintenance_sweep.completed"),
                "source": .string("legacy_context_receipt_retention"),
                "completedAt": .string(timestamp),
                "removed": .int(Int64(artifacts.count)),
                "discovered": .int(Int64(max(0, discovered))),
                "protected": .int(Int64(max(0, protected))),
                "failedRemovals": .int(Int64(max(0, failedRemovals))),
                "unavailable": .bool(unavailable),
            ]),
            to: path,
            using: persistence,
            maxLines: JSONLLineCaps.maintenanceSweep,
            logLabel: "MaintenanceSweepFeed"
        )
    }

    private static func auditRelativePath(_ rawPath: String) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return nil
        }
        return components.joined(separator: "/")
    }
}

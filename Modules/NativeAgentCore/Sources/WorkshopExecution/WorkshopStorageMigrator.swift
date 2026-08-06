import Foundation

/// Durable receipt for Workshop storage repair passes.
///
/// The shape is FROZEN: receipts written by earlier builds (including the
/// retired `missions/` absorption) live on disk under
/// `workshop/migrations/` and are decoded with these exact keys. Fields the
/// surviving passes never populate stay present and empty rather than being
/// removed.
public struct WorkshopStorageMigrationReport: Codable, Equatable, Sendable {
    public let version: Int
    public let didMigrate: Bool
    public let createdAt: String
    public let archiveRelativePath: String?
    public let receiptRelativePath: String?
    public let moved: [String]
    public let deduplicated: [String]
    public let conflictsPreservedInArchive: [String]
}

/// Repairs Workshop-owned execution storage in place before any scheduler or
/// executor starts.
///
/// Two marker-gated passes remain, each running at most once per version:
/// the P2-1 record rename (`mission.json` → `execution.json`) and the A5.3
/// execution-pointer normalization. Both are idempotent and non-destructive.
///
/// De-mission P2-7: the Python-era `data/missions` absorption path is GONE.
/// It last had anything to absorb in July 2026 (receipts in
/// `workshop/migrations/`), every public release shipped Workshop-era
/// storage, and the branch was pure dead weight carrying a recursive
/// merge + tree-archive. A dataRoot that still contains `missions/` is now
/// simply IGNORED — nothing is read, moved, merged, or archived out of it.
/// The only remaining consumer of the legacy `missions.json` filename is the
/// backup-restore mapping in `NativeClient+TrustBackupOps.swift`, which lands
/// it at `workshop/legacy_executions.json` where the live readers look.
public enum WorkshopStorageMigrator {
    public static func migrateIfNeeded(
        dataRoot: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> WorkshopStorageMigrationReport {
        let workshopRoot = dataRoot.appendingPathComponent("workshop", isDirectory: true)
        let executionsRoot = workshopRoot.appendingPathComponent("executions", isDirectory: true)

        var moved: [String] = []
        var conflicts: [String] = []

        // P2-1: gated by its OWN marker, not the pointer-normalization one, so
        // an install that already stamped pointer normalization still gets
        // renamed exactly once.
        let renamed = renameExecutionRecordsIfNeeded(
            workshopRoot: workshopRoot,
            executionsRoot: executionsRoot,
            dataRoot: dataRoot,
            now: now,
            fileManager: fileManager
        )
        moved.append(contentsOf: renamed.renamed)
        conflicts.append(contentsOf: renamed.conflicts)

        // A5.3 (W5#P1-3): `normalizeExecutionPointers` used to re-enumerate
        // every execution dir and re-read every record on EVERY launch — an
        // O(all-executions) scan on the main thread. Once a full pass has run
        // for the current canonical format, a version-stamped done-marker lets
        // subsequent launches skip the rescan entirely. Live code writes new
        // executions with a canonical receipts_dir, so they never need this
        // legacy repair; bump `pointerNormalizationVersion` if the canonical
        // format changes and the stale marker is ignored so exactly one rescan
        // re-runs.
        if !pointerNormalizationCompleted(workshopRoot: workshopRoot, fileManager: fileManager) {
            moved.append(contentsOf: try normalizeExecutionPointers(
                executionsRoot: executionsRoot,
                dataRoot: dataRoot,
                fileManager: fileManager
            ))
            // Stamp only after the full pass completed — a crash before this
            // leaves the marker absent so the next launch safely re-runs.
            markPointerNormalizationCompleted(
                workshopRoot: workshopRoot, now: now, fileManager: fileManager)
        }

        guard !moved.isEmpty || !conflicts.isEmpty else {
            return WorkshopStorageMigrationReport(
                version: 1,
                didMigrate: false,
                createdAt: iso8601(now),
                archiveRelativePath: nil,
                receiptRelativePath: nil,
                moved: [],
                deduplicated: [],
                conflictsPreservedInArchive: []
            )
        }
        return try writeReport(
            dataRoot: dataRoot,
            workshopRoot: workshopRoot,
            now: now,
            moved: moved,
            conflicts: conflicts,
            fileManager: fileManager
        )
    }

    /// Canonical format version for the execution-pointer normalization pass.
    /// Bump this when the canonical `receipts_dir` shape changes so an existing
    /// done-marker is ignored and exactly one fresh rescan re-normalizes.
    static let pointerNormalizationVersion = 1

    private static func pointerNormalizationMarkerURL(workshopRoot: URL) -> URL {
        workshopRoot
            .appendingPathComponent("migrations", isDirectory: true)
            .appendingPathComponent("pointer_normalization_v\(pointerNormalizationVersion).done")
    }

    /// True once a full pointer-normalization pass has been stamped for the
    /// current `pointerNormalizationVersion`.
    static func pointerNormalizationCompleted(
        workshopRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(
            atPath: pointerNormalizationMarkerURL(workshopRoot: workshopRoot).path)
    }

    /// Durably records that a full normalization pass finished, so later
    /// launches skip the O(all-executions) rescan. Best-effort: a failed write
    /// simply means the next launch rescans (correct, just not free).
    private static func markPointerNormalizationCompleted(
        workshopRoot: URL,
        now: Date,
        fileManager: FileManager
    ) {
        let marker = pointerNormalizationMarkerURL(workshopRoot: workshopRoot)
        try? fileManager.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(iso8601(now).utf8).write(to: marker, options: .atomic)
    }

    // MARK: - P2-1 record rename (mission.json -> execution.json)

    /// Canonical format version for the per-execution record rename pass. Bump
    /// to force exactly one fresh pass (the existing marker is then ignored).
    static let recordRenameVersion = 1

    static func recordRenameMarkerURL(workshopRoot: URL) -> URL {
        workshopRoot
            .appendingPathComponent("migrations", isDirectory: true)
            .appendingPathComponent("record_rename_v\(recordRenameVersion).done")
    }

    /// True once a full record-rename pass has been stamped for the current
    /// `recordRenameVersion`.
    static func recordRenameCompleted(
        workshopRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(atPath: recordRenameMarkerURL(workshopRoot: workshopRoot).path)
    }

    /// One-time pass renaming `<execution>/mission.json` → `execution.json`.
    ///
    /// Runs at most once per `recordRenameVersion` (done-marker, same shape as
    /// `pointerNormalizationVersion`) and is stamped only AFTER the full pass
    /// completes, so a crash mid-pass leaves the marker absent and the next
    /// launch safely re-runs. Re-running is harmless: an already-renamed
    /// directory has no legacy file left to move. Directories the pass never
    /// reaches still work — every reader goes through
    /// `ExecutionRecordFile.resolve`, which falls back to the legacy name.
    ///
    /// CONFLICT (both names present): the canonical file is authoritative and
    /// is left untouched; the legacy file is preserved beside it as
    /// `mission.json.premigration-conflict` rather than deleted, and reported.
    /// Nothing is ever destroyed on this path.
    ///
    /// ORPHAN LOCKS: `withFileLock` derives its sidecar as `<target>.lock`
    /// (PersistenceCore+FileLock.swift), so a renamed record leaves a
    /// `mission.json.lock` nobody will ever open again. It is removed ONLY for
    /// directories whose record actually moved. Removing it cannot race a live
    /// holder: `migrateIfNeeded` runs synchronously inside
    /// `applicationDidFinishLaunching`, strictly before any scheduler,
    /// executor or runner exists in this process — so in-process there is no
    /// holder at all, and the acquire-then-validate-inode logic in
    /// `withFileLock` makes lock-file unlinking safe regardless.
    static func renameExecutionRecordsIfNeeded(
        workshopRoot: URL,
        executionsRoot: URL,
        dataRoot: URL,
        now: Date,
        fileManager: FileManager
    ) -> (renamed: [String], conflicts: [String]) {
        guard !recordRenameCompleted(workshopRoot: workshopRoot, fileManager: fileManager) else {
            return ([], [])
        }
        var renamed: [String] = []
        var conflicts: [String] = []
        if let executions = try? fileManager.contentsOfDirectory(
            at: executionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for execution in executions {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: execution.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let legacy = ExecutionRecordFile.legacyPath(in: execution)
                guard fileManager.fileExists(atPath: legacy.path) else { continue }
                let canonical = ExecutionRecordFile.canonicalPath(in: execution)
                // Label off the DIRECTORY, which exists on both sides of the
                // move. `relativePath` standardizes, and `standardizedFileURL`
                // only resolves symlinks (`/var` → `/private/var`) for paths
                // that exist — so labelling a file that is about to be created,
                // or one that was just moved away, silently degrades to a bare
                // filename and the receipt loses which execution it named.
                let dirLabel = relativePath(execution, under: dataRoot)
                let legacyLabel = "\(dirLabel)/\(ExecutionRecordFile.legacyName)"
                let canonicalLabel = "\(dirLabel)/\(ExecutionRecordFile.canonicalName)"
                if fileManager.fileExists(atPath: canonical.path) {
                    let aside = execution.appendingPathComponent(
                        "\(ExecutionRecordFile.legacyName).premigration-conflict")
                    guard (try? fileManager.moveItem(at: legacy, to: aside)) != nil else { continue }
                    conflicts.append(legacyLabel)
                    continue
                }
                guard (try? fileManager.moveItem(at: legacy, to: canonical)) != nil else { continue }
                renamed.append("\(legacyLabel) -> \(canonicalLabel)")
                // Only now is the legacy lock provably orphaned.
                let orphanLock = URL(fileURLWithPath: legacy.path + ".lock")
                try? fileManager.removeItem(at: orphanLock)
            }
        }
        // Stamp AFTER the full pass — a crash before this leaves the marker
        // absent so the next launch safely re-runs (same crash-safety contract
        // as the A5.3 pointer-normalization marker).
        let marker = recordRenameMarkerURL(workshopRoot: workshopRoot)
        try? fileManager.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(iso8601(now).utf8).write(to: marker, options: .atomic)
        return (renamed, conflicts)
    }

    /// Migrated records may retain the old absolute receipts directory even
    /// after their execution folder moves. Repair that pointer in-place so
    /// status/detail consumers never advertise or follow the retired root.
    private static func normalizeExecutionPointers(
        executionsRoot: URL,
        dataRoot: URL,
        fileManager: FileManager
    ) throws -> [String] {
        guard fileManager.fileExists(atPath: executionsRoot.path) else { return [] }
        var repaired: [String] = []
        for execution in try fileManager.contentsOfDirectory(
            at: executionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: execution.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let record = ExecutionRecordFile.resolve(in: execution, fileManager: fileManager)
            guard fileManager.fileExists(atPath: record.path),
                  let data = try? Data(contentsOf: record),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let canonical = execution.appendingPathComponent("receipts", isDirectory: true).path
            guard object["receipts_dir"] as? String != canonical else { continue }
            object["receipts_dir"] = canonical
            let normalized = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try normalized.write(to: record, options: .atomic)
            repaired.append("\(relativePath(record, under: dataRoot)) receipts_dir -> \(canonical)")
        }
        return repaired
    }

    /// Writes the durable receipt for a pass that changed something.
    ///
    /// `archiveRelativePath` and `deduplicated` are permanently nil/empty:
    /// both only ever described the retired `missions/` absorption. The fields
    /// (and the `missions_absorption_v1_` receipt filename) stay as-is because
    /// receipts already on disk decode through this exact shape.
    private static func writeReport(
        dataRoot: URL,
        workshopRoot: URL,
        now: Date,
        moved: [String],
        conflicts: [String],
        fileManager: FileManager
    ) throws -> WorkshopStorageMigrationReport {
        let migrationsRoot = workshopRoot.appendingPathComponent("migrations", isDirectory: true)
        try fileManager.createDirectory(at: migrationsRoot, withIntermediateDirectories: true)
        let receipt = migrationsRoot.appendingPathComponent(
            "missions_absorption_v1_\(filenameTimestamp(now)).json"
        )
        let report = WorkshopStorageMigrationReport(
            version: 1,
            didMigrate: true,
            createdAt: iso8601(now),
            archiveRelativePath: nil,
            receiptRelativePath: relativePath(receipt, under: dataRoot),
            moved: moved.sorted(),
            deduplicated: [],
            conflictsPreservedInArchive: conflicts.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: receipt, options: .atomic)
        return report
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return path == rootPath ? "." : String(path.dropFirst(rootPath.count + 1))
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}

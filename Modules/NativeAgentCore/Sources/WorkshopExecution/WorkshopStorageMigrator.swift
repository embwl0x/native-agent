import Foundation

/// Durable receipt for the one-way Workshop storage absorption.
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

/// Moves legacy execution state under Workshop ownership before any scheduler
/// or executor starts. The migration is merge-safe: existing Workshop state
/// wins, byte-identical duplicates are removed, and differing legacy files are
/// retained in the archived source tree for manual recovery.
public enum WorkshopStorageMigrator {
    public static func migrateIfNeeded(
        dataRoot: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> WorkshopStorageMigrationReport {
        let legacyRoot = dataRoot.appendingPathComponent("missions", isDirectory: true)
        let workshopRoot = dataRoot.appendingPathComponent("workshop", isDirectory: true)
        let executionsRoot = workshopRoot.appendingPathComponent("executions", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyRoot.path) else {
            // A5.3 (W5#P1-3): `normalizeExecutionPointers` used to re-enumerate
            // every execution dir and re-read every mission.json on EVERY
            // launch — an O(all-executions) scan on the main thread. Once a full
            // pass has run for the current canonical format, a version-stamped
            // done-marker lets subsequent launches skip the rescan entirely.
            // Live code writes new executions with a canonical receipts_dir, so
            // they never need this legacy repair; bump
            // `pointerNormalizationVersion` if the canonical format changes and
            // the stale marker is ignored so exactly one rescan re-runs.
            if pointerNormalizationCompleted(workshopRoot: workshopRoot, fileManager: fileManager) {
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
            let normalized = try normalizeExecutionPointers(
                executionsRoot: executionsRoot,
                dataRoot: dataRoot,
                fileManager: fileManager
            )
            // Stamp only after the full pass completed — a crash before this
            // leaves the marker absent so the next launch safely re-runs.
            markPointerNormalizationCompleted(
                workshopRoot: workshopRoot, now: now, fileManager: fileManager)
            if !normalized.isEmpty {
                return try writeReport(
                    dataRoot: dataRoot,
                    workshopRoot: workshopRoot,
                    now: now,
                    archive: nil,
                    moved: normalized,
                    deduplicated: [],
                    conflicts: [],
                    fileManager: fileManager
                )
            }
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

        try fileManager.createDirectory(at: workshopRoot, withIntermediateDirectories: true)

        var moved: [String] = []
        var deduplicated: [String] = []
        var conflicts: [String] = []

        try merge(
            source: legacyRoot.appendingPathComponent("queue", isDirectory: true),
            destination: executionsRoot,
            dataRoot: dataRoot,
            fileManager: fileManager,
            moved: &moved,
            deduplicated: &deduplicated,
            conflicts: &conflicts
        )
        try merge(
            source: legacyRoot.appendingPathComponent("missions.json"),
            destination: workshopRoot.appendingPathComponent("legacy_executions.json"),
            dataRoot: dataRoot,
            fileManager: fileManager,
            moved: &moved,
            deduplicated: &deduplicated,
            conflicts: &conflicts
        )
        try merge(
            source: legacyRoot.appendingPathComponent("triggers.json"),
            destination: workshopRoot.appendingPathComponent("triggers.json"),
            dataRoot: dataRoot,
            fileManager: fileManager,
            moved: &moved,
            deduplicated: &deduplicated,
            conflicts: &conflicts
        )
        try merge(
            source: legacyRoot.appendingPathComponent("trigger_state.json"),
            destination: workshopRoot.appendingPathComponent("trigger_state.json"),
            dataRoot: dataRoot,
            fileManager: fileManager,
            moved: &moved,
            deduplicated: &deduplicated,
            conflicts: &conflicts
        )

        // Early checkpoint builds stored these files at missions/<execution-id>/
        // instead of inside the queue directory. Fold only recognizable
        // execution-state directories into the canonical location; backups and
        // unknown artifacts remain in the archive.
        let topLevel = try fileManager.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for candidate in topLevel where isExecutionStateDirectory(candidate, fileManager: fileManager) {
            try merge(
                source: candidate,
                destination: executionsRoot.appendingPathComponent(candidate.lastPathComponent, isDirectory: true),
                dataRoot: dataRoot,
                fileManager: fileManager,
                moved: &moved,
                deduplicated: &deduplicated,
                conflicts: &conflicts
            )
        }
        moved.append(contentsOf: try normalizeExecutionPointers(
            executionsRoot: executionsRoot,
            dataRoot: dataRoot,
            fileManager: fileManager
        ))
        // The heavy migration just normalized every pointer; stamp the marker
        // so the next launch (missions/ now archived) takes the fast path
        // instead of rescanning (A5.3).
        markPointerNormalizationCompleted(
            workshopRoot: workshopRoot, now: now, fileManager: fileManager)

        let archiveRoot = dataRoot.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let archive = availableArchiveURL(
            archiveRoot: archiveRoot,
            timestamp: filenameTimestamp(now),
            fileManager: fileManager
        )
        try fileManager.moveItem(at: legacyRoot, to: archive)

        return try writeReport(
            dataRoot: dataRoot,
            workshopRoot: workshopRoot,
            now: now,
            archive: archive,
            moved: moved,
            deduplicated: deduplicated,
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
            let record = execution.appendingPathComponent("mission.json")
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

    private static func writeReport(
        dataRoot: URL,
        workshopRoot: URL,
        now: Date,
        archive: URL?,
        moved: [String],
        deduplicated: [String],
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
            archiveRelativePath: archive.map { relativePath($0, under: dataRoot) },
            receiptRelativePath: relativePath(receipt, under: dataRoot),
            moved: moved.sorted(),
            deduplicated: deduplicated.sorted(),
            conflictsPreservedInArchive: conflicts.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: receipt, options: .atomic)
        return report
    }

    private static func merge(
        source: URL,
        destination: URL,
        dataRoot: URL,
        fileManager: FileManager,
        moved: inout [String],
        deduplicated: inout [String],
        conflicts: inout [String]
    ) throws {
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else { return }

        var destinationIsDirectory: ObjCBool = false
        let destinationExists = fileManager.fileExists(
            atPath: destination.path,
            isDirectory: &destinationIsDirectory
        )
        if !destinationExists {
            let sourceRelativePath = relativePath(source, under: dataRoot)
            let destinationRelativePath = relativePath(destination, under: dataRoot)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
            moved.append("\(sourceRelativePath) -> \(destinationRelativePath)")
            return
        }

        if sourceIsDirectory.boolValue, destinationIsDirectory.boolValue {
            for child in try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) {
                try merge(
                    source: child,
                    destination: destination.appendingPathComponent(child.lastPathComponent),
                    dataRoot: dataRoot,
                    fileManager: fileManager,
                    moved: &moved,
                    deduplicated: &deduplicated,
                    conflicts: &conflicts
                )
            }
            if (try fileManager.contentsOfDirectory(atPath: source.path)).isEmpty {
                try fileManager.removeItem(at: source)
            }
            return
        }

        if !sourceIsDirectory.boolValue, !destinationIsDirectory.boolValue,
           try Data(contentsOf: source) == Data(contentsOf: destination) {
            let sourceRelativePath = relativePath(source, under: dataRoot)
            try fileManager.removeItem(at: source)
            deduplicated.append(sourceRelativePath)
            return
        }

        conflicts.append(relativePath(source, under: dataRoot))
    }

    private static func isExecutionStateDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              url.lastPathComponent != "queue",
              !url.lastPathComponent.hasPrefix("queue.bak") else { return false }
        let recognized = ["checkpoints.jsonl", "escalations.jsonl", "mission.json", "timeline.jsonl"]
        return recognized.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    private static func availableArchiveURL(
        archiveRoot: URL,
        timestamp: String,
        fileManager: FileManager
    ) -> URL {
        let base = "missions-pre-workshop-\(timestamp)"
        var candidate = archiveRoot.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = archiveRoot.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
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

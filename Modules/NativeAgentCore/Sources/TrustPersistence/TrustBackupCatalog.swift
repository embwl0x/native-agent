import Foundation
import NativeAgentShared
import PersistenceCore
import TrustCenter
import MemoryV2
import Privacy
import SystemOps
// Blueprint: | `TrustBackupCatalog.swift` | TrustBackupPersistence catalog publication and retention; writable index.json, read-only legacy registry.json, verified restore points, pins and staged dependencies |

extension TrustBackupPersistence {
    public static func diskStorageOwner(dataRoot root: URL) -> DiskStorageOwner {
        DiskStorageOwner(id: "backups", plan: {
            try backupReclamationPlan(dataRoot: root)
        }, reclaim: { saved in
            guard await nativeBackupRestoreCoordinator.acquire(dataRoot: root) else {
                throw backupError(code: 409, "A backup restore is in progress; backups were kept.")
            }
            do {
                let backupRoot = root.appendingPathComponent("backups")
                let index = backupRoot.appendingPathComponent("index.json")
                let outcomes = try await SwiftNativePersistenceCore.withFileLock(index) {
                    let fresh = try backupReclamationPlan(dataRoot: root)
                    let catalog = try readBackupCatalogChecked(index)
                    var outcomes = saved.candidates.sorted(by: { $0.key < $1.key }).map { path, token in
                        guard fresh.candidates[path] == token else {
                            return DiskStorageOwner.Outcome(relativePath: path,
                                skippedReason: "retention or restore dependencies changed; kept")
                        }
                        return DiskStorageOwner.trash(path, candidate: token, dataRoot: root)
                    }
                    let moved = Set(outcomes.filter { $0.skippedReason == nil }.map {
                        URL(fileURLWithPath: $0.relativePath).lastPathComponent
                    })
                    if !moved.isEmpty {
                        do {
                            let rows = JSONValue.array(catalog.rows.filter {
                                !moved.contains($0.objectValue?["id"]?.stringValue ?? "")
                            })
                            var value = catalog.raw
                            if case .object(var wrapper) = value { wrapper["backups"] = rows; value = .object(wrapper) }
                            else { value = rows }
                            try await SwiftNativePersistenceCore.writeJSON(value, to: index)
                        } catch {
                            outcomes.append(DiskStorageOwner.Outcome(relativePath: "backups/index.json",
                                skippedReason: "bytes reached Trash, but catalog update failed: \(error.localizedDescription)"))
                        }
                    }
                    return outcomes
                }
                await nativeBackupRestoreCoordinator.release(dataRoot: root)
                return outcomes
            } catch {
                await nativeBackupRestoreCoordinator.release(dataRoot: root)
                throw error
            }
        })
    }

    private static func backupReclamationPlan(dataRoot root: URL) throws -> DiskStorageOwner.Plan {
        let keepCount = 2
        var plan = DiskStorageOwner.Plan(owner: "backups", roots: ["backups"],
            policy: "Keep the newest two verified restore points, catalog pins and staged restore dependencies. Older registered restore points and legacy exports move to Trash; failed verification and unregistered branches stay.",
            candidates: [:])
        let backupRoot = root.appendingPathComponent("backups")
        guard pathEntryExists(backupRoot) else { return plan }
        try requireRegularDirectory(backupRoot)
        var records: [String: (record: BackupRecord, date: Date)] = [:]
        var pinned: Set<String> = []
        for name in ["registry.json", "index.json"] {
            let catalog = try readBackupCatalogChecked(backupRoot.appendingPathComponent(name))
            for row in catalog.rows {
                guard let id = row.objectValue?["id"]?.stringValue, UUID(uuidString: id)?.uuidString.lowercased() == id,
                      case .object(let object) = row else {
                    throw backupError(code: 422, "Backup catalog has an invalid identity; backups were kept.")
                }
                if let pin = object["pinned"] {
                    guard case .bool(let value) = pin else {
                        throw backupError(code: 422, "Backup catalog pin is invalid; backups were kept.")
                    }
                    if value { pinned.insert(id) }
                }
            }
            for record in catalog.records {
                guard let date = NativeTimestampFormat.parseISO8601(record.createdAt) else {
                    throw backupError(code: 422, "Backup catalog date is invalid; backups were kept.")
                }
                records[record.id] = (record, date)
            }
        }
        let intentPath = backupRestoreIntentPath(dataRoot: root)
        if pathEntryExists(intentPath) {
            let intent = try readRestoreIntent(at: intentPath)
            pinned.insert(intent.targetID)
            if let id = intent.safetyBackupID { pinned.insert(id) }
        }
        let ordered = records.values.sorted {
            $0.date == $1.date ? $0.record.id < $1.record.id : $0.date > $1.date
        }.map(\.record)
        var verified: [String] = []
        var invalid: Set<String> = []
        for record in ordered {
            let manifest = backupRoot.appendingPathComponent(record.id).appendingPathComponent("manifest.json")
            guard pathEntryExists(manifest) else { continue }
            do {
                let snapshot = try validateBackupSnapshot(id: record.id, dataRoot: root)
                guard snapshot.createdAt == record.createdAt else {
                    throw backupError(code: 422, "Catalog and snapshot dates differ.")
                }
                verified.append(record.id)
            } catch {
                invalid.insert(record.id)
                plan.notes.append("\(record.id) kept: restore verification failed (\(error.localizedDescription)).")
            }
        }
        guard verified.count >= keepCount else {
            plan.notes.append("No backup reclamation: \(verified.count) verified restore points; two are required before retiring older backups. Create verified backups using backup.now.")
            return plan
        }
        pinned.formUnion(verified.prefix(keepCount))
        for record in ordered where !pinned.contains(record.id) && !invalid.contains(record.id) {
            guard let cutoff = records[verified[keepCount - 1]]?.date,
                  let date = records[record.id]?.date, date < cutoff else { continue }
            let path = "backups/\(record.id)"
            guard pathEntryExists(root.appendingPathComponent(path)) else { continue }
            try requireRegularDirectory(root.appendingPathComponent(path))
            plan.candidates[path] = try DiskStorageOwner.candidate(path, dataRoot: root)
        }
        return plan
    }

    static func appendBackupRecord(_ record: BackupRecord, backupRoot: URL) async throws {
        // Only the index is published. The registry remains read-only legacy input.
        try await appendRegistryRow(Self.backupRecordJSON(record), path: backupRoot.appendingPathComponent("index.json"), id: record.id, maxRows: nil, isBackupCatalog: true)
    }

    public static func appendRegistryRow(_ row: JSONValue, path: URL, id: String, maxRows: Int? = 200) async throws {
        try await appendRegistryRow(row, path: path, id: id, maxRows: maxRows, isBackupCatalog: false)
    }

    private static func appendRegistryRow(_ row: JSONValue, path: URL, id: String, maxRows: Int?, isBackupCatalog: Bool) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            // Only absent registries bootstrap; unreadable or malformed existing bytes stay intact.
            let existing: [JSONValue]
            // A backup catalog may wrap its rows ({backups, ...}): only its rows change.
            var wrapper: [String: JSONValue]?
            if isBackupCatalog {
                let catalog = try Self.readBackupCatalogChecked(path)
                existing = catalog.rows
                if case .object(let object) = catalog.raw { wrapper = object }
            } else {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else {
                        throw NSError(domain: "NativeAgentBackup", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Registry must be a regular file."
                        ])
                    }
                    let raw = try JSONValue.parse(Data(contentsOf: path))
                    guard case .array(let rows) = raw else {
                        throw NSError(domain: "NativeAgentBackup", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Registry must contain an array."
                        ])
                    }
                    existing = rows
                } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError {
                    existing = []
                }
            }
            var rows = existing.filter { $0.objectValue?["id"]?.stringValue != id }
            rows.append(row)
            if let maxRows, rows.count > maxRows {
                rows = Array(rows.suffix(maxRows))
            }
            if var wrapper {
                wrapper["backups"] = .array(rows)
                try await SwiftNativePersistenceCore.writeJSON(.object(wrapper), to: path)
            } else {
                try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: path)
            }
        }
    }

    public static func readBackupRecords(root: URL) throws -> [BackupRecord] {
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        var byId: [String: BackupRecord] = [:]
        let fm = FileManager.default
        for name in ["registry.json", "index.json"] {
            let path = backupRoot.appendingPathComponent(name)
            for record in try readBackupRecordsFile(path) {
                var normalized = record
                let localBackupDir = backupRoot.appendingPathComponent(record.id, isDirectory: true)
                if path.lastPathComponent == "registry.json",
                   !fm.fileExists(atPath: localBackupDir.path), !fm.fileExists(atPath: record.path) { continue }
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

    private static func readBackupRecordsFile(_ path: URL) throws -> [BackupRecord] {
        try Self.readBackupCatalogChecked(path).records
    }

    private static func readBackupCatalogChecked(_ path: URL) throws
        -> (rows: [JSONValue], records: [BackupRecord], raw: JSONValue)
    {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw Self.backupError(code: 422, "Backup catalog is malformed: \(path.lastPathComponent)")
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return ([], [], .array([]))
        }
        let raw = try JSONValue.parse(Data(contentsOf: path))
        let rows: [JSONValue]
        switch raw {
        case .array(let values): rows = values
        case .object(let object):
            guard case .array(let values)? = object["backups"] else {
                throw Self.backupError(code: 422, "Backup catalog is malformed: \(path.lastPathComponent)")
            }
            rows = values
        default:
            throw Self.backupError(code: 422, "Backup catalog is malformed: \(path.lastPathComponent)")
        }
        let records = try JSONDecoder.nativeAgent.decode(
            [BackupRecord].self,
            from: JSONValue.array(rows).serializedData(pretty: false)
        )
        return (rows, records, raw)
    }

    private static func backupRecordJSON(_ record: BackupRecord) -> JSONValue {
        .object([
            "id": .string(record.id),
            "reason": .string(record.reason),
            "scope": .array(record.scope.map { .string($0) }),
            "path": .string(record.path),
            "createdAt": .string(record.createdAt),
        ])
    }
}

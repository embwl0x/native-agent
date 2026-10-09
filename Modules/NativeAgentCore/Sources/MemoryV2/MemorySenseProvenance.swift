import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
import Senses

/// Descriptive provenance only: warning does not erase or retire the memory.
public enum MemorySenseProvenance {
    public static let warning = "from a sense version later found wrong"
    public static func warning(in metadata: JSONValue?) -> String? {
        guard case .object(let object)? = metadata,
              object["sense_version_later_wrong"] == .bool(true) else { return nil }
        return warning
    }

    static func stamping(_ metadata: JSONValue?) throws -> JSONValue? {
        guard let reads = try SenseTurnReads.current?.snapshot(), !reads.isEmpty else { return metadata }
        var object: [String: JSONValue] = [:]
        if case .object(let value)? = metadata { object = value }
        var versions: [JSONValue] = []
        if case .array(let value)? = object["sense_versions"] { versions = value }
        for read in reads {
            let entry = JSONValue.object(["sense_id": .string(read.senseID), "version": .int(Int64(read.version))])
            if !versions.contains(entry) { versions.append(entry) }
        }
        object["sense_versions"] = .array(versions)
        return .object(object)
    }

    static func merging(existing: JSONValue?, incoming: JSONValue?) -> [String: JSONValue] {
        guard case .object(let new)? = incoming, case .array(let added)? = new["sense_versions"] else { return [:] }
        var versions: [JSONValue] = []
        if case .object(let old)? = existing, case .array(let saved)? = old["sense_versions"] { versions = saved }
        for entry in added where !versions.contains(entry) { versions.append(entry) }
        return ["sense_versions": .array(versions)]
    }

    static func preserving(existing: JSONValue?, incoming: JSONValue?) throws -> JSONValue? {
        guard case .object(let old)? = existing,
              old["sense_versions"] != nil || old["sense_version_later_wrong"] == .bool(true) else { return incoming }
        guard case .object(var metadata)? = incoming else {
            throw MemoryStorageError.databaseUnavailable("memory metadata replacement must retain sense provenance")
        }
        for (key, value) in merging(existing: incoming, incoming: existing) { metadata[key] = value }
        if old["sense_version_later_wrong"] == .bool(true) { metadata["sense_version_later_wrong"] = .bool(true) }
        return .object(metadata)
    }
}

extension MemoryStorage: SenseMemoryProvenanceSink {
    public func markVersionWrong(senseID: String, version: Int) async throws {
        guard !senseID.isEmpty, version > 0 else {
            throw SenseFailure(code: "bad_provenance", message: "Cannot flag memories: sense id and positive version are required.")
        }
        let changed = try await dbPool.write { db -> [StoredMemory] in
            try db.execute(sql: "INSERT OR IGNORE INTO memory_wrong_sense_versions (sense_id, version) VALUES (?, ?)", arguments: [senseID, version])
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM memories WHERE EXISTS (
                  SELECT 1 FROM json_each(memories.metadata_json, '$.sense_versions') ref
                  WHERE json_extract(ref.value, '$.sense_id') = ?
                    AND json_extract(ref.value, '$.version') = ?
                ) AND COALESCE(json_extract(metadata_json, '$.sense_version_later_wrong'), 0) != 1
                """, arguments: [senseID, version]).map(Self.decodeMemory)
            return try rows.map { row in
                var row = row
                guard case .object(var metadata)? = row.metadata else {
                    throw MemoryStorageError.databaseUnavailable("sense provenance metadata is not an object")
                }
                metadata["sense_version_later_wrong"] = .bool(true)
                row.metadata = .object(metadata)
                try db.execute(sql: "UPDATE memories SET metadata_json = ? WHERE id = ?", arguments: [Self.encodeMetadata(row.metadata), row.id])
                return row
            }
        }
        invalidateRecallCache()
        try await refreshProjectionHooks(ids: changed.map(\.id))
        await DerivedStateInvalidationCenter.shared.flush()
    }
}

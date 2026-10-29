import CryptoKit
import Foundation
import GRDB
// Blueprint: | `MemoryStorage+Integrity.swift` | `MemoryStorage`: `requireSemanticIntegrity`, `spotlightSnapshot` returns eligible exported items and their fingerprint; `createConsistentBackup` |

extension MemoryStorage {
    /// Validate the semantic payloads SQLite itself cannot type-check. SQLite's
    /// structural integrity checks do not notice a damaged JSON string or an
    /// embedding blob whose byte count is no longer a multiple of Float32.
    /// Treating those values as nil would make a canonical fact look healthy
    /// after silently dropping evidence, provenance, or recall capability.
    ///
    /// The queries are index-independent and stop at the first bad row. The
    /// canonical memory table is already hard-bounded; the companion tables are
    /// checked with SQL predicates rather than materialized in Swift.
    static func requireSemanticIntegrity(in db: Database) throws {
        // SQLite permits NULL in a TEXT PRIMARY KEY. Check required scalars
        // before launch consumers can reach a row subscript that traps.
        let memories = try Row.fetchCursor(db, sql: "SELECT * FROM memories")
        while let row = try memories.next() {
            _ = try decodeMemory(row)
        }
        let proposals = try Row.fetchCursor(db, sql: "SELECT * FROM proposals")
        while let row = try proposals.next() {
            _ = try decodeProposal(row)
        }
        let tombstones = try Row.fetchCursor(db, sql: "SELECT content_hash, content, rejected_at FROM tombstones")
        while let row = try tombstones.next() {
            let _: String = try row.decode(forColumn: "content_hash")
            let _: String = try row.decode(forColumn: "content")
            let _: String = try row.decode(forColumn: "rejected_at")
        }
        let entities = try Row.fetchCursor(db, sql: "SELECT rowid, id, name, type, mention_count FROM kg_entities")
        while let row = try entities.next() {
            do {
                let _: String = try row.decode(forColumn: "id")
                let _: String = try row.decode(forColumn: "name")
                let _: String = try row.decode(forColumn: "type")
                let _: Int64? = try row.decode(forColumn: "mention_count")
            } catch {
                let rowID: Int64 = try row.decode(forColumn: "rowid")
                throw MemoryStorageError.databaseUnavailable("semantic integrity failed: kg_entities row \(rowID): \(error)")
            }
        }
        let relationships = try Row.fetchCursor(db, sql: "SELECT id, from_id, to_id, type, mention_count FROM kg_relationships")
        while let row = try relationships.next() {
            let id: Int64 = try row.decode(forColumn: "id")
            do {
                let _: String = try row.decode(forColumn: "from_id")
                let _: String = try row.decode(forColumn: "to_id")
                let _: String = try row.decode(forColumn: "type")
                let _: Int64? = try row.decode(forColumn: "mention_count")
            } catch {
                throw MemoryStorageError.databaseUnavailable("semantic integrity failed: kg_relationships row \(id): \(error)")
            }
        }
        for table in ["kg_entities", "kg_relationships"] {
            if let rowID = try Int64.fetchOne(db, sql: """
                SELECT rowid FROM \(table) WHERE mention_count IS NOT NULL
                    AND typeof(mention_count) != 'integer' LIMIT 1
                """) {
                throw MemoryStorageError.databaseUnavailable("semantic integrity failed: \(table) row \(rowID) has a noninteger mention_count")
            }
        }
        let jsonColumns: [(table: String, id: String, column: String)] = [
            ("memories", "id", "metadata_json"),
            ("memories", "id", "evidence_json"),
            ("proposals", "id", "metadata_json"),
            ("kg_entities", "id", "aliases_json"),
            ("kg_entities", "id", "metadata_json"),
            ("kg_relationships", "CAST(id AS TEXT)", "metadata_json"),
        ]
        for field in jsonColumns {
            let sql = """
                SELECT \(field.id) FROM \(field.table)
                WHERE \(field.column) IS NOT NULL
                  AND json_valid(\(field.column)) = 0
                LIMIT 1
                """
            if let id = try String.fetchOne(db, sql: sql) {
                throw MemoryStorageError.databaseUnavailable(
                    "semantic integrity failed: \(field.table).\(field.column) is malformed for row \(id)"
                )
            }
        }

        let blobColumns: [(table: String, id: String, column: String)] = [
            ("memories", "id", "embedding"),
            ("proposals", "id", "embedding"),
            ("tombstones", "content_hash", "embedding"),
        ]
        for field in blobColumns {
            let sql = """
                SELECT \(field.id) FROM \(field.table)
                WHERE \(field.column) IS NOT NULL
                  AND (typeof(\(field.column)) != 'blob'
                       OR length(\(field.column)) = 0
                       OR length(\(field.column)) % 4 != 0)
                LIMIT 1
                """
            if let id = try String.fetchOne(db, sql: sql) {
                throw MemoryStorageError.databaseUnavailable(
                    "semantic integrity failed: \(field.table).\(field.column) has invalid Float32 bytes for row \(id)"
                )
            }
        }

        // An epoch names one immutable vector space, so every row bearing the
        // same non-legacy epoch must have the same byte width. A 4-byte blob is
        // structurally decodable but is still semantic corruption beside the
        // 384-dimensional rows in that epoch; recall would otherwise skip it
        // silently on every query-dimension check.
        if let epoch = try String.fetchOne(db, sql: """
            SELECT epoch FROM (
                SELECT embedding_epoch AS epoch, length(embedding) AS bytes
                FROM memories WHERE embedding IS NOT NULL AND embedding_epoch IS NOT NULL
                UNION ALL
                SELECT embedding_epoch AS epoch, length(embedding) AS bytes
                FROM proposals WHERE embedding IS NOT NULL AND embedding_epoch IS NOT NULL
                UNION ALL
                SELECT embedding_epoch AS epoch, length(embedding) AS bytes
                FROM tombstones WHERE embedding IS NOT NULL AND embedding_epoch IS NOT NULL
            )
            GROUP BY epoch
            HAVING MIN(bytes) != MAX(bytes)
            LIMIT 1
            """) {
            throw MemoryStorageError.databaseUnavailable(
                "semantic integrity failed: embedding epoch \(epoch) has mixed vector dimensions"
            )
        }
    }

    /// Re-run the open-time semantic audit for Doctor, backup validation, and
    /// focused repair workflows without creating another MemoryV2 owner.
    public func requireSemanticIntegrity() async throws {
        try await dbPool.read { db in
            try Self.requireSemanticIntegrity(in: db)
        }
    }

    /// The exact exported Spotlight items and their ID-ordered fingerprint.
    public func spotlightSnapshot() async throws -> (items: [SpotlightItem], fingerprint: String) {
        try await dbPool.read { db in
            var hasher = SHA256()
            var items: [SpotlightItem] = []
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, content, status FROM memories
                WHERE status = 'active' AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                    AND json_extract(metadata_json, '$.\(Self.pendingAdmissionKey)') IS NOT 1
                ORDER BY id
                """)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            while let row = try rows.next() {
                let item = SwiftNativeMemoryIndexer.makeItem(
                    id: try row.decode(forColumn: "id"),
                    text: try row.decode(forColumn: "content"),
                    kind: try row.decode(forColumn: "status"))
                hasher.update(data: try encoder.encode(item))
                items.append(item)
            }
            return (items, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    /// Create one transactionally coherent copy of the canonical MemoryV2
    /// database for app backups. Default-root callers are routed through the
    /// exact storage actor beneath `SwiftNativeMemoryV2.shared`; alternate roots
    /// stay isolated. The destination is verified before this method returns, so
    /// a caller never seals a byte-consistent but unreadable SQLite artifact.
    public static func createConsistentBackup(
        dataRoot: URL,
        destinationDatabaseURL destination: URL
    ) async throws {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        try await storage.createConsistentBackup(destinationDatabaseURL: destination)
    }

    public func createConsistentBackup(destinationDatabaseURL destination: URL) throws {
        let normalizedSource = path.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard normalizedSource.path != normalizedDestination.path else {
            throw MemoryStorageError.databaseUnavailable(
                "consistent-backup destination must differ from the live database"
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MemoryStorageError.databaseUnavailable(
                "consistent-backup destination already exists"
            )
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var completed = false
        defer {
            if !completed {
                for candidate in [
                    destination,
                    URL(fileURLWithPath: destination.path + "-wal"),
                    URL(fileURLWithPath: destination.path + "-shm"),
                ] {
                    try? FileManager.default.removeItem(at: candidate)
                }
            }
        }
        var destinationConfiguration = Configuration()
        destinationConfiguration.busyMode = .timeout(5)
        let destinationQueue = try DatabaseQueue(
            path: destination.path,
            configuration: destinationConfiguration
        )
        do {
            try dbPool.backup(to: destinationQueue)
            try destinationQueue.read { db in
                let quickCheck = try String.fetchAll(db, sql: "PRAGMA quick_check")
                guard quickCheck == ["ok"] else {
                    throw MemoryStorageError.databaseUnavailable(
                        "consistent-backup quick_check failed: \(quickCheck.joined(separator: "; "))"
                    )
                }
                try Self.requireSemanticIntegrity(in: db)
            }
            try destinationQueue.close()
        } catch {
            try? destinationQueue.close()
            throw error
        }
        // Verification may open transient WAL/SHM sidecars on the destination.
        // They are not part of the coherent online-backup artifact; remove them
        // only after the verifying connection is closed.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        completed = true
    }

}

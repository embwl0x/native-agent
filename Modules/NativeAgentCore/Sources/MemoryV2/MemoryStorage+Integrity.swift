import Foundation
import GRDB

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
            ("memory_embedding_previous", "kind || ':' || row_id", "embedding"),
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
                UNION ALL
                SELECT embedding_epoch AS epoch, length(embedding) AS bytes
                FROM memory_embedding_previous
                WHERE embedding IS NOT NULL AND embedding_epoch IS NOT NULL
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

    /// Stable canonical generation for rebuildable memory projections. Recall
    /// counters are deliberately excluded by the consolidation fingerprint, so
    /// ordinary reads do not force Spotlight/USER/KG reconciliation.
    public func projectionGenerationFingerprint() async throws -> String {
        try await dbPool.read { db in
            try MemoryConsolidationGate.fingerprint(in: db)
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

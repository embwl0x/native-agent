// EVAL FENCE: core.persistence / memory.schemaOwnership
//
// Ledger row: memory.schemaOwnership (stable-failure #4 root cause,
// Desk 751.7, authorized by User 2026-08-27).
//
// For every store MemoryStorage creates, the kg_* tables have exactly ONE
// schema owner: MemoryStorage's migrator
// (migration `v2_knowledge_graph`). Historically the KnowledgeGraph side could
// win a race on a fresh path: the indexer's create-on-missing fallback opened a
// bare DatabasePool (creating memory.sqlite with NO grdb_migrations ledger) and
// the pool cache's ensureSchema then created kg_* via IF NOT EXISTS. The next
// MemoryStorage init replayed migrations from v1 against that file and the bare
// `CREATE TABLE kg_entities` threw "table already exists", bricking the whole
// migration chain — a real fresh-install hazard, not test trivia.
//
// These evals pin the settled contract from both directions:
//   1. graph-first on a fresh root must NOT brick a later MemoryStorage init —
//      because the graph layer now refuses to create the store at all.
//   2. storage-first stays green and the store carries the migrator's ledger.

import Foundation
import GRDB
import Testing
@testable import KnowledgeGraph
@testable import MemoryV2

@Suite("memory.schemaOwnership — single schema owner")
struct SchemaOwnershipEvalTests {

    private func freshRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sqlitePath(_ root: URL) -> URL {
        root.appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }

    @Test("graph-first on a fresh root cannot produce a store that bricks MemoryStorage migrations")
    func graphFirstFreshRoot_thenMemoryStorageInit_succeeds() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = sqlitePath(root)

        // Graph writer arrives first on a fresh path. Under the settled
        // contract it must FAIL LOUD (no store to index into) rather than
        // create a ledger-less database.
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
        await #expect(throws: (any Error).self) {
            try await indexer.indexMemory(
                KnowledgeGraphMemoryFact(id: "m1", content: "graph-first probe", createdAt: "2026-08-27T12:00:00Z", updatedAt: "2026-08-27T12:00:00Z")
            )
        }
        #expect(
            !FileManager.default.fileExists(atPath: sqlite.path),
            "the graph layer must never create memory.sqlite — that file would have no migration ledger"
        )

        // The real owner initializes the store; the full migration chain must
        // apply cleanly — this is the exact path that bricked before the fix.
        let storage = try MemoryStorage(dataRoot: root)
        _ = storage

        // And the graph layer now works against the migrated store.
        try await indexer.indexMemory(
            KnowledgeGraphMemoryFact(id: "m2", content: "post-migration index", createdAt: "2026-08-27T12:00:00Z", updatedAt: "2026-08-27T12:00:00Z")
        )
    }

    @Test("a wild ledger-less graph-created store is adopted, not bricked")
    func wildLedgerlessGraphStore_isAdoptedByMemoryStorageInit() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = sqlitePath(root)
        try FileManager.default.createDirectory(
            at: sqlite.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Reproduce EXACTLY what the pre-fix bug left on disk: a bare file
        // with the v2-shape kg tables and zero grdb_migrations rows.
        let bare = try DatabasePool(path: sqlite.path)
        try await bare.write { db in
            try db.execute(sql: """
                CREATE TABLE kg_entities (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL,
                  type TEXT NOT NULL DEFAULT 'concept', summary TEXT,
                  aliases_json TEXT, mention_count INTEGER DEFAULT 0,
                  first_seen TEXT, last_seen TEXT, provenance TEXT,
                  metadata_json TEXT
                );
                CREATE TABLE kg_relationships (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  from_id TEXT NOT NULL, to_id TEXT NOT NULL,
                  type TEXT NOT NULL, weight REAL,
                  mention_count INTEGER DEFAULT 0, provenance TEXT,
                  metadata_json TEXT, UNIQUE(from_id, to_id, type)
                );
                CREATE TABLE kg_memory_index (
                  memory_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL,
                  indexed_at TEXT NOT NULL, index_version TEXT NOT NULL
                );
                INSERT INTO kg_entities (id, name) VALUES ('e1', 'Survivor');
                """)
        }

        // Pre-fix this init threw "table kg_entities already exists" and the
        // store was bricked forever. Adoption stamps v2 and migrates the rest.
        _ = try MemoryStorage(dataRoot: root)

        let pool = try DatabasePool(path: sqlite.path)
        let (identifiers, survivors) = try await pool.read { db in
            (try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities") ?? 0)
        }
        #expect(identifiers.contains("v1_initial"))
        #expect(identifiers.contains("v2_knowledge_graph"))
        #expect(identifiers.contains("v8_kg_memory_index"))
        #expect(survivors == 1, "adoption must preserve existing graph rows")
    }

    @Test("a mismatched wild store is NOT silently adopted — it still fails loud")
    func mismatchedWildStore_staysLoud() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = sqlitePath(root)
        try FileManager.default.createDirectory(
            at: sqlite.deletingLastPathComponent(), withIntermediateDirectories: true)

        // kg_entities with a WRONG shape (missing columns): the adoption guard
        // must refuse to stamp, so migrate() collides and throws — loud, never
        // a silent guess about a store we do not recognize.
        let bare = try DatabasePool(path: sqlite.path)
        try await bare.write { db in
            try db.execute(sql: "CREATE TABLE kg_entities (id TEXT PRIMARY KEY, name TEXT); CREATE TABLE kg_relationships (id INTEGER PRIMARY KEY);")
        }
        #expect(throws: (any Error).self) {
            _ = try MemoryStorage(dataRoot: root)
        }
    }

    @Test("storage-first stays green and the store carries the migrator ledger")
    func storageFirst_thenGraph_succeeds_andLedgerIsComplete() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = sqlitePath(root)

        _ = try MemoryStorage(dataRoot: root)
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
        try await indexer.indexMemory(
            KnowledgeGraphMemoryFact(id: "m1", content: "storage-first probe", createdAt: "2026-08-27T12:00:00Z", updatedAt: "2026-08-27T12:00:00Z")
        )

        // The migration ledger must be complete — a store the graph touched
        // first would have an empty grdb_migrations table.
        let pool = try DatabasePool(path: sqlite.path)
        let identifiers = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(identifiers.contains("v2_knowledge_graph"))
        #expect(
            identifiers.contains("v8_kg_memory_index"),
            "store must carry the migrator's full ledger, not a bare ensureSchema footprint"
        )
    }
}

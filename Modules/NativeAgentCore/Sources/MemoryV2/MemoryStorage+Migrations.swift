import Foundation
import GRDB

extension MemoryStorage {
    // MARK: - Migrator

    /// One-time adoption of stores poisoned by the pre-2026-08-27 graph-first
    /// bug (stable-failure #4 / Desk 751.7): the KnowledgeGraph side could
    /// create memory.sqlite itself — kg tables present, zero grdb_migrations
    /// rows — and replaying v2_knowledge_graph against those tables bricked
    /// the whole migration chain on the next open. Stamp v2 as applied ONLY
    /// when the ledger has no applied migrations, the memories table is absent
    /// (v1 never ran, so this cannot be a real migrated store), and both kg
    /// tables match the v2 shape column-for-column. Any other shape is left
    /// untouched so migrate() fails loud rather than guessing (gpt-5.5 review
    /// 2026-08-27: stamp only on exact match, otherwise stay loud).
    static func adoptLedgerlessGraphStoreIfNeeded(_ pool: DatabasePool) throws {
        try pool.write { db in
            let applied = (try? Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM grdb_migrations")) ?? 0
            guard applied == 0 else { return }
            guard try !db.tableExists("memories"),
                  try db.tableExists("kg_entities"),
                  try db.tableExists("kg_relationships") else { return }
            func columns(_ table: String) throws -> [String] {
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
            }
            let v2Entities = [
                "id", "name", "type", "summary", "aliases_json",
                "mention_count", "first_seen", "last_seen",
                "provenance", "metadata_json",
            ]
            let v2Relationships = [
                "id", "from_id", "to_id", "type", "weight",
                "mention_count", "provenance", "metadata_json",
            ]
            guard try columns("kg_entities") == v2Entities,
                  try columns("kg_relationships") == v2Relationships else { return }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS grdb_migrations (
                  identifier TEXT NOT NULL PRIMARY KEY
                )
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO grdb_migrations (identifier)
                VALUES ('v2_knowledge_graph')
                """)
        }
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE memories (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  persona_id TEXT NOT NULL DEFAULT 'NativeAgent',
                  source TEXT,
                  confidence REAL DEFAULT 1.0,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  embedding BLOB,
                  status TEXT NOT NULL DEFAULT 'active',
                  metadata_json TEXT
                );
                CREATE INDEX idx_memories_persona ON memories(persona_id, status);
                CREATE INDEX idx_memories_created ON memories(created_at);
                CREATE INDEX idx_memories_source ON memories(source);

                CREATE TABLE proposals (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  persona_id TEXT NOT NULL DEFAULT 'NativeAgent',
                  source TEXT,
                  staged_at TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'pending',
                  resolved_at TEXT,
                  rejection_reason TEXT,
                  embedding BLOB,
                  metadata_json TEXT
                );
                CREATE INDEX idx_proposals_status ON proposals(status, staged_at);

                CREATE TABLE tombstones (
                  content_hash TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  rejected_at TEXT NOT NULL,
                  reason TEXT
                );
                CREATE INDEX idx_tombstones_rejected ON tombstones(rejected_at);
            """)
        }
        m.registerMigration("v2_knowledge_graph") { db in
            try db.execute(sql: """
                CREATE TABLE kg_entities (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  type TEXT NOT NULL DEFAULT 'concept',
                  summary TEXT,
                  aliases_json TEXT,
                  mention_count INTEGER DEFAULT 0,
                  first_seen TEXT,
                  last_seen TEXT,
                  provenance TEXT,
                  metadata_json TEXT
                );
                CREATE INDEX idx_kg_entities_type ON kg_entities(type);
                CREATE INDEX idx_kg_entities_last_seen ON kg_entities(last_seen);

                CREATE TABLE kg_relationships (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  from_id TEXT NOT NULL,
                  to_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  weight REAL,
                  mention_count INTEGER DEFAULT 0,
                  provenance TEXT,
                  metadata_json TEXT,
                  UNIQUE(from_id, to_id, type)
                );
                CREATE INDEX idx_kg_rel_from ON kg_relationships(from_id);
                CREATE INDEX idx_kg_rel_to ON kg_relationships(to_id);
            """)
        }
        // v3 (2026-06-09): recall access counters. Additive — existing rows
        // default to use_count 0 / last_used_at NULL, so old code that ignores
        // these columns is unaffected. `use_count` is a real column (not
        // metadata JSON) so recall can increment it atomically without a
        // read-modify-write race under concurrent recalls. See the
        // memory-recall-correctness build plan (#0).
        m.registerMigration("v3_recall_counters") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE memories ADD COLUMN last_used_at TEXT;
                CREATE INDEX idx_memories_last_used ON memories(last_used_at);
            """)
        }
        // v4 (2026-06-09): semantic tombstones. Additive nullable column —
        // legacy tombstone rows keep NULL and remain exact-hash-only; new
        // tombstones store the claim's embedding so paraphrases of a deleted
        // claim can be blocked (memory-semantics-wave1, lane T).
        m.registerMigration("v4_tombstone_embeddings") { db in
            try db.execute(sql: "ALTER TABLE tombstones ADD COLUMN embedding BLOB;")
        }
        // v5 (2026-06-20): explicit lifecycle/confidence hygiene. `status`
        // remains the coarse storage state (active/archived); lifecycle carries
        // fact quality: confirmed, temporary, inferred, stale, corrected,
        // contradicted, or deleted. Additive default keeps legacy rows confirmed.
        m.registerMigration("v5_memory_lifecycle") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'confirmed';
                CREATE INDEX idx_memories_lifecycle ON memories(lifecycle);
            """)
        }
        // v6 (2026-07-14): vector-space identity. Legacy vectors remain
        // nullable/unverified until a full-corpus candidate is embedded and
        // atomically activated; migration never guesses their provenance.
        m.registerMigration("v6_embedding_epochs") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN embedding_epoch TEXT;
                ALTER TABLE proposals ADD COLUMN embedding_epoch TEXT;
                ALTER TABLE tombstones ADD COLUMN embedding_epoch TEXT;
                CREATE INDEX idx_memories_embedding_epoch ON memories(embedding_epoch);
                CREATE INDEX idx_proposals_embedding_epoch ON proposals(embedding_epoch);
                CREATE INDEX idx_tombstones_embedding_epoch ON tombstones(embedding_epoch);

                CREATE TABLE memory_embedding_state (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  active_epoch TEXT,
                  previous_epoch TEXT,
                  activated_at TEXT,
                  rollback_available INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO memory_embedding_state (id) VALUES (1);

                CREATE TABLE memory_embedding_previous (
                  kind TEXT NOT NULL,
                  row_id TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  embedding BLOB,
                  embedding_epoch TEXT,
                  PRIMARY KEY (kind, row_id)
                );
            """)
        }
        // v7: nullable temporal validity and evidence lineage. Additive only;
        // no historical row is assigned invented dates or evidence.
        m.registerMigration("v7_temporal_evidence") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN valid_from TEXT;
                ALTER TABLE memories ADD COLUMN valid_to TEXT;
                ALTER TABLE memories ADD COLUMN observed_at TEXT;
                ALTER TABLE memories ADD COLUMN evidence_json TEXT;
                CREATE INDEX idx_memories_valid_from ON memories(valid_from);
                CREATE INDEX idx_memories_valid_to ON memories(valid_to);
                CREATE INDEX idx_memories_observed_at ON memories(observed_at);
            """)
        }
        // v8 (2026-08-27): adopt kg_memory_index into the migrator, making the
        // migration lineage the SINGLE owner of every kg_* table. This table
        // was historically created only by the KnowledgeGraph side's
        // ensureSchema, which also let a graph-first open mint a memory.sqlite
        // with an empty grdb_migrations ledger — the next MemoryStorage init
        // then replayed v2 against existing tables and bricked the chain
        // (stable-failure #4 / Desk 751.7). IF NOT EXISTS here is a one-time
        // ADOPTION of live stores that already carry the hand-created table;
        // the KnowledgeGraph side now verifies schema and never creates it.
        m.registerMigration("v8_kg_memory_index") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS kg_memory_index (
                  memory_id TEXT PRIMARY KEY,
                  content_hash TEXT NOT NULL,
                  indexed_at TEXT NOT NULL,
                  index_version TEXT NOT NULL
                );
            """)
        }
        return m
    }

}

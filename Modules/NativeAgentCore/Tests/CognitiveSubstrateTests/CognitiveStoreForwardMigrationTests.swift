import Foundation
import GRDB
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `store.migrator` (fence core.substrate.field).
//
// THE GAP: every existing test opens a FRESH temp dataRoot, so all four
// migrations always run together in one shot. Nobody has ever opened a store
// that was already at v1/v2 and watched it migrate forward — which is the only
// shape that exists on a real user's machine. The v3 comment calls the
// ALTER-ADD-COLUMN path "the migration-safety crux" and nothing proved it.
//
// The silent failure is total and invisible: a throw out of `init` leaves the
// substrate with `store == nil` → persistenceHealth degraded + writesBlocked
// (CognitiveSubstrate.swift:389). She keeps thinking and nothing lands, with no
// user-visible error anywhere.
//
// This is a REPLAY-THE-REAL-SHAPE test, not a fixture of my assumptions: the
// legacy database is built with the byte-exact v1 + v2 DDL from
// CognitiveSQLiteStore.migrator and marked complete in GRDB's own
// `grdb_migrations` ledger, so opening it exercises v3 + v4 and nothing else.
// Migration SQL is immutable once shipped, so this copy cannot drift.
@Suite("CognitiveStoreForwardMigration")
struct CognitiveStoreForwardMigrationTests {

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-cogmigrate-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Byte-exact v1 + v2 schema of a pre-emotional-tag install.
    private static let legacyV1V2DDL = """
        CREATE TABLE cognitive_nodes (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            subject_type TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            subject_label TEXT,
            activation REAL NOT NULL,
            salience REAL NOT NULL,
            confidence REAL NOT NULL,
            source_class TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_activated_at REAL NOT NULL,
            decay_half_life REAL NOT NULL,
            summary TEXT NOT NULL,
            metadata_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_cognitive_nodes_kind ON cognitive_nodes(kind);
        CREATE INDEX idx_cognitive_nodes_subject ON cognitive_nodes(subject_type, subject_id);
        CREATE INDEX idx_cognitive_nodes_salience ON cognitive_nodes(salience, activation);

        CREATE TABLE cognitive_artifacts (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            score REAL NOT NULL,
            payload_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_cognitive_artifacts_kind ON cognitive_artifacts(kind, status);
        CREATE INDEX idx_cognitive_artifacts_updated ON cognitive_artifacts(updated_at);

        CREATE TABLE cognitive_receipts (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX idx_cognitive_receipts_kind ON cognitive_receipts(kind, created_at);

        CREATE TABLE cognitive_schema_markers (
            name TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        INSERT INTO cognitive_schema_markers (name, value)
        VALUES ('schema_version', '2');
        """

    private static let legacyNodeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let legacyTimestamp: Double = 1_690_000_000

    /// Writes a populated v1/v2-era cognition.sqlite at the canonical path the
    /// store will later open, and marks ONLY v1 and v2 as already applied.
    private func seedLegacyDatabase(at dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("cognition.sqlite").path)
        try dbQueue.write { db in
            try db.execute(sql: Self.legacyV1V2DDL)
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in ["v1_cognitive_substrate", "v2_cognitive_receipts_and_schema_markers"] {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(
                sql: """
                    INSERT INTO cognitive_nodes (
                        id, kind, subject_type, subject_id, subject_label,
                        activation, salience, confidence, source_class,
                        created_at, last_activated_at, decay_half_life,
                        summary, metadata_json, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Self.legacyNodeID.uuidString, "conversationFocus", "chat.user_turn", "legacy-turn",
                    "legacy turn", 0.7, 0.6, 0.85, "userStated",
                    Self.legacyTimestamp, Self.legacyTimestamp, 3_600,
                    "A turn she had before emotional tags existed.",
                    "{\"sessionId\":\"legacy-session\"}", Self.legacyTimestamp,
                ]
            )
            // `episode` survives the retired-machinery drain that also runs at
            // open; a `prediction*`/`commitment*` kind would be deleted by design.
            try db.execute(
                sql: """
                    INSERT INTO cognitive_artifacts (id, kind, status, score, payload_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, "episode", "recorded", 0.5,
                    "{\"id\":\"legacy-episode\"}", Self.legacyTimestamp, Self.legacyTimestamp,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO cognitive_receipts (id, kind, payload_json, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, "microcycle", "{\"reason\":\"legacy\"}", Self.legacyTimestamp]
            )
        }
    }

    @Test("a v1/v2 database migrates forward: open succeeds, rows survive, pre-tag nodes are neutral")
    func legacyDatabaseMigratesForwardWithoutLosingRows() async throws {
        let root = try tempDataRoot("forward")
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyDatabase(at: root)

        // The whole silent-failure mode is a throw here.
        let store = try CognitiveSQLiteStore(dataRoot: root)

        let nodes = try await store.loadNodes()
        #expect(nodes.count == 1)
        let node = try #require(nodes.first)
        #expect(node.id == Self.legacyNodeID)
        #expect(node.summary == "A turn she had before emotional tags existed.")
        #expect(node.subjectReference.type == "chat.user_turn")
        #expect(node.sessionId == "legacy-session")
        // The v3 ALTER-ADD-COLUMN default: a pre-tag node loads NEUTRAL, never
        // as a fabricated feeling and never as a decode failure.
        #expect(node.emotionalValence == 0)
        #expect(node.emotionalArousal == 0)
        #expect(node.emotionalWarmth == 0)

        #expect(try await store.loadArtifacts(kindPrefix: "episode", limit: 10).count == 1)
        #expect(try await store.loadReceipts(kindPrefix: "microcycle", limit: 10).count == 1)
        // v2 app bookkeeping is deliberately left untouched by later migrations.
        #expect(try await store.schemaMarkers()["schema_version"] == "2")

        // v4 arrived in the same forward run: the motor replay guard is usable
        // on a migrated store, not only on a freshly created one.
        #expect(try await store.admitMotorConsequence(
            MotorActionReadModel(
                domain: "workshop",
                actionIdentity: "post-migration",
                phase: .succeeded,
                domainState: "succeeded",
                verification: .satisfied,
                expectedNextEvidence: nil,
                updatedAt: "2026-08-23T10:00:00Z"
            ),
            at: Date(timeIntervalSince1970: 1_700_000_000)) == true)

        // And the migrated store still WRITES: the failure this row guards is
        // "she keeps thinking and nothing lands".
        let fresh = CognitiveNode(
            id: UUID(),
            kind: .correction,
            subjectReference: CognitiveSubjectReference(type: "chat.user_turn", id: "post-migration"),
            activation: 0.9,
            salience: 0.9,
            confidence: 0.9,
            sourceClass: .userStated,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            decayHalfLife: 3_600,
            summary: "post-migration write",
            metadata: [:],
            emotionalValence: 0.4,
            emotionalArousal: 0.5,
            emotionalWarmth: 0.6
        )
        try await store.saveNodes([fresh], at: Date(timeIntervalSince1970: 1_700_000_000))
        let reread = try #require(try await store.loadNodes().first)
        #expect(reread.emotionalWarmth == 0.6)
    }

    @Test("re-opening an already-migrated database is an idempotent no-op")
    func reopeningMigratedDatabaseIsIdempotent() async throws {
        let root = try tempDataRoot("idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyDatabase(at: root)

        _ = try CognitiveSQLiteStore(dataRoot: root)
        // Second open runs the migrator (and the retired-machinery drain) again
        // over a database that is already current — a relaunch, in other words.
        let second = try CognitiveSQLiteStore(dataRoot: root)
        let nodes = try await second.loadNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.id == Self.legacyNodeID)
        #expect(try await second.loadArtifacts(kindPrefix: "episode", limit: 10).count == 1)
    }
}

import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
import Testing
@testable import KnowledgeGraph

private struct SQLiteForgetFixture {
    let directory: URL
    let sqlitePath: URL
    let jsonPath: URL
    let pool: DatabasePool
}

private func makeSQLiteForgetFixture(json: JSONValue? = nil) async throws -> SQLiteForgetFixture {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg-forget-sqlite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sqlitePath = directory.appendingPathComponent("memory.sqlite")
    let jsonPath = directory.appendingPathComponent("knowledge_graph.json")
    let pool = try DatabasePool(path: sqlitePath.path)
    try SwiftNativeKnowledgeGraphIndexer.ensureSchema(pool)
    if let json {
        try json.serializedData(pretty: true).write(to: jsonPath)
    }
    return SQLiteForgetFixture(
        directory: directory,
        sqlitePath: sqlitePath,
        jsonPath: jsonPath,
        pool: pool
    )
}

private func insertEntity(
    _ db: Database,
    id: String,
    name: String,
    provenance: String,
    metadataJSON: String? = nil
) throws {
    try db.execute(sql: """
        INSERT INTO kg_entities
          (id, name, type, summary, aliases_json, mention_count,
           first_seen, last_seen, provenance, metadata_json)
        VALUES (?, ?, 'concept', ?, '[]', 1, '2026-07-13T00:00:00Z',
                '2026-07-13T00:00:00Z', ?, ?)
        """, arguments: [id, name, "Summary for \(name)", provenance, metadataJSON])
}

private func staleJSONGraph(entityID: String) -> JSONValue {
    .object([
        "entities": .object([
            entityID: .object([
                "id": .string(entityID),
                "name": .string("Stale JSON entity"),
                "type": .string("concept"),
            ]),
        ]),
        "edges": .array([]),
        "version": .int(1),
        "_commit_seq": .int(41),
    ])
}

@Test func sqliteForgetIsAtomicDurableAndVisibleThroughCanonicalReader() async throws {
    let fixture = try await makeSQLiteForgetFixture(json: staleJSONGraph(entityID: "manual-a"))
    let jsonBefore = try Data(contentsOf: fixture.jsonPath)
    try await fixture.pool.write { db in
        try insertEntity(db, id: "manual-a", name: "Alpha", provenance: "legacy-manual")
        try insertEntity(db, id: "manual-b", name: "Beta", provenance: "legacy-manual")
        try insertEntity(
            db,
            id: "indexed-c",
            name: "Gamma",
            provenance: "memory-index",
            metadataJSON: #"{"created_by_indexer":"memory-v2-v2","last_memory_id":"memory-1"}"#
        )
        try db.execute(sql: """
            INSERT INTO kg_relationships
              (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
            VALUES
              ('manual-a', 'manual-b', 'related', 0.8, 1, 'legacy-edge', '{"source":"a-b"}'),
              ('indexed-c', 'manual-a', 'related', 0.7, 1, 'memory-edge', '{"source":"c-a"}'),
              ('manual-b', 'indexed-c', 'related', 0.6, 1, 'surviving-edge', '{"source":"b-c"}')
            """)
        try db.execute(sql: """
            INSERT INTO kg_memory_index (memory_id, content_hash, indexed_at, index_version)
            VALUES ('memory-1', 'hash-1', '2026-07-13T00:00:00Z', 'memory-v2-v2')
            """)
    }

    let result = try await SwiftNativeKnowledgeGraphForgetClient(
        graphPath: fixture.jsonPath
    ).forgetEntity(entityId: "manual-a", reason: "user requested")
    #expect(result == .object([
        "ok": .bool(true),
        "forgotten": .string("manual-a"),
        "reason": .string("user requested"),
    ]))

    let counts = try await fixture.pool.read { db in
        (
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities WHERE id = 'manual-a'") ?? -1,
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities WHERE id IN ('manual-b', 'indexed-c')") ?? -1,
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_relationships WHERE from_id = 'manual-a' OR to_id = 'manual-a'") ?? -1,
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_relationships WHERE from_id = 'manual-b' AND to_id = 'indexed-c'") ?? -1,
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_memory_index WHERE memory_id = 'memory-1'") ?? -1,
            try String.fetchOne(db, sql: "SELECT provenance FROM kg_entities WHERE id = 'manual-b'"),
            try String.fetchOne(db, sql: "SELECT provenance FROM kg_relationships WHERE from_id = 'manual-b' AND to_id = 'indexed-c'")
        )
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 2)
    #expect(counts.2 == 0)
    #expect(counts.3 == 1)
    // The per-memory index is canonical MemoryV2 bookkeeping, not entity
    // provenance. Explicit graph forget must not corrupt it.
    #expect(counts.4 == 1)
    #expect(counts.5 == "legacy-manual")
    #expect(counts.6 == "surviving-edge")
    #expect(try Data(contentsOf: fixture.jsonPath) == jsonBefore)

    let reader = SwiftNativeKnowledgeGraphReader(graphPath: fixture.jsonPath)
    if case .found = try await reader.entityChecked(id: "manual-a") {
        Issue.record("forgotten SQLite entity remained visible")
    }
    await KnowledgeGraphPoolCache.shared.invalidate(path: fixture.sqlitePath)
    let reopened = SwiftNativeKnowledgeGraphReader(graphPath: fixture.jsonPath)
    if case .found = try await reopened.entityChecked(id: "manual-a") {
        Issue.record("forgotten entity resurrected after reopening SQLite")
    }
}

@Test func emptySQLiteImportsLegacyGraphBeforeForgetSoNextReadCannotResurrect() async throws {
    let fixture = try await makeSQLiteForgetFixture(json: staleJSONGraph(entityID: "legacy-a"))
    let result = try await SwiftNativeKnowledgeGraphForgetClient(
        graphPath: fixture.jsonPath
    ).forgetEntity(entityId: "legacy-a", reason: "migration cleanup")
    #expect(result == .object([
        "ok": .bool(true),
        "forgotten": .string("legacy-a"),
        "reason": .string("migration cleanup"),
    ]))
    #expect(FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent(".kg_migrated_to_sqlite_v1").path
    ))
    #expect(try await fixture.pool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities") ?? -1
    } == 0)

    await KnowledgeGraphPoolCache.shared.invalidate(path: fixture.sqlitePath)
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: fixture.jsonPath)
    if case .found = try await reader.entityChecked(id: "legacy-a") {
        Issue.record("legacy JSON resurrected an entity forgotten during migration")
    }
}

@Test func staleJSONCannotImpersonateSuccessWhenSQLiteHasDifferentReality() async throws {
    let fixture = try await makeSQLiteForgetFixture(json: staleJSONGraph(entityID: "json-only"))
    let jsonBefore = try Data(contentsOf: fixture.jsonPath)
    try await fixture.pool.write { db in
        try insertEntity(db, id: "sqlite-only", name: "SQLite", provenance: "manual")
    }

    let result = try await SwiftNativeKnowledgeGraphForgetClient(
        graphPath: fixture.jsonPath
    ).forgetEntity(entityId: "json-only", reason: "must not touch JSON")
    #expect(result == .object(["error": .string("not_found")]))
    #expect(try Data(contentsOf: fixture.jsonPath) == jsonBefore)
    #expect(try await fixture.pool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities WHERE id = 'sqlite-only'") ?? -1
    } == 1)
}

@Test func unreadableSQLiteFailsClosedWithoutMutatingLegacyJSON() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg-forget-corrupt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sqlitePath = directory.appendingPathComponent("memory.sqlite")
    let jsonPath = directory.appendingPathComponent("knowledge_graph.json")
    try Data("not a sqlite database".utf8).write(to: sqlitePath)
    try staleJSONGraph(entityID: "legacy-a").serializedData(pretty: true).write(to: jsonPath)
    let jsonBefore = try Data(contentsOf: jsonPath)

    do {
        _ = try await SwiftNativeKnowledgeGraphForgetClient(graphPath: jsonPath)
            .forgetEntity(entityId: "legacy-a", reason: "must fail closed")
        Issue.record("unreadable SQLite unexpectedly fell back to legacy JSON")
    } catch KnowledgeGraphSQLiteLoadError.unreadable(let path, _) {
        #expect(path == sqlitePath.path)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(try Data(contentsOf: jsonPath) == jsonBefore)
}

@Test func unwritableMigrationSentinelPreventsForgetFromClaimingSuccess() async throws {
    let fixture = try await makeSQLiteForgetFixture(json: staleJSONGraph(entityID: "manual-a"))
    try await fixture.pool.write { db in
        try insertEntity(db, id: "manual-a", name: "Alpha", provenance: "manual")
    }
    // Remove write permission from the containing directory so Foundation
    // cannot create the atomic sentinel temp file. Restore it before reading
    // assertions or test cleanup.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500],
        ofItemAtPath: fixture.directory.path
    )
    let jsonBefore = try Data(contentsOf: fixture.jsonPath)

    do {
        _ = try await SwiftNativeKnowledgeGraphForgetClient(graphPath: fixture.jsonPath)
            .forgetEntity(entityId: "manual-a", reason: "must not partially commit")
        Issue.record("forget succeeded without a durable migration sentinel")
    } catch KnowledgeGraphSQLiteLoadError.unreadable(let path, _) {
        #expect(path == fixture.sqlitePath.path)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: fixture.directory.path
    )
    #expect(try await fixture.pool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities WHERE id = 'manual-a'") ?? -1
    } == 1)
    #expect(try Data(contentsOf: fixture.jsonPath) == jsonBefore)
}

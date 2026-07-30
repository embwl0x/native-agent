// U5 W-C (2026-06-11): KG hygiene tests — cached pool lifecycle,
// empty-vs-error (throwing load, no stale-JSON resurrection), the GC sweep,
// and the indexMemory re-entry fix.

import Testing
import Foundation
import GRDB
@testable import KnowledgeGraph
import PersistenceCore

// MARK: - Helpers

private func hygieneTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg-hygiene-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func fact(
    _ id: String,
    _ content: String,
    status: String = "active"
) -> KnowledgeGraphMemoryFact {
    KnowledgeGraphMemoryFact(
        id: id,
        content: content,
        source: "unit",
        status: status,
        createdAt: "2026-06-11T00:00:00Z",
        updatedAt: "2026-06-11T00:00:00Z"
    )
}

private func entityNames(_ store: KnowledgeGraphStore) -> Set<String> {
    Set(store.entities.values.compactMap { v -> String? in
        if case .object(let o) = v, case .string(let n)? = o["name"] { return n }
        return nil
    })
}

private func mentionCount(_ store: KnowledgeGraphStore, name: String) -> Int? {
    for v in store.entities.values {
        guard case .object(let o) = v,
              case .string(let n)? = o["name"], n == name else { continue }
        switch o["mention_count"] {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)): return Int(d)
        default: return nil
        }
    }
    return nil
}

// MARK: - Pool cache lifecycle

@Test func poolCacheReturnsSameInstanceAcrossQueries() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("memory.sqlite")
    _ = try DatabasePool(path: path.path) // create the file
    let cache = KnowledgeGraphPoolCache()
    let p1 = try await cache.pool(at: path)
    let p2 = try await cache.pool(at: path)
    #expect(p1 === p2)
    #expect(await cache.entryCount() == 1)
}

@Test func poolCacheInvalidatesOnFileReplace() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("memory.sqlite")
    _ = try DatabasePool(path: path.path)
    let cache = KnowledgeGraphPoolCache()
    let p1 = try await cache.pool(at: path)
    // Replace the file: delete db + sidecars, recreate (new inode).
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path.path + suffix))
    }
    _ = try DatabasePool(path: path.path)
    let p2 = try await cache.pool(at: path)
    #expect(p1 !== p2)
    // Still exactly one entry — the stale one was removed when the fresh one
    // was added (every add has a remove).
    #expect(await cache.entryCount() == 1)
}

@Test func poolCacheThrowsAndDropsEntryWhenFileMissing() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("memory.sqlite")
    _ = try DatabasePool(path: path.path)
    let cache = KnowledgeGraphPoolCache()
    _ = try await cache.pool(at: path)
    #expect(await cache.entryCount() == 1)
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path.path + suffix))
    }
    await #expect(throws: KnowledgeGraphPoolCache.PoolError.databaseMissing(path.standardizedFileURL.path)) {
        _ = try await cache.pool(at: path)
    }
    #expect(await cache.entryCount() == 0)
}

@Test func poolCacheExplicitInvalidateReopens() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("memory.sqlite")
    _ = try DatabasePool(path: path.path)
    let cache = KnowledgeGraphPoolCache()
    let p1 = try await cache.pool(at: path)
    await cache.invalidate(path: path)
    #expect(await cache.entryCount() == 0)
    let p2 = try await cache.pool(at: path)
    #expect(p1 !== p2)
}

@Test func poolCacheEvictsLRUBeyondCap() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = KnowledgeGraphPoolCache(maxEntries: 2)
    for i in 0..<3 {
        let p = dir.appendingPathComponent("db\(i).sqlite")
        _ = try DatabasePool(path: p.path)
        _ = try await cache.pool(at: p)
    }
    #expect(await cache.entryCount() == 2)
}

// MARK: - Empty-vs-error

@Test func corruptSQLiteThrowsAndNeverResurrectsStaleJSON() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // A corrupt DB next to a stale-but-valid JSON snapshot — the resurrection
    // scenario: pre-U5 this silently served the JSON entity as healthy.
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    try Data("definitely not a sqlite database, padded to look real enough to open".utf8)
        .write(to: sqlitePath)
    let jsonPath = dir.appendingPathComponent("knowledge_graph.json")
    let staleJSON = """
    {"entities": {"stale1": {"id": "stale1", "name": "Resurrected", "type": "concept"}},
     "edges": [], "version": 1}
    """
    try staleJSON.data(using: .utf8)!.write(to: jsonPath)

    // 1. The loader THROWS (not an empty store).
    await #expect(throws: (any Error).self) {
        _ = try await KnowledgeGraphStore.loadFromMemoryV2(
            memoryDir: dir, jsonImportPath: jsonPath)
    }
    // 2. The checked reader THROWS — and the optional reader returns nil.
    //    Neither serves the stale JSON entity.
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: jsonPath)
    await #expect(throws: (any Error).self) {
        _ = try await reader.allEntitiesChecked(page: 0)
    }
    #expect(await reader.allEntities(page: 0) == nil)
    await #expect(throws: (any Error).self) {
        _ = try await reader.searchChecked(q: "Resurrected")
    }
    await #expect(throws: (any Error).self) {
        _ = try await reader.entityChecked(id: "stale1")
    }
}

@Test func authoritativeEmptySQLiteNeverResurrectsStaleJSONAfterMigration() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    _ = try DatabasePool(path: sqlitePath.path)
    let jsonPath = dir.appendingPathComponent("knowledge_graph.json")

    // The first healthy read performs the one-way migration check. With no
    // legacy JSON to import, it stamps the migration sentinel and returns the
    // authoritative empty SQLite graph.
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: jsonPath)
    guard case .object(let first) = try await reader.allEntitiesChecked(page: 0) else {
        Issue.record("expected an empty SQLite envelope")
        return
    }
    #expect(first["total_entities"] == .int(0))
    #expect(first["total_edges"] == .int(0))
    #expect(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(".kg_migrated_to_sqlite_v1").path
    ))

    // A stale compatibility file appears after migration. It must never become
    // authoritative again, including after the backing pool is reopened.
    let staleJSON = """
    {"entities": {"stale1": {"id": "stale1", "name": "Resurrected", "type": "concept"}},
     "edges": [], "version": 1}
    """
    try staleJSON.data(using: .utf8)!.write(to: jsonPath)
    await KnowledgeGraphPoolCache.shared.invalidate(path: sqlitePath)
    let restartedReader = SwiftNativeKnowledgeGraphReader(graphPath: jsonPath)
    guard case .object(let restarted) = try await restartedReader.allEntitiesChecked(page: 0) else {
        Issue.record("expected an empty SQLite envelope after restart")
        return
    }
    #expect(restarted["total_entities"] == .int(0))
    #expect(restarted["total_edges"] == .int(0))

    guard case .object(let search) = try await restartedReader.searchChecked(q: "Resurrected"),
          case .array(let results)? = search["results"] else {
        Issue.record("expected an empty SQLite search envelope")
        return
    }
    #expect(results.isEmpty)
    if case .notFound = try await restartedReader.entityChecked(id: "stale1") {} else {
        Issue.record("stale JSON entity must not be visible")
    }
}

@Test func missingSQLiteFallsBackToJSONAsHealthyEmptyOrContent() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let jsonPath = dir.appendingPathComponent("knowledge_graph.json")
    // No memory.sqlite, no JSON: a legitimate EMPTY graph, no error.
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: jsonPath)
    let env = try await reader.allEntitiesChecked(page: 0)
    if case .object(let o) = env { #expect(o["total_entities"] == .int(0)) }
    else { Issue.record("expected envelope") }
    // JSON appears: served.
    let json = """
    {"entities": {"j1": {"id": "j1", "name": "FromJSON", "type": "concept"}},
     "edges": [], "version": 1}
    """
    try json.data(using: .utf8)!.write(to: jsonPath)
    let env2 = try await reader.allEntitiesChecked(page: 0)
    if case .object(let o) = env2 { #expect(o["total_entities"] == .int(1)) }
    else { Issue.record("expected envelope") }
}

@Test func corruptJSONThrowsCheckedButLegacyLoadStaysEmpty() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let jsonPath = dir.appendingPathComponent("knowledge_graph.json")
    try Data("{not json at all".utf8).write(to: jsonPath)
    // Checked: error (file exists but unreadable).
    #expect(throws: (any Error).self) {
        _ = try KnowledgeGraphStore.loadChecked(path: jsonPath)
    }
    // Legacy load keeps its silent-empty contract for the import path.
    let legacy = KnowledgeGraphStore.load(path: jsonPath)
    #expect(legacy.entities.isEmpty)
    // Reader surfaces the error (no memory.sqlite in this dir).
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: jsonPath)
    await #expect(throws: (any Error).self) {
        _ = try await reader.allEntitiesChecked(page: 0)
    }
}

// MARK: - indexMemory re-entry

@Test func concurrentIndexOfSameMemoryCountsMentionsOnce() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let f = fact("mem-concurrent", "the user ships NativeAgent tonight.")
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask { try await indexer.indexMemory(f) }
        }
        try await group.waitForAll()
    }
    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(mentionCount(graph, name: "NativeAgent") == 1)
}

@Test func deleteClearsIndexRowSoReindexCountsAgain() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let f = fact("mem-cycle", "NativeAgent build notes.")
    try await indexer.indexMemory(f)
    try await indexer.indexMemory(f, deleted: true)   // index row removed
    try await indexer.indexMemory(f)                   // hash gone -> counts again
    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(mentionCount(graph, name: "NativeAgent") == 2)
}

@Test func canonicalRebuildRetractsChangedClaimsAndPreservesLegacyEntities() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let pool = try DatabasePool(path: sqlitePath.path)
    try await pool.write { db in
        try db.execute(sql: """
            CREATE TABLE memories (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              source TEXT,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              metadata_json TEXT,
              lifecycle TEXT
            );
            INSERT INTO memories
              (id, content, source, status, created_at, updated_at, metadata_json, lifecycle)
            VALUES
              ('mem-rebuild', 'NativeAgent uses TradingView.', 'unit', 'active',
               '2026-07-12T00:00:00Z', '2026-07-12T00:00:00Z', NULL, 'confirmed');
            """)
    }
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let first = try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore()
    #expect(first.factsIndexed == 1)
    var graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    #expect(entityNames(graph).contains("TradingView"))

    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES
              ('legacy-manual', 'Manual Truth', 'concept', 'operator-authored',
               '[]', 1, NULL, NULL, 'manual', NULL),
              ('legacy-v1-owned', 'Two', 'concept', 'old indexer residue',
               '[]', 1, NULL, NULL, 'default-concept',
               '{"created_by_indexer":"swift-memory-kg-v1"}'),
              ('legacy-v2-owned', 'Ordinary', 'concept', 'prior indexer residue',
               '[]', 1, NULL, NULL, 'default-concept',
               '{"created_by_indexer":"swift-memory-kg-v2"}'),
              ('legacy-v3-owned', 'Deterministic', 'concept', 'prior indexer residue',
               '[]', 1, NULL, NULL, 'default-concept',
               '{"created_by_indexer":"swift-memory-kg-v3"}');
            UPDATE memories
            SET content = 'NativeAgent uses local dashboards.',
                updated_at = '2026-07-12T00:01:00Z'
            WHERE id = 'mem-rebuild';
            """)
    }

    let second = try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore()
    #expect(second.factsIndexed == 1)
    #expect(second.entitiesRemoved > 0)
    graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    #expect(!entityNames(graph).contains("TradingView"))
    #expect(entityNames(graph).contains("NativeAgent"))
    #expect(entityNames(graph).contains("Manual Truth"))
    #expect(!entityNames(graph).contains("Two"))
    #expect(!entityNames(graph).contains("Ordinary"))
    #expect(!entityNames(graph).contains("Deterministic"))
    let rebuiltVersions = try await pool.read { db in
        try Set(String.fetchAll(db, sql: "SELECT DISTINCT index_version FROM kg_memory_index"))
    }
    #expect(rebuiltVersions == ["swift-memory-kg-v4"])
}

@Test func canonicalEmptyRebuildRetractsAllMemoryDerivedRows() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    try await indexer.indexMemory(fact("mem-stale", "NativeAgent uses TradingView."))

    let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
    try await pool.write { db in
        try db.execute(sql: """
            CREATE TABLE memories (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              source TEXT,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              metadata_json TEXT,
              lifecycle TEXT
            );
            """)
    }

    let report = try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore()
    #expect(report.factsIndexed == 0)
    #expect(report.entitiesRemoved > 0)
    #expect(report.relationshipsRemoved > 0)
    #expect(report.indexRowsRemoved == 1)

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(entityNames(graph).isEmpty)
}

@Test func ordinaryChangedFactReindexRetractsThePriorClaim() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let pool = try DatabasePool(path: sqlitePath.path)
    try await pool.write { db in
        try db.execute(sql: """
            CREATE TABLE memories (
              id TEXT PRIMARY KEY, content TEXT NOT NULL, source TEXT,
              status TEXT NOT NULL, created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL, metadata_json TEXT, lifecycle TEXT
            );
            INSERT INTO memories VALUES
              ('mem-change', 'The user relies on TradingView.', 'unit', 'active',
               '2026-07-12T00:00:00Z', '2026-07-12T00:00:00Z', NULL, 'confirmed');
            """)
    }
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    try await indexer.indexMemory(fact("mem-change", "The user relies on TradingView."))
    var graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    #expect(entityNames(graph).contains("TradingView"))

    try await pool.write { db in
        try db.execute(
            sql: "UPDATE memories SET content = ?, updated_at = ? WHERE id = ?",
            arguments: ["The user relies on local dashboards.", "2026-07-12T00:01:00Z", "mem-change"]
        )
    }
    try await indexer.indexMemory(fact("mem-change", "The user relies on local dashboards."))
    graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    #expect(!entityNames(graph).contains("TradingView"))
}

// MARK: - GC

@Test func gcSweepsOrphanKeepsSharedEntityAndUser() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let memA = fact("mem-a", "NativeAgent ships tonight.")
    let memB = fact("mem-b", "TradingView dashboards inside NativeAgent.")
    try await indexer.indexMemory(memA)
    try await indexer.indexMemory(memB)
    // Delete memory B — its index row goes; TradingView's last source is gone,
    // NativeAgent is still mentioned by live memory A.
    try await indexer.indexMemory(memB, deleted: true)

    let report = try await indexer.collectGarbage(liveFacts: [memA], apply: true)
    #expect(report.applied)
    #expect(report.entitiesDeleted == 1)
    #expect(report.candidates.map { $0.name } == ["TradingView"])

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    let names = entityNames(graph)
    #expect(!names.contains("TradingView"))      // orphan swept
    #expect(names.contains("NativeAgent"))       // shared entity survives
    #expect(names.contains("the user"))          // hub survives
    // No edge in the surviving graph touches a missing entity (incident edges
    // swept in the same transaction; readFromPool would drop them). The live
    // memory now also has a source-backed fact node, so the survivors are
    // user->fact, fact->NativeAgent, and user->NativeAgent.
    #expect(graph.edges.count == 3)
}

@Test func gcDryRunReportsButDeletesNothing() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let memB = fact("mem-b", "TradingView charts look healthy.")
    try await indexer.indexMemory(memB)
    try await indexer.indexMemory(memB, deleted: true)

    let report = try await indexer.collectGarbage(liveFacts: [], apply: false)
    #expect(!report.applied)
    #expect(report.candidates.contains { $0.name == "TradingView" })

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(entityNames(graph).contains("TradingView")) // nothing deleted
}

@Test func gcApplyRefusesOverThresholdWithoutApproval() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    // Two distinct orphans-to-be.
    let m1 = fact("m1", "TradingView analysis session.")
    let m2 = fact("m2", "Telegram bridge ping check.")
    try await indexer.indexMemory(m1)
    try await indexer.indexMemory(m2)
    try await indexer.indexMemory(m1, deleted: true)
    try await indexer.indexMemory(m2, deleted: true)

    // Threshold 1, two candidates, no approval -> refusal, zero mutations.
    let refused = try await indexer.collectGarbage(
        liveFacts: [], apply: true, approvalThreshold: 1)
    #expect(refused.requiresApproval)
    #expect(!refused.applied)
    #expect(refused.entitiesDeleted == 0)
    let before = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(entityNames(before).contains("TradingView"))
    #expect(entityNames(before).contains("Telegram"))

    // Approval flips it through.
    let approved = try await indexer.collectGarbage(
        liveFacts: [], apply: true, approvalThreshold: 1, approvedOverThreshold: true)
    #expect(approved.applied)
    #expect(approved.entitiesDeleted == 2)
    let after = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(!entityNames(after).contains("TradingView"))
    #expect(!entityNames(after).contains("Telegram"))
}

@Test func gcGraceWindowProtectsFreshlyIndexedMemory() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    // Indexed seconds ago, but ABSENT from the caller's (stale) live list —
    // the new-memory race. Its index row is inside the grace window, so the
    // entity must be kept and the index row must NOT be reconciled away.
    let fresh = fact("mem-fresh", "TradingView watchlist sync.")
    try await indexer.indexMemory(fresh)
    let report = try await indexer.collectGarbage(liveFacts: [], apply: true)
    #expect(report.applied)
    #expect(report.candidates.isEmpty)
    #expect(report.staleIndexRowsDeleted == 0)
    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(entityNames(graph).contains("TradingView"))
}

@Test func gcDoesNotGraceFreshIndexRowForArchivedMemoryInCurrentStore() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    _ = try DatabasePool(path: sqlitePath.path)
    let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
    try await pool.write { db in
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memories (
              id TEXT PRIMARY KEY,
              content TEXT,
              status TEXT
            );
            INSERT INTO memories (id, content, status)
            VALUES ('mem-archived-fresh-index', 'TradingView watchlist sync.', 'archived');
            """)
    }
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let archived = fact("mem-archived-fresh-index", "TradingView watchlist sync.")
    try await indexer.indexMemory(archived)

    let report = try await indexer.collectGarbage(
        liveFacts: [fact(
            "mem-archived-fresh-index",
            "TradingView watchlist sync.",
            status: "archived"
        )],
        apply: true
    )
    #expect(report.applied)
    #expect(report.staleIndexRowsDeleted == 1)
    #expect(report.candidates.contains { $0.name == "TradingView" })

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(!entityNames(graph).contains("TradingView"))
}

@Test func gcNeverSweepsEntitiesWithoutCreationStamp() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    // Simulate a daemon-era imported entity: row without created_by_indexer.
    _ = try DatabasePool(path: sqlitePath.path)
    let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO kg_entities (id, name, type, summary, mention_count, metadata_json)
            VALUES ('legacy1', 'DaemonEra', 'concept', 'imported', 3,
                    '{"embedding_text": "concept: DaemonEra", "last_memory_id": "long-gone"}')
            """)
    }
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let report = try await indexer.collectGarbage(liveFacts: [], apply: true)
    #expect(report.applied)
    #expect(report.candidates.isEmpty)
    #expect(report.legacyUntrackedEntities == 1)
    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir, jsonImportPath: nil)
    #expect(entityNames(graph).contains("DaemonEra"))
}

// MARK: - Stale index-row reconcile (2026-07-02 audit)

@Test func reconcileDeletesIndexRowsForMissingMemoriesOnly() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    try await indexer.indexMemory(fact("mem-live", "NativeAgent reconcile notes."))
    try await indexer.indexMemory(fact("mem-leaked", "OpenClaw leaked row."))
    // Minimal `memories` table containing ONLY the live id — mem-leaked's
    // memory was hard-deleted while its delete hook never fired (the leak
    // class the 2026-07-02 audit found 8 of on the live store).
    let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
    try await pool.write { db in
        try db.execute(sql: "CREATE TABLE memories (id TEXT PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO memories (id) VALUES ('mem-live')")
        // SQLite quirk: TEXT PRIMARY KEY in a rowid table admits NULL. A
        // NULL memory id must not poison the reconcile (gpt-5.5 review:
        // NOT IN would match nothing; NOT EXISTS stays exact).
        try db.execute(sql: "INSERT INTO memories (id) VALUES (NULL)")
    }
    let removed = try await indexer.reconcileStaleMemoryIndexRows()
    #expect(removed == 1)
    let survivors = try await pool.read { db in
        try String.fetchAll(db, sql: "SELECT memory_id FROM kg_memory_index ORDER BY memory_id")
    }
    #expect(survivors == ["mem-live"])
    // Idempotent: a second reconcile finds nothing.
    #expect(try await indexer.reconcileStaleMemoryIndexRows() == 0)
}

@Test func reconcileNoopsWithoutMemoriesTable() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    try await indexer.indexMemory(fact("mem-solo", "KG-only fixture row."))
    // No `memories` table at all (KG-only fixture): reconcile must be a
    // no-op, never a wipe-everything.
    #expect(try await indexer.reconcileStaleMemoryIndexRows() == 0)
    let count = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath).read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM kg_memory_index") ?? -1
    }
    #expect(count == 1)
}

@Test func canonicalRebuildConvergesPrimaryUserIdentityAndLegacyRoleDuplicates() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    try Data(#"{"name":"River","userName":"Alex"}"#.utf8)
        .write(to: dir.appendingPathComponent("profile.json"))
    let pool = try DatabasePool(path: sqlitePath.path)
    try await pool.write { db in
        try db.execute(sql: """
            CREATE TABLE memories (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              source TEXT,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              metadata_json TEXT,
              lifecycle TEXT
            );
            INSERT INTO memories
              (id, content, source, status, created_at, updated_at, metadata_json, lifecycle)
            VALUES
              ('identity-a', 'NativeAgent keeps exact identity.', 'unit', 'active',
               '2026-07-26T00:00:00Z', '2026-07-26T00:00:00Z', NULL, 'confirmed'),
              ('identity-b', 'NativeAgent preserves role aliases.', 'unit', 'active',
               '2026-07-26T00:01:00Z', '2026-07-26T00:01:00Z', NULL, 'confirmed');
            """)
    }
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    _ = try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore()

    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES
              ('legacy-user', 'User', 'person', 'legacy generic role',
               '["User"]', 9, NULL, NULL, NULL, NULL),
              ('legacy-the-user', 'the user', 'person', 'legacy role hub',
               '["the user"]', 11, NULL, NULL, NULL, NULL),
              ('derived-alex-concept', 'Alex', 'concept', 'derived type residue',
               '["Alex"]', 4, NULL, NULL, NULL,
               '{"indexer":"swift-memory-kg-v3"}'),
              ('manual-target', 'Manual Target', 'concept', 'manual graph truth',
               '[]', 1, NULL, NULL, 'manual', NULL);
            INSERT INTO kg_relationships
              (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
            VALUES
              ('legacy-user', 'manual-target', 'knows', 0.4, 2, 'manual', NULL),
              ('legacy-the-user', 'manual-target', 'knows', 0.8, 3, 'manual', NULL),
              ('derived-alex-concept', 'manual-target', 'knows', 0.6, 4, NULL, NULL);
            """)
    }

    _ = try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore()
    _ = try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore()

    try await pool.read { db in
        let roleRows = try Row.fetchAll(db, sql: """
            SELECT id, name, type, aliases_json, mention_count, metadata_json
            FROM kg_entities
            WHERE lower(name) IN ('alex', 'user', 'the user')
            ORDER BY name
            """)
        #expect(roleRows.count == 1)
        let role = try #require(roleRows.first)
        let roleID: String = role["id"]
        let roleName: String = role["name"]
        let roleType: String = role["type"]
        let roleMentions: Int = role["mention_count"]
        let aliasesRaw: String = role["aliases_json"]
        let metadataRaw: String = role["metadata_json"]
        let aliases = try JSONDecoder().decode([String].self, from: Data(aliasesRaw.utf8))
        #expect(roleName == "Alex")
        #expect(roleType == "person")
        #expect(roleMentions == 2)
        #expect(Set(aliases.map { $0.lowercased() }) == ["user", "the user"])
        #expect(metadataRaw.contains(#""role": "primary_user""#))
        #expect(!metadataRaw.contains("created_by_indexer"))

        let manualTargetCount = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM kg_entities WHERE id = 'manual-target'"
        )
        #expect(manualTargetCount == 1)
        let mergedEdges = try Row.fetchAll(db, sql: """
            SELECT weight, mention_count, provenance
            FROM kg_relationships
            WHERE from_id = ? AND to_id = 'manual-target' AND type = 'knows'
            """, arguments: [roleID])
        #expect(mergedEdges.count == 1)
        let merged = try #require(mergedEdges.first)
        let mergedWeight: Double = merged["weight"]
        let mergedMentions: Int = merged["mention_count"]
        let mergedProvenance: String = merged["provenance"]
        #expect(mergedWeight == 0.8)
        #expect(mergedMentions == 9)
        #expect(mergedProvenance == "manual")
    }
}

@Test func missingConfiguredUserNameKeepsOneGenericRoleHub() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    try await indexer.indexMemory(fact(
        "generic-user",
        "User prefers NativeAgent while the user tests recall."
    ))
    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir,
        jsonImportPath: nil
    )
    let roleNames = graph.entities.values.compactMap { value -> String? in
        guard case .object(let object) = value,
              object["type"] == .string("person"),
              case .string(let name)? = object["name"] else {
            return nil
        }
        return name
    }
    #expect(roleNames == ["the user"])
}

@Test func onboardingIdentityBecomesVisibleWithoutRecreatingTheIndexer() async throws {
    let dir = try hygieneTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    try await indexer.indexMemory(fact("before-profile", "NativeAgent is ready."))

    try Data(#"{"name":"River","userName":"Alex"}"#.utf8)
        .write(to: dir.appendingPathComponent("profile.json"))
    try await indexer.indexMemory(fact("after-profile", "NativeAgent remembers identity."))

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: dir,
        jsonImportPath: nil
    )
    let roleNames = graph.entities.values.compactMap { value -> String? in
        guard case .object(let object) = value,
              object["type"] == .string("person"),
              case .string(let name)? = object["name"] else {
            return nil
        }
        return name
    }
    #expect(roleNames == ["Alex"])
}

// MARK: - Pronoun deny-list (2026-07-02 audit)

@Test func extractorNeverMintsPronounEntities() async throws {
    let extracted = SwiftNativeKnowledgeGraphIndexer.extractEntities(
        from: "He said She and They went with Us to see Them near Our place; My car, His idea."
    )
    let names = Set(extracted.map { $0.name.lowercased() })
    let pronouns: Set<String> = [
        "he", "she", "her", "him", "his", "hers", "they", "them", "their",
        "theirs", "us", "our", "ours", "me", "my", "mine", "we", "you",
        "these", "those",
    ]
    #expect(names.isDisjoint(with: pronouns))
}

// MARK: - Sentence-initial junk + word-boundary known terms (2026-07-21 audit)

@Test func extractorNeverMintsSentenceInitialJunkEntities() async throws {
    let extracted = SwiftNativeKnowledgeGraphIndexer.extractEntities(
        from: """
        Today Remember to Update the board. Monday we ship; January was slow; Tomorrow check Again.
        Do not report it as a defect. Hard limits kept. Nightly jobs can wait. Rewrote the file; it is EXPECTED.
        Do the next check too. Hard cases may recur; the outcome is still EXPECTED.
        Two checks ran. Two checks passed.
        NativeAgent must NOT auto-create a shelf and must NOT fail that state.
        (1) Useful signal. (2) Empty optional shelf. (3) Ordinary conversation. (4) Deterministic refusal.
        """
    )
    let names = Set(extracted.map { $0.name.lowercased() })
    let junk: Set<String> = [
        "today", "remember", "update", "monday", "january", "tomorrow", "again",
        "do", "hard", "nightly", "rewrote", "expected", "two",
        "not", "empty", "ordinary", "deterministic",
    ]
    #expect(names.isDisjoint(with: junk), "sentence-initial junk minted as entities: \(names)")
}

@Test func extractorPreservesMeaningfulRepeatedAndDomainConceptsAroundListNoise() async throws {
    let extracted = SwiftNativeKnowledgeGraphIndexer.extractEntities(
        from: """
        Alex asked River to review the QZX protocol; River confirmed QZX.
        River asked Codex to check MemoryV2 and the Knowledge Graph. WAL evidence matched the WAL receipt.
        (1) Empty shelf. (2) Ordinary conversation. NativeAgent remained healthy.
        """
    )
    let names = Set(extracted.map(\.name))
    #expect(names.contains("River"))
    #expect(names.contains("QZX"))
    #expect(names.contains("Codex"))
    #expect(names.contains("MemoryV2"))
    #expect(names.contains("Knowledge Graph"))
    #expect(names.contains("WAL"))
    #expect(names.contains("NativeAgent"))
    #expect(!names.contains("Empty"))
    #expect(!names.contains("Ordinary"))
}

@Test func extractorRejectsAcronymInflectedVerbFragmentsWithoutLosingNounPhrases() async throws {
    let extracted = SwiftNativeKnowledgeGraphIndexer.extractEntities(
        from: """
        Codex does not run locally. Codex SSHes into the VM through an SSH Bridge.
        River Stone reviewed the Knowledge Graph with Codex.
        """
    )
    let names = Set(extracted.map(\.name))
    #expect(names.contains("Codex"))
    #expect(names.contains("SSH Bridge"))
    #expect(names.contains("River Stone"))
    #expect(names.contains("Knowledge Graph"))
    #expect(!names.contains("Codex SSHes"))
}

@Test func extractorKeepsRepeatedNamesAndCanonicalizesPersonaDocuments() async throws {
    let extracted = SwiftNativeKnowledgeGraphIndexer.extractEntities(
        from: """
        Nova helped Morgan update persona/SOUL.md. Morgan asked Nova to rewrite VOICE.md.
        I met Calypso yesterday.
        SOUL and VOICE refer to those files, while Claude Opus reviewed the result.
        """
    )
    let names = Set(extracted.map(\.name))
    #expect(names.contains("Morgan"))
    #expect(names.contains("Nova"))
    #expect(names.contains("Calypso"))
    #expect(names.contains("Claude Opus"))
    #expect(names.contains("SOUL.md"))
    #expect(names.contains("VOICE.md"))
    #expect(!names.contains("SOUL"))
    #expect(!names.contains("VOICE"))
    #expect(!names.contains("persona/SOUL.md"))
}

@Test func knownTermMatchRequiresWordBoundary() async throws {
    // "Apple" must not fire inside "pineapple" — but must still fire as a
    // standalone word (any case, punctuation-adjacent).
    let noMatch = SwiftNativeKnowledgeGraphIndexer.extractEntities(
        from: "I grilled a pineapple and a crabapple for dessert."
    )
    #expect(!noMatch.contains { $0.name.lowercased() == "apple" },
            "substring match leaked 'Apple' out of 'pineapple': \(noMatch.map { $0.name })")

    let match = SwiftNativeKnowledgeGraphIndexer.extractEntities(
        from: "apple released a new build of macOS today."
    )
    #expect(match.contains { $0.name == "Apple" && $0.type == "organization" })
    #expect(match.contains { $0.name == "macOS" && $0.type == "tool" })
}

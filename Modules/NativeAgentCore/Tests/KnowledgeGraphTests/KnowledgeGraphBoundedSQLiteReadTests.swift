import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
import Testing
@testable import KnowledgeGraph

@Suite("KnowledgeGraph bounded SQLite reads")
struct KnowledgeGraphBoundedSQLiteReadTests {
    private func fixture() throws -> (directory: URL, sqlite: URL, json: URL, pool: DatabasePool) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kg-bounded-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqlite = directory.appendingPathComponent("memory.sqlite")
        let json = directory.appendingPathComponent("knowledge_graph.json")
        let pool = try DatabasePool(path: sqlite.path)
        try SwiftNativeKnowledgeGraphIndexer.ensureSchema(pool)
        return (directory, sqlite, json, pool)
    }

    private func insertEntity(_ db: Database, id: String, name: String) throws {
        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES (?, ?, 'concept', ?, '[]', 1,
                    '2026-08-16T00:00:00Z', '2026-08-16T00:00:00Z',
                    'test', NULL)
            """, arguments: [id, name, "Summary for \(name)"])
    }

    @Test("page, entity, search, and complete snapshot read canonical SQLite")
    func canonicalSQLiteProjections() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.pool.write { db in
            for index in 0..<150 {
                let id = String(format: "entity-%03d", index)
                try insertEntity(
                    db,
                    id: id,
                    name: index == 149 ? "Unique Needle" : "Entity \(index)"
                )
            }
            try db.execute(sql: """
                INSERT INTO kg_relationships
                  (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
                VALUES ('entity-000', 'entity-149', 'related', 1, 1, 'test', NULL)
                """)
        }
        let reader = SwiftNativeKnowledgeGraphReader(graphPath: f.json)

        guard case .object(let page) = try await reader.allEntitiesChecked(page: 1),
              case .array(let entities)? = page["entities"],
              case .array(let edges)? = page["edges"] else {
            Issue.record("page envelope malformed")
            return
        }
        #expect(entities.count == 50)
        #expect(page["total_entities"] == .int(150))
        #expect(edges.count == 1)

        guard case .object(let search) = try await reader.searchChecked(q: "Unique Needle"),
              case .array(let results)? = search["results"] else {
            Issue.record("search envelope malformed")
            return
        }
        #expect(results.count == 1)
        if case .object(let match) = results[0] {
            #expect(match["id"] == .string("entity-149"))
        }

        guard case .found(let neighborEnvelope) = try await reader.entityChecked(id: "entity-149"),
              case .object(let neighborObject) = neighborEnvelope,
              case .object(let neighbors)? = neighborObject["neighbors"] else {
            Issue.record("entity envelope malformed")
            return
        }
        #expect(neighbors["entity-000"] != nil)

        guard case .object(let snapshot) = try await reader.completeSnapshotChecked(),
              case .array(let snapshotEntities)? = snapshot["entities"],
              case .array(let snapshotEdges)? = snapshot["edges"] else {
            Issue.record("snapshot envelope malformed")
            return
        }
        #expect(snapshotEntities.count == 150)
        #expect(snapshotEdges.count == 1)
    }

    @Test("SQLite search candidate materialization is bounded and ordered")
    func searchCandidateBound() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.pool.write { db in
            for index in 0..<(KnowledgeGraphStore.sqliteSearchCandidateLimit + 5) {
                try insertEntity(
                    db,
                    id: String(format: "entity-%04d", index),
                    name: "Shared Match \(index)"
                )
            }
        }
        let envelope = try await SwiftNativeKnowledgeGraphReader(graphPath: f.json)
            .searchChecked(q: "Shared Match")
        guard case .object(let object) = envelope,
              case .array(let results)? = object["results"] else {
            Issue.record("search envelope malformed")
            return
        }
        #expect(results.count == KnowledgeGraphStore.sqliteSearchCandidateLimit)
        if case .object(let first) = results.first,
           case .object(let last) = results.last {
            #expect(first["id"] == .string("entity-0000"))
            #expect(last["id"] == .string("entity-1999"))
        }
    }

    @Test("exact name survives the SQL candidate cap")
    func exactNameSurvivesCandidateCap() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.pool.write { db in
            for index in 0...KnowledgeGraphStore.sqliteSearchCandidateLimit {
                try db.execute(sql: """
                    INSERT INTO kg_entities
                      (id, name, type, summary, aliases_json, mention_count,
                       first_seen, last_seen, provenance, metadata_json)
                    VALUES (?, 'Common', 'concept', 'Needle appears weakly here', '[]', 1,
                            NULL, NULL, 'test', NULL)
                    """, arguments: [String(format: "a-%04d", index)])
            }
            try insertEntity(db, id: "zzzz-exact", name: "Needle")
        }

        let envelope = try await SwiftNativeKnowledgeGraphReader(graphPath: f.json)
            .searchChecked(q: "Needle")
        guard case .object(let object) = envelope,
              case .array(let results)? = object["results"],
              case .object(let first)? = results.first else {
            Issue.record("search envelope malformed")
            return
        }
        #expect(first["id"] == .string("zzzz-exact"))
    }

    @Test("oversized search is refused before SQL construction")
    func oversizedSearchIsRefused() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let query = String(repeating: "x", count: KnowledgeGraphStore.sqliteSearchQueryMaximumBytes + 1)
        await #expect(throws: KnowledgeGraphReadError.self) {
            _ = try await SwiftNativeKnowledgeGraphReader(graphPath: f.json).searchChecked(q: query)
        }
    }

    @Test("corrupt legacy JSON never stamps the one-way SQLite sentinel")
    func corruptLegacyJSONDoesNotStampSentinel() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try Data("{".utf8).write(to: f.json)
        let sentinel = f.directory.appendingPathComponent(".kg_migrated_to_sqlite_v1")

        await #expect(throws: (any Error).self) {
            _ = try await SwiftNativeKnowledgeGraphReader(graphPath: f.json)
                .allEntitiesChecked(page: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}

import Foundation
import GRDB
import Testing
@testable import KnowledgeGraph

/// Fluid Context sweep item 23 (2026-09-01): the bounded typed-relation read
/// that makes the graph reachable from the resident context index.
///
/// The bounds are the whole point — an unbounded read would hand the projection
/// 1,500 edges and turn "connected" into "clouded".
@Suite("KnowledgeGraph context relations")
struct KnowledgeGraphContextRelationsTests {

    @Test("structural and memory-fact edges never reach the context index")
    func onlyTypedEntityToEntityEdgesAreProjected() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.pool.write { db in
            try insertEntity(db, id: "user", name: "User")
            try insertEntity(db, id: "hermes", name: "Hermes")
            // A memory-fact node's NAME is a rendering of the memory's own
            // text; projecting it would duplicate a memory atom's body.
            try insertEntity(
                db, id: "memfact_abc", name: "Preference: User prefers concise summaries."
            )
            try insertEdge(db, from: "user", to: "hermes", type: "works_on")
            try insertEdge(db, from: "user", to: "hermes", type: "mentions")
            try insertEdge(db, from: "user", to: "memfact_abc", type: "prefers")
        }
        let relations = try await indexer(fixture.sqlite).contextRelations()
        #expect(relations.count == 1)
        #expect(relations[0].subject == "User")
        #expect(relations[0].predicate == "works_on")
        #expect(relations[0].object == "Hermes")
    }

    @Test("per-subject and total caps bound the read")
    func capsBoundTheRead() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.pool.write { db in
            try insertEntity(db, id: "user", name: "User")
            try insertEntity(db, id: "agent", name: "Agent")
            for index in 0..<12 {
                try insertEntity(db, id: "p-\(index)", name: "Project \(index)")
                try insertEdge(db, from: "user", to: "p-\(index)", type: "works_on")
                try insertEdge(db, from: "agent", to: "p-\(index)", type: "knows")
            }
        }
        let indexer = try indexer(fixture.sqlite)

        let capped = try await indexer.contextRelations(perSubjectLimit: 3, maximumRelations: 192)
        #expect(capped.count == 6)
        #expect(capped.filter { $0.subjectID == "user" }.count == 3)
        #expect(capped.filter { $0.subjectID == "agent" }.count == 3)

        let totalCapped = try await indexer.contextRelations(
            perSubjectLimit: 12, maximumRelations: 5
        )
        #expect(totalCapped.count == 5)

        #expect(try await indexer.contextRelations(maximumRelations: 0).isEmpty)
    }

    @Test("best-attested edges survive the caps")
    func orderingIsEvidenceFirst() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.pool.write { db in
            try insertEntity(db, id: "user", name: "User")
            try insertEntity(db, id: "weak", name: "Weak")
            try insertEntity(db, id: "strong", name: "Strong")
            try insertEdge(db, from: "user", to: "weak", type: "knows", mentionCount: 1)
            try insertEdge(db, from: "user", to: "strong", type: "knows", mentionCount: 40)
        }
        let relations = try await indexer(fixture.sqlite)
            .contextRelations(perSubjectLimit: 1, maximumRelations: 192)
        #expect(relations.map(\.object) == ["Strong"])
    }

    @Test("a missing store is an empty graph, not an error")
    func missingStoreReadsEmpty() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kg-relations-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: directory.appendingPathComponent("memory.sqlite")
        )
        #expect(try await indexer.contextRelations().isEmpty)
    }

    // MARK: - Fixtures

    private func indexer(_ sqlite: URL) throws -> SwiftNativeKnowledgeGraphIndexer {
        try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
    }

    private func fixture() throws -> (directory: URL, sqlite: URL, pool: DatabasePool) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kg-relations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqlite = directory.appendingPathComponent("memory.sqlite")
        let pool = try DatabasePool(path: sqlite.path)
        try SwiftNativeKnowledgeGraphIndexer.ensureSchema(pool)
        return (directory, sqlite, pool)
    }

    private func insertEntity(_ db: Database, id: String, name: String) throws {
        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES (?, ?, 'concept', NULL, '[]', 1,
                    '2026-08-16T00:00:00Z', '2026-08-16T00:00:00Z', 'test', NULL)
            """, arguments: [id, name])
    }

    private func insertEdge(
        _ db: Database, from: String, to: String, type: String, mentionCount: Int = 1
    ) throws {
        try db.execute(sql: """
            INSERT INTO kg_relationships
              (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
            VALUES (?, ?, ?, 0.7, ?, 'test', NULL)
            """, arguments: [from, to, type, mentionCount])
    }
}

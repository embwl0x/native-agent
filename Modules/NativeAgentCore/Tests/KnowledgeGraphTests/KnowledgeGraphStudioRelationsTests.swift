import Foundation
import GRDB
import PersistenceCore
import Testing
@testable import KnowledgeGraph

/// Desk 903 phase 3 — "Relations become KG edges; kill the mini-graph outright."
///
/// The journal's typed links used to live only inside the JSONL, reachable by
/// one hand-written filter. These pin that works and creators become entities
/// once, that a link becomes a real typed edge carrying the journal entry id as
/// provenance, and that the pass is idempotent — because the one-shot backfill
/// and the per-append update are deliberately the same operation.
@Suite("Studio relations become knowledge-graph edges")
struct KnowledgeGraphStudioRelationsTests {

    // MARK: - Pure derivation

    @Test("works and creators appear once however many entries name them")
    func nodesAreDedupedAcrossEntries() {
        let graph = SwiftNativeKnowledgeGraphIndexer.deriveStudioGraph(from: [
            entry(id: "e1", title: "The Green Ray", creator: "Éric Rohmer", medium: "film"),
            entry(id: "e2", title: "the green ray", creator: "éric rohmer"),
            entry(id: "e3", title: "Le Rayon Vert", creator: "Éric Rohmer"),
        ])
        #expect(graph.works.count == 2)
        #expect(graph.creators.count == 1)
        // One creator edge per work, not per entry.
        let createdBy = graph.edges.filter {
            $0.key.type == SwiftNativeKnowledgeGraphIndexer.studioCreatedByRelationType
        }
        #expect(createdBy.count == 2)
        // The edge names every entry that asserts it — that is the provenance.
        let rayEdge = createdBy.first { $0.value.contains("e1") }
        #expect(rayEdge?.value.sorted() == ["e1", "e2"])
    }

    @Test("a typed link becomes a work→work edge carrying the entry id")
    func typedLinksBecomeEdgesWithProvenance() {
        let graph = SwiftNativeKnowledgeGraphIndexer.deriveStudioGraph(from: [
            entry(id: "e1", title: "The Green Ray", creator: "Rohmer"),
            entry(
                id: "e2", title: "Kairos", creator: "Erpenbeck",
                relations: [StudioRelation(kind: .deepens, entryId: "e1")]
            ),
        ])
        let deepens = graph.edges.first { $0.key.type == "deepens" }
        #expect(deepens?.value == ["e2"])
        #expect(graph.unresolvedRelations == 0)
    }

    /// A later entry deepening an earlier one about the SAME work is a real and
    /// common shape. The graph holds no self-loop for it — the entry's own
    /// provenance line already says it, and the edge would add nothing.
    @Test("a link between two entries about one work makes no self-edge")
    func sameWorkLinksMakeNoSelfEdge() {
        let graph = SwiftNativeKnowledgeGraphIndexer.deriveStudioGraph(from: [
            entry(id: "e1", title: "The Green Ray"),
            entry(
                id: "e2", title: "The Green Ray",
                relations: [StudioRelation(kind: .revises, entryId: "e1")]
            ),
        ])
        #expect(graph.edges.keys.allSatisfy { $0.type != "revises" })
        #expect(graph.unresolvedRelations == 0)
    }

    /// A dangling link is a fact about the journal. It is counted, never given
    /// an invented endpoint.
    @Test("a link to an entry the journal does not hold is counted, not invented")
    func danglingLinksAreCounted() {
        let graph = SwiftNativeKnowledgeGraphIndexer.deriveStudioGraph(from: [
            entry(
                id: "e2", title: "Kairos",
                relations: [StudioRelation(kind: .echoes, entryId: "entry_that_never_existed")]
            )
        ])
        #expect(graph.unresolvedRelations == 1)
        #expect(graph.edges.keys.allSatisfy { $0.type != "echoes" })
    }

    // MARK: - Writing, and writing again

    @Test("edges land in the graph and a second pass changes nothing")
    func indexingIsIdempotent() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let entries = [
            entry(id: "e1", title: "The Green Ray", creator: "Éric Rohmer", medium: "film"),
            entry(
                id: "e2", title: "Kairos", creator: "Jenny Erpenbeck", medium: "novel",
                relations: [StudioRelation(kind: .deepens, entryId: "e1")]
            ),
        ]

        let first = try await indexer.indexStudioJournal(entries)
        #expect(first.graphAvailable)
        #expect(first.worksIndexed == 2)
        #expect(first.creatorsIndexed == 2)
        // Two created_by edges + one deepens edge.
        #expect(first.edgesWritten == 3)

        let before = try snapshot(fixture.pool)
        _ = try await indexer.indexStudioJournal(entries)
        let after = try snapshot(fixture.pool)
        #expect(before == after, "a re-derive must not inflate counts or duplicate rows")
    }

    /// Studio edges are selectable exactly like the other 94 — same reader,
    /// same caps — and they arrive carrying the entry that made the claim.
    @Test("the context-relation reader carries studio provenance")
    func contextRelationsCarryStudioProvenance() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        _ = try await indexer.indexStudioJournal([
            entry(id: "e1", title: "The Green Ray", creator: "Éric Rohmer"),
            entry(
                id: "e2", title: "Kairos", creator: "Jenny Erpenbeck",
                relations: [StudioRelation(kind: .deepens, entryId: "e1")]
            ),
        ])

        let relations = try await indexer.contextRelations()
        let deepens = try #require(relations.first { $0.predicate == "deepens" })
        #expect(deepens.subject == "Kairos")
        #expect(deepens.object == "The Green Ray")
        #expect(deepens.provenance == SwiftNativeKnowledgeGraphIndexer.studioProvenance)
        #expect(deepens.journalEntryIDs == ["e2"])

        // A creator is reachable as an endpoint, which is the whole point of
        // making them entities.
        #expect(relations.contains { $0.object == "Éric Rohmer" })
        // Nothing non-studio has been given a provenance it does not have.
        #expect(relations.allSatisfy { $0.provenance != nil || $0.journalEntryIDs.isEmpty })
    }

    /// The indexer never creates `memory.sqlite`. A fresh install with no memory
    /// has no graph to write into, and that is not an error — a journal write
    /// must never fail because the graph has not been born yet.
    @Test("a missing graph is unavailable, not a failure")
    func missingGraphIsUnavailable() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kg-studio-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: directory.appendingPathComponent("memory.sqlite")
        )
        let report = try await indexer.indexStudioJournal([entry(id: "e1", title: "A")])
        #expect(report == .unavailable)
    }

    /// The three memory-side collection lanes key on things a studio row
    /// deliberately does not have. Pinned here because a life record silently
    /// collected as garbage is exactly the failure this design cannot survive.
    @Test("studio rows are stamped so the memory lanes step over them")
    func studioRowsAreNotMemoryGarbage() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        _ = try await indexer.indexStudioJournal([
            entry(id: "e1", title: "The Green Ray", creator: "Éric Rohmer")
        ])
        let rows = try fixture.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT provenance, metadata_json FROM kg_entities")
        }
        #expect(!rows.isEmpty)
        for row in rows {
            let provenance: String? = row["provenance"]
            #expect(provenance == SwiftNativeKnowledgeGraphIndexer.studioProvenance,
                    "an explicit provenance keeps the row out of the stale sweep")
            let metadata: String = row["metadata_json"] ?? ""
            // Not a `swift-memory-kg-*` stamp: the memory rebuild's owned-row
            // delete cannot reach these.
            #expect(metadata.contains(SwiftNativeKnowledgeGraphIndexer.studioIndexVersion))
            #expect(!metadata.contains("swift-memory-kg"))
            // No `last_memory_id`, so GC's orphan scan skips the row outright.
            #expect(!metadata.contains("last_memory_id"))
        }
    }

    // MARK: - Fixtures

    private func fixture() throws -> (directory: URL, sqlite: URL, pool: DatabasePool) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kg-studio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqlite = directory.appendingPathComponent("memory.sqlite")
        let pool = try DatabasePool(path: sqlite.path)
        try SwiftNativeKnowledgeGraphIndexer.ensureSchema(pool)
        return (directory, sqlite, pool)
    }

    /// Everything a re-derive must leave untouched.
    private func snapshot(_ pool: DatabasePool) throws -> [String] {
        try pool.read { db in
            let entities = try Row.fetchAll(db, sql: """
                SELECT id, name, type, mention_count, provenance FROM kg_entities ORDER BY id
                """).map { "\($0["id"] ?? "")|\($0["name"] ?? "")|\($0["mention_count"] ?? 0)" }
            let edges = try Row.fetchAll(db, sql: """
                SELECT from_id, to_id, type, weight, mention_count, metadata_json
                FROM kg_relationships ORDER BY from_id, to_id, type
                """).map {
                    "\($0["from_id"] ?? "")|\($0["to_id"] ?? "")|\($0["type"] ?? "")"
                        + "|\($0["weight"] ?? 0)|\($0["mention_count"] ?? 0)"
                }
            return entities + edges
        }
    }

    private func entry(
        id: String,
        title: String,
        creator: String? = nil,
        medium: String? = nil,
        recordedAt: String = "2026-09-01T12:00:00.000000Z",
        relations: [StudioRelation] = []
    ) -> StudioJournalEntry {
        StudioJournalEntry(
            id: id,
            encounteredAt: recordedAt,
            recordedAt: recordedAt,
            work: StudioWork(title: title, creator: creator, medium: medium),
            origin: StudioOrigin(kind: .wandering),
            response: "A judgment, written out.",
            stance: StudioStanceValue(kind: .formed),
            relations: relations
        )
    }
}

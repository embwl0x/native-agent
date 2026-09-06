import Foundation
import GRDB
import PersistenceCore
import Testing
@testable import KnowledgeGraph

/// Agent's addendum (2026-09-01, binding): the journal's `relations` field stays
/// provenance-only and accepted, WITH a guard — every relation must have a graph
/// edge citing that entry id back. Fail loud, never repair, never block recall.
///
/// And the canon's evidence, read off the same edges: recurrence is `deepens` /
/// `echoes` pointing AT a work, counted as distinct entries — never `revises` or
/// `contradicts`, which are her arguing with an earlier judgment rather than
/// evidence that a work has become load-bearing.
@Suite("Studio relation audit and canon evidence")
struct KnowledgeGraphStudioRelationAuditTests {

    @Test("an indexed journal is consistent — every relation has an edge citing it")
    func indexedJournalPassesTheGuard() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let entries = [
            entry(id: "e1", title: "The Green Ray", creator: "Éric Rohmer"),
            entry(
                id: "e2", title: "Kairos", creator: "Erpenbeck",
                relations: [StudioRelation(kind: .deepens, entryId: "e1")]
            ),
        ]
        _ = try await indexer.indexStudioJournal(entries)
        let report = try await indexer.auditStudioRelations(entries)
        #expect(report.graphAvailable)
        #expect(report.isConsistent)
        #expect(report.relationsChecked == 1)
        #expect(report.unresolvedRelations == 0)
    }

    @Test("a relation with no edge behind it is REPORTED, not repaired")
    func missingEdgeIsReportedNotRepaired() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let indexed = [
            entry(id: "e1", title: "The Green Ray"),
            entry(id: "e2", title: "Kairos"),
        ]
        _ = try await indexer.indexStudioJournal(indexed)
        // The same journal, now claiming a link the graph was never told about.
        let claimed = [
            indexed[0],
            entry(
                id: "e2", title: "Kairos",
                relations: [StudioRelation(kind: .deepens, entryId: "e1")]
            ),
        ]
        let report = try await indexer.auditStudioRelations(claimed)
        #expect(!report.isConsistent)
        #expect(report.mismatches.count == 1)
        #expect(report.mismatches.first?.entryID == "e2")
        #expect(report.mismatches.first?.reason == .edgeMissing)
        // NEVER REPAIRED: the audit is read-only, so the graph is unchanged and
        // a second audit says exactly the same thing.
        let again = try await indexer.auditStudioRelations(claimed)
        #expect(again.mismatches.count == 1)
    }

    @Test("a same-work link and a dangling link are excused, not reported as defects")
    func selfAndDanglingLinksAreNotMismatches() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let entries = [
            entry(id: "e1", title: "The Green Ray"),
            entry(
                id: "e2", title: "The Green Ray",
                relations: [
                    StudioRelation(kind: .revises, entryId: "e1"),
                    StudioRelation(kind: .echoes, entryId: "never_existed"),
                ]
            ),
        ]
        _ = try await indexer.indexStudioJournal(entries)
        let report = try await indexer.auditStudioRelations(entries)
        #expect(report.isConsistent)
        #expect(report.selfRelations == 1)
        #expect(report.unresolvedRelations == 1)
        #expect(report.relationsChecked == 0)
    }

    @Test("recurrence evidence counts deepens/echoes into a work — not revises")
    func canonEvidenceCountsTheRightEdges() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let entries = [
            entry(id: "e1", title: "The Green Ray", creator: "Éric Rohmer",
                  recordedAt: "2026-01-01T12:00:00.000000Z"),
            entry(
                id: "e2", title: "Kairos", recordedAt: "2026-03-01T12:00:00.000000Z",
                relations: [StudioRelation(kind: .deepens, entryId: "e1")]
            ),
            entry(
                id: "e3", title: "Ozu Still", recordedAt: "2026-04-01T12:00:00.000000Z",
                relations: [StudioRelation(kind: .echoes, entryId: "e1")]
            ),
            entry(
                id: "e4", title: "A Loud Building", recordedAt: "2026-05-01T12:00:00.000000Z",
                relations: [StudioRelation(kind: .contradicts, entryId: "e1")]
            ),
        ]
        _ = try await indexer.indexStudioJournal(entries)
        let evidence = try await indexer.studioCanonEvidence(entries: entries, recallCounts: [:])
        let key = StudioCanonLaw.workKey(title: "The Green Ray", creator: "Éric Rohmer")
        let green = evidence.first { $0.workKey == key }
        #expect(green?.recurrenceEntryIDs.sorted() == ["e2", "e3"])
        // A contradiction is an argument, not evidence the work is load-bearing.
        #expect(green?.recurrenceEntryIDs.contains("e4") == false)
        // Two of them is not recurrence yet — the law still proposes nothing.
        #expect(StudioCanonLaw.proposals(
            evidence: evidence, membership: [:], now: Date(timeIntervalSince1970: 1_800_000_000)
        ).isEmpty)
    }

    @Test("a production pull recorded against a work reaches the law as evidence")
    func recallCountsJoinTheEvidence() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let entries = [entry(id: "e1", title: "Univers", creator: "Adrian Frutiger")]
        _ = try await indexer.indexStudioJournal(entries)
        let key = StudioCanonLaw.workKey(title: "Univers", creator: "Adrian Frutiger")
        let evidence = try await indexer.studioCanonEvidence(
            entries: entries,
            recallCounts: [key: (count: 2, lastAt: "2026-09-01T12:00:00.000000Z")]
        )
        #expect(evidence.first?.recallHits == 2)
        let drafts = StudioCanonLaw.proposals(
            evidence: evidence, membership: [:], now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(drafts.count == 1)
        #expect(drafts.first?.evidenceKind == .pulledInProduction)
    }


    /// "N LATER entries." An edge carries no time, so counting edges counted a
    /// forward reference — an EARLIER entry pointing at a work — as that work
    /// recurring. Recurrence has to mean she came back to it.
    @Test("an earlier entry linking forward is not recurrence")
    func forwardReferencesAreNotRecurrence() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let entries = [
            // e1 is the OLDEST and points forward at three works recorded after
            // it. Under an edge-count reading each of those works would show one
            // "later entry"; under the real rule none of them do.
            entry(
                id: "e1", title: "The Green Ray", recordedAt: "2026-01-01T12:00:00.000000Z",
                relations: [
                    StudioRelation(kind: .deepens, entryId: "e2"),
                    StudioRelation(kind: .echoes, entryId: "e3"),
                ]
            ),
            entry(id: "e2", title: "Kairos", recordedAt: "2026-06-01T12:00:00.000000Z"),
            entry(id: "e3", title: "Ozu Still", recordedAt: "2026-07-01T12:00:00.000000Z"),
        ]
        _ = try await indexer.indexStudioJournal(entries)
        let evidence = try await indexer.studioCanonEvidence(entries: entries, recallCounts: [:])
        #expect(evidence.allSatisfy { $0.recurrenceEntryIDs.isEmpty })
    }

    /// A relation the journal asserts but the graph does not carry is not
    /// evidence. That intersection is what makes the audit load-bearing rather
    /// than decorative.
    @Test("a relation the graph never indexed cannot argue for canon")
    func unindexedRelationsAreNotEvidence() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let indexed = [
            entry(id: "e1", title: "The Green Ray", recordedAt: "2026-01-01T12:00:00.000000Z"),
            entry(id: "e2", title: "Kairos", recordedAt: "2026-02-01T12:00:00.000000Z"),
            entry(id: "e3", title: "Ozu Still", recordedAt: "2026-03-01T12:00:00.000000Z"),
            entry(id: "e4", title: "A Wall", recordedAt: "2026-04-01T12:00:00.000000Z"),
        ]
        _ = try await indexer.indexStudioJournal(indexed)
        // The same journal, now claiming three links the graph was never told
        // about — exactly what a mid-flight index failure would leave behind.
        let claimed = [
            indexed[0],
            entry(id: "e2", title: "Kairos", recordedAt: "2026-02-01T12:00:00.000000Z",
                  relations: [StudioRelation(kind: .deepens, entryId: "e1")]),
            entry(id: "e3", title: "Ozu Still", recordedAt: "2026-03-01T12:00:00.000000Z",
                  relations: [StudioRelation(kind: .echoes, entryId: "e1")]),
            entry(id: "e4", title: "A Wall", recordedAt: "2026-04-01T12:00:00.000000Z",
                  relations: [StudioRelation(kind: .deepens, entryId: "e1")]),
        ]
        let evidence = try await indexer.studioCanonEvidence(entries: claimed, recallCounts: [:])
        #expect(evidence.allSatisfy { $0.recurrenceEntryIDs.isEmpty })
        // And the guard says why, loudly.
        let report = try await indexer.auditStudioRelations(claimed)
        #expect(report.mismatches.count == 3)
    }

    /// Canon identity is title + creator. Reading the target work off a folded
    /// TITLE merged two different works that happen to share a name, and the
    /// merged count could cross the threshold neither of them reached.
    @Test("two works sharing a title but not a creator stay separate")
    func creatorIsPartOfTheIdentityEndToEnd() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: fixture.sqlite)
        let entries = [
            entry(id: "e1", title: "Untitled", creator: "Agnes Martin",
                  recordedAt: "2026-01-01T12:00:00.000000Z"),
            entry(id: "e2", title: "Untitled", creator: "Donald Judd",
                  recordedAt: "2026-02-01T12:00:00.000000Z"),
        ]
        _ = try await indexer.indexStudioJournal(entries)
        let evidence = try await indexer.studioCanonEvidence(entries: entries, recallCounts: [:])
        #expect(evidence.count == 2)
        #expect(Set(evidence.map(\.creator)) == ["Agnes Martin", "Donald Judd"])
        // And a pull recorded against one of them is not credited to the other.
        let martin = StudioCanonLaw.workKey(title: "Untitled", creator: "Agnes Martin")
        let scoped = try await indexer.studioCanonEvidence(
            entries: entries,
            recallCounts: [martin: (count: 3, lastAt: "2026-09-01T12:00:00.000000Z")]
        )
        #expect(scoped.first { $0.workKey == martin }?.recallHits == 3)
        #expect(scoped.filter { $0.recallHits > 0 }.count == 1)
    }

    // MARK: - Fixtures

    private func fixture() throws -> (directory: URL, sqlite: URL, pool: DatabasePool) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kg-studio-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqlite = directory.appendingPathComponent("memory.sqlite")
        let pool = try DatabasePool(path: sqlite.path)
        try SwiftNativeKnowledgeGraphIndexer.ensureSchema(pool)
        return (directory, sqlite, pool)
    }

    private func entry(
        id: String,
        title: String,
        creator: String? = nil,
        recordedAt: String = "2026-09-01T12:00:00.000000Z",
        relations: [StudioRelation] = []
    ) -> StudioJournalEntry {
        StudioJournalEntry(
            id: id,
            encounteredAt: recordedAt,
            recordedAt: recordedAt,
            work: StudioWork(title: title, creator: creator),
            origin: StudioOrigin(kind: .wandering),
            response: "A judgment, written out.",
            stance: StudioStanceValue(kind: .formed),
            relations: relations
        )
    }
}

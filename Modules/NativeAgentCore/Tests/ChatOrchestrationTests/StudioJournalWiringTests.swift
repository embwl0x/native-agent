import Foundation
import GRDB
import Testing
@testable import ChatOrchestration
@testable import CognitiveSubstrate
@testable import KnowledgeGraph
import NativeAgentCore
@testable import PersistenceCore

/// Desk 903 phases 2, 3 and 5 at the point they actually meet: what a FILED
/// entry sets in motion.
///
/// The append is the canonical act. Everything here runs after it is already
/// durable, and none of it may make a successful write look like a failure.
@Suite("StudioJournalWiring")
struct StudioJournalWiringTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioWiring-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Mint the memory store the knowledge graph lives inside. The indexer never
    /// creates it — that is a deliberate stable failure — so a test that wants
    /// edges has to provide it, exactly like production does.
    @discardableResult
    private func makeGraphStore(at root: URL) throws -> URL {
        let directory = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqlite = directory.appendingPathComponent("memory.sqlite")
        let pool = try DatabasePool(path: sqlite.path)
        try SwiftNativeKnowledgeGraphIndexer.ensureSchema(pool)
        return sqlite
    }

    private func journalArguments(
        title: String,
        creator: String,
        response: String,
        relations: [JSONValue] = []
    ) -> [String: JSONValue] {
        var input: [String: JSONValue] = [
            "work": .object([
                "title": .string(title), "creator": .string(creator), "medium": .string("film"),
            ]),
            "reception": .object(["how": .string("screening"), "whole_or_part": .string("whole")]),
            "artifact_refs": .array([.string("/tmp/still.png")]),
            "origin": .object(["kind": .string("wandering")]),
            "response": .string(response),
            "stance": .object(["kind": .string("formed")]),
        ]
        if !relations.isEmpty { input["relations"] = .array(relations) }
        return input
    }

    @Test("a filed entry becomes graph edges that cite it")
    func filedEntryBecomesGraphEdges() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = try makeGraphStore(at: root)
        let d = SwiftToolDispatcher(dataRoot: root)

        let first = try await d.impl_studio_journal(input: journalArguments(
            title: "The Green Ray", creator: "Éric Rohmer",
            response: "The colour holds because he refuses to explain it."
        ))
        guard case .object(let firstObject) = first,
              case .string(let firstID)? = firstObject["entry_id"] else {
            Issue.record("studio_journal did not return an entry id: \(first)")
            return
        }

        let second = try await d.impl_studio_journal(input: journalArguments(
            title: "Kairos", creator: "Jenny Erpenbeck",
            response: "It is exactly right about how a thing ends before it stops.",
            relations: [.object(["kind": .string("deepens"), "entry_id": .string(firstID)])]
        ))
        guard case .object(let secondObject) = second else {
            Issue.record("studio_journal returned a non-object: \(second)")
            return
        }
        #expect(secondObject["status"] == .string("ok"))

        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
        let relations = try await indexer.contextRelations()
        let deepens = try #require(relations.first { $0.predicate == "deepens" })
        #expect(deepens.subject == "Kairos")
        #expect(deepens.object == "The Green Ray")
        // The provenance requirement: the edge names the judgment that made it.
        #expect(deepens.journalEntryIDs.contains { $0.hasPrefix("entry_") })
        #expect(deepens.provenance == SwiftNativeKnowledgeGraphIndexer.studioProvenance)
        // Creators are entities, so they are reachable endpoints too.
        #expect(relations.contains { $0.object == "Éric Rohmer" })
    }

    /// A fresh install has no `memory.sqlite`. The journal write must still
    /// succeed — the entry is the canonical record; the graph is a consumer.
    @Test("no graph yet is a quieter system, not a failed journal write")
    func missingGraphNeverFailsTheWrite() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = SwiftToolDispatcher(dataRoot: root)
        let result = try await d.impl_studio_journal(input: journalArguments(
            title: "The Green Ray", creator: "Éric Rohmer", response: "It holds."
        ))
        guard case .object(let object) = result else {
            Issue.record("studio_journal returned a non-object: \(result)")
            return
        }
        #expect(object["status"] == .string("ok"))
        // No graph, so nothing to report about one — and no invented counts.
        #expect(object["graph"] == nil)
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readJournal().count == 1)
    }

    /// The cognitive-bus seam: a filed entry reaches whoever owns the substrate.
    @Test("a filed entry is published onto the cognitive bus")
    func filedEntryReachesTheCognitiveBus() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = EntryInbox()
        await StudioJournalCognitiveBus.install { await inbox.record($0.id) }
        defer { Task { await StudioJournalCognitiveBus.install { _ in } } }

        let d = SwiftToolDispatcher(dataRoot: root)
        let result = try await d.impl_studio_journal(input: journalArguments(
            title: "The Green Ray", creator: "Éric Rohmer", response: "It holds."
        ))
        guard case .object(let object) = result,
              case .string(let entryID)? = object["entry_id"] else {
            Issue.record("studio_journal did not return an entry id: \(result)")
            return
        }
        #expect(await inbox.ids == [entryID])
    }

    /// Her vetoes, still standing after the wiring: a description-only consult
    /// can never become an entry, so it can never reach the graph or the bus.
    @Test("a description-only consult still cannot become an encounter")
    func descriptionOnlyConsultStillRefused() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeGraphStore(at: root)
        let d = SwiftToolDispatcher(dataRoot: root)
        let filed = try await d.impl_studio_consult(input: [
            "question": .string("Is the idea any good?"),
            "description": .string("A concept for a reissue series — no artwork yet."),
            "description_only": .bool(true),
        ])
        guard case .object(let filedObject) = filed,
              case .string(let consultID)? = filedObject["consult_id"] else {
            Issue.record("studio_consult did not return an id: \(filed)")
            return
        }
        var input = journalArguments(
            title: "Reissue series", creator: "Nobody", response: "Looks fine."
        )
        input["origin"] = .object(["kind": .string("consult"), "ref": .string(consultID)])
        let refused = try await d.impl_studio_journal(input: input)
        guard case .object(let refusedObject) = refused else {
            Issue.record("studio_journal returned a non-object: \(refused)")
            return
        }
        #expect(refusedObject["status"] == .string("refused"))
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readJournal().isEmpty)
    }

    private actor EntryInbox {
        private(set) var ids: [String] = []
        func record(_ id: String) { ids.append(id) }
    }
}

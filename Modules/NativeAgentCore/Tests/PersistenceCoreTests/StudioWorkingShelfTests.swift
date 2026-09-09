import Foundation
import Testing
@testable import PersistenceCore

@Suite("StudioWorkingShelf")
struct StudioWorkingShelfTests {
    @Test func orderedAtomicSelectionsPreserveJournalAndExactText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        let shelf = StudioWorkingShelf(dataRoot: root)
        #expect(try shelf.selections().isEmpty)
        #expect(try shelf.pointerLine() == nil)
        var entries: [StudioJournalEntry] = []
        for index in 0..<3 {
            entries.append(try await store.appendJournalEntry(
                encounteredAt: nil, work: StudioWork(title: "Work \(index)"), reception: StudioReception(),
                artifactRefs: ["/tmp/pair \(index)-a.png", "/tmp/pair \(index)-b.png"],
                origin: StudioOrigin(kind: .project), response: "The spacing holds. Keep this—exactly.",
                stance: StudioStanceValue(kind: .open), relations: [], tags: []))
        }
        let journal = try Data(contentsOf: store.journalPath)
        func slot(_ index: Int, sentence: String = "Keep this—exactly.") -> JSONValue {
            .object(["entry_id": .string(entries[index].id), "selected_sentence": .string(sentence), "title": .string("Choice \(index)")])
        }
        try await shelf.replace(.array([slot(2), slot(0), slot(1)]))
        #expect(try StudioWorkingShelf(dataRoot: root).selections().map(\.entryID) == [entries[2].id, entries[0].id, entries[1].id])
        #expect(try shelf.selections().first?.limitation == "Not yet tested")
        #expect(try shelf.pointerLine() == "Working shelf: Choice 2; Choice 0; Choice 1; open with studio_shelf_read")
        let saved = try Data(contentsOf: shelf.path)
        for invalid: JSONValue in [
            .array([slot(0), slot(1), slot(2), slot(0)]), .array([slot(0), slot(0)]),
            .array([slot(0, sentence: "Keep this-exactly.")]), .array([slot(0, sentence: "")]),
            .array([slot(0, sentence: "spacing holds")]),
            .array([slot(0, sentence: "The spacing holds. Keep this—exactly.")]),
            .array([slot(0, sentence: "The spacing holds")]),
            .array([.object(["entry_id": .string(entries[0].id), "selected_sentence": .string("The spacing holds.")])]),
            .array([.object(["entry_id": .string(entries[0].id), "title": .string(" "), "selected_sentence": .string("The spacing holds.")])]),
            .array([.object(["entry_id": .string("absent"), "title": .string("Absent"), "selected_sentence": .string("No.")])]),
            .object([:]),
        ] {
            await #expect(throws: (any Error).self) { try await shelf.replace(invalid) }
            #expect(try Data(contentsOf: shelf.path) == saved)
        }
        let read = try await shelf.read { _ in "missing" }
        guard case .object(let obj) = read, case .array(let cards)? = obj["slots"],
              case .object(let first)? = cards.first, case .array(let refs)? = first["work_refs"] else {
            Issue.record("Missing shelf cards"); return
        }
        #expect(first["selected_sentence"] == .string("Keep this—exactly."))
        #expect(refs.count == 2)
        #expect(refs.allSatisfy { if case .object(let ref) = $0 { return ref["availability"] == .string("missing") }; return false })
        try await shelf.replace(.array([slot(1), slot(2)]))
        #expect(try shelf.selections().map(\.entryID) == [entries[1].id, entries[2].id])
        try await shelf.replace(.array([]))
        #expect(try shelf.pointerLine() == nil)
        #expect(try Data(contentsOf: store.journalPath) == journal)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: shelf.path)
        await #expect(throws: (any Error).self) { try await shelf.replace(.array([])) }
        #expect(try Data(contentsOf: shelf.path) == corrupt)
    }

    @Test func requiresWorkAndResolvesConsultPairsWithoutChangingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        let shelf = StudioWorkingShelf(dataRoot: root)
        let consult = try await store.fileConsult(
            artifactRefs: ["designs/a.png", "designs/b.png"], description: nil, portionAvailable: nil,
            question: "Does the pair hold?", projectContext: nil, stage: nil, constraints: nil,
            priorDiscussion: nil, descriptionOnly: false)
        let paired = try await store.appendJournalEntry(
            encounteredAt: nil, work: StudioWork(title: "Pair"), reception: StudioReception(),
            artifactRefs: [], origin: StudioOrigin(kind: .consult, ref: consult.id),
            response: "Does it hold? It does!", stance: StudioStanceValue(kind: .open), relations: [], tags: [])
        let noWork = try await store.appendJournalEntry(
            encounteredAt: nil, work: StudioWork(title: "No work"), reception: StudioReception(),
            artifactRefs: [], origin: StudioOrigin(kind: .project), response: "The spacing holds.",
            stance: StudioStanceValue(kind: .open), relations: [], tags: [])
        func selection(_ entry: StudioJournalEntry, _ sentence: String) -> JSONValue {
            .object(["entry_id": .string(entry.id), "title": .string("Chosen title"), "selected_sentence": .string(sentence)])
        }
        try await shelf.replace(.array([selection(paired, "It does!")]))
        let saved = try Data(contentsOf: shelf.path)
        let journal = try Data(contentsOf: store.journalPath)
        do {
            try await shelf.replace(.array([selection(paired, "Does it hold?"), selection(noWork, "The spacing holds.")]))
            Issue.record("An encounter without work must be refused")
        } catch {
            #expect(error.localizedDescription.contains("this encounter has no openable work"))
        }
        #expect(try Data(contentsOf: shelf.path) == saved)
        let read = try await shelf.read { _ in "missing" }
        guard case .object(let result) = read, case .array(let cards)? = result["slots"],
              case .object(let card)? = cards.first, case .array(let refs)? = card["work_refs"] else {
            Issue.record("Missing consult work"); return
        }
        #expect(refs.count == 2)
        #expect(refs.allSatisfy { if case .object(let ref) = $0 { return ref["source"] == .string("consult") }; return false })
        #expect(try Data(contentsOf: store.journalPath) == journal)
    }
}

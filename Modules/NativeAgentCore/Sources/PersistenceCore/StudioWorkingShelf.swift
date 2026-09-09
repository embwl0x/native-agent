import Foundation
import NaturalLanguage

/// Explicit selections beside the additive journal. No cached artifacts or usage state.
public struct StudioWorkingShelf: Sendable {
    public let dataRoot: URL
    public var path: URL { dataRoot.appendingPathComponent("studio/working_shelf.json") }
    public init(dataRoot: URL) { self.dataRoot = dataRoot }

    public struct Refusal: Error, LocalizedError, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Slot: Sendable, Equatable {
        public let entryID: String
        public let title: String
        public let sentence: String
        public let quoteField: String
        public let limitation: String

        public var json: JSONValue {
            let row: [String: JSONValue] = [
                "entry_id": .string(entryID), "selected_sentence": .string(sentence),
                "title": .string(title),
                "quote_field": .string(quoteField), "limitation": .string(limitation),
            ]
            return .object(row)
        }
    }

    public static func decodeSlots(_ value: JSONValue) throws -> [Slot] {
        guard case .array(let rows) = value, rows.count <= 3 else {
            throw Refusal(message: "Supply a complete ordered slots array with at most three entries; [] empties the shelf.")
        }
        var seen = Set<String>()
        return try rows.map { row in
            guard case .object(let obj) = row,
                  Set(obj.keys).isSubset(of: ["entry_id", "title", "selected_sentence", "quote_field", "limitation"]),
                  case .string(let id)? = obj["entry_id"], !id.isEmpty,
                  seen.insert(id).inserted,
                  case .string(let sentence)? = obj["selected_sentence"],
                  !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Refusal(message: "Each slot needs a distinct entry_id and an exact selected_sentence; unknown fields are refused.")
            }
            func optional(_ key: String) throws -> String? {
                guard let value = obj[key] else { return nil }
                guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Refusal(message: "\(key) must be a nonempty string when supplied.")
                }
                return text
            }
            guard let title = try optional("title") else {
                throw Refusal(message: "Each slot needs a short title chosen for the shelf.")
            }
            let field = try optional("quote_field") ?? "response"
            let limitation = try optional("limitation") ?? "Not yet tested"
            guard ["response", "stance.reason"].contains(field) else {
                throw Refusal(message: "quote_field must be response or stance.reason.")
            }
            guard title.utf8.count <= 120,
                  !title.contains(where: { $0.isNewline }),
                  sentence.utf8.count <= 4096, limitation.utf8.count <= 2048 else {
                throw Refusal(message: "Use a short title and aim for about 60 prose words per slot. Choose a shorter sentence from the journal rather than clipping it.")
            }
            return Slot(entryID: id, title: title, sentence: sentence, quoteField: field, limitation: limitation)
        }
    }

    public func selections() throws -> [Slot] {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        guard case .object(let document) = try JSONValue.parse(data),
              Set(document.keys) == ["version", "slots"], document["version"] == .int(1),
              let slots = document["slots"] else {
            throw Refusal(message: "Working shelf is unavailable; its existing file was preserved.")
        }
        return try Self.decodeSlots(slots)
    }

    private func entry(_ id: String, in entries: [StudioJournalEntry]) -> StudioJournalEntry? {
        let matches = entries.filter { $0.id == id }
        guard let first = matches.first, matches.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func validates(_ slot: Slot, entry: StudioJournalEntry) -> Bool {
        let source = slot.quoteField == "response" ? entry.response : entry.stance.reason
        guard let source else { return false }
        // One complete sentence, as the platform sentence tokenizer sees it (so
        // "Dr. Smith arrived." is one sentence, not two). Compare bytes so even
        // canonically equivalent Unicode cannot rewrite a quotation.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = source
        var found = false
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            if source[range].trimmingCharacters(in: .whitespacesAndNewlines).utf8.elementsEqual(slot.sentence.utf8) { found = true; return false }
            return true
        }
        return found
    }

    public func replace(_ value: JSONValue) async throws {
        let slots = try Self.decodeSlots(value)
        let persistence = SwiftNativePersistenceCore()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try await persistence.withFileLock(path) {
            _ = try selections() // Corruption cannot be cleared by a set request.
            let store = SwiftNativeStudioStore(dataRoot: dataRoot)
            let entries = try await store.journalEntriesIncludingArchive()
            for slot in slots {
                guard let entry = entry(slot.entryID, in: entries), validates(slot, entry: entry) else {
                    throw Refusal(message: "Entry \(slot.entryID) is unavailable or selected_sentence is not one complete sentence verbatim in \(slot.quoteField). Fragments and multiple sentences are not accepted. Choose a shorter existing sentence rather than clipping or rewriting it. The shelf is unchanged.")
                }
                var workRefs = entry.artifactRefs
                if entry.origin.kind == .consult, let id = entry.origin.ref,
                   let consult = try? await store.readConsult(id: id), !consult.descriptionOnly {
                    workRefs.append(contentsOf: consult.artifactRefs)
                }
                guard workRefs.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw Refusal(message: "Entry \(slot.entryID): this encounter has no openable work. The shelf is unchanged.")
                }
            }
            try await persistence.writeJSON(.object(["version": .int(1), "slots": .array(slots.map(\.json))]), to: path)
        }
    }

    /// Metadata only. The caller supplies the existing file authorization policy.
    public func read(availability: @Sendable (String) async -> String) async throws -> JSONValue {
        let slots = try selections()
        guard !slots.isEmpty else { return .object(["status": .string("ok"), "slots": .array([])]) }
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        let entries = try await store.journalEntriesIncludingArchive()
        var cards: [JSONValue] = []
        for slot in slots {
            guard let entry = entry(slot.entryID, in: entries), validates(slot, entry: entry) else {
                cards.append(.object(["entry_id": .string(slot.entryID), "entry_availability": .string("entry unavailable")]))
                continue
            }
            var refs: [JSONValue] = []
            var seen = Set<String>()
            for ref in entry.artifactRefs where seen.insert(ref).inserted {
                refs.append(.object(["ref": .string(ref), "source": .string("entry"), "availability": .string(await availability(ref))]))
            }
            var consultUnavailable = false
            if entry.origin.kind == .consult, let id = entry.origin.ref {
                if let consult = try? await store.readConsult(id: id), !consult.descriptionOnly {
                    for ref in consult.artifactRefs where seen.insert(ref).inserted {
                        refs.append(.object(["ref": .string(ref), "source": .string("consult"), "availability": .string(await availability(ref))]))
                    }
                } else { consultUnavailable = true }
            }
            guard case .object(var card) = slot.json else { continue }
            card["entry_availability"] = .string("available")
            card["work_refs"] = .array(refs)
            if consultUnavailable { card["consult_availability"] = .string("unavailable") }
            cards.append(.object(card))
        }
        return .object(["status": .string("ok"), "slots": .array(cards)])
    }

    /// Titles only, for the existing Studio pointer. Never reads journal judgments or artifacts.
    public func pointerLine() throws -> String? {
        let slots = try selections()
        guard !slots.isEmpty else { return nil }
        return "Working shelf: " + slots.map(\.title).joined(separator: "; ") + "; open with studio_shelf_read"
    }
}

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

    /// What a correction did to this slot's sentence: the amendments that
    /// touch it, and the sentence as it now READS.
    struct Supersession {
        /// In document order, the amendments whose passage overlaps the
        /// sentence. Never empty.
        let amendments: [StudioAmendment]
        /// The selected sentence with each correction shown IN PLACE — only the
        /// corrected words struck through, the rest of the sentence intact.
        let correctedSentence: String

        var first: StudioAmendment { amendments[0] }
    }

    /// The corrections that superseded this slot's sentence, if any. A
    /// correction that covers any part of the quoted sentence supersedes it:
    /// serving the sentence unchanged would present words she has already
    /// struck through as what she currently says.
    ///
    /// RANGES, not string containment: a correction over "beta. Gamma" overlaps
    /// the shelved sentence "Alpha beta." without either string containing the
    /// other, and containment could not say WHERE inside the sentence the
    /// correction lands. Both are resolved in the ORIGINAL response, the same
    /// way `responseAsCorrected` and the amend write path resolve them.
    ///
    /// Only `response` is amendable, so a `stance.reason` quote never matches.
    private func supersession(_ slot: Slot, entry: StudioJournalEntry) -> Supersession? {
        guard slot.quoteField == "response",
              let response = entry.response,
              let sentence = response.range(of: slot.sentence) else { return nil }
        var applied: [(range: Range<String.Index>, amendment: StudioAmendment)] = []
        for amendment in entry.amendments {
            guard let passage = amendment.supersedes,
                  let range = response.range(of: passage),
                  range.overlaps(sentence),
                  // An amendment overlapping one already applied would nest one
                  // strike-through inside another, exactly as the projection in
                  // `responseAsCorrected` guards against.
                  !applied.contains(where: { $0.range.overlaps(range) }) else { continue }
            applied.append((range, amendment))
        }
        guard !applied.isEmpty else { return nil }
        applied.sort { $0.range.lowerBound < $1.range.lowerBound }
        // Rebuild the SENTENCE the way `responseAsCorrected` rebuilds the whole
        // response, clipped to the sentence: a correction reaching past either
        // end marks only the words inside the sentence it is shown beside.
        var rebuilt = ""
        var cursor = sentence.lowerBound
        for (range, amendment) in applied {
            let clipped = max(range.lowerBound, sentence.lowerBound)..<min(range.upperBound, sentence.upperBound)
            if cursor < clipped.lowerBound { rebuilt += response[cursor..<clipped.lowerBound] }
            rebuilt += "~~\(response[clipped])~~ \(amendment.correction) [corrected \(amendment.amendedOn) — \(amendment.reason)]"
            cursor = max(cursor, clipped.upperBound)
        }
        if cursor < sentence.upperBound { rebuilt += response[cursor..<sentence.upperBound] }
        return Supersession(amendments: applied.map(\.amendment), correctedSentence: rebuilt)
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
                // The journal line still says it; she no longer does.
                if let superseded = supersession(slot, entry: entry) {
                    let amendment = superseded.first
                    throw Refusal(message: "Entry \(slot.entryID): that sentence was corrected on \(amendment.amendedOn) (\(amendment.reason)) and now reads \"\(amendment.correction)\". Shelve the corrected sentence instead. The shelf is unchanged.")
                }
                if entry.correctionsUnreadable {
                    throw Refusal(message: "Entry \(slot.entryID): its corrections could not be read (journal/amendments.jsonl is damaged), so whether that sentence still stands is unknown. The shelf is unchanged.")
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
            // A shelved sentence is served as CURRENT, so a correction filed
            // since has to travel with it — struck through, with the correction,
            // its date and its reason — or the shelf keeps a retracted claim in
            // circulation with none of that attached.
            if let superseded = supersession(slot, entry: entry) {
                let amendment = superseded.first
                card["selected_sentence_status"] = .string("superseded")
                // The correction shown at the passage it actually covers, not
                // the whole sentence struck out: striking words she never
                // retracted misreports her as having withdrawn them.
                card["selected_sentence_as_corrected"] = .string(superseded.correctedSentence)
                card["correction"] = .string(amendment.correction)
                card["corrected_on"] = .string(amendment.amendedOn)
                card["correction_reason"] = .string(amendment.reason)
            } else if entry.correctionsUnreadable {
                card["selected_sentence_status"] = .string("corrections unreadable")
                card["corrections_note"] = .string(
                    "journal/amendments.jsonl is damaged — this sentence may already have been corrected")
            } else if !entry.amendments.isEmpty {
                card["selected_sentence_status"] = .string("current")
                if let corrected = entry.responseAsCorrected {
                    card["entry_response_as_corrected"] = .string(corrected)
                }
            }
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

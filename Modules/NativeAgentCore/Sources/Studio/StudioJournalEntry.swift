import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import CryptoKit
// Blueprint: | `StudioJournalEntry.swift` | Encounter, journal and amendment vocabulary; corrections project without rewriting journal bytes |

public enum StudioOriginKind: String, Sendable, CaseIterable, Equatable {
    case wandering, consult, project
}

public enum StudioStance: String, Sendable, CaseIterable, Equatable {
    case open, formed, abstained
}

public enum StudioRelationKind: String, Sendable, CaseIterable, Equatable {
    case deepens, contradicts, revises, echoes
}

/// What was encountered. `title` is the only required part — the rest is whatever is actually known, never invented to fill a field.
public struct StudioWork: Sendable, Equatable {
    public var title: String
    public var creator: String?
    public var medium: String?
    public var date: String?
    public var version: String?
    public var edition: String?

    public init(
        title: String,
        creator: String? = nil,
        medium: String? = nil,
        date: String? = nil,
        version: String? = nil,
        edition: String? = nil
    ) {
        self.title = title
        self.creator = creator
        self.medium = medium
        self.date = date
        self.version = version
        self.edition = edition
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["title": .string(title)]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        put("creator", creator)
        put("medium", medium)
        put("date", date)
        put("version", version)
        put("edition", edition)
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioWork? {
        guard case .object(let obj) = value, case .string(let title)? = obj["title"] else { return nil }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key], !s.isEmpty { return s }
            return nil
        }
        return StudioWork(
            title: title, creator: str("creator"), medium: str("medium"),
            date: str("date"), version: str("version"), edition: str("edition")
        )
    }
}

/// HOW the work was received. Both fields are free text on purpose: the design names examples ("original, reproduction, screening, playthrough, excerpt"), not a closed set, and a closed enum would force a caller to misdescribe a reception
/// the vocabulary does not cover — the exact dishonesty the honest-encounter rule exists to prevent.
public struct StudioReception: Sendable, Equatable {
    public var how: String?
    public var wholeOrPart: String?

    public init(how: String? = nil, wholeOrPart: String? = nil) {
        self.how = how
        self.wholeOrPart = wholeOrPart
    }

    public var isEmpty: Bool { (how ?? "").isEmpty && (wholeOrPart ?? "").isEmpty }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        if let how, !how.isEmpty { obj["how"] = .string(how) }
        if let wholeOrPart, !wholeOrPart.isEmpty { obj["whole_or_part"] = .string(wholeOrPart) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioReception {
        guard case .object(let obj) = value else { return StudioReception() }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key], !s.isEmpty { return s }
            return nil
        }
        return StudioReception(how: str("how"), wholeOrPart: str("whole_or_part"))
    }
}

public struct StudioOrigin: Sendable, Equatable {
    public var kind: StudioOriginKind
    public var ref: String?

    public init(kind: StudioOriginKind, ref: String? = nil) {
        self.kind = kind
        self.ref = ref
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let ref, !ref.isEmpty { obj["ref"] = .string(ref) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioOrigin? {
        guard case .object(let obj) = value,
              case .string(let kindRaw)? = obj["kind"],
              let kind = StudioOriginKind(rawValue: kindRaw) else { return nil }
        var ref: String?
        if case .string(let r)? = obj["ref"], !r.isEmpty { ref = r }
        return StudioOrigin(kind: kind, ref: ref)
    }
}

/// Where the judgment stands. `abstained` is a first-class outcome, not a failure — and it carries an optional reason, never a penalty.
public struct StudioStanceValue: Sendable, Equatable {
    public var kind: StudioStance
    public var reason: String?

    public init(kind: StudioStance, reason: String? = nil) {
        self.kind = kind
        self.reason = reason
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let reason, !reason.isEmpty { obj["reason"] = .string(reason) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioStanceValue? {
        guard case .object(let obj) = value,
              case .string(let kindRaw)? = obj["kind"],
              let kind = StudioStance(rawValue: kindRaw) else { return nil }
        var reason: String?
        if case .string(let r)? = obj["reason"], !r.isEmpty { reason = r }
        return StudioStanceValue(kind: kind, reason: reason)
    }
}

/// Self-contained provenance linking a new judgment to an earlier entry; both remain in the journal. The knowledge graph owns traversal and cites entries on its edges; recall filters inspect the stored links.
public struct StudioRelation: Sendable, Equatable {
    public var kind: StudioRelationKind
    public var entryId: String

    public init(kind: StudioRelationKind, entryId: String) {
        self.kind = kind
        self.entryId = entryId
    }

    public func toJSON() -> JSONValue {
        .object(["kind": .string(kind.rawValue), "entry_id": .string(entryId)])
    }

    public static func fromJSON(_ value: JSONValue) -> StudioRelation? {
        guard case .object(let obj) = value,
              case .string(let kindRaw)? = obj["kind"],
              let kind = StudioRelationKind(rawValue: kindRaw),
              case .string(let entryId)? = obj["entry_id"],
              !entryId.isEmpty else { return nil }
        return StudioRelation(kind: kind, entryId: entryId)
    }
}

/// One encounter and its written response; no rating, score, confidence, sentiment or canon-status field.
public struct StudioJournalEntry: Sendable, Equatable {
    public var id: String
    public var encounteredAt: String
    public var recordedAt: String
    public var work: StudioWork
    public var reception: StudioReception
    public var artifactRefs: [String]
    public var origin: StudioOrigin
    public var response: String?
    public var stance: StudioStanceValue
    public var relations: [StudioRelation]
    public var tags: [String]
    /// Corrections filed against this entry, oldest first. NEVER written into `journal.jsonl` — they live in `journal/amendments.jsonl` and are projected onto the entry on every read, so the entry reads as corrected without the line it was
    /// written on ever changing. See `StudioAmendment`.
    public var amendments: [StudioAmendment]
    /// TRUE when `journal/amendments.jsonl` could not be read whole on the read that produced this entry — a malformed row, a row this build cannot decode, or a file-level read failure. Which entry lost a correction is not knowable from a
    /// damaged file, so every entry in that read says so, and nothing may present the response as healthy. Never written to disk.
    public var correctionsUnreadable: Bool = false

    public init(
        id: String,
        encounteredAt: String,
        recordedAt: String,
        work: StudioWork,
        reception: StudioReception = StudioReception(),
        artifactRefs: [String] = [],
        origin: StudioOrigin,
        response: String? = nil,
        stance: StudioStanceValue,
        relations: [StudioRelation] = [],
        tags: [String] = [],
        amendments: [StudioAmendment] = [],
        correctionsUnreadable: Bool = false
    ) {
        self.id = id
        self.encounteredAt = encounteredAt
        self.recordedAt = recordedAt
        self.work = work
        self.reception = reception
        self.artifactRefs = artifactRefs
        self.origin = origin
        self.response = response
        self.stance = stance
        self.relations = relations
        self.tags = tags
        self.amendments = amendments
        self.correctionsUnreadable = correctionsUnreadable
    }

    /// The response as it now READS: the original text with every correction shown in place. A superseded passage is kept and struck through, the correction stands beside it with its date and reason, and an appended correction becomes a
    /// dated block at the end. Nothing here removes a word she wrote — a reader can always see what the entry used to say.
    public var responseAsCorrected: String? {
        guard !amendments.isEmpty else { return response }
        var text = correctedResponse().text
        for amendment in amendments where amendment.supersedes == nil {
            let block = "[Correction \(amendment.amendedOn) — \(amendment.reason)] \(amendment.correction)"
            text = text.isEmpty ? block : text + "\n\n" + block
        }
        return text.isEmpty ? nil : text
    }

    /// Resolve against original text, accepting the first nonoverlapping amendments that touch the selection, then render only inside its bounds.
    func correctedResponse(in selection: Range<String.Index>? = nil) -> (text: String, amendments: [StudioAmendment]) {
        let original = response ?? ""
        let bounds = selection ?? original.startIndex..<original.endIndex
        var applied: [(range: Range<String.Index>, amendment: StudioAmendment)] = []
        for amendment in amendments where !original.isEmpty {
            guard let passage = amendment.supersedes,
                  let range = original.range(of: passage),
                  selection == nil || range.overlaps(bounds),
                  !applied.contains(where: { $0.range.overlaps(range) }) else { continue }
            applied.append((range, amendment))
        }
        applied.sort { $0.range.lowerBound < $1.range.lowerBound }
        var text = ""
        var cursor = bounds.lowerBound
        for (range, amendment) in applied {
            let clipped = max(range.lowerBound, bounds.lowerBound)..<min(range.upperBound, bounds.upperBound)
            if cursor < clipped.lowerBound { text += original[cursor..<clipped.lowerBound] }
            text += "~~\(original[clipped])~~ \(amendment.correction) [corrected \(amendment.amendedOn) — \(amendment.reason)]"
            cursor = max(cursor, clipped.upperBound)
        }
        if cursor < bounds.upperBound { text += original[cursor..<bounds.upperBound] }
        return (text, applied.map(\.amendment))
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "encountered_at": .string(encounteredAt),
            "recorded_at": .string(recordedAt),
            "work": work.toJSON(),
            "origin": origin.toJSON(),
            "stance": stance.toJSON(),
        ]
        if !reception.isEmpty { obj["reception"] = reception.toJSON() }
        if !artifactRefs.isEmpty { obj["artifact_refs"] = .array(artifactRefs.map { .string($0) }) }
        if let response, !response.isEmpty { obj["response"] = .string(response) }
        if !relations.isEmpty { obj["relations"] = .array(relations.map { $0.toJSON() }) }
        if !tags.isEmpty { obj["tags"] = .array(tags.map { .string($0) }) }
        // Only ever present on a READ (the append path writes a fresh entry with none). `response` above stays exactly as it was written; this pair is what makes the correction visible wherever the entry is shown.
        if !amendments.isEmpty {
            obj["amendments"] = .array(amendments.map { $0.toJSON() })
            if let corrected = responseAsCorrected { obj["response_as_corrected"] = .string(corrected) }
        }
        // Damage is louder than silence: a reader that cannot see this entry's corrections must not be shown the response as if it still stands.
        if correctionsUnreadable {
            obj["corrections_unreadable"] = .bool(true)
            obj["corrections_note"] = .string(
                "corrections unreadable — journal/amendments.jsonl is damaged, so this response may have been corrected in ways not shown here")
        }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioJournalEntry? {
        guard case .object(let obj) = value,
              case .string(let id)? = obj["id"],
              case .string(let recordedAt)? = obj["recorded_at"],
              let work = obj["work"].flatMap(StudioWork.fromJSON),
              let origin = obj["origin"].flatMap(StudioOrigin.fromJSON),
              let stance = obj["stance"].flatMap(StudioStanceValue.fromJSON) else { return nil }
        var encounteredAt = recordedAt
        if case .string(let e)? = obj["encountered_at"], !e.isEmpty { encounteredAt = e }
        let reception = obj["reception"].map(StudioReception.fromJSON) ?? StudioReception()
        var refs: [String] = []
        if case .array(let arr)? = obj["artifact_refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        var response: String?
        if case .string(let r)? = obj["response"], !r.isEmpty { response = r }
        var relations: [StudioRelation] = []
        if case .array(let arr)? = obj["relations"] {
            relations = arr.compactMap { StudioRelation.fromJSON($0) }
        }
        var tags: [String] = []
        if case .array(let arr)? = obj["tags"] {
            tags = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        var amendments: [StudioAmendment] = []
        if case .array(let arr)? = obj["amendments"] {
            amendments = arr.compactMap { StudioAmendment.fromJSON($0) }
        }
        return StudioJournalEntry(
            id: id, encounteredAt: encounteredAt, recordedAt: recordedAt,
            work: work, reception: reception, artifactRefs: refs, origin: origin,
            response: response, stance: stance, relations: relations, tags: tags,
            amendments: amendments
        )
    }
}

// MARK: - Amendment

/// A factual correction in journal/amendments.jsonl; journal bytes stay append-only. Reads project corrections onto entries; a changed judgment belongs in a new encounter. Nil supersedes adds a dated block; passage corrections keep the
/// original struck through with date and reason.
public struct StudioAmendment: Sendable, Equatable {
    public var id: String
    public var entryId: String
    public var amendedAt: String
    /// Why it is being corrected, in her words. Required — a correction with no reason is a rewrite wearing a date.
    public var reason: String
    /// The exact passage of the original `response` this supersedes, or nil for an appended correction.
    public var supersedes: String?
    public var correction: String

    public init(
        id: String,
        entryId: String,
        amendedAt: String,
        reason: String,
        supersedes: String? = nil,
        correction: String
    ) {
        self.id = id
        self.entryId = entryId
        self.amendedAt = amendedAt
        self.reason = reason
        self.supersedes = supersedes
        self.correction = correction
    }

    /// The date a reader sees on the correction — day precision, which is what a corrected record needs to say.
    public var amendedOn: String { String(amendedAt.prefix(10)) }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "entry_id": .string(entryId),
            "amended_at": .string(amendedAt),
            "reason": .string(reason),
            "correction": .string(correction),
        ]
        if let supersedes, !supersedes.isEmpty { obj["supersedes"] = .string(supersedes) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioAmendment? {
        guard case .object(let obj) = value,
              case .string(let id)? = obj["id"],
              case .string(let entryId)? = obj["entry_id"],
              case .string(let amendedAt)? = obj["amended_at"],
              case .string(let reason)? = obj["reason"],
              case .string(let correction)? = obj["correction"],
              !correction.isEmpty else { return nil }
        var supersedes: String?
        if case .string(let s)? = obj["supersedes"], !s.isEmpty { supersedes = s }
        return StudioAmendment(
            id: id, entryId: entryId, amendedAt: amendedAt,
            reason: reason, supersedes: supersedes, correction: correction
        )
    }
}

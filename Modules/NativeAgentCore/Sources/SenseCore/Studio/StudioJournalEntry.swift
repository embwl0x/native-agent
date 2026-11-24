import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import CryptoKit
// Blueprint: | `StudioJournalEntry.swift` | Strict encounter rows and projected amendments |

/// Shared field checks for current saved Studio records. Missing optional fields are legitimate; a present malformed field rejects the entire owning row.
struct StudioSavedRow {
    let fields: [String: JSONValue]
    init(_ value: JSONValue) throws {
        guard case .object(let fields) = value else { throw CocoaError(.fileReadCorruptFile) }
        self.fields = fields
    }
    func string(_ key: String) throws -> String {
        guard case .string(let value)? = fields[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
    func optionalString(_ key: String) throws -> String? {
        guard fields[key] != nil else { return nil }
        return try string(key)
    }
    func strings(_ key: String, required: Bool = false) throws -> [String] {
        try rows(key, required: required) { value in
            guard case .string(let text) = value, !text.isEmpty else { return nil }
            return text
        }
    }
    func rows<T>(_ key: String, required: Bool = false, decode: (JSONValue) -> T?) throws -> [T] {
        guard let value = fields[key] else {
            if required { throw CocoaError(.fileReadCorruptFile) }
            return []
        }
        guard case .array(let values) = value else { throw CocoaError(.fileReadCorruptFile) }
        return try values.map {
            guard let row = decode($0) else { throw CocoaError(.fileReadCorruptFile) }
            return row
        }
    }
}

public enum StudioOriginKind: String, Sendable, CaseIterable, Equatable {
    case wandering, consult, project
}

public enum StudioStance: String, Sendable, CaseIterable, Equatable {
    case open, formed, abstained
}

public enum StudioRelationKind: String, Sendable, CaseIterable, Equatable {
    case deepens, contradicts, revises, echoes
}

/// Only title is required; optional encounter facts must never be invented.
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
        do {
            let row = try StudioSavedRow(value)
            return try StudioWork(title: row.string("title"), creator: row.optionalString("creator"),
                medium: row.optionalString("medium"), date: row.optionalString("date"),
                version: row.optionalString("version"), edition: row.optionalString("edition"))
        } catch { return nil }
    }
}

/// Free-text reception fields avoid forcing an honest encounter into a vocabulary that cannot describe it.
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

    public static func fromJSON(_ value: JSONValue) -> StudioReception? {
        do {
            let row = try StudioSavedRow(value)
            return try StudioReception(how: row.optionalString("how"), wholeOrPart: row.optionalString("whole_or_part"))
        } catch { return nil }
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
        do {
            let ref = try StudioSavedRow(value).optionalString("ref")
            guard kind != .consult || ref != nil else { return nil }
            return StudioOrigin(kind: kind, ref: ref)
        } catch { return nil }
    }
}

/// Abstention is a valid outcome with an optional reason, never a penalty.
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
        do { return try StudioStanceValue(kind: kind, reason: StudioSavedRow(value).optionalString("reason")) }
        catch { return nil }
    }
}

/// Keep linked judgments intact; the graph owns traversal while recall filters read stored provenance.
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
    /// Project amendments on every read without rewriting append-only journal bytes.
    public var amendments: [StudioAmendment]
    /// Incomplete correction history warns every entry: damage cannot identify which response lost a correction. Never persisted.
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

    /// Show corrections in place with original words struck through, date and reason; appended corrections remain dated blocks.
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
        // Project corrections only on reads; the stored response remains byte-for-byte unchanged.
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
              let work = obj["work"].flatMap(StudioWork.fromJSON),
              let origin = obj["origin"].flatMap(StudioOrigin.fromJSON),
              let stance = obj["stance"].flatMap(StudioStanceValue.fromJSON) else { return nil }
        do {
            let row = try StudioSavedRow(value)
            let reception: StudioReception
            if let value = obj["reception"] {
                guard let decoded = StudioReception.fromJSON(value) else { return nil }
                reception = decoded
            } else { reception = StudioReception() }
            let response = try row.optionalString("response")
            guard stance.kind == .abstained || response != nil else { return nil }
            return try StudioJournalEntry(
                id: row.string("id"), encounteredAt: row.string("encountered_at"), recordedAt: row.string("recorded_at"),
                work: work, reception: reception, artifactRefs: row.strings("artifact_refs"), origin: origin,
                response: response, stance: stance, relations: row.rows("relations", decode: StudioRelation.fromJSON),
                tags: row.strings("tags"), amendments: row.rows("amendments", decode: StudioAmendment.fromJSON))
        } catch { return nil }
    }
}

// MARK: - Amendment

/// Amendments preserve append-only journal bytes. Nil supersedes appends a dated block; passage corrections retain struck-through originals.
public struct StudioAmendment: Sendable, Equatable {
    public var id: String
    public var entryId: String
    public var amendedAt: String
    /// Require a reason so a correction cannot silently rewrite history.
    public var reason: String
    /// Nil appends; a passage correction must name exact original response text.
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

    /// Day precision is sufficient for the displayed correction date.
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
        do {
            let row = try StudioSavedRow(value)
            return try StudioAmendment(id: row.string("id"), entryId: row.string("entry_id"),
                amendedAt: row.string("amended_at"), reason: row.string("reason"),
                supersedes: row.optionalString("supersedes"), correction: row.string("correction"))
        } catch { return nil }
    }
}

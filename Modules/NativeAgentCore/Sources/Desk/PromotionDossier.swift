import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `PromotionDossier.swift` | Desk notes and typed evidence dossiers for self-authored pursuits |

public struct DeskNote: Sendable, Equatable {
    public var ts: String
    public var text: String
    public var author: String?
    /// Typed release identity belongs only to system-release notes.
    public var releaseCondition: String?

    public init(ts: String, text: String, author: String? = nil, releaseCondition: String? = nil) {
        self.ts = ts
        self.text = text
        self.author = author
        self.releaseCondition = releaseCondition
    }

    public func toJSON() -> JSONValue {
        var fields: [String: JSONValue] = ["ts": .string(ts), "text": .string(text)]
        if let author { fields["author"] = .string(author) }
        if let releaseCondition { fields["releaseCondition"] = .string(releaseCondition) }
        return .object(fields)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskNote? {
        guard case .object(let obj) = value,
              let ts = obj["ts"]?.stringValue,
              DeskClock.parseISO(ts) != nil,
              let text = obj["text"]?.stringValue,
              DeskJSON.optionalStringsAreValid(obj, keys: ["author", "releaseCondition"]) else { return nil }
        if let condition = obj["releaseCondition"]?.stringValue {
            guard obj["author"] == .string("system"), MyQueue.When(condition) != nil else { return nil }
        }
        return DeskNote(ts: ts, text: text, author: obj["author"]?.stringValue, releaseCondition: obj["releaseCondition"]?.stringValue)
    }
}

// MARK: - Promotion dossier
// Pursuits need typed evidence with at least one non-friction source.

/// Friction alone cannot justify a pursuit.
public enum DossierSource: Sendable, Equatable {
    case care(id: String)
    case dreamDigest(id: String)
    case feltSalience(dates: [String])
    case chatObservation(noteIds: [String], distinctDays: Int)
    case traceFriction(count: Int, window: String)

    public var token: String {
        switch self {
        case .care: return "care"
        case .dreamDigest: return "dream_digest"
        case .feltSalience: return "felt_salience"
        case .chatObservation: return "chat_observation"
        case .traceFriction: return "trace_friction"
        }
    }

    public var isFriction: Bool { if case .traceFriction = self { return true } else { return false } }

    public func structuralError() -> String? {
        switch self {
        case .care(let id), .dreamDigest(let id):
            return id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(token): id is empty" : nil
        case .feltSalience(let dates):
            let clean = dates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard clean.count == dates.count else { return "felt_salience: an entry is empty" }
            guard clean.allSatisfy({ DeskClock.isParseableDate($0) }) else { return "felt_salience: an entry is not a parseable date (yyyy-MM-dd)" }
            // Normalize calendar days so timestamp variants cannot inflate recurrence evidence.
            return Set(clean.compactMap { DeskClock.normalizedDay($0) }).count >= 2 ? nil : "felt_salience: needs ≥2 distinct calendar days"
        case .chatObservation(let noteIds, let distinctDays):
            guard noteIds.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return "chat_observation: a note id is empty"
            }
            let clean = Set(noteIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !clean.isEmpty else { return "chat_observation: noteIds is empty" }
            // Distinct days cannot exceed the number of cited notes.
            guard distinctDays >= 2 else { return "chat_observation: needs distinctDays ≥ 2" }
            return clean.count >= distinctDays ? nil : "chat_observation: distinctDays (\(distinctDays)) exceeds cited notes (\(clean.count))"
        case .traceFriction(let count, let window):
            guard count > 0 else { return "trace_friction: count must be positive" }
            let w = window.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { return "trace_friction: window is empty" }
            let ok = w.range(of: #"^[0-9]+[smhdw]$"#, options: .regularExpression) != nil
                && Int(w.dropLast()).map { $0 > 0 } == true
            return ok ? nil : "trace_friction: window must be a positive duration (e.g. 7d, 24h)"
        }
    }

    public func toJSON() -> JSONValue {
        switch self {
        case .care(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .dreamDigest(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .feltSalience(let dates):
            return .object(["source": .string(token), "dates": .array(dates.map { .string($0) })])
        case .chatObservation(let noteIds, let distinctDays):
            return .object([
                "source": .string(token),
                "noteIds": .array(noteIds.map { .string($0) }),
                "distinctDays": .int(Int64(distinctDays)),
            ])
        case .traceFriction(let count, let window):
            return .object(["source": .string(token), "count": .int(Int64(count)), "window": .string(window)])
        }
    }

    /// Preserve complete citation evidence so decoding cannot weaken the admission gate.
    public static func fromJSON(_ value: JSONValue) -> DossierSource? {
        guard case .object(let obj) = value, let token = obj["source"]?.stringValue else { return nil }
        let citation: DossierSource
        switch token {
        case "care":
            guard let id = obj["id"]?.stringValue else { return nil }
            citation = .care(id: id)
        case "dream_digest":
            guard let id = obj["id"]?.stringValue else { return nil }
            citation = .dreamDigest(id: id)
        case "felt_salience":
            guard let dates = DeskJSON.strings(obj["dates"], defaultWhenAbsent: false) else { return nil }
            citation = .feltSalience(dates: dates)
        case "chat_observation":
            guard let noteIds = DeskJSON.strings(obj["noteIds"], defaultWhenAbsent: false),
                  case .int(let raw)? = obj["distinctDays"], let days = Int(exactly: raw) else { return nil }
            citation = .chatObservation(noteIds: noteIds, distinctDays: days)
        case "trace_friction":
            guard let window = obj["window"]?.stringValue,
                  case .int(let raw)? = obj["count"], let count = Int(exactly: raw) else { return nil }
            citation = .traceFriction(count: count, window: window)
        default:
            return nil
        }
        return citation.structuralError() == nil ? citation : nil
    }
}

public struct PromotionDossier: Sendable, Equatable {
    public var citations: [DossierSource]

    public init(citations: [DossierSource]) { self.citations = citations }

    /// Require at least one fully valid citation and one non-friction source before admitting a pursuit.
    public func validationError() -> String? {
        guard !citations.isEmpty else { return "dossier: no citations — a pursuit needs cited evidence" }
        for c in citations { if let e = c.structuralError() { return e } }
        guard citations.contains(where: { !$0.isFriction }) else {
            return "dossier: trace-friction alone is insufficient — needs at least one non-friction source"
        }
        return nil
    }

    public var isValid: Bool { validationError() == nil }

    public func toJSON() -> JSONValue {
        .object(["citations": .array(citations.map { $0.toJSON() })])
    }

    public static func fromJSON(_ value: JSONValue) -> PromotionDossier? {
        guard case .object(let obj) = value, case .array(let arr)? = obj["citations"],
              let citations = DeskJSON.collection(JSONValue.array(arr), decode: DossierSource.fromJSON) else { return nil }
        let dossier = PromotionDossier(citations: citations)
        return dossier.isValid ? dossier : nil
    }
}

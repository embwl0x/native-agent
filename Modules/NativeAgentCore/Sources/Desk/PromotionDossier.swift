import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `PromotionDossier.swift` | Desk notes and typed evidence dossiers for self-authored pursuits |

public struct DeskNote: Sendable, Equatable {
    public var ts: String
    public var text: String
    public var author: String?

    var legacyFindingKey: String? {
        let line = text.prefix { $0 != "\n" }
        return line.hasPrefix("harness-key ") ? String(line.dropFirst("harness-key ".count)) : nil
    }

    public init(ts: String, text: String, author: String? = nil) {
        self.ts = ts
        // Normalize colon-delimited finding labels for display without rewriting stored ops.
        self.text = text.hasPrefix("harness-key:") ? "harness-key " + text.dropFirst("harness-key:".count) : text
        self.author = author
    }

    public func toJSON() -> JSONValue {
        var fields: [String: JSONValue] = ["ts": .string(ts), "text": .string(text)]
        if let author { fields["author"] = .string(author) }
        return .object(fields)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskNote? {
        guard case .object(let obj) = value,
              let ts = obj["ts"]?.stringValue,
              let text = obj["text"]?.stringValue else { return nil }
        return DeskNote(ts: ts, text: text, author: obj["author"]?.stringValue)
    }
}

// MARK: - Promotion dossier
//
// Pursuits require structurally valid typed evidence and a non-friction source.

/// One typed evidence citation. `traceFriction` is the ONLY friction source and never qualifies a pursuit by itself (source-mix rule).
public enum DossierSource: Sendable, Equatable {
    case care(id: String)
    case standingView(id: String)
    case dreamDigest(id: String)
    case openQuestionSeed(id: String)
    case feltSalience(dates: [String])
    case chatObservation(noteIds: [String], distinctDays: Int)
    case traceFriction(count: Int, window: String)

    /// Wire token written as the citation's `source` field.
    public var token: String {
        switch self {
        case .care: return "care"
        case .standingView: return "standing_view"
        case .dreamDigest: return "dream_digest"
        case .openQuestionSeed: return "open_question_seed"
        case .feltSalience: return "felt_salience"
        case .chatObservation: return "chat_observation"
        case .traceFriction: return "trace_friction"
        }
    }

    /// friction is the low-weight source the mix rule caps — see `isFriction`.
    public var isFriction: Bool { if case .traceFriction = self { return true } else { return false } }

    /// Structural validity of THIS citation in isolation. Returns a human reason on failure (ids non-empty, dates parseable + recurrent, counts positive).
    public func structuralError() -> String? {
        switch self {
        case .care(let id), .standingView(let id), .dreamDigest(let id), .openQuestionSeed(let id):
            return id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(token): id is empty" : nil
        case .feltSalience(let dates):
            let clean = dates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard clean.allSatisfy({ DeskClock.isParseableDate($0) }) else { return "felt_salience: an entry is not a parseable date (yyyy-MM-dd)" }
            // Normalize dates so timestamps on one calendar day count as one day.
            return Set(clean.compactMap { DeskClock.normalizedDay($0) }).count >= 2 ? nil : "felt_salience: needs ≥2 distinct calendar days"
        case .chatObservation(let noteIds, let distinctDays):
            let clean = Set(noteIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !clean.isEmpty else { return "chat_observation: noteIds is empty" }
            // Claimed distinct days cannot exceed distinct cited notes.
            guard distinctDays >= 2 else { return "chat_observation: needs distinctDays ≥ 2" }
            return clean.count >= distinctDays ? nil : "chat_observation: distinctDays (\(distinctDays)) exceeds cited notes (\(clean.count))"
        case .traceFriction(let count, let window):
            guard count > 0 else { return "trace_friction: count must be positive" }
            let w = window.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { return "trace_friction: window is empty" }
            // Duration syntax is unsigned digits followed by a unit.
            let ok = w.range(of: #"^[0-9]+[smhdw]$"#, options: .regularExpression) != nil
            return ok ? nil : "trace_friction: window must be a positive duration (e.g. 7d, 24h)"
        }
    }

    public func toJSON() -> JSONValue {
        switch self {
        case .care(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .standingView(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .dreamDigest(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .openQuestionSeed(let id):
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

    /// Tolerant decode — an unknown `source` token → nil (skipped by the caller, exactly like DeskRef). A dropped citation can only WEAKEN a dossier, never strengthen it, so tolerance can't launder evidence.
    public static func fromJSON(_ value: JSONValue) -> DossierSource? {
        guard case .object(let obj) = value, let token = obj["source"]?.stringValue else { return nil }
        switch token {
        case "care":
            guard let id = obj["id"]?.stringValue else { return nil }
            return .care(id: id)
        case "standing_view":
            guard let id = obj["id"]?.stringValue else { return nil }
            return .standingView(id: id)
        case "dream_digest":
            guard let id = obj["id"]?.stringValue else { return nil }
            return .dreamDigest(id: id)
        case "open_question_seed":
            guard let id = obj["id"]?.stringValue else { return nil }
            return .openQuestionSeed(id: id)
        case "felt_salience":
            return .feltSalience(dates: (obj["dates"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        case "chat_observation":
            return .chatObservation(noteIds: (obj["noteIds"]?.arrayValue?.compactMap(\.stringValue) ?? []), distinctDays: jsonInt(obj, "distinctDays") ?? 0)
        case "trace_friction":
            guard let window = obj["window"]?.stringValue else { return nil }
            return .traceFriction(count: jsonInt(obj, "count") ?? 0, window: window)
        default:
            return nil
        }
    }
}

public struct PromotionDossier: Sendable, Equatable {
    public var citations: [DossierSource]

    public init(citations: [DossierSource]) { self.citations = citations }

    /// The single gate a pursuit's evidence must pass at WRITE time. Returns a human reason on the first failure, or nil when the dossier is admissible:   1. at least one citation;   2. every citation structurally valid (ids/dates/counts);
    /// 3. SOURCE-MIX: at least one NON-friction source (friction alone caps out).
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

    public static func fromJSON(_ value: JSONValue) -> PromotionDossier {
        guard case .object(let obj) = value, case .array(let arr)? = obj["citations"] else {
            return PromotionDossier(citations: [])
        }
        return PromotionDossier(citations: arr.compactMap { DossierSource.fromJSON($0) })
    }
}

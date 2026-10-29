// Stored moment-row vocabulary and shared memory provenance.

import Transcripts
import CognitiveSubstrate
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TurnTrace

// Blueprint: | `MemoryV2+Moments.swift` | `MemoryMoments`: the retired moment lane's row vocabulary, turn and source provenance metadata and recall origin |

// MARK: - The record's vocabulary and shared helpers

public enum MemoryMoments {
    /// Metadata `lane` AND `kind` of the retired lane's rows.
    public static let lane = "moment"
    public static let kind = "moment"
    /// The source prefix the lane's rows carry.
    public static let sourcePrefix = "moment-promoter"

    static func author(surface: String, peer: Bool) -> String {
        surface == "studio_wander" ? "app" : peer ? "peer" : "user"
    }

    /// Where a kept memory came from and when it became true, in the keys the
    /// store lifts into `evidence_json`, `observed_at` and `valid_from`: the
    /// exchange (session, message, turn), who spoke, and the supporting words.
    public static func sourceMetadata(sessionId: String?, messageId: String?, turnId: String?, at: Date,
                                      speaker: String, words: String?) -> [String: JSONValue] {
        var evidence: [String: JSONValue] = ["speaker": .string(speaker)]
        if let sessionId { evidence["session_id"] = .string(sessionId) }
        if let messageId { evidence["message_id"] = .string(messageId) }
        if let turnId { evidence["turn_id"] = .string(turnId) }
        let words = MemoryTextClip.wordClip((words ?? "").trimmingCharacters(in: .whitespacesAndNewlines), cap: 400)
        if !words.isEmpty { evidence["words"] = .string(words) }
        return ["evidence": .object(evidence), "observed_at": .string(at.ISO8601Format()),
                "valid_from": .string(at.ISO8601Format())]
    }

    /// The turn a memory was kept in: turn, run and session ids, and the
    /// transcript locator the recent_receipts strip renders (`history:` and the
    /// id of the message that opened the turn) and when. Moments, standing
    /// corrections and committed memories stamp it alike, so a correction knows
    /// its miss — and a repeat that collapses into it keeps its own turn.
    public static func turnMetadata(turnId: String?, origin: AfterTurnOrigin?) -> [String: JSONValue] {
        var meta: [String: JSONValue] = [:]
        if let turnId { meta["turn_id"] = .string(turnId) }
        guard let origin else { return meta }
        meta["session_id"] = .string(origin.sessionId)
        if let runId = origin.runId { meta["run_id"] = .string(runId) }
        meta["history"] = .string("history:" + origin.messageId)
        meta["turn_at"] = .string((origin.occurredAt ?? Date()).ISO8601Format())
        return meta
    }

    /// True when a proposal/memory row belongs to the retired lane. A row
    /// staged before `lane` existed is identified by its kind.
    public static func isMoment(_ metadata: JSONValue?) -> Bool {
        guard case .object(let obj)? = metadata else { return false }
        if case .string(let value)? = obj["lane"] { return value == lane }
        if case .string(let value)? = obj["kind"] { return value == kind }
        return false
    }

    public static func metadataNumber(_ metadata: JSONValue?, _ key: String) -> Double? {
        guard case .object(let obj)? = metadata else { return nil }
        switch obj[key] {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Keep the conversation seat visible without treating acceptance as proof
    /// that the person said it. The promoter's source names the original seat.
    public static func recallOrigin(source: String?, metadata: JSONValue?, dataRoot: URL = defaultDataRoot()) -> JSONValue? {
        guard isMoment(metadata) || source?.hasPrefix("\(sourcePrefix):") == true else { return nil }
        let sourceSession = source.flatMap {
            $0.hasPrefix("\(sourcePrefix):") ? String($0.dropFirst(sourcePrefix.count + 1)) : nil
        }
        let session = sourceSession ?? metadata?.objectValue?["session_id"]?.stringValue
        let storedAuthor = metadata?.objectValue?["author"]?.stringValue.flatMap { ["app", "peer", "user"].contains($0) ? $0 : nil }
        let author = SessionConversation.kind(session, dataRoot: dataRoot, includingArchived: true)?.isPeerConversation == true
            ? "peer" : (storedAuthor ?? "unknown")
        var origin: [String: JSONValue] = ["author": .string(author)]
        if let session, !session.isEmpty { origin["session_id"] = .string(session) }
        if let source, !source.isEmpty { origin["source"] = .string(source) }
        if let surface = metadata?.objectValue?["surface"]?.stringValue, !surface.isEmpty {
            origin["surface"] = .string(surface)
        }
        return .object(origin)
    }

    /// Calendar-day key (local zone).
    public static func dayKey(_ instant: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    public static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    /// Words only, single-spaced, lowercase: a copied span with a comma added
    /// or a period dropped is still the same span.
    static func wordFold(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// A row's own sentence: the lane appended its quote to the stored content.
    public static func narration(ofStored content: String, metadata: JSONValue?) -> String {
        guard let quote = metadata?.objectValue?["quote"]?.stringValue, !quote.isEmpty else { return content }
        let suffix = " — \"\(quote)\""
        guard content.hasSuffix(suffix) else { return content }
        return String(content.dropLast(suffix.count))
    }

}

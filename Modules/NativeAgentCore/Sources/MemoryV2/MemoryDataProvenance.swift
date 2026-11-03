import CognitiveSubstrate
import ChatTurnContracts
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryDataProvenance.swift` | `MemoryDataProvenance`: current source/evidence and turn stamps, time and word-fold helpers, source retention and display across writes, readbacks and prompt projections |

/// Stored untrusted content keeps its steer through duplicate saves and edits.
/// Reading remains allowed; only subsequent effects use the turn's usual gates.
public enum MemoryDataProvenance {
    public static func presentation(_ text: String, metadata: JSONValue?, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> String {
        MemoryDisplayText.attributed(text, sources: sources(in: metadata, dataRoot: dataRoot))
    }

    public static func sources(in metadata: JSONValue?, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [String] {
        guard case .object(let fields)? = metadata else { return [] }
        var sources: [String] = []
        for key in ["peer_sources", "peer_data_sources", "untrusted_sources"] {
            guard case .array(let values)? = fields[key] else { continue }
            for case .string(let source) in values where !source.isEmpty && !sources.contains(source) {
                sources.append(source)
            }
        }
        // An explicit empty checkpoint attests a clean write. Only older rows
        // need their descriptive told provenance interpreted as a boundary.
        if fields["peer_sources"] == nil, fields["provenance"] == .string("told"),
           case .string(let by)? = fields["provenance_by"], !by.isEmpty, !sources.contains(by) {
            do {
                let name = try MemoryRecallQueryExpansion.names(
                    storeDirectory: dataRoot.appendingPathComponent("memory")).user
                if let name {
                    if by.caseInsensitiveCompare(name) != .orderedSame { sources.append(by) }
                } else { sources.append(by) }
            } catch {
                // Unreadable identity cannot establish that these are the
                // person's trusted words. Keep their actual named boundary.
                sources.append(by)
                nativeLog("Memory provenance identity unavailable; retaining named source %@: %@", by, error.localizedDescription)
            }
        }
        if sources.isEmpty, fields["untrusted_remote_data"] == .bool(true) {
            sources.append("untrusted stored content")
        }
        return sources
    }

    public static func fields(in metadata: JSONValue?, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [String: JSONValue] {
        let sources = sources(in: metadata, dataRoot: dataRoot)
        if sources.isEmpty {
            if case .object(let fields)? = metadata, case .array? = fields["peer_sources"] {
                return ["peer_sources": .array([])]
            }
            return [:]
        }
        return ["untrusted_remote_data": .bool(true), "peer_sources": .array(sources.map(JSONValue.string)),
                "agent": .string(sources.joined(separator: ", ")), "source_boundary": .bool(true)]
    }

    static func merging(existing: JSONValue?, incoming: JSONValue?) -> [String: JSONValue] {
        var sources = sources(in: existing)
        for source in self.sources(in: incoming) where !sources.contains(source) {
            sources.append(source)
        }
        return fields(in: .object(["peer_sources": .array(sources.map(JSONValue.string))]))
    }

    public static func preserving(existing: JSONValue?, incoming: JSONValue?) -> JSONValue? {
        let provenance = merging(existing: existing, incoming: incoming)
        guard !provenance.isEmpty else { return incoming }
        var fields: [String: JSONValue] = [:]
        if case .object(let value)? = incoming { fields = value }
        fields.merge(provenance) { _, value in value }
        return .object(fields)
    }

    public static func stamping(_ metadata: JSONValue?) -> JSONValue? {
        var sources = PeerDataTaint.current?.checkpointSources ?? []
        if ChatToolSessionContext.envelope?.surface.lowercased().replacingOccurrences(of: "_", with: "-") == "agent-bridge" {
            let id = ChatToolSessionContext.envelope?.verifiedUserId
            let peer = id.map { "peer:" + $0 } ?? "another agent"
            if (id == nil || !PeerDataTaint.ownerTrusts(peer)), !sources.contains(peer) { sources.append(peer) }
        }
        var fields: [String: JSONValue] = [:]
        if case .object(let value)? = metadata { fields = value }
        if fields["peer_sources"] == nil { fields["peer_sources"] = .array([]) }
        let provenance = merging(existing: .object(fields), incoming: .object([
            "peer_sources": .array(sources.map(JSONValue.string))
        ]))
        fields["peer_sources"] = .array(sources.map(JSONValue.string))
        fields.merge(provenance) { _, value in value }
        return .object(fields)
    }

    // Kept memories disclose their speaker through `fields(in:)`; only peer words in the turn's input steer it.

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

    /// Calendar-day key (local zone) used by the REM evidence owner.
    public static func dayKey(_ instant: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
}

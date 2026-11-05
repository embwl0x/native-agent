// Read cue and memory competition from traces on demand so the prompt carries no diagnostic weight.
// The substrate owns bounded rejection and disposition undo.

import ChatTurnContracts
import AgentConversations
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Privacy
import Studio
import TurnTrace

// Blueprint: | `NativeCognitionRuntime+MindLedger.swift` | `NativeCognitionRuntime`. |

extension NativeCognitionRuntime {
    /// Keep each turn's evidence, including acts that never reached a why or terminal row: this day's and the previous day's whole days, each its
    /// own bounded read. Unreadable details cannot be assigned to a turn; only a failed record read fails the ledger read.
    private static func whyEvents(dataRoot: URL) async throws -> (events: [TurnTraceEvent], traceGaps: [JSONValue]) {
        let reader = TurnTraceRecentReader(dataRootOverride: dataRoot)
        let now = Date()
        var events: [TurnTraceEvent] = []
        var traceGaps: [JSONValue] = []
        for offset in 0..<2 {
            guard let day = TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: -offset, to: now) else {
                throw PersistenceCoreError.ioFailure("Could not resolve the record day.")
            }
            let snapshot = try await reader.read(now: day)
            events += snapshot.events
            if snapshot.limitReached || snapshot.unreadable > 0 {
                traceGaps.append(.object([
                    "source": .string("detail"),
                    "day": .string(TurnTracePersistLane.dayString(from: day)),
                    "limit_reached": .bool(snapshot.limitReached),
                    "unreadable_rows": .int(Int64(snapshot.unreadable)),
                    "detail": .string(
                        "These gaps may hide other records; their turn ids cannot be established. They do not invalidate the rows read for a known turn."),
                ]))
            }
        }
        return (events.sorted { $0.ts > $1.ts }, traceGaps)
    }

    /// Check every observed why row; a readable sibling row cannot conceal its gap.
    /// Missing evidence describes only this act, never its outcome or a sibling's record.
    private static func whyGap(turn: String, events: [TurnTraceEvent], whyAvailable: (TurnTraceEvent) -> Bool) -> JSONValue? {
        var missing: [String] = []
        if !events.contains(where: { TurnTraceEvent.isTerminalKind($0.kind) }) { missing.append("terminal") }
        let why = events.filter { $0.kind == "mind.why" }
        if why.isEmpty { missing.append("mind.why") }
        for event in why where !whyAvailable(event) {
            let label: String
            if let lane = whyLane(event.payload) { label = "mind.why." + lane }
            else { label = "mind.why" }
            if !missing.contains(label) { missing.append(label) }
        }
        guard !missing.isEmpty else { return nil }
        return .object([
            "turn": .string(turn), "missing": .array(missing.map(JSONValue.string)),
            "detail": .string("""
                Some evidence is unavailable for this turn in the retained conversation trace: \(missing.joined(separator: ", ")). Evidence may be unreadable, \
                may still arrive, may not have been emitted or retained, or may be withheld by current disclosure. This does not establish the turn's outcome.
                """),
        ])
    }

    /// A known lane can still name its gap when its evidence cannot be read or disclosed.
    private static func whyLane(_ payload: JSONValue) -> String? {
        guard case .object(let fields) = payload,
              case .string(let lane)? = fields["lane"],
              ["cue", "memory", "outreach", "expansion", "interpretation"].contains(lane) else { return nil }
        return lane
    }

    /// The same structural evidence check serves gap reporting and selected-row disclosure.
    private static func whyEvidence(_ payload: JSONValue) -> (lane: String, sources: Set<String>)? {
        guard let lane = whyLane(payload) else { return nil }
        var sources: Set<String> = []
        func collect(_ value: JSONValue) -> Bool {
            switch value {
            case .object(let object):
                guard object["_truncated"] == nil else { return false }
                if object["atom"] != nil, object["source"] == nil { return false }
                if case .string(let source)? = object["source"] { sources.insert(source) }
                return object.values.allSatisfy(collect)
            case .array(let values): return values.allSatisfy(collect)
            default: return true
            }
        }
        guard collect(payload) else { return nil }
        return (lane, sources)
    }

    /// Bind cue and memory explanations to the verified caller's conversation.
    public func why(turn wantedTurn: String?, callerTurn turn: Turn) async -> JSONValue {
        guard let caller = turn.runtime,
              let session = turn.verifiedSessionID,
              !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !caller.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .object(["status": .string("unavailable"),
                            "detail": .string("This read needs a verified conversation.")])
        }
        let envelope = TurnEnvelope.current(turn: turn, surface: caller.surface)
        let surface = MemoryRecordDisclosurePolicy.canonicalSurface(
            envelope.agent == nil ? envelope.replyRoute.surface : "bridge")
        let destination = envelope.replyRoute.destinationId
        let thread = envelope.replyRoute.threadId
        let traced: [TurnTraceEvent]
        let traceGaps: [JSONValue]
        do {
            (traced, traceGaps) = try await Self.whyEvents(dataRoot: dataRoot)
        } catch {
            return .object(["status": .string("unavailable"), "detail": .string(error.localizedDescription)])
        }
        let events = traced.filter {
            $0.sessionId == session && $0.surface == caller.surface
                && $0.destinationId == destination && $0.threadId == thread
        }
        let byTurn = Dictionary(grouping: events, by: \.turnId)
        let wanted = wantedTurn?.trimmingCharacters(in: .whitespacesAndNewlines)
        var recent: [String] = []
        for event in events where event.kind == "mind.why" && !recent.contains(event.turnId) {
            recent.append(event.turnId)
            if recent.count == 5 { break }
        }
        let completed = events.first {
            guard $0.kind == "turn.terminal", $0.turnId != turn.id,
                  case .object(let payload) = $0.payload else { return false }
            return payload["status"] == .string("completed")
        }
        let target = (wanted?.isEmpty == false ? wanted : nil) ?? completed?.turnId
        var rows: [(event: TurnTraceEvent, payload: JSONValue, lane: String)] = []
        if let target {
            for event in events where event.kind == "mind.why" && event.turnId == target {
                if let disclosed = await disclosedWhyPayload(event.payload, surface: surface) {
                    rows.append((event, disclosed.payload, disclosed.lane))
                }
            }
        }
        var gaps: [JSONValue] = []
        for (id, recorded) in byTurn.sorted(by: { $0.key < $1.key }) where id != turn.id && id != target {
            if let gap = Self.whyGap(turn: id, events: recorded, whyAvailable: {
                Self.whyEvidence($0.payload) != nil
            }) {
                gaps.append(gap)
            }
        }
        var out: [String: JSONValue] = [
            "status": .string("ok"),
            "recent_turns": .array(recent.map(JSONValue.string)),
            "trace_gaps": .array(traceGaps),
        ]
        if let target {
            let recorded = events.filter { $0.turnId == target }
            let gap = Self.whyGap(turn: target, events: recorded, whyAvailable: { event in
                rows.contains { $0.event == event }
            })
            if let gap { gaps.append(gap) }
            out["turn"] = .string(target)
            out["selection"] = .string(wanted?.isEmpty == false ? "requested" : "latest_recorded_completed")
            out["record_status"] = .string(recorded.isEmpty ? "unrecorded" : gap == nil ? "recorded" : "incomplete")
            out["detail"] = .string(rows.isEmpty
                ? """
                    No currently disclosable why record is available for turn \(target) in the retained conversation trace. This does not establish that none \
                    was produced; it may still arrive.
                    """
                : "Why it surfaced on turn \(target), from its recorded evidence. Any missing evidence is named separately in turn_gaps and trace_gaps.")
        } else {
            out["record_status"] = .string("unrecorded")
            out["detail"] = .string("""
                No completed turn can be established from the retained records in this conversation. Pass turn explicitly to read the evidence available for \
                it. This does not establish that no turn completed.
                """)
        }
        for row in rows where out[row.lane] == nil {
            out[row.lane] = row.payload
            out["at"] = out["at"] ?? .string(ISO8601DateFormatter().string(from: row.event.ts))
        }
        out["turn_gaps"] = .array(gaps)
        return .object(out)
    }

    /// Recheck current memory disclosure; a trace copy cannot grant access after policy changes.
    private func disclosedWhyPayload(_ payload: JSONValue, surface: String) async -> (lane: String, payload: JSONValue)? {
        guard let evidence = Self.whyEvidence(payload) else { return nil }
        if evidence.lane != "memory",
           MemoryRecordDisclosurePolicy.classify(
            personaID: nil, status: nil, lifecycle: nil, tags: nil, metadata: nil
           )?.permits(surface: surface, personaID: nil) != true { return nil }
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        for source in evidence.sources where source.hasPrefix("memory:") {
            let id = String(source.dropFirst(7))
            guard (try? await memory.readMemoryRecord(id: id, persona: nil, surface: surface)) != nil else {
                return nil
            }
        }
        // Gap prose lacks source provenance for current disclosure checks and may quote memories or peers.
        func redactGapText(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(var object):
                if case .string(let source)? = object["source"], source.hasPrefix("gap:") {
                    object.removeValue(forKey: "text")
                    object["text_withheld"] = .bool(true)
                }
                return .object(object.mapValues(redactGapText))
            case .array(let values): return .array(values.map(redactGapText))
            default: return value
            }
        }
        return (evidence.lane, redactGapText(payload))
    }

    public func rejectAssociation(
        source: String,
        turn wantedTurn: String?,
        always: Bool,
        seat: StudioCanonTurnProvenance,
        callerTurn turn: Turn
    ) async -> (ok: Bool, detail: String) {
        await bootstrap()
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("memory:") {
            let record = try? await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
                .authorityRecord(id: String(trimmed.dropFirst(7)))
            if let refusal = Self.rejectionRefusal(for: record) { return (false, refusal) }
        }
        var terms: [String] = []
        if !always {
            guard case .object(let record) = await why(turn: wantedTurn, callerTurn: turn),
                  let lane = [record["cue"], record["memory"]].compactMap({ $0 }).first,
                  case .object(let fields) = lane,
                  case .array(let signature)? = fields["signature"] else {
                return (false, "No why record for that turn to take its kind of thing from. Pass a turn from mind.why, or always: true.")
            }
            terms = signature.compactMap { if case .string(let term) = $0 { term } else { nil } }
            guard !terms.isEmpty else {
                return (false, "That turn had no content words to recognise it by. Pass always: true to stop it everywhere.")
            }
        }
        if let failure = await substrate.rejectAssociation(source: source, terms: terms, seat: seat) {
            return (false, failure)
        }
        publishRuntimeChange(reason: "mind:association_rejected")
        return (true, terms.isEmpty
            ? "\(source) will not surface again."
            : "\(source) will not surface for messages about \(terms.joined(separator: ", ")).")
    }

    /// Never suppress person-authorized pinned core, corrections or safety memory; unreadable authority fails closed.
    public static func rejectionRefusal(for record: MemoryRecord?) -> String? {
        guard let record else { return "that memory could not be read, so it cannot be checked; nothing was rejected" }
        let tags = Set((record.tags ?? []).map { $0.lowercased() })
        if record.pinned == true { return "that memory is pinned to your core; only the owner unpins it" }
        if record.memoryKind == "correction" || tags.contains("correction") {
            return "that memory is a correction; corrections always stand"
        }
        if tags.contains("safety") { return "that memory is tagged safety; it always stands" }
        return nil
    }

    public func undo(
        item: String?,
        seat: StudioCanonTurnProvenance
    ) async -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        await bootstrap()
        let key = item?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            let entries = await substrate.undoSnapshot().reversed().map { entry -> JSONValue in
                .object(["item": .string(entry.key), "what": .string(entry.what),
                         "at": .string(ISO8601DateFormatter().string(from: entry.at))])
            }
            return (true, entries.isEmpty ? "Nothing of yours to undo." : "Pass one item to undo it.",
                    ["undoable": .array(Array(entries))])
        }
        switch await substrate.undoUpdate(key: key, seat: seat) {
        case .undone(let what):
            scheduleDirtyMicrocycle(reason: "mind_undo")
            publishRuntimeChange(reason: "mind:undo")
            return (true, "Undone: \(what). Nothing else changed.", ["item": .string(key)])
        case .refused(let reason, let current):
            return (false, "Not undone: \(reason).", ["item": .string(key), "current": current])
        }
    }
}

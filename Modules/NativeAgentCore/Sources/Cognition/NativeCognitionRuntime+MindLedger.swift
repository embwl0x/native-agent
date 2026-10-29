// Why reads the turn trace, where each delivered turn records why its felt cue
// (or none) won and each context build records which memories competed. The
// prompt never carries any of it. Reject and undo are her own verbs over her
// own mind; the substrate owns bounded rejections and one disposition undo.

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

// Blueprint: | `NativeCognitionRuntime+MindLedger.swift` | `NativeCognitionRuntime` mind ledger: trace-backed why (cue, memory, outreach, expansion and interpretation lanes), association rejection and undertone undo through substrate owners |

extension NativeCognitionRuntime {
    /// Why and terminal rows of today and yesterday (calendar days), newest
    /// first, and each day's trace that could not be read: never "no record".
    private static func whyEvents(dataRoot: URL) async -> (events: [TurnTraceEvent], unreadable: [String]) {
        let reader = TurnTraceRecentReader(dataRootOverride: dataRoot)
        let now = Date()
        var events: [TurnTraceEvent] = []
        var unreadable: [String] = []
        for (name, day) in [("today", now), ("yesterday", Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)] {
            do {
                events += try await reader.read(now: day).events.filter { $0.kind == "mind.why" || $0.kind == "turn.terminal" }
            } catch {
                unreadable.append("\(name)'s turn trace (\(error.localizedDescription))")
            }
        }
        return (events.sorted { $0.ts > $1.ts }, unreadable)
    }

    private static func lane(_ event: TurnTraceEvent) -> String {
        if case .object(let payload) = event.payload, case .string(let lane)? = payload["lane"] { return lane }
        return "cue"
    }

    /// Why a cue or memory surfaced in the verified caller's conversation.
    public func why(turn: String?) async -> JSONValue {
        guard let caller = ChatTurnRuntimeContext.current,
              let session = ChatToolSessionContext.verifiedSessionId,
              !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !caller.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .object(["status": .string("unavailable"),
                            "detail": .string("This read needs a verified conversation.")])
        }
        let envelope = TurnEnvelope.current(surface: caller.surface)
        let surface = MemoryRecordDisclosurePolicy.canonicalSurface(
            envelope.agent == nil ? envelope.replyRoute.surface : "bridge")
        let destination = TurnTraceContext.destinationId
        let thread = TurnTraceContext.threadId
        let (traced, unreadable) = await Self.whyEvents(dataRoot: dataRoot)
        let events = traced.filter {
            $0.sessionId == session && $0.surface == caller.surface
                && $0.destinationId == destination && $0.threadId == thread
        }
        let unread = unreadable.isEmpty ? nil
            : "Could not read " + unreadable.joined(separator: " or ") + ", so a record there may be missing."
        let wanted = turn?.trimmingCharacters(in: .whitespacesAndNewlines)
        var recent: [String] = []
        for event in events where event.kind == "mind.why" && !recent.contains(event.turnId) {
            recent.append(event.turnId)
            if recent.count == 5 { break }
        }
        let completed = events.first {
            guard $0.kind == "turn.terminal", $0.turnId != TurnTraceContext.turnId,
                  case .object(let payload) = $0.payload else { return false }
            return payload["status"] == .string("completed")
        }
        guard let target = (wanted?.isEmpty == false ? wanted : nil) ?? completed?.turnId else {
            return .object(["status": .string("unavailable"),
                            "detail": .string(unread ?? "No completed turn is recorded in this conversation. Pass turn explicitly to read its record."),
                            "recent_turns": .array(recent.map { .string($0) })])
        }
        var rows: [(event: TurnTraceEvent, payload: JSONValue)] = []
        for event in events where event.kind == "mind.why" && event.turnId == target {
            if let payload = await disclosedWhyPayload(event.payload, surface: surface) {
                rows.append((event, payload))
            }
        }
        var out: [String: JSONValue] = [
            "status": .string(!rows.isEmpty ? "ok" : unread == nil ? "empty" : "unavailable"), "turn": .string(target)]
        if rows.isEmpty {
            out["detail"] = .string(unread ?? (target == TurnTraceContext.turnId
                ? "No why record is available for this turn yet. Its cue record lands at delivery; pass this turn explicitly after it finishes."
                : "No why record is available for the requested turn in this conversation."))
        } else if let unread {
            out["unreadable"] = .string(unread)
        }
        for row in rows where out[Self.lane(row.event)] == nil {
            out[Self.lane(row.event)] = row.payload
            out["at"] = out["at"] ?? .string(ISO8601DateFormatter().string(from: row.event.ts))
        }
        out["recent_turns"] = .array(recent.map { .string($0) })
        return .object(out)
    }

    /// Trace copies cannot grant disclosure after a memory's policy changes.
    /// Unsourced cue prose has the ordinary local-private boundary.
    private func disclosedWhyPayload(_ payload: JSONValue, surface: String) async -> JSONValue? {
        guard case .object(let fields) = payload,
              case .string(let lane)? = fields["lane"],
              ["cue", "memory", "outreach", "expansion", "interpretation"].contains(lane) else { return nil }
        if lane != "memory",
           MemoryRecordDisclosurePolicy.classify(
            personaID: nil, status: nil, lifecycle: nil, tags: nil, metadata: nil
           )?.permits(surface: surface, personaID: nil) != true { return nil }
        var sources: Set<String> = []
        func collect(_ value: JSONValue) -> Bool {
            switch value {
            case .object(let object):
                guard object["_truncated"] == nil else { return false }
                if object["atom"] != nil, object["source"] == nil { return false }
                if case .string(let source)? = object["source"] {
                    sources.insert(source)
                }
                return object.values.allSatisfy(collect)
            case .array(let values): return values.allSatisfy(collect)
            default: return true
            }
        }
        guard collect(payload) else { return nil }
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        for source in sources where source.hasPrefix("memory:") {
            let id = String(source.dropFirst(7))
            guard (try? await memory.readMemoryRecord(id: id, persona: nil, surface: surface)) != nil else {
                return nil
            }
        }
        // Gap prose may quote memories or peers, but the trace retains no
        // source provenance with which to check their current disclosure.
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
        return redactGapText(payload)
    }

    /// She rejects one association: `source` (memory:/care:/dream:, or an
    /// outreach subject desk:/ship:, which any rejection stops outright) stops
    /// surfacing for messages like `turn`'s, or for any message when `always`.
    public func rejectAssociation(
        source: String,
        turn: String?,
        always: Bool,
        seat: StudioCanonTurnProvenance
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
            guard case .object(let record) = await why(turn: turn),
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

    /// Memory that carries User's authority is never hers to suppress: the
    /// pinned USER core (his pins), corrections, anything tagged safety. An
    /// unreadable record fails closed.
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

    /// Undo one update of hers, or list what can be undone when `item` is nil.
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

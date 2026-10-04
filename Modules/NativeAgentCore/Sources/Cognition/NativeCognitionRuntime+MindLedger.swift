// NativeCognitionRuntime+MindLedger.swift
// Phase 5 B0 (2026-10-03) — `mind.why`, `mind.reject`, `mind.undo`.
//
// Why reads the turn trace, where each delivered turn records why its felt cue
// (or none) won and each context build records which memories competed. The
// prompt never carries any of it. Reject and undo are her own verbs over her
// own mind; the substrate owns both lists and their caps.

import ChatOrchestration
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Privacy
import Studio
import TurnTrace

extension NativeCognitionRuntime {
    /// The `mind.why` rows of today and yesterday, newest first.
    private static func whyEvents(dataRoot: URL) async -> [TurnTraceEvent] {
        let reader = TurnTraceRecentReader(dataRootOverride: dataRoot)
        var events: [TurnTraceEvent] = []
        for day in [Date(), Date().addingTimeInterval(-86_400)] {
            guard let snapshot = try? await reader.read(now: day) else { continue }
            events += snapshot.events.filter { $0.kind == "mind.why" }
        }
        return events.sorted { $0.ts > $1.ts }
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
        let events = await Self.whyEvents(dataRoot: dataRoot).filter {
            $0.sessionId == session && $0.surface == caller.surface
                && $0.destinationId == destination && $0.threadId == thread
        }
        let wanted = turn?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Phase 5 D (Agent): the latest turn, the current one included — its
        // memory row is written when its context is built, before the cue
        // row lands at delivery. Defaulting to the newest CUE row answered
        // for the previous exchange.
        guard let target = (wanted?.isEmpty == false ? wanted : nil) ?? events.first?.turnId else {
            return .object(["status": .string("empty"),
                            "detail": .string("No why record is available in this conversation.")])
        }
        var rows: [(event: TurnTraceEvent, payload: JSONValue)] = []
        for event in events where event.turnId == target {
            if let payload = await disclosedWhyPayload(event.payload, surface: surface) {
                rows.append((event, payload))
            }
        }
        var out: [String: JSONValue] = ["status": .string(rows.isEmpty ? "empty" : "ok"), "turn": .string(target)]
        if rows.isEmpty { out["detail"] = .string("No why record is available in this conversation.") }
        for row in rows where out[Self.lane(row.event)] == nil {
            out[Self.lane(row.event)] = row.payload
            out["at"] = out["at"] ?? .string(ISO8601DateFormatter().string(from: row.event.ts))
        }
        // Phase 5 D (Agent): the personal recall lane (Phase 5 C) on its own,
        // not buried inside the memory lane — or said plainly when it is absent.
        if case .object(let memory)? = out["memory"], let personal = memory["personal"] {
            out["personal"] = personal
        } else if !rows.isEmpty {
            out["personal"] = .object(["pick": .null, "detail": .string(
                "No personal memory is available for this turn.")])
        }
        var recent: [String] = []
        for event in events where !recent.contains(event.turnId) {
            recent.append(event.turnId)
            if recent.count == 5 { break }
        }
        out["recent_turns"] = .array(recent.map { .string($0) })
        return .object(out)
    }

    /// Trace copies cannot grant disclosure after a memory's policy changes.
    /// Unsourced cue prose has the ordinary local-private boundary.
    private func disclosedWhyPayload(_ payload: JSONValue, surface: String) async -> JSONValue? {
        guard case .object(let fields) = payload,
              case .string(let lane)? = fields["lane"],
              ["cue", "memory", "outreach"].contains(lane) else { return nil }
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
        let seedSources = sources.filter { $0.hasPrefix("seed:") }
        if !seedSources.isEmpty {
            let seeds = await substrate.thoughtSeedSnapshot()
            for source in seedSources {
                guard let id = UUID(uuidString: String(source.dropFirst(5))),
                      let seed = seeds.first(where: { $0.id == id }) else { return nil }
                if seed.kind == .reflectionTakeaway {
                    guard let peers = seed.sourcePeerIds,
                          peers.allSatisfy({ PeerTrust.ownerTrusts($0, dataRoot: dataRoot) }) else { return nil }
                }
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

    /// She rejects one association: `source` (memory:/view:/seed:/dream:, or an
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
        if record.pinned == true { return "that memory is pinned to your core; only User unpins it" }
        if record.memoryKind == "correction" || tags.contains("correction") {
            return "that memory is a correction; corrections always stand"
        }
        if tags.contains("safety") { return "that memory is tagged safety; it always stands" }
        return nil
    }

    /// Phase 5 D1: her own revision of one of her opinions, with its evidence.
    public func reviseOpinion(
        id: UUID, stance: String, evidence: String, wouldChangeMind: String,
        seat: StudioCanonTurnProvenance
    ) async -> String? {
        await bootstrap()
        let refusal = await substrate.reviseOpinion(
            id: id, stance: stance, evidence: evidence, wouldChangeMind: wouldChangeMind, seat: seat)
        if refusal == nil { publishRuntimeChange(reason: "mind:opinion_revised") }
        return refusal
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

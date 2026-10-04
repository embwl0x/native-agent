// REMLessonOrigin.swift
// Phase 5 C1 (2026-10-03): a lesson keeps the moment that taught it.
//
// Agent: "compression saves conclusions and loses the experience behind them."
// A REM lesson lands in GROWTH as a slogan. Its proposal row already keeps the
// dream passages and their sources; REM now also writes `whatChanged` (what
// surprised her, what changed). When the lesson is approved, this keeps one
// small memory of kind `lesson_origin`: the moment behind it (his verbatim
// words, from the moment recorded in the same conversation on the same day)
// plus what changed. It rides the personal recall lane, so a turn the lesson
// is relevant to can bring back the moment instead of the slogan, which
// GROWTH already carries.
//
// On-device only: no model call. One record per approved lesson; storing the
// same origin again re-asserts the existing row.

import ChatTurnContracts
import DreamREMCycle
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Transcripts

public enum REMLessonOrigin {
    public static let kind = "lesson_origin"
    static let momentLimit = 3
    static let quoteCap = 160

    /// (conversation, lived day) pairs the lesson's passages were woven from.
    /// Refs read `<kind>:<session>/<id>@<YYYY-MM-DD>`.
    static func sourceDays(_ row: REMProposalRow) -> Set<String> {
        var out = Set<String>()
        for ref in (row.supportingPassages ?? []).flatMap(\.sourceRefs) {
            guard let at = ref.lastIndex(of: "@"), let colon = ref.firstIndex(of: ":"), colon < at else { continue }
            let body = ref[ref.index(after: colon)..<at]
            guard let slash = body.lastIndex(of: "/") else { continue }
            out.insert("\(body[..<slash])|\(ref[ref.index(after: at)...])")
        }
        return out
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
    }

    /// The moments behind the lesson: same conversation, same lived day,
    /// ranked by the words they share with the passages and what changed. A
    /// moment that shares none is not evidence of this lesson.
    public static func originMoments(
        for row: REMProposalRow,
        moments: [MemoryRecord],
        peerSessionTrusted: (String) -> Bool
    ) -> [MemoryRecord] {
        let days = sourceDays(row)
        guard !days.isEmpty else { return [] }
        let about = words(((row.supportingPassages ?? []).map(\.quote) + [row.whatChanged ?? "", row.proposalText])
            .joined(separator: " "))
        let ranked: [(MemoryRecord, Int)] = moments.compactMap { record in
            guard (record.status ?? "active") == "active", MemoryMoments.isMoment(record.extras),
                  let session = MemoryMoments.metadataString(record.extras, "session_id"),
                  let at = MemoryMoments.parseTimestamp(record.createdAt),
                  days.contains("\(session)|\(MemoryMoments.dayKey(at))"),
                  ownExchange(record, session: session, peerSessionTrusted: peerSessionTrusted) else { return nil }
            let shared = words(record.text).intersection(about).count
            return shared > 0 ? (record, shared) : nil
        }
        return ranked.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .prefix(momentLimit).map(\.0)
    }

    /// User and Agent's own exchange, or a peer User made his own in Trust
    /// (`PeerTrust`). Any other peer's moment is not the origin of her lesson.
    static func ownExchange(_ record: MemoryRecord, session: String, peerSessionTrusted: (String) -> Bool) -> Bool {
        let author = MemoryMoments.metadataString(record.extras, "author") ?? "user"
        let peer = author != "user" || session.hasPrefix("agent-") || session.hasPrefix("bot-")
        return !peer || peerSessionTrusted(session)
    }

    /// A contact's sessions are `agent-<hash of its id>-…`; the contact is
    /// trusted only when User elevated it (`PeerDataTaint.ownerTrusts`, which
    /// the engine binds to `PeerTrust`; unbound, nothing is).
    static func peerSessionTrusted(_ session: String, dataRoot: URL,
                                   ownerTrusts: (String) -> Bool = { PeerDataTaint.ownerTrusts($0) }) -> Bool {
        var owners = ["claude", "codex", "omp"]
        if let data = try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")),
           case .array(let peers)? = try? JSONValue.parse(data) {
            for case .object(let peer) in peers { if case .string(let id)? = peer["id"] { owners.append(id) } }
        }
        guard let owner = owners.first(where: {
            session.hasPrefix(ChatSessionRetention.contactSessionPrefix(owner: $0))
        }) else { return false }
        return ownerTrusts(owner)
    }

    /// One origin per lesson: the memory id is the proposal's, so a second
    /// approval run or a launch reconcile finds the row instead of adding one.
    public static func memoryID(for proposalID: String) -> String { "lesson-origin:" + proposalID }

    /// What recall surfaces in place of the slogan (GROWTH already carries
    /// that): the moment, in his words, and what changed; with no qualifying
    /// moment, what changed alone. It closes on the day it was lived, which
    /// also keeps the memory gate from reading a sentence that ends "…than I
    /// was" as a clipped capture. nil without a "what changed".
    public static func originText(for row: REMProposalRow, moment: MemoryRecord?) -> String? {
        guard let changed = row.whatChanged?.trimmingCharacters(in: .whitespacesAndNewlines),
              !changed.isEmpty else { return nil }
        let lived = moment.flatMap { MemoryMoments.parseTimestamp($0.createdAt) }.map { MemoryMoments.dayKey($0) }
            ?? row.livedDates?.last ?? String(row.createdAt.prefix(10))
        guard let said = moment.flatMap({ MemoryMoments.metadataString($0.extras, "quote") })?
            .trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty else {
            return "What changed: \(changed) (lived \(lived))"
        }
        return "\"\(String(said.prefix(quoteCap)))\" — what changed: \(changed) (lived \(lived))"
    }

    /// Keep the origin of an approved lesson, once: a replay returns the row
    /// already kept for this proposal, whatever moment ranks first now. The
    /// moment's author and disclosure ride along, so the origin is never
    /// shown anywhere the moment could not be.
    @discardableResult
    public static func record(
        _ row: REMProposalRow,
        memory: SwiftNativeMemoryV2,
        dataRoot: URL,
        ownerTrusts: @escaping (String) -> Bool = { PeerDataTaint.ownerTrusts($0) }
    ) async throws -> MemoryRecord? {
        let id = memoryID(for: row.id)
        if let kept = try await memory.authorityRecord(id: id) { return kept }
        let moments = try await memory.listMemory(kind: MemoryMoments.kind)
        let behind = originMoments(for: row, moments: moments) {
            peerSessionTrusted($0, dataRoot: dataRoot, ownerTrusts: ownerTrusts)
        }
        guard let text = originText(for: row, moment: behind.first) else { return nil }
        var metadata: [String: JSONValue] = [
            "kind": .string(kind),
            "lesson": .string(row.proposalText),
            "proposal_id": .string(row.id),
            "what_changed": .string(row.whatChanged ?? ""),
            "moment_ids": .array(behind.map { .string($0.id) }),
            "lived_dates": .array((row.livedDates ?? []).prefix(8).map { .string($0) }),
        ]
        if let moment = behind.first, case .object(let source)? = moment.extras {
            for key in ["author", "session_id", "surface", "privacy", "permittedSurfaces", "surfaces"] {
                if let value = source[key] { metadata[key] = value }
            }
            let scoped = (moment.tags ?? []).filter { $0.hasPrefix("privacy:") || $0.hasPrefix("surface:") }
            if !scoped.isEmpty { metadata["tags"] = .array(scoped.map { .string($0) }) }
        }
        do {
            return try await memory.store(
                content: text, source: "rem-lesson-origin:\(row.id)", metadata: .object(metadata), id: id)
        } catch {
            // Two runs raced past the read above: the loser finds the winner's row.
            if let kept = try await memory.authorityRecord(id: id) { return kept }
            throw error
        }
    }
}

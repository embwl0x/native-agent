// REMLessonOrigin.swift
// Approved lessons retain one idempotent, on-device lesson_origin memory with source moments and whatChanged.

import ChatTurnContracts
import DreamREMCycle
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Transcripts

// Blueprint: | `REMLessonOrigin.swift` | `REMLessonOrigin`: approved lesson provenance and origin moments, retaining what changed and the exchange that taught it |

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

    /// The moments behind the lesson: same conversation, same lived day (when
    /// it happened, not when it was reviewed), ranked by the words they share
    /// with the passages and what changed. A moment that shares none is not
    /// evidence of this lesson.
    public static func originMoments(
        for row: REMProposalRow,
        moments: [MemoryRecord],
        peerSessionTrusted: (String) -> Bool,
        dataRoot: URL = defaultDataRoot()
    ) -> [MemoryRecord] {
        let days = sourceDays(row)
        guard !days.isEmpty else { return [] }
        let about = words(((row.supportingPassages ?? []).map(\.quote) + [row.whatChanged ?? "", row.proposalText])
            .joined(separator: " "))
        let ranked: [(MemoryRecord, Int)] = moments.compactMap { record in
            guard (record.status ?? "active") == "active", MemoryMoments.isMoment(record.extras),
                  let session = record.extras?.objectValue?["session_id"]?.stringValue,
                  let at = MemoryMoments.parseTimestamp(record.observedAt ?? record.createdAt),
                  days.contains("\(session)|\(MemoryMoments.dayKey(at))"),
                  ownExchange(record, session: session, peerSessionTrusted: peerSessionTrusted, dataRoot: dataRoot) else { return nil }
            let shared = words(record.text).intersection(about).count
            return shared > 0 ? (record, shared) : nil
        }
        return ranked.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .prefix(momentLimit).map(\.0)
    }

    /// User and Agent's own exchange, or a peer User made his own in Trust
    /// (`PeerTrust`). Any other peer's moment is not the origin of her lesson.
    static func ownExchange(_ record: MemoryRecord, session: String, peerSessionTrusted: (String) -> Bool, dataRoot: URL) -> Bool {
        let author = record.extras?.objectValue?["author"]?.stringValue ?? "user"
        let peer = author != "user" || SessionConversation.kind(session, dataRoot: dataRoot, includingArchived: true)?.isPeerConversation == true
        return !peer || peerSessionTrusted(session)
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
        let lived = moment.flatMap { MemoryMoments.parseTimestamp($0.observedAt ?? $0.createdAt) }.map { MemoryMoments.dayKey($0) }
            ?? row.livedDates?.last ?? String(row.createdAt.prefix(10))
        guard let said = moment.flatMap({ $0.extras?.objectValue?["quote"]?.stringValue })?
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
        var peerOwners: [(id: String, prefix: String)]?
        let behind = originMoments(for: row, moments: moments, peerSessionTrusted: { session in
            // Read contacts once when a peer candidate needs them; trust is
            // still checked for each candidate against the live authority.
            if peerOwners == nil {
                var owners = ["claude", "codex", "omp"]
                if let data = try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")),
                   case .array(let peers)? = try? JSONValue.parse(data) {
                    for case .object(let peer) in peers { if case .string(let id)? = peer["id"] { owners.append(id) } }
                }
                peerOwners = owners.map { ($0, ChatSessionRetention.contactSessionPrefix(owner: $0)) }
            }
            guard let owner = peerOwners?.first(where: { session.hasPrefix($0.prefix) }) else { return false }
            return ownerTrusts(owner.id)
        }, dataRoot: dataRoot)
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

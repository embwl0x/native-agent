import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `StudioCanon.swift` | Append-only membership, evidence-bound proposal references and unchanged native identity/fingerprints (fixed 90-day silence ledger units); editable `Resources/abilities/studio-canon.js` owns proposal selection/reasons and the next silence deadline; native counts/entry ids cannot be supplied by the part, native capacity and agent-only decision/append authority remain |

// Native storage owns canon identity, membership, evidence and the append-only decision ledger.
// studio-canon.js owns proposal selection, reasons and silence deadlines; proposals never decide membership.

// MARK: - Vocabulary

public enum StudioCanonStanding: String, Sendable, CaseIterable, Equatable {
    /// A work that holds. The argument for it lives in the entries cited.
    case canon
    /// A work she keeps returning to in order to say no. Anti-canon is part of
    /// a developed taste, not a failure state, and it is reachable only by her
    /// saying so — nothing derives it from a judgment's tone.
    case antiCanon = "anti_canon"
}

public enum StudioCanonAction: String, Sendable, CaseIterable, Equatable {
    case promote, demote
}

/// What argued for a proposal. Recorded on the row so a canon entry can always
/// say why it was even asked about.
public enum StudioCanonEvidenceKind: String, Sendable, CaseIterable, Equatable {
    case recurrence
    case pulledInProduction = "pulled_in_production"
    case silence
}

/// One decided row on the canon ledger. Append-only: a later row supersedes an
/// earlier one for the same work, and neither is ever rewritten.
public struct StudioCanonRow: Sendable, Equatable {
    /// The proposal this row resolves — the approval record id, so a row can
    /// always be traced back to the card she actually saw.
    public var proposalID: String
    public var action: StudioCanonAction
    public var standing: StudioCanonStanding
    public var workTitle: String
    public var workCreator: String?
    public var decidedAt: String
    /// The seat that decided. Only an agent seat may appear on a promote or
    /// demote row — see `StudioCanonSeat`.
    public var decidedBy: String
    /// WHERE the decision was actually made, derived from the runtime rather
    /// than from anything the caller said: the live chat turn's own surface and
    /// turn identity. A row that cannot name them is refused, so "she decided
    /// this, in a turn, on this surface" is a fact on the ledger rather than an
    /// assumption about who called a tool.
    public var decidedOnSurface: String
    public var decidedInTurn: String
    public var evidenceKind: StudioCanonEvidenceKind
    /// The journal entry ids that argued for this. Bounded; the row is
    /// provenance, not a log.
    public var evidenceEntryIDs: [String]
    public var note: String?

    public static let maximumEvidenceEntryIDs = 24

    public init(
        proposalID: String,
        action: StudioCanonAction,
        standing: StudioCanonStanding,
        workTitle: String,
        workCreator: String? = nil,
        decidedAt: String,
        decidedBy: String,
        decidedOnSurface: String,
        decidedInTurn: String,
        evidenceKind: StudioCanonEvidenceKind,
        evidenceEntryIDs: [String] = [],
        note: String? = nil
    ) {
        self.proposalID = proposalID
        self.action = action
        self.standing = standing
        self.workTitle = workTitle
        self.workCreator = workCreator
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
        self.decidedOnSurface = decidedOnSurface
        self.decidedInTurn = decidedInTurn
        self.evidenceKind = evidenceKind
        self.evidenceEntryIDs = Array(evidenceEntryIDs.prefix(Self.maximumEvidenceEntryIDs))
        self.note = note
    }

    public var workKey: String { StudioCanonLaw.workKey(title: workTitle, creator: workCreator) }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "proposal_id": .string(proposalID),
            "action": .string(action.rawValue),
            "standing": .string(standing.rawValue),
            "work": .object({
                var work: [String: JSONValue] = ["title": .string(workTitle)]
                if let workCreator, !workCreator.isEmpty { work["creator"] = .string(workCreator) }
                return work
            }()),
            "decided_at": .string(decidedAt),
            "decided_by": .string(decidedBy),
            "decided_on_surface": .string(decidedOnSurface),
            "decided_in_turn": .string(decidedInTurn),
            "evidence_kind": .string(evidenceKind.rawValue),
            "evidence_entry_ids": .array(evidenceEntryIDs.map { .string($0) }),
        ]
        if let note, !note.isEmpty { obj["note"] = .string(note) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioCanonRow? {
        guard case .object(let obj) = value,
              case .string(let proposalID)? = obj["proposal_id"],
              case .string(let actionRaw)? = obj["action"],
              let action = StudioCanonAction(rawValue: actionRaw),
              case .string(let standingRaw)? = obj["standing"],
              let standing = StudioCanonStanding(rawValue: standingRaw),
              case .object(let work)? = obj["work"],
              case .string(let title)? = work["title"],
              case .string(let decidedAt)? = obj["decided_at"],
              case .string(let decidedBy)? = obj["decided_by"] else { return nil }
        var surface = ""
        if case .string(let value)? = obj["decided_on_surface"] { surface = value }
        var turn = ""
        if case .string(let value)? = obj["decided_in_turn"] { turn = value }
        var creator: String?
        if case .string(let c)? = work["creator"], !c.isEmpty { creator = c }
        var evidenceKind = StudioCanonEvidenceKind.recurrence
        if case .string(let raw)? = obj["evidence_kind"],
           let parsed = StudioCanonEvidenceKind(rawValue: raw) { evidenceKind = parsed }
        var entryIDs: [String] = []
        if case .array(let arr)? = obj["evidence_entry_ids"] {
            entryIDs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        var note: String?
        if case .string(let n)? = obj["note"], !n.isEmpty { note = n }
        return StudioCanonRow(
            proposalID: proposalID, action: action, standing: standing,
            workTitle: title, workCreator: creator, decidedAt: decidedAt,
            decidedBy: decidedBy, decidedOnSurface: surface, decidedInTurn: turn,
            evidenceKind: evidenceKind, evidenceEntryIDs: entryIDs, note: note
        )
    }
}

/// A work's CURRENT standing, derived from the append-only rows.
public struct StudioCanonMember: Sendable, Equatable {
    public var workTitle: String
    public var workCreator: String?
    public var standing: StudioCanonStanding
    public var since: String
    public var evidenceEntryIDs: [String]

    public init(
        workTitle: String,
        workCreator: String?,
        standing: StudioCanonStanding,
        since: String,
        evidenceEntryIDs: [String]
    ) {
        self.workTitle = workTitle
        self.workCreator = workCreator
        self.standing = standing
        self.since = since
        self.evidenceEntryIDs = evidenceEntryIDs
    }
}

// MARK: - Evidence in

/// Everything the law is allowed to know about one work. Assembled by the
/// caller from the GRAPH (recurrence) and the recall counter (production
/// pulls); nothing here is inferred from the text of a judgment.
public struct StudioCanonWorkEvidence: Sendable, Equatable {
    public var title: String
    public var creator: String?
    /// Distinct LATER journal entries whose `deepens`/`echoes` relation resolves
    /// to this work. Ids, not a count, so the proposal can cite them.
    public var recurrenceEntryIDs: [String]
    /// Live-turn studio_recall pulls that returned this work; evidence, not a preference score.
    public var recallHits: Int
    /// The most recent thing that touched this work at all: a new entry about
    /// it, or a pull of it. Empty means "nothing recorded", which never demotes.
    public var lastActivityAt: String

    public init(
        title: String,
        creator: String? = nil,
        recurrenceEntryIDs: [String] = [],
        recallHits: Int = 0,
        lastActivityAt: String = ""
    ) {
        self.title = title
        self.creator = creator
        self.recurrenceEntryIDs = recurrenceEntryIDs
        self.recallHits = max(0, recallHits)
        self.lastActivityAt = lastActivityAt
    }

    public var workKey: String { StudioCanonLaw.workKey(title: title, creator: creator) }
}

/// One thing to ASK her. Never a decision, and it carries no verdict of its own.
public struct StudioCanonProposalDraft: Sendable, Equatable {
    public var action: StudioCanonAction
    public var workTitle: String
    public var workCreator: String?
    public var evidenceKind: StudioCanonEvidenceKind
    public var evidenceEntryIDs: [String]
    public var recurrenceCount: Int
    public var recallHits: Int
    public var lastActivityAt: String
    public var elapsedSilenceWindows: Int
    public var reasonLine: String

    public init(
        action: StudioCanonAction,
        workTitle: String,
        workCreator: String?,
        evidenceKind: StudioCanonEvidenceKind,
        evidenceEntryIDs: [String],
        recurrenceCount: Int,
        recallHits: Int,
        lastActivityAt: String,
        reasonLine: String,
        elapsedSilenceWindows: Int = 0
    ) {
        self.action = action
        self.workTitle = workTitle
        self.workCreator = workCreator
        self.evidenceKind = evidenceKind
        self.evidenceEntryIDs = Array(evidenceEntryIDs.prefix(StudioCanonRow.maximumEvidenceEntryIDs))
        self.recurrenceCount = recurrenceCount
        self.recallHits = recallHits
        self.lastActivityAt = lastActivityAt
        self.elapsedSilenceWindows = elapsedSilenceWindows
        self.reasonLine = reasonLine
    }

    /// The LANE key: this work, this direction. At most one card may be OPEN on
    /// it at a time — two live questions about the same work is noise.
    public var key: String {
        "\(action.rawValue)|\(StudioCanonLaw.workKey(title: workTitle, creator: workCreator))"
    }

    /// What this proposal is ARGUING FROM, not merely what it is about.
    ///
    /// The lane key alone was the wrong dedupe across resolved cards: denying
    /// one card silenced the work forever, so a judgment she kept deepening for
    /// another year could never be asked about again. A denial should settle THE
    /// ARGUMENT SHE SAW, not the subject. So a resolved card blocks only a
    /// proposal built on the SAME evidence — new entries, a new pull count, or a
    /// later silence window all produce a new fingerprint and may be asked once.
    public var evidenceFingerprint: String {
        var parts = [key, evidenceKind.rawValue]
        switch evidenceKind {
        case .recurrence, .pulledInProduction:
            parts.append(evidenceEntryIDs.sorted().joined(separator: ","))
            parts.append("recurrences:\(recurrenceCount)")
            parts.append("pulls:\(recallHits)")
        case .silence:
            // The window this demotion is arguing from. A work that stays silent
            // another 90 days is a genuinely new question, not a repeat.
            parts.append("silent_since:\(lastActivityAt)")
            parts.append("windows:\(elapsedSilenceWindows)")
        }
        return parts.joined(separator: "\u{1f}")
    }

}

// MARK: - The law

public enum StudioCanonLaw {
    /// Existing silence fingerprints count these fixed ledger windows. The
    /// editable proposal/deadline policy lives in studio-canon.js; changing it
    /// cannot reinterpret the identity of an argument already decided.
    public static let silenceIdentityWindow: TimeInterval = 90 * 24 * 60 * 60
    /// Bound on one pass. Canon-tending is deliberate and low-frequency; an
    /// inbox of twenty cards is homework, which the design forbids.
    public static let maximumProposalsPerPass = 3

    /// Title + creator, folded. Two spellings of one work are one work.
    public static func workKey(title: String, creator: String?) -> String {
        func fold(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
        }
        return fold(title) + "\u{1f}" + fold(creator ?? "")
    }

    /// Current standing per work key, from the append-only rows in file order.
    /// A later row supersedes an earlier one; a `demote` removes membership
    /// without erasing the promote row that preceded it.
    public static func membership(from rows: [StudioCanonRow]) -> [String: StudioCanonMember] {
        var result: [String: StudioCanonMember] = [:]
        for row in rows {
            switch row.action {
            case .promote:
                result[row.workKey] = StudioCanonMember(
                    workTitle: row.workTitle,
                    workCreator: row.workCreator,
                    standing: row.standing,
                    since: row.decidedAt,
                    evidenceEntryIDs: row.evidenceEntryIDs
                )
            case .demote:
                result.removeValue(forKey: row.workKey)
            }
        }
        return result
    }

    /// Export neutral facts, then bind the part's references back to those
    /// facts. The part supplies no counts, entry ids, membership or identity.
    public static func project(
        evidence: [StudioCanonWorkEvidence],
        membership: [String: StudioCanonMember],
        now: Date,
        deadlineDate: @Sendable (String) -> Date? = { NativeTimestampFormat.parseISO8601FractionalFirst($0) },
        decide: @Sendable (JSONValue) async throws -> JSONValue
    ) async throws -> (drafts: [StudioCanonProposalDraft], nextAt: Date?) {
        let works = Dictionary(evidence.map { ($0.workKey, $0) }, uniquingKeysWith: { first, _ in first })
        let activity = Dictionary(evidence.map { ($0.workKey, $0.lastActivityAt) }, uniquingKeysWith: { max($0, $1) })
        func stamp(_ key: String, _ member: StudioCanonMember) -> String { max(works[key]?.lastActivityAt ?? "", member.since) }
        func seconds(_ stamp: String) -> JSONValue { NativeTimestampFormat.parseISO8601FractionalFirst(stamp).map { .double($0.timeIntervalSince1970) } ?? .null }
        func deadlineSeconds(_ stamp: String) -> JSONValue { deadlineDate(stamp).map { .double($0.timeIntervalSince1970) } ?? .null }
        let workFacts: [JSONValue] = evidence.sorted { $0.workKey < $1.workKey }.map { work in
            .object(["key": .string(work.workKey), "title": .string(work.title),
                "creator": work.creator.map(JSONValue.string) ?? .null,
                "recurrence_entry_ids": .array(uniqued(work.recurrenceEntryIDs).map(JSONValue.string)),
                "recurrence_count": .int(Int64(uniqued(work.recurrenceEntryIDs).count)),
                "recall_hits": .int(Int64(work.recallHits)), "last_activity_at": .string(work.lastActivityAt)])
        }
        let memberFacts: [JSONValue] = membership.keys.sorted().compactMap { key in
            membership[key].map { member in
                .object(["key": .string(key), "title": .string(member.workTitle),
                    "creator": member.workCreator.map(JSONValue.string) ?? .null,
                    "evidence_entry_ids": .array(member.evidenceEntryIDs.map(JSONValue.string)),
                    "last_signal": .string(stamp(key, member)), "last_signal_seconds": seconds(stamp(key, member)),
                    "deadline_signal_seconds": deadlineSeconds(max(activity[key] ?? "", member.since))])
            }
        }
        let facts = JSONValue.object(["now": .double(now.timeIntervalSince1970),
            "evidence": .array(workFacts), "members": .array(memberFacts)])
        struct Choice: Decodable { let key: String; let action: String; let evidenceKind: String; let reasonLine: String }
        struct Selection: Decodable { let proposals: [Choice]; let nextAt: Double? }
        let selection = try JSONDecoder().decode(Selection.self, from: try await decide(facts).serializedData(pretty: false))
        var seen = Set<String>()
        let drafts = try selection.proposals.map { choice -> StudioCanonProposalDraft in
            guard seen.insert(choice.action + "|" + choice.key).inserted,
                  !choice.reasonLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersistenceCoreError.ioFailure("Canon returned a duplicate proposal or an empty reason.")
            }
            if choice.action == "promote", let work = works[choice.key], membership[choice.key] == nil,
               let kind = StudioCanonEvidenceKind(rawValue: choice.evidenceKind), kind != .silence {
                let ids = uniqued(work.recurrenceEntryIDs)
                guard kind == .recurrence ? !ids.isEmpty : work.recallHits > 0 else {
                    throw PersistenceCoreError.ioFailure("Canon proposed recurrence or a production pull without a native witness.")
                }
                return StudioCanonProposalDraft(action: .promote, workTitle: work.title, workCreator: work.creator,
                    evidenceKind: kind, evidenceEntryIDs: ids, recurrenceCount: ids.count, recallHits: work.recallHits,
                    lastActivityAt: work.lastActivityAt, reasonLine: choice.reasonLine)
            }
            if choice.action == "demote", choice.evidenceKind == "silence", let member = membership[choice.key],
               let last = NativeTimestampFormat.parseISO8601FractionalFirst(stamp(choice.key, member)) {
                return StudioCanonProposalDraft(action: .demote, workTitle: member.workTitle, workCreator: member.workCreator,
                    evidenceKind: .silence, evidenceEntryIDs: member.evidenceEntryIDs,
                    recurrenceCount: works[choice.key]?.recurrenceEntryIDs.count ?? 0, recallHits: works[choice.key]?.recallHits ?? 0,
                    lastActivityAt: stamp(choice.key, member), reasonLine: choice.reasonLine,
                    elapsedSilenceWindows: Int(max(0, now.timeIntervalSince(last)) / silenceIdentityWindow))
            }
            throw PersistenceCoreError.ioFailure("Canon selected a proposal without matching native evidence or membership.")
        }
        if let next = selection.nextAt, !next.isFinite || next <= now.timeIntervalSince1970 {
            throw PersistenceCoreError.ioFailure("Canon's next deadline must be a finite future instant.")
        }
        return (drafts, selection.nextAt.map(Date.init(timeIntervalSince1970:)))
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Who may decide

/// Only the agent's live tool turn may decide canon membership; the owner cannot approve it.
public enum StudioCanonSeat {
    /// The only seat a canon row may carry: her own tool lane, reached when SHE
    /// calls `studio_canon_resolve` during a turn.
    public static let agent = "studio_agent"

    public static func isAgent(_ decidedBy: String?) -> Bool {
        (decidedBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == agent
    }
}

/// Decision surface and identity come from live turn task-locals, never caller-supplied provenance.
public struct StudioCanonTurnProvenance: Sendable, Equatable {
    /// The surface the LIVE turn is running on, as the tool loop bound it.
    public let surface: String
    /// The turn's own identity — the pinned run id when the surface has one,
    /// otherwise the transport-verified session. Never model-supplied.
    public let turnID: String

    public init(surface: String, turnID: String) {
        self.surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        self.turnID = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool { !surface.isEmpty && !turnID.isEmpty }
}

// MARK: - The ledger

public extension SwiftNativeStudioStore {

    /// `<dataRoot>/studio/canon/`.
    var canonDirectory: URL {
        studioRoot.appendingPathComponent("canon", isDirectory: true)
    }

    /// `<dataRoot>/studio/canon/canon.jsonl` — append-only promote/demote rows.
    var canonPath: URL {
        canonDirectory.appendingPathComponent("canon.jsonl")
    }

    /// `<dataRoot>/studio/canon/recall_hits.json` — the bounded production-pull
    /// counter. See `noteRecallPulls`.
    var canonRecallHitsPath: URL {
        canonDirectory.appendingPathComponent("recall_hits.json")
    }

    /// Every decided row, in file order. Missing file is an empty canon.
    func readCanon() async throws -> [StudioCanonRow] {
        try await Self.readCanon(at: canonPath)
    }

    private static func readCanon(at path: URL) async throws -> [StudioCanonRow] {
        let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
        let decoded = rows.compactMap { StudioCanonRow.fromJSON($0) }
        guard report.malformedLineCount == 0, !report.trailingPartialLine,
              decoded.count == rows.count else {
            throw StudioCanonError.unreadableHistory
        }
        return decoded
    }

    /// Current membership, canon and anti-canon together.
    func canonMembership() async throws -> [String: StudioCanonMember] {
        StudioCanonLaw.membership(from: try await readCanon())
    }

    /// Append ONE decided row. Idempotent by `proposalID`: resolving the same
    /// card twice (the crash-window reconcile does exactly that) writes one row.
    ///
    /// Refuses any seat but hers — the sole-approver rule, enforced at the last
    /// place a row could reach the disk rather than only at the tool.
    @discardableResult
    func appendCanonRow(_ row: StudioCanonRow) async throws -> Bool {
        guard StudioCanonSeat.isAgent(row.decidedBy) else {
            throw StudioCanonError.approvalNotFromAgentSeat(row.decidedBy)
        }
        // A row that cannot say WHERE it was decided is not hers by evidence,
        // only by assertion. Refuse it here too, at the last place a row can
        // reach the disk, so no future caller can skip the tool's gate.
        guard StudioCanonTurnProvenance(
            surface: row.decidedOnSurface, turnID: row.decidedInTurn
        ).isComplete else {
            throw StudioCanonError.decisionHasNoLiveTurn
        }
        guard !row.workTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioCanonError.missingWorkTitle
        }
        try FileManager.default.createDirectory(
            at: canonDirectory, withIntermediateDirectories: true
        )
        // Proposal-id deduplication and append share one flock, including replayed decisions.
        let path = canonPath
        let payload = row.toJSON()
        let proposalID = row.proposalID
        let label = Self.logLabel
        let appended = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            let existing: [StudioCanonRow]
            do { existing = try await Self.readCanon(at: path) }
            catch {
                nativeLog("[StudioCanon] Append deferred: %@", error.localizedDescription)
                throw error
            }
            guard !existing.contains(where: { $0.proposalID == proposalID }) else { return false }
            try await appendPathOwnedJSONL(
                payload,
                to: path,
                logLabel: label,
                durable: true
            )
            return true
        }
        if appended {
            await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                namespace: "studio", stableID: "canon", operation: .changed,
                canonicalLocator: path.standardizedFileURL.path,
                reason: "studio_canon_membership_changed"
            ))
        }
        return appended
    }

    // MARK: Production pulls

    /// Count works actually returned by live-turn recall as native evidence for the editable canon policy.
    /// Bound to maximumTrackedWorks keys by evicting the least recently pulled; no preference or decay.
    func noteRecallPulls(
        titles: [(title: String, creator: String?)],
        now: Date = Date(),
        maximumTrackedWorks: Int = 256
    ) async {
        guard !titles.isEmpty, maximumTrackedWorks > 0 else { return }
        let stamp = NativeTimestampFormat.sixDigitUTCOffset(now)
        try? FileManager.default.createDirectory(
            at: canonDirectory, withIntermediateDirectories: true
        )
        let path = canonRecallHitsPath
        do { try await SwiftNativePersistenceCore.withFileLock(path) {
            let current = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:]))
            var table: [String: JSONValue] = [:]
            if case .object(let obj) = current, case .object(let works)? = obj["works"] {
                table = works
            }
            _ = try Self.checkedRecallCounts(current)
            var seen = Set<String>()
            for entry in titles {
                let cleaned = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let key = StudioCanonLaw.workKey(title: cleaned, creator: entry.creator)
                guard seen.insert(key).inserted else { continue }
                var count: Int64 = 0
                if case .object(let row)? = table[key], case .int(let existing)? = row["count"] {
                    count = existing
                }
                let (next, overflow) = count.addingReportingOverflow(1)
                guard !overflow else { throw StudioCanonError.unavailableRecallCounts }
                let row: [String: JSONValue] = [
                    "count": .int(next),
                    "last_at": .string(stamp),
                ]
                table[key] = .object(row)
            }
            if table.count > maximumTrackedWorks {
                // Evict the least recently pulled. A counter that grows forever
                // is telemetry; this one is evidence with a bound.
                let ordered = table.sorted { lhs, rhs in
                    func stamp(_ value: JSONValue) -> String {
                        if case .object(let obj) = value, case .string(let s)? = obj["last_at"] {
                            return s
                        }
                        return ""
                    }
                    return stamp(lhs.value) > stamp(rhs.value)
                }
                table = Dictionary(
                    uniqueKeysWithValues: ordered.prefix(maximumTrackedWorks).map { ($0.key, $0.value) }
                )
            }
            try await SwiftNativePersistenceCore.writeJSON(
                .object(["works": .object(table)]),
                to: path
            )
        } } catch {
            nativeLog("[StudioCanon] Recall counting unavailable: %@", error.localizedDescription)
        }
    }

    /// The counter, read back as `workKey → (count, lastAt)`.
    func recallPullCounts() async throws -> [String: (count: Int, lastAt: String)] {
        let value = try await SwiftNativePersistenceCore.readJSON(canonRecallHitsPath, ifMissing: .object([:]))
        return try Self.checkedRecallCounts(value)
    }

    private static func checkedRecallCounts(_ value: JSONValue) throws -> [String: (count: Int, lastAt: String)] {
        guard case .object(let obj) = value else { throw StudioCanonError.unavailableRecallCounts }
        if obj.isEmpty { return [:] } // A missing counter has no pulls yet.
        guard case .object(let works)? = obj["works"] else { throw StudioCanonError.unavailableRecallCounts }
        var result: [String: (count: Int, lastAt: String)] = [:]
        for (key, row) in works {
            guard case .object(let fields) = row,
                  case .int(let value)? = fields["count"], value >= 0,
                  let count = Int(exactly: value),
                  case .string(let lastAt)? = fields["last_at"] else {
                throw StudioCanonError.unavailableRecallCounts
            }
            result[key] = (count, lastAt)
        }
        return result
    }
}

public enum StudioCanonError: Error, LocalizedError, Sendable, Equatable {
    /// User approved a canon card. The whole point of the lane is that he can't.
    case approvalNotFromAgentSeat(String)
    /// The call did not come from her live chat turn — a bridge tool run, an
    /// approval executor, a replay, or a background lane.
    case decisionHasNoLiveTurn
    case missingWorkTitle
    case unknownProposal(String)
    case unreadableHistory
    case unavailableRecallCounts

    public var errorDescription: String? {
        switch self {
        case .unavailableRecallCounts:
            return "studio canon: recall counts are invalid or exhausted; counting is unavailable and stored bytes were preserved."
        case .approvalNotFromAgentSeat(let seat):
            return "studio canon: '\(seat)' is not the agent seat. The canon is hers to tend — "
                + "only she may promote or demote a work, through studio_canon_resolve. "
                + "Nothing was written."
        case .decisionHasNoLiveTurn:
            return "studio canon: a canon decision has to be made IN a turn — yours, on a local "
                + "surface, live. This call did not come from one (a bridge tool run, an "
                + "approval replay, or a background pass), so the seat cannot be established "
                + "and nothing was written. Decide it in chat."
        case .unreadableHistory:
            return "studio canon: history is unreadable; retry after it can be read. Nothing was written."
        case .missingWorkTitle:
            return "studio canon: a canon row needs the work's title."
        case .unknownProposal(let id):
            return "studio canon: no pending canon proposal with id '\(id)'."
        }
    }
}

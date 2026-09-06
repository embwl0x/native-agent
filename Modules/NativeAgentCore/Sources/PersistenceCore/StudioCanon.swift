import Foundation

// MARK: - The museum's canon — desk 903 phase 4
//
// Her brief, verbatim: "Museum/canon — earned by recurrence, not the calendar.
// A work is proposed when N later entries deepen/echo it or it is pulled in
// production; evidence is the graph. Proposal/approval shape kept; Agent is the
// SOLE approver ('my taste, not User's to sign off'). Demotion proposals for
// canon that goes silent. No auto-canonization."
//
// ── WHAT THIS FILE IS, AND IS NOT ────────────────────────────────────────────
// It is the LAW and the LEDGER, and nothing else:
//   • `StudioCanonLaw` — pure. Evidence in, PROPOSALS out. It has no clock of
//     its own, no store, no approval inbox, and no way to write anything. That
//     is what makes "no auto-canonization" structural rather than promised: the
//     only thing this code can produce is a request for her decision.
//   • `canon.jsonl` — append-only promote/demote rows, each naming the evidence
//     entry ids that argued for it and WHO decided. A demotion does not erase a
//     promotion; both rows stay, so the canon's own history reads as the record
//     of a mind changing, which is the same promise the journal makes.
//
// It is NOT a score. Recurrence is a COUNT of distinct later entries that
// deepened or echoed a work — a fact about how often she came back — never a
// ranking of one work against another. Two works that both cross the threshold
// are both proposed; nothing sorts them.
//
// ── WHY RECURRENCE, AND WHY A PULL ───────────────────────────────────────────
// Two independent doors, either of which is enough:
//   1. RECURRENCE — `recurrenceThreshold` distinct later entries linking back to
//      the work with `deepens` or `echoes`. Not `revises` and not
//      `contradicts`: those are her arguing with an earlier judgment, and an
//      argument is not evidence that a work has become load-bearing.
//   2. PULLED IN PRODUCTION — the pointer was actually used in a live judgment.
//      This is the phase-5 success metric turned into canon evidence: "never
//      called in production means pull failed", so a work that IS called has
//      proved the opposite about itself.
//
// ── AND WHY SILENCE DEMOTES ──────────────────────────────────────────────────
// A canon that only ever grows is a favourites list with extra steps. If
// nothing has been written about a canon work and nothing has pulled it for
// `silenceWindow`, that is a PROPOSAL to demote — never a demotion. She may
// look at it and say it still holds.

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
    /// How many times a `studio_recall` pull actually returned this work in a
    /// live turn. The phase-5 metric, reused as evidence.
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

    public init(
        action: StudioCanonAction,
        workTitle: String,
        workCreator: String?,
        evidenceKind: StudioCanonEvidenceKind,
        evidenceEntryIDs: [String],
        recurrenceCount: Int,
        recallHits: Int,
        lastActivityAt: String
    ) {
        self.action = action
        self.workTitle = workTitle
        self.workCreator = workCreator
        self.evidenceKind = evidenceKind
        self.evidenceEntryIDs = Array(evidenceEntryIDs.prefix(StudioCanonRow.maximumEvidenceEntryIDs))
        self.recurrenceCount = recurrenceCount
        self.recallHits = recallHits
        self.lastActivityAt = lastActivityAt
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
            parts.append("pulls:\(recallHits)")
        case .silence:
            // The window this demotion is arguing from. A work that stays silent
            // another 90 days is a genuinely new question, not a repeat.
            parts.append("silent_since:\(lastActivityAt)")
        }
        return parts.joined(separator: "\u{1f}")
    }

    /// The card's reason line — states the evidence and stops. No adjective
    /// about the work, no suggested answer.
    public var reasonLine: String {
        switch evidenceKind {
        case .recurrence:
            return "\(recurrenceCount) later entries deepen or echo this work. "
                + "That is recurrence, not a rating — you kept coming back to it."
        case .pulledInProduction:
            return "This work's pointer was pulled \(recallHits) time(s) in live judgments. "
                + "It is being used, not just filed."
        case .silence:
            return "Nothing has been written about this work and nothing has pulled it "
                + "since \(lastActivityAt.isEmpty ? "it entered the canon" : lastActivityAt). "
                + "Demote it, or say it still holds and it stays."
        }
    }
}

// MARK: - The law

public enum StudioCanonLaw {
    /// N later entries that deepen/echo a work. Her brief says "N later
    /// entries"; three is the smallest number that is a pattern rather than a
    /// pair, and the plan names it.
    public static let recurrenceThreshold = 3
    /// One real production pull is enough. The whole point of phase 5 was that
    /// a pointer nobody calls has failed; a pointer that IS called has proved
    /// something about the work it points at.
    public static let recallThreshold = 1
    /// 90 days of nothing — no new entry, no recall.
    public static let silenceWindow: TimeInterval = 90 * 24 * 60 * 60
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

    /// THE ONLY THING THIS FILE PRODUCES. Evidence in, proposals out — never a
    /// row, never a write, never a canonization.
    ///
    /// `now` is passed in rather than read: the law has no clock, so a test and
    /// production run the same code.
    public static func proposals(
        evidence: [StudioCanonWorkEvidence],
        membership: [String: StudioCanonMember],
        now: Date,
        parseISO: (String) -> Date? = { StudioClock.parseISO($0) }
    ) -> [StudioCanonProposalDraft] {
        var drafts: [StudioCanonProposalDraft] = []

        // Promotions: only for works that are NOT already in the canon.
        for work in evidence.sorted(by: { $0.workKey < $1.workKey }) {
            guard membership[work.workKey] == nil else { continue }
            let recurrence = uniqued(work.recurrenceEntryIDs)
            if recurrence.count >= recurrenceThreshold {
                drafts.append(StudioCanonProposalDraft(
                    action: .promote,
                    workTitle: work.title,
                    workCreator: work.creator,
                    evidenceKind: .recurrence,
                    evidenceEntryIDs: recurrence,
                    recurrenceCount: recurrence.count,
                    recallHits: work.recallHits,
                    lastActivityAt: work.lastActivityAt
                ))
            } else if work.recallHits >= recallThreshold {
                drafts.append(StudioCanonProposalDraft(
                    action: .promote,
                    workTitle: work.title,
                    workCreator: work.creator,
                    evidenceKind: .pulledInProduction,
                    evidenceEntryIDs: recurrence,
                    recurrenceCount: recurrence.count,
                    recallHits: work.recallHits,
                    lastActivityAt: work.lastActivityAt
                ))
            }
        }

        // Demotions: canon that has gone silent for the whole window.
        let evidenceByKey = Dictionary(
            evidence.map { ($0.workKey, $0) }, uniquingKeysWith: { first, _ in first }
        )
        for key in membership.keys.sorted() {
            guard let member = membership[key] else { continue }
            // The latest signal of life: activity if there is any, otherwise the
            // day it entered the canon. A work promoted yesterday is never
            // silent, whatever the evidence table does or does not hold.
            let lastActivity = evidenceByKey[key]?.lastActivityAt ?? ""
            let stamp = [lastActivity, member.since].filter { !$0.isEmpty }.max() ?? ""
            guard let last = parseISO(stamp) else { continue }
            guard now.timeIntervalSince(last) >= silenceWindow else { continue }
            drafts.append(StudioCanonProposalDraft(
                action: .demote,
                workTitle: member.workTitle,
                workCreator: member.workCreator,
                evidenceKind: .silence,
                evidenceEntryIDs: member.evidenceEntryIDs,
                recurrenceCount: evidenceByKey[key]?.recurrenceEntryIDs.count ?? 0,
                recallHits: evidenceByKey[key]?.recallHits ?? 0,
                lastActivityAt: stamp
            ))
        }
        return Array(drafts.prefix(maximumProposalsPerPass))
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Who may decide

/// SHE IS THE SOLE APPROVER. This is the inversion of every other card in the
/// app: elsewhere the owner decides and the agent proposes; here the agent
/// decides and the owner may not.
///
/// Her line: "my taste, not User's to sign off." So the seat check is not a
/// courtesy — a canon row carrying an owner seat is refused and nothing is
/// written. User can still see the card, argue about it in chat, and watch what
/// she does with it; he cannot resolve it into her museum.
public enum StudioCanonSeat {
    /// The only seat a canon row may carry: her own tool lane, reached when SHE
    /// calls `studio_canon_resolve` during a turn.
    public static let agent = "studio_agent"

    /// Owner surfaces, named explicitly so the refusal reads as a decision
    /// rather than a fallback. Every other seat is refused too — this list is
    /// documentation, not the gate.
    public static let ownerSeats: Set<String> = [
        "mac_ui", "local_desk_click", "full_mac_yolo", "ios_signed_operator", "mac_operator",
    ]

    public static func isAgent(_ decidedBy: String?) -> Bool {
        (decidedBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == agent
    }
}

/// WHERE a canon decision was made, derived from the running turn.
///
/// The seat string alone was never enough: any dispatch path — the Claude
/// bridge's `/claude/tool` runner, an approval executor, a replay — could call
/// a tool that stamped it. So the seat is now composed of two halves that a
/// caller cannot supply: this value, which only the tool lane can obtain from
/// the live turn's own task-locals, and the agent seat above. The store refuses
/// a row missing either.
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
        guard FileManager.default.fileExists(atPath: canonPath.path) else { return [] }
        let rows = try await persistence.readJSONL(canonPath)
        return rows.compactMap { StudioCanonRow.fromJSON($0) }
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
        // ONE transaction. The proposal-id check and the append have to be
        // atomic against a concurrent writer, or two racing replays both read
        // "no row yet" and both append — the exact lost-update shape the desk
        // stores learned the hard way. `readJSONL` takes no lock of its own, so
        // the read is safe inside the flock and the append takes none.
        let path = canonPath
        let core = persistence
        let payload = row.toJSON()
        let proposalID = row.proposalID
        let label = Self.logLabel
        return try await core.withFileLock(path) { () async throws -> Bool in
            let existing = (try? await core.readJSONL(path))?
                .compactMap { StudioCanonRow.fromJSON($0) } ?? []
            guard !existing.contains(where: { $0.proposalID == proposalID }) else { return false }
            try await appendPathOwnedJSONL(
                payload,
                to: path,
                using: core,
                logLabel: label,
                takeLock: false,
                durable: true
            )
            return true
        }
    }

    // MARK: Production pulls

    /// Note that a `studio_recall` actually RETURNED these works during a live
    /// turn. This is the "pulled in production" evidence door, and it is the
    /// only counter in the whole studio.
    ///
    /// It counts PULLS, not preference: there is no ordering, no decay, and
    /// nothing reads it except the canon law's threshold test. Bounded to
    /// `maximumTrackedWorks` keys, evicting the least recently pulled, so a
    /// noisy month cannot grow a file without end.
    func noteRecallPulls(
        titles: [(title: String, creator: String?)],
        now: Date = Date(),
        maximumTrackedWorks: Int = 256
    ) async {
        guard !titles.isEmpty else { return }
        let stamp = StudioClock.nowISO(now)
        try? FileManager.default.createDirectory(
            at: canonDirectory, withIntermediateDirectories: true
        )
        let path = canonRecallHitsPath
        let core = persistence
        _ = try? await core.withFileLock(path) {
            let current = await core.readJSON(path, defaultValue: .object([:]))
            var table: [String: JSONValue] = [:]
            if case .object(let obj) = current, case .object(let works)? = obj["works"] {
                table = works
            }
            for entry in titles {
                let cleaned = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let key = StudioCanonLaw.workKey(title: cleaned, creator: entry.creator)
                var count: Int64 = 0
                if case .object(let row)? = table[key], case .int(let existing)? = row["count"] {
                    count = existing
                }
                var row: [String: JSONValue] = [
                    "count": .int(count + 1),
                    "last_at": .string(stamp),
                    "title": .string(String(cleaned.prefix(200))),
                ]
                if let creator = entry.creator?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !creator.isEmpty {
                    row["creator"] = .string(String(creator.prefix(160)))
                }
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
            try await core.writeJSON(
                .object(["updated_at": .string(stamp), "works": .object(table)]),
                to: path
            )
        }
    }

    /// The counter, read back as `workKey → (count, lastAt)`.
    func recallPullCounts() async -> [String: (count: Int, lastAt: String)] {
        let value = await persistence.readJSON(canonRecallHitsPath, defaultValue: .object([:]))
        guard case .object(let obj) = value, case .object(let works)? = obj["works"] else {
            return [:]
        }
        var result: [String: (count: Int, lastAt: String)] = [:]
        for (key, row) in works {
            guard case .object(let fields) = row else { continue }
            var count = 0
            if case .int(let value)? = fields["count"] { count = Int(value) }
            var lastAt = ""
            if case .string(let value)? = fields["last_at"] { lastAt = value }
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

    public var errorDescription: String? {
        switch self {
        case .approvalNotFromAgentSeat(let seat):
            return "studio canon: '\(seat)' is not the agent seat. The canon is hers to tend — "
                + "only she may promote or demote a work, through studio_canon_resolve. "
                + "Nothing was written."
        case .decisionHasNoLiveTurn:
            return "studio canon: a canon decision has to be made IN a turn — yours, on a local "
                + "surface, live. This call did not come from one (a bridge tool run, an "
                + "approval replay, or a background pass), so the seat cannot be established "
                + "and nothing was written. Decide it in chat."
        case .missingWorkTitle:
            return "studio canon: a canon row needs the work's title."
        case .unknownProposal(let id):
            return "studio canon: no pending canon proposal with id '\(id)'."
        }
    }
}

// MARK: - Sensibility — personality-depth item 10 (taste → sophistication)
//
// "When canon changes she distills 2–3 lines of what she has come to care about
// in work; sole author and approver; lives in the cached stable head. Zero
// per-turn cost."
//
// ── WHAT IT IS ───────────────────────────────────────────────────────────────
// Not a summary of the canon and not a profile. The canon says WHAT she keeps;
// this says what she has come to CARE ABOUT — the thing a person can state
// about their own taste without listing a single work. It is the only part of
// the studio that rides her prompt, and it rides it as three lines in the
// cached prefix, which is why it must never contain a date, a count, a work
// list or anything else that changes without her deciding it changed.
//
// ── SHE IS BOTH AUTHOR AND APPROVER ──────────────────────────────────────────
// Every other distillation in this app is proposed by machinery and approved by
// User. This one has no machine author at all: the LINES ARE HERS, typed in her
// own live turn through `studio_canon_resolve`, and the store refuses anything
// that cannot prove it came from that seat. There is no draft for her to accept,
// because a draft written for her would already be someone else's sensibility.
//
// ── STAGED BY A CANON CHANGE, AND ONLY BY ONE ───────────────────────────────
// `stagingState` derives staging from the two files: a canon row decided after
// the newest sensibility entry means one is staged. No stager, no card queue, no
// pending file — so nothing can be staged by anything except an actual canon
// change, and nothing can get stuck staged after she writes.
//
// ── APPEND-ONLY HISTORY + CURRENT ────────────────────────────────────────────
// `data/studio/canon/sensibility.md`, one `## <stamp>` section per distillation.
// Current is the LAST section. Earlier ones are never rewritten: she is allowed
// to have cared about different things in March, and the file says so.

public enum StudioSensibility {
    /// The hard bound on what may enter the cached stable prefix. Three lines
    /// of a person's taste, not an essay: over the bound the block is truncated
    /// at a line boundary rather than shipped long.
    public static let maximumRenderedCharacters = 400
    /// What she may write in one distillation before the store trims it. Sized
    /// so the render bound is reached by the render, never by a silent cut here.
    public static let maximumLines = 3
    public static let maximumLineCharacters = 200

    /// The heading the stable prefix renders. Matched by the reader too, so the
    /// block's shape lives in exactly one place.
    public static let stableHeading = "# Sensibility"

    public enum Staging: Sendable, Equatable {
        /// A canon row was decided after the last distillation (or the first
        /// canon row exists and she has never written one).
        case staged(sinceCanonDecidedAt: String)
        case notStaged
    }

    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case notFromAgentSeat(String)
        case decisionHasNoLiveTurn
        case notStaged
        case empty

        public var errorDescription: String? {
            switch self {
            case .notFromAgentSeat(let seat):
                return "studio sensibility: '\(seat)' is not the agent seat. What you have "
                    + "come to care about in work is yours to write and nobody else's to "
                    + "approve. Nothing was written."
            case .decisionHasNoLiveTurn:
                return "studio sensibility: this has to be written IN your own live turn. "
                    + "A background pass, a bridge run or an approval replay cannot author "
                    + "it. Nothing was written."
            case .notStaged:
                return "studio sensibility: nothing has changed in the canon since your last "
                    + "distillation, so there is nothing to restate. Nothing was written."
            case .empty:
                return "studio sensibility: the distillation was empty."
            }
        }
    }
}

public extension SwiftNativeStudioStore {

    /// `<dataRoot>/studio/canon/sensibility.md`.
    var sensibilityPath: URL {
        canonDirectory.appendingPathComponent("sensibility.md")
    }

    /// Every distillation she has written, oldest first, as `(stamp, lines)`.
    func readSensibilityHistory() async -> [(at: String, lines: [String])] {
        guard let text = try? String(contentsOf: sensibilityPath, encoding: .utf8) else {
            return []
        }
        var sections: [(String, [String])] = []
        var stamp: String?
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.hasPrefix("## ") {
                if let stamp { sections.append((stamp, lines)) }
                stamp = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                lines = []
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, stamp != nil else { continue }
            lines.append(trimmed)
        }
        if let stamp { sections.append((stamp, lines)) }
        return sections.filter { !$0.1.isEmpty }
    }

    /// The current sensibility: the LAST section she wrote. `nil` when she has
    /// never written one, which is the ordinary state and never a gap.
    func currentSensibility() async -> [String]? {
        let history = await readSensibilityHistory()
        guard let last = history.last, !last.lines.isEmpty else { return nil }
        return last.lines
    }

    /// Is a distillation staged? Derived from the two files, never stored.
    ///
    /// Staged means: a canon row was DECIDED after the newest distillation was
    /// written. A build with no canon rows is never staged, and writing clears
    /// the staging by construction.
    func sensibilityStaging() async -> StudioSensibility.Staging {
        let rows = (try? await readCanon()) ?? []
        guard let newestCanonAt = rows.map(\.decidedAt).max(), !newestCanonAt.isEmpty else {
            return .notStaged
        }
        let history = await readSensibilityHistory()
        guard let lastWrittenAt = history.last?.at else {
            return .staged(sinceCanonDecidedAt: newestCanonAt)
        }
        guard newestCanonAt > lastWrittenAt else { return .notStaged }
        return .staged(sinceCanonDecidedAt: newestCanonAt)
    }

    /// Append ONE distillation, in her words, from her seat.
    ///
    /// Refuses every seat but hers and every call that cannot prove a live turn
    /// — the same two-part gate `appendCanonRow` enforces, at the last place the
    /// bytes can reach the disk. Refuses when nothing is staged, so the block in
    /// her prompt can only ever change because the canon did.
    @discardableResult
    func appendSensibility(
        lines: [String],
        decidedBy: String,
        provenance: StudioCanonTurnProvenance,
        now: Date = Date()
    ) async throws -> [String] {
        guard StudioCanonSeat.isAgent(decidedBy) else {
            throw StudioSensibility.Error.notFromAgentSeat(decidedBy)
        }
        guard provenance.isComplete else { throw StudioSensibility.Error.decisionHasNoLiveTurn }
        let cleaned = lines
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(StudioSensibility.maximumLines)
            .map { String($0.prefix(StudioSensibility.maximumLineCharacters)) }
        guard !cleaned.isEmpty else { throw StudioSensibility.Error.empty }
        guard case .staged = await sensibilityStaging() else {
            throw StudioSensibility.Error.notStaged
        }
        try FileManager.default.createDirectory(
            at: canonDirectory, withIntermediateDirectories: true
        )
        let path = sensibilityPath
        let core = persistence
        let section = "## \(StudioClock.nowISO(now))\n" + cleaned.joined(separator: "\n") + "\n\n"
        _ = try await core.withFileLock(path) { () async throws -> Bool in
            let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            try (existing + section).write(to: path, atomically: true, encoding: .utf8)
            return true
        }
        return Array(cleaned)
    }

    /// The block the cached stable prefix renders, or `nil` when she has never
    /// written one. Byte-stable by construction: no stamp, no count, no work
    /// names — the same bytes on every turn until SHE writes different ones.
    func renderedSensibilityBlock() async -> String? {
        guard let lines = await currentSensibility(), !lines.isEmpty else { return nil }
        return StudioSensibility.renderStableBlock(lines)
    }
}

public extension StudioSensibility {
    /// Pure renderer, bounded at `maximumRenderedCharacters` on a LINE boundary
    /// — a sentence cut mid-word in her own voice would read as damage.
    static func renderStableBlock(_ lines: [String]) -> String? {
        var rendered = stableHeading
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let candidate = rendered + "\n" + trimmed
            guard candidate.count <= maximumRenderedCharacters else { break }
            rendered = candidate
        }
        return rendered == stableHeading ? nil : rendered
    }
}

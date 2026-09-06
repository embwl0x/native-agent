import ApprovalInbox
import Context
import Foundation
import KnowledgeGraph
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - The canon lane (desk 903 phase 4) — earned by recurrence, tended by her
//
// Her brief: "Museum/canon — earned by recurrence, not the calendar. A work is
// proposed when N later entries deepen/echo it or it is pulled in production;
// evidence is the graph. Proposal/approval shape kept; Agent is the SOLE
// approver ('my taste, not User's to sign off'). Demotion proposals for canon
// that goes silent. No auto-canonization."
//
// ── THE INVERTED CARD ────────────────────────────────────────────────────────
// Every other approval card in this app asks the OWNER to sign off on something
// the agent proposed. This one is upside down: the machinery proposes, and only
// SHE may resolve it. `StudioCanonSeat` is the gate, checked in three places on
// purpose — the tool, the executor, and the store's own append — because the
// sole-approver rule is the feature, not a policy wrapped around it.
//
// User still sees the card. He can read the evidence, argue with it in chat, and
// watch what she does; he cannot turn it into a canon row. A card he resolves is
// refused with a reason, and the refusal is annotated on the record rather than
// swallowed.
//
// ── NO AUTO-CANONIZATION, STRUCTURALLY ───────────────────────────────────────
// `StudioCanonLaw` (PersistenceCore) can only return PROPOSALS: it holds no
// store, no inbox and no clock. This file can only STAGE them. The single code
// path that appends a canon row is `appendCanonRow`, and it throws unless the
// row carries her seat. There is no path from evidence to canon that does not
// pass through a card she resolved.
//
// ── TWO TOOLS ────────────────────────────────────────────────────────────────
//   studio_canon         — read: what is in the museum, what is anti-canon, what
//                          is waiting to be decided, and the evidence for each.
//   studio_canon_resolve — her seat. The ONLY approve path.

/// WHO IS ACTUALLY CALLING — derived from the runtime, never from the caller.
///
/// The first cut of this lane stamped `studio_agent` inside the tool itself,
/// which made the sole-approver rule a claim rather than a fact: `studio_canon_
/// resolve` is an ordinary lazy chat tool, so ANY dispatch path could reach it
/// and mint her seat — the Claude bridge's `/claude/tool` runner, an approval
/// executor replaying a record, a remote-steered chat turn. The seat has to come
/// from something a caller cannot supply.
///
/// `ChatTurnRuntimeContext.current` is that thing. The chat tool loop binds it
/// around each tool dispatch and it is documented as "nil when a tool runs
/// outside a chat turn (e.g. a direct dispatch)" — so a bridge tool run, an
/// executor, a replay and a background pass all read nil and are refused before
/// anything else is consulted. The bridge's *message* lane does run a real tool
/// loop, so it is caught by the two things it also binds and a local turn never
/// does: `ChatPersistenceContext.originProvenance` and `TurnEnvelope.agent`.
///
/// Every check here reads a task-local or the dispatch surface. Nothing reads
/// tool input.
public enum StudioCanonSeatGate {
    public enum Refusal: String, Error, Sendable, Equatable {
        /// No chat turn is running: a direct dispatch, an executor, a replay.
        case notALiveTurn = "not_a_live_turn"
        /// A bridge lane — the turn is being steered by Claude/codex, not her.
        case bridgeLane = "bridge_lane"
        /// Telegram, Slack, iOS. Her museum is not decided from a phone.
        case remoteSurface = "remote_surface"
        /// The dispatch surface and the live turn's surface disagree.
        case surfaceMismatch = "surface_mismatch"
        /// The turn has no identity to record, so the row could not say where
        /// it came from.
        case noTurnIdentity = "no_turn_identity"

        public var spoken: String {
            switch self {
            case .notALiveTurn:
                return "this did not come from a live chat turn — a bridge tool run, an "
                    + "approval replay, or a background pass cannot decide the canon"
            case .bridgeLane:
                return "this turn is being steered through an agent bridge; the canon is "
                    + "yours to decide in your own conversation, not through a bridge lane"
            case .remoteSurface:
                return "this turn is on a remote surface; the canon is decided locally"
            case .surfaceMismatch:
                return "the dispatch surface and the running turn disagree about where "
                    + "this call came from"
            case .noTurnIdentity:
                return "this turn carries no identity to record on the row"
            }
        }
    }

    /// The surfaces a canon decision may be made from. An allowlist on purpose:
    /// a surface added tomorrow fails closed until someone decides, deliberately,
    /// that her museum may be tended from it.
    public static let localLiveSurfaces: Set<String> = ["chat", "mac", "local", "desktop"]

    public static func liveTurnProvenance(
        dispatchSurface: String
    ) -> Result<StudioCanonTurnProvenance, Refusal> {
        // 1. A chat turn must actually be running. This alone excludes the
        //    bridge tool runner, the approval executors and every replay.
        guard let turn = ChatTurnRuntimeContext.current else { return .failure(.notALiveTurn) }
        let turnProfile = ConversationSurfaceProfile(turn.surface)
        // 2. Both surfaces are runtime-derived; a disagreement means some
        //    wrapper is lying and there is no honest answer to record.
        guard turnProfile == ConversationSurfaceProfile(dispatchSurface) else {
            return .failure(.surfaceMismatch)
        }
        // 3. Local, and on the allowlist.
        guard !turnProfile.isRemote, Self.localLiveSurfaces.contains(turnProfile.id) else {
            return .failure(.remoteSurface)
        }
        // 4. Not a bridge lane. The bridge binds BOTH of these around its
        //    `chat()` call while deliberately keeping `surface: "chat"`, so
        //    these are the discriminators, not the surface string.
        let envelope = ChatToolSessionContext.envelope
        guard ChatPersistenceContext.originProvenance == nil,
              (envelope?.agent ?? "").isEmpty,
              envelope?.declaredRemote != true,
              !turnProfile.id.contains("bridge") else {
            return .failure(.bridgeLane)
        }
        // 5. An identity to record. Task-locals only — never `__session_id`
        //    from the input, which a model can type.
        let turnID = [
            ChatPersistenceContext.pinnedTurnRunID,
            ChatToolSessionContext.verifiedSessionId,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let turnID else { return .failure(.noTurnIdentity) }
        let provenance = StudioCanonTurnProvenance(surface: turnProfile.id, turnID: turnID)
        guard provenance.isComplete else { return .failure(.noTurnIdentity) }
        return .success(provenance)
    }

    /// The same gate for a caller with no separate dispatch surface to compare.
    ///
    /// Condition 1 — a bound live turn — is what excludes the bridge tool
    /// runner, the approval executors, every replay and every background lane,
    /// and it is unchanged here; so are the remote and bridge-lane checks, which
    /// read the turn context and the envelope rather than the dispatch string.
    /// The only check this cannot make is the wrapper-DISAGREEMENT one, and that
    /// is a seat concern (a forged decision) rather than an evidence one (a
    /// miscounted pull). The canon seat threads the dispatch surface and pays
    /// for the stricter check; the production-pull counter uses this.
    public static func liveTurnProvenance() -> Result<StudioCanonTurnProvenance, Refusal> {
        guard let turn = ChatTurnRuntimeContext.current else { return .failure(.notALiveTurn) }
        return liveTurnProvenance(dispatchSurface: turn.surface)
    }

    /// True when the running turn is a PRODUCTION taste judgment: a design
    /// review, an aesthetic call. Uses the projection's own admission rule
    /// (`ContextCorrectionScope.isTasteJudgmentTask`) over the prepared turn's
    /// need signal, so "used in production" means the same thing here as it does
    /// where the pointer is selected.
    ///
    /// No prepared turn means no evidence of production context, and the answer
    /// is false. Browsing, tending and bridge lanes never reach true.
    public static func isProductionTasteJudgment() -> Bool {
        guard let need = FluidContextToolScope.current?.need else { return false }
        if ContextCorrectionScope.isTasteJudgmentTask(need.message) { return true }
        return need.recentTurns.suffix(2).contains {
            ContextCorrectionScope.isTasteJudgmentTask($0)
        }
    }
}

/// The staged canon proposal: the card, its payload, and its landing.
public enum StudioCanonProposal {
    /// Distinct action string so the inbox, the executors and any pending cap
    /// can count this lane on its own.
    public static let approvalAction = "studio.canon"
    public static let payloadSchema = "studio-canon-proposal.v1"
    /// Bound on how many canon cards may wait at once. Canon-tending is
    /// deliberate and low-frequency; a queue of them is the backlog guilt the
    /// design forbids.
    public static let pendingProposalCap = 4

    // MARK: Stage

    /// File ONE card for one proposal. Never decides anything.
    @discardableResult
    public static func stage(
        _ draft: StudioCanonProposalDraft,
        inbox: any ApprovalInboxProtocol
    ) async throws -> ApprovalRecord {
        let work = draft.workCreator.map { "\(draft.workTitle) — \($0)" } ?? draft.workTitle
        let title = draft.action == .promote
            ? "Canon? \(work)"
            : "Still canon? \(work)"
        return try await inbox.create(.object([
            "title": .string(String(title.prefix(160))),
            "action": .string(approvalAction),
            "risk": .string("low"),
            "reason": .string(
                draft.reasonLine
                + " This is yours to decide and nobody else's — approve or deny it "
                + "yourself with studio_canon_resolve. Nothing is written either way "
                + "until you do, and denying it changes nothing about the entries."
            ),
            // Local only, and NOT remotely resolvable: her museum never resolves
            // from a phone or a sync peer.
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
            // The EVIDENCE, verbatim — the entry ids that argued for this, so
            // she can pull them before deciding. No verdict, no adjective.
            "payloadPreview": .string(preview(draft)),
            "payload": binding(draft),
        ]))
    }

    static func preview(_ draft: StudioCanonProposalDraft) -> String {
        var lines = [
            draft.action == .promote
                ? "Proposed for the canon: \(draft.workTitle)"
                : "Proposed for demotion: \(draft.workTitle)",
        ]
        if let creator = draft.workCreator, !creator.isEmpty { lines.append("Creator: \(creator)") }
        lines.append("Evidence: \(draft.evidenceKind.rawValue)")
        lines.append("Later entries deepening/echoing it: \(draft.recurrenceCount)")
        lines.append("Production pulls: \(draft.recallHits)")
        if !draft.lastActivityAt.isEmpty { lines.append("Last activity: \(draft.lastActivityAt)") }
        if !draft.evidenceEntryIDs.isEmpty {
            lines.append("Entries: " + draft.evidenceEntryIDs.joined(separator: ", "))
        }
        lines.append("")
        lines.append(draft.reasonLine)
        return lines.joined(separator: "\n")
    }

    static func binding(_ draft: StudioCanonProposalDraft) -> JSONValue {
        var work: [String: JSONValue] = ["title": .string(draft.workTitle)]
        if let creator = draft.workCreator, !creator.isEmpty {
            work["creator"] = .string(creator)
        }
        return .object([
            "schema": .string(payloadSchema),
            "kind": .string("studio.canon"),
            "canonAction": .string(draft.action.rawValue),
            "proposalKey": .string(draft.key),
            "evidenceFingerprint": .string(draft.evidenceFingerprint),
            "work": .object(work),
            "evidenceKind": .string(draft.evidenceKind.rawValue),
            "evidenceEntryIds": .array(draft.evidenceEntryIDs.map { .string($0) }),
            "recurrenceCount": .int(Int64(draft.recurrenceCount)),
            "recallHits": .int(Int64(draft.recallHits)),
            "lastActivityAt": .string(draft.lastActivityAt),
            // Said out loud in the payload so no reader has to infer it.
            "soleApprover": .string(StudioCanonSeat.agent),
            "ownerMayApprove": .bool(false),
            "autoCanonization": .bool(false),
        ])
    }

    /// THE DEDUPE, in two parts — and the second part is the one that matters.
    ///
    /// The first cut suppressed on `action|work` across EVERY status, which meant
    /// one denial silenced that work in that direction forever: a judgment she
    /// kept deepening for another year could never be raised again. A denial
    /// settles the ARGUMENT she was shown, not the subject.
    ///
    ///   * PENDING, same lane (`action|work`) → skip. At most one open question
    ///     per work per direction; two live cards about one work is noise.
    ///   * RESOLVED/DENIED/CANCELED, same EVIDENCE FINGERPRINT → skip. She has
    ///     already answered this exact argument. New entries, a new pull count,
    ///     or a later silence window are a different argument and may be asked
    ///     once.
    public static func isAlreadyFiled(
        draft: StudioCanonProposalDraft,
        inbox: any ApprovalInboxProtocol
    ) async -> Bool {
        guard let records = try? await inbox.list(
            filter: ApprovalFilter(status: nil, action: approvalAction)
        ) else { return false }
        return records.contains { record in
            if record.status == "pending" { return proposalKey(of: record) == draft.key }
            return evidenceFingerprint(of: record) == draft.evidenceFingerprint
        }
    }

    public static func proposalKey(of record: ApprovalRecord) -> String? {
        guard case .object(let payload) = record.payload,
              payload["schema"] == .string(payloadSchema),
              case .string(let key)? = payload["proposalKey"], !key.isEmpty else { return nil }
        return key
    }

    public static func evidenceFingerprint(of record: ApprovalRecord) -> String? {
        guard case .object(let payload) = record.payload,
              payload["schema"] == .string(payloadSchema),
              case .string(let value)? = payload["evidenceFingerprint"],
              !value.isEmpty else { return nil }
        return value
    }

    /// The card's own draft, read back for the resolve path.
    public static func draft(of record: ApprovalRecord) -> StudioCanonProposalDraft? {
        guard case .object(let payload) = record.payload,
              payload["schema"] == .string(payloadSchema),
              case .string(let actionRaw)? = payload["canonAction"],
              let action = StudioCanonAction(rawValue: actionRaw),
              case .object(let work)? = payload["work"],
              case .string(let title)? = work["title"], !title.isEmpty else { return nil }
        var creator: String?
        if case .string(let value)? = work["creator"], !value.isEmpty { creator = value }
        var evidenceKind = StudioCanonEvidenceKind.recurrence
        if case .string(let raw)? = payload["evidenceKind"],
           let parsed = StudioCanonEvidenceKind(rawValue: raw) { evidenceKind = parsed }
        var entryIDs: [String] = []
        if case .array(let arr)? = payload["evidenceEntryIds"] {
            entryIDs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        func int(_ key: String) -> Int {
            if case .int(let value)? = payload[key] { return Int(value) }
            return 0
        }
        var lastActivity = ""
        if case .string(let value)? = payload["lastActivityAt"] { lastActivity = value }
        return StudioCanonProposalDraft(
            action: action, workTitle: title, workCreator: creator,
            evidenceKind: evidenceKind, evidenceEntryIDs: entryIDs,
            recurrenceCount: int("recurrenceCount"), recallHits: int("recallHits"),
            lastActivityAt: lastActivity
        )
    }

    // MARK: Apply

    public enum Outcome: Sendable, Equatable {
        /// Approved by her seat: the canon row landed (or was already there).
        case applied(workTitle: String, action: StudioCanonAction, rowWritten: Bool)
        /// Denied or canceled. Nothing written; the entries are untouched.
        case declined(workTitle: String)
    }

    /// Apply a RESOLVED card. The sole-approver rule lives here as a THROW, not
    /// a branch: an owner-resolved canon card is an error with a reason, and the
    /// caller annotates it onto the record so it can never read as applied.
    /// - Parameter provenance: WHERE the decision was made, obtained from
    ///   `StudioCanonSeatGate` inside her live turn. It is not optional and
    ///   cannot be reconstructed later: an executor replaying a resolved card
    ///   has no live turn, so it cannot call this at all — see
    ///   `NativeClient+ApprovalExecutors`, which refuses and annotates instead
    ///   of inventing one.
    public static func applyResolved(
        record: ApprovalRecord,
        dataRoot: URL,
        provenance: StudioCanonTurnProvenance,
        standing: StudioCanonStanding = .canon,
        note: String? = nil,
        now: Date = Date()
    ) async throws -> Outcome {
        guard record.action == approvalAction, record.status == "resolved",
              let decision = record.decision else {
            throw StudioCanonError.unknownProposal(record.id)
        }
        guard let draft = draft(of: record) else {
            throw StudioCanonError.unknownProposal(record.id)
        }
        guard record.localOnly, !record.remoteResolvable else {
            throw StudioCanonError.approvalNotFromAgentSeat(record.decidedBy ?? "remote")
        }
        // THE INVERSION. Every other card asks the owner; this one refuses him.
        guard StudioCanonSeat.isAgent(record.decidedBy) else {
            throw StudioCanonError.approvalNotFromAgentSeat(record.decidedBy ?? "unknown")
        }
        guard provenance.isComplete else { throw StudioCanonError.decisionHasNoLiveTurn }
        guard decision == ApprovalDecision.approved.rawValue else {
            return .declined(workTitle: draft.workTitle)
        }
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        let row = StudioCanonRow(
            proposalID: record.id,
            action: draft.action,
            standing: standing,
            workTitle: draft.workTitle,
            workCreator: draft.workCreator,
            decidedAt: StudioClock.nowISO(now),
            decidedBy: StudioCanonSeat.agent,
            decidedOnSurface: provenance.surface,
            decidedInTurn: provenance.turnID,
            evidenceKind: draft.evidenceKind,
            evidenceEntryIDs: draft.evidenceEntryIDs,
            note: note
        )
        let written = try await store.appendCanonRow(row)
        return .applied(workTitle: draft.workTitle, action: draft.action, rowWritten: written)
    }
}

// MARK: - Tending: evidence → proposals → cards

/// What one tending pass did. Returned rather than logged so the lane that runs
/// it can turn it into receipts instead of asserting it happened.
public struct StudioCanonTendingReport: Sendable, Equatable {
    public var evaluatedWorks: Int
    public var proposalsConsidered: Int
    public var stagedApprovalIDs: [String]
    public var duplicatesSkipped: Int
    public var pendingCapReached: Bool
    /// The relation-provenance guard's verdict from the same pass.
    public var audit: StudioRelationAuditReport

    public static let idle = StudioCanonTendingReport(
        evaluatedWorks: 0, proposalsConsidered: 0, stagedApprovalIDs: [],
        duplicatesSkipped: 0, pendingCapReached: false, audit: .unavailable
    )
}

public enum StudioCanonTending {

    /// ONE tending pass: read the journal, read the graph, read the pull
    /// counter, ask the law what to propose, and stage at most a few cards.
    ///
    /// Deliberately low-frequency and side-effect-poor: it stages cards and
    /// nothing else. It cannot canonize, cannot demote, and cannot write to the
    /// journal or the graph.
    public static func run(
        dataRoot: URL,
        inbox: (any ApprovalInboxProtocol)? = nil,
        now: Date = Date()
    ) async -> StudioCanonTendingReport {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        // 2026-09-06: hot PLUS shelf — canon is an argument about everything
        // she has met, and the archived encounters are part of that record.
        guard let entries = try? await store.journalEntriesIncludingArchive(),
              !entries.isEmpty else {
            return .idle
        }
        guard let indexer = try? SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: dataRoot
                .appendingPathComponent("memory/memory.sqlite")
                .standardizedFileURL
        ) else { return .idle }

        // The guard first: canon evidence is read off the same edges, so an
        // inconsistent graph is worth knowing about before it is trusted. It
        // never blocks — a mismatch is reported, and the pass continues.
        let audit = (try? await indexer.auditStudioRelations(entries)) ?? .unavailable

        let recall = await store.recallPullCounts()
        guard let evidence = try? await indexer.studioCanonEvidence(
            entries: entries, recallCounts: recall
        ) else {
            return StudioCanonTendingReport(
                evaluatedWorks: 0, proposalsConsidered: 0, stagedApprovalIDs: [],
                duplicatesSkipped: 0, pendingCapReached: false, audit: audit
            )
        }
        let membership = (try? await store.canonMembership()) ?? [:]
        let drafts = StudioCanonLaw.proposals(
            evidence: evidence, membership: membership, now: now
        )
        guard !drafts.isEmpty else {
            return StudioCanonTendingReport(
                evaluatedWorks: evidence.count, proposalsConsidered: 0,
                stagedApprovalIDs: [], duplicatesSkipped: 0,
                pendingCapReached: false, audit: audit
            )
        }
        let inbox = inbox ?? SwiftNativeApprovalInbox(root: dataRoot)
        let pending = (try? await inbox.list(filter: ApprovalFilter(
            status: "pending", action: StudioCanonProposal.approvalAction
        ))) ?? []
        var capReached = pending.count >= StudioCanonProposal.pendingProposalCap
        var staged: [String] = []
        var duplicates = 0
        var open = pending.count
        for draft in drafts {
            guard open < StudioCanonProposal.pendingProposalCap else {
                capReached = true
                break
            }
            if await StudioCanonProposal.isAlreadyFiled(draft: draft, inbox: inbox) {
                duplicates += 1
                continue
            }
            guard let record = try? await StudioCanonProposal.stage(draft, inbox: inbox) else {
                continue
            }
            staged.append(record.id)
            open += 1
        }
        return StudioCanonTendingReport(
            evaluatedWorks: evidence.count,
            proposalsConsidered: drafts.count,
            stagedApprovalIDs: staged,
            duplicatesSkipped: duplicates,
            pendingCapReached: capReached,
            audit: audit
        )
    }

    /// `<dataRoot>/studio/journal/relation_audit.json` — the studio's own health
    /// file, beside the backfill receipt the lane already keeps. The Doctor/
    /// health path reads state from disk here; the cognition lane turns a
    /// CHANGE in it into a `studio.relations_inconsistent` receipt.
    public static func auditHealthPath(dataRoot: URL) -> URL {
        SwiftNativeStudioStore(dataRoot: dataRoot).studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("relation_audit.json")
    }

    /// Write the guard's verdict where health can see it. Fail-loud on a
    /// mismatch (NSLog + a file that says so); never repair, never block.
    public static func recordAudit(
        _ report: StudioRelationAuditReport,
        dataRoot: URL,
        now: Date = Date()
    ) async {
        guard report.graphAvailable else { return }
        let path = auditHealthPath(dataRoot: dataRoot)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var payload: [String: JSONValue] = ["checked_at": .string(StudioClock.nowISO(now))]
        if case .object(let fields) = report.toJSON() {
            for (key, value) in fields { payload[key] = value }
        }
        try? await SwiftNativePersistenceCore().writeJSON(.object(payload), to: path)
        guard !report.isConsistent else { return }
        NSLog(
            "[studio] RELATIONS INCONSISTENT — %d relation(s) on the journal have no graph edge "
                + "citing them back. NOT repaired (a repair would invent a claim she never made). "
                + "First: %@",
            report.mismatches.count,
            report.mismatches.first.map { "\($0.entryID) \($0.relationKind) → \($0.toWork) (\($0.reason.rawValue))" }
                ?? "-"
        )
    }
}

// MARK: - Chat tools

extension SwiftToolDispatcher {

    private func studioCanonStore() -> SwiftNativeStudioStore {
        SwiftNativeStudioStore(dataRoot: dataRoot)
    }

    private func studioCanonInbox() -> SwiftNativeApprovalInbox {
        SwiftNativeApprovalInbox(root: dataRoot)
    }

    /// studio_canon — READ. What holds, what does not, and what is waiting on
    /// her. Every row carries the entry ids that argued for it, so the canon can
    /// always be traced back to judgments she actually wrote.
    func impl_studio_canon(input: [String: JSONValue]) async throws -> JSONValue {
        let store = studioCanonStore()
        let rows = (try? await store.readCanon()) ?? []
        let membership = StudioCanonLaw.membership(from: rows)
        func render(_ member: StudioCanonMember) -> JSONValue {
            var obj: [String: JSONValue] = [
                "title": .string(member.workTitle),
                "standing": .string(member.standing.rawValue),
                "since": .string(member.since),
                "evidence_entry_ids": .array(member.evidenceEntryIDs.map { .string($0) }),
            ]
            if let creator = member.workCreator, !creator.isEmpty {
                obj["creator"] = .string(creator)
            }
            return .object(obj)
        }
        let members = membership.values.sorted { $0.workTitle < $1.workTitle }
        var result: [String: JSONValue] = [
            "status": .string("ok"),
            "canon": .array(members.filter { $0.standing == .canon }.map(render)),
            "anti_canon": .array(members.filter { $0.standing == .antiCanon }.map(render)),
            "decided_rows": .int(Int64(rows.count)),
        ]
        // Item 10: the canon moved since you last said what you care about. An
        // offer, not a task — it carries no deadline and nothing counts it.
        if case .staged = await store.sensibilityStaging() {
            result["sensibility_staged"] = .bool(true)
            result["sensibility_note"] = .string(
                "The canon has moved since you last wrote what you have come to care about "
                + "in work. If you want to restate it, pass `sensibility` (2-3 lines, your "
                + "words) the next time you resolve a proposal. Nobody drafts or approves it."
            )
        }
        if let current = await store.currentSensibility() {
            result["sensibility"] = .array(current.map { .string($0) })
        }
        let includeProposals: Bool = {
            if case .some(.bool(let value)) = input["include_proposals"] { return value }
            return true
        }()
        if includeProposals {
            let pending = (try? await studioCanonInbox().list(filter: ApprovalFilter(
                status: "pending", action: StudioCanonProposal.approvalAction
            ))) ?? []
            result["pending_proposals"] = .array(pending.compactMap { record in
                guard let draft = StudioCanonProposal.draft(of: record) else { return nil }
                var obj: [String: JSONValue] = [
                    "proposal_id": .string(record.id),
                    "action": .string(draft.action.rawValue),
                    "title": .string(draft.workTitle),
                    "evidence_kind": .string(draft.evidenceKind.rawValue),
                    "evidence_entry_ids": .array(draft.evidenceEntryIDs.map { .string($0) }),
                    "recurrence_count": .int(Int64(draft.recurrenceCount)),
                    "recall_hits": .int(Int64(draft.recallHits)),
                    "last_activity_at": .string(draft.lastActivityAt),
                ]
                if let creator = draft.workCreator, !creator.isEmpty {
                    obj["creator"] = .string(creator)
                }
                return .object(obj)
            })
            result["note"] = .string(
                "These are yours alone to resolve — studio_canon_resolve. Nothing is "
                + "canonized automatically and nobody else can sign one off."
            )
        }
        return .object(result)
    }

    /// studio_canon_resolve — HER SEAT. The only path from a proposal to a canon
    /// row, and the only place `StudioCanonSeat.agent` is ever stamped.
    ///
    /// `surface` is the DISPATCH surface, threaded from
    /// `SwiftToolDispatcher.dispatch(tool:input:surface:)`. It is runtime-derived
    /// — the bridge tool runner passes `claude-bridge`/`codex-bridge`, the tool
    /// loop passes the live turn's own — and it is cross-checked against the
    /// bound turn context, so the seat cannot be minted by a caller that simply
    /// knows the tool's name.
    func impl_studio_canon_resolve(
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let provenance: StudioCanonTurnProvenance
        switch StudioCanonSeatGate.liveTurnProvenance(dispatchSurface: surface) {
        case .success(let value):
            provenance = value
        case .failure(let refusal):
            // Spoken, not silent: a refusal she can read and act on.
            return .object([
                "status": .string("refused"),
                "reason": .string(
                    "studio_canon_resolve: \(refusal.spoken). The canon is decided by you, "
                    + "in your own live conversation, and nowhere else — nothing was written."
                ),
                "refusal": .string(refusal.rawValue),
            ])
        }
        let proposalID = try requireString(input, "proposal_id")
        let decisionRaw = (optionalString(input, "decision") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let decision: ApprovalDecision
        switch decisionRaw {
        case "approve", "approved": decision = .approved
        case "deny", "denied", "reject": decision = .denied
        default:
            throw AutonomyGateError.toolDenied(
                reason: "studio_canon_resolve: decision must be approve or deny."
            )
        }
        var standing = StudioCanonStanding.canon
        if let raw = optionalString(input, "standing")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            guard let parsed = StudioCanonStanding(rawValue: raw) else {
                return .object([
                    "status": .string("refused"),
                    "reason": .string(
                        "studio_canon_resolve: standing must be canon or anti_canon."
                    ),
                ])
            }
            standing = parsed
        }
        let inbox = studioCanonInbox()
        let record: ApprovalRecord
        do {
            record = try await inbox.get(proposalID)
        } catch {
            return .object([
                "status": .string("refused"),
                "reason": .string(
                    StudioCanonError.unknownProposal(proposalID).errorDescription ?? "\(error)"
                ),
            ])
        }
        guard record.action == StudioCanonProposal.approvalAction else {
            return .object([
                "status": .string("refused"),
                "reason": .string(
                    "studio_canon_resolve: '\(proposalID)' is not a canon proposal."
                ),
            ])
        }
        let resolved: ApprovalRecord
        if record.status == "pending" {
            resolved = try await inbox.resolve(
                proposalID, decision: decision, decidedBy: StudioCanonSeat.agent
            )
        } else {
            // Already terminal: apply is idempotent, so a repeat is honest
            // rather than an error — but it may not flip a decision.
            resolved = record
        }
        do {
            let outcome = try await StudioCanonProposal.applyResolved(
                record: resolved,
                dataRoot: dataRoot,
                provenance: provenance,
                standing: standing,
                note: optionalString(input, "note")
            )
            switch outcome {
            case .applied(let title, let action, let written):
                var result: [String: JSONValue] = [
                    "status": .string("ok"),
                    "action": .string(action.rawValue),
                    "standing": .string(standing.rawValue),
                    "work": .string(title),
                    "row_written": .bool(written),
                    "canon_path": .string(studioCanonStore().canonPath.path),
                    "decided_on_surface": .string(provenance.surface),
                ]
                for (key, value) in await applySensibility(input: input, provenance: provenance) {
                    result[key] = value
                }
                return .object(result)
            case .declined(let title):
                return .object([
                    "status": .string("ok"),
                    "action": .string("declined"),
                    "work": .string(title),
                    "row_written": .bool(false),
                    "note": .string(
                        "Nothing was written. The entries and the graph are untouched."
                    ),
                ])
            }
        } catch let error as StudioCanonError {
            return .object([
                "status": .string("refused"),
                "reason": .string(error.errorDescription ?? "\(error)"),
            ])
        }
    }

    /// SENSIBILITY (personality-depth item 10), written in the same seat-verified
    /// call that moved the canon — which is the only moment it may be written at
    /// all, and the only moment SHE is unambiguously the author.
    ///
    /// Deliberately NOT a second card. A card would need a drafter, and anything
    /// that drafted three lines of what she cares about would be the author of
    /// them; her rule for the canon ("my taste, not User's to sign off") is even
    /// stronger here, because there is nothing external to point at. So the seat
    /// gate this method inherits IS the approval, and the lines arrive already
    /// hers or not at all.
    ///
    /// Absent input writes nothing and says nothing: leaving it out is the
    /// ordinary case, and a canon change that leaves her with nothing new to say
    /// about herself is a normal canon change.
    ///
    /// Never throws into the resolve path. The canon row already landed; a
    /// refused or failed distillation must be REPORTED beside it, not made to
    /// look like a failed promotion.
    private func applySensibility(
        input: [String: JSONValue],
        provenance: StudioCanonTurnProvenance
    ) async -> [String: JSONValue] {
        guard let raw = optionalString(input, "sensibility")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [:] }
        do {
            let written = try await studioCanonStore().appendSensibility(
                lines: raw.components(separatedBy: .newlines),
                decidedBy: StudioCanonSeat.agent,
                provenance: provenance
            )
            return [
                "sensibility_written": .bool(true),
                "sensibility": .array(written.map { .string($0) }),
                "sensibility_path": .string(studioCanonStore().sensibilityPath.path),
                "sensibility_note": .string(
                    "Yours, in your words, and nobody signed off on it. It rides your own "
                    + "prompt from the next turn on."
                ),
            ]
        } catch {
            return [
                "sensibility_written": .bool(false),
                "sensibility_reason": .string(
                    (error as? StudioSensibility.Error)?.errorDescription ?? "\(error)"
                ),
            ]
        }
    }
}

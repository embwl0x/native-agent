import ApprovalInbox
import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `StudioCanonProposal.swift` | `StudioCanonProposal`: compatible approval payloads, pending cap, action/work and evidence-fingerprint dedupe; resolved cards append idempotently only with their seat and live-turn provenance |

/// The staged canon proposal: the card, its payload, and its landing.
public enum StudioCanonProposal {
    /// Distinct inbox action for canon execution and pending-card counts.
    public static let approvalAction = "studio.canon"
    public static let payloadSchema = "studio-canon-proposal.v1"
    /// Bound on canon cards waiting for her decision.
    public static let pendingProposalCap = 4

    /// File ONE card for one proposal. Never decides anything.
    @discardableResult
    public static func stage(
        _ draft: StudioCanonProposalDraft,
        inbox: SwiftNativeApprovalInbox
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
            // Canon cards cannot be resolved by a phone or sync peer.
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
            // Verbatim evidence lets her inspect the cited entries before deciding.
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
            "soleApprover": .string(StudioCanonSeat.agent),
            "ownerMayApprove": .bool(false),
            "autoCanonization": .bool(false),
        ])
    }

    /// Pending cards dedupe by action/work; settled cards dedupe by evidence fingerprint, allowing new evidence.
    public static func isAlreadyFiled(
        draft: StudioCanonProposalDraft,
        records: [ApprovalRecord]
    ) -> Bool {
        records.contains { record in
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
            lastActivityAt: lastActivity, reasonLine: record.reason
        )
    }

    public enum Outcome: Sendable, Equatable {
        /// Approved by her seat: the canon row landed (or was already there).
        case applied(workTitle: String, action: StudioCanonAction, rowWritten: Bool)
        /// Denied or canceled. Nothing written; the entries are untouched.
        case declined(workTitle: String)
    }

    /// Apply a resolved card only from her seat; owner decisions throw for annotation.
    /// Provenance comes from `StudioCanonSeatGate` in her live turn and cannot be
    /// reconstructed by an executor replay; `ApprovalExecution` refuses and annotates.
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
        // Only her agent seat may decide canon membership.
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
            decidedAt: NativeTimestampFormat.sixDigitUTCOffset(now),
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

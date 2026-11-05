import ApprovalInbox
import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `StudioCanonProposal.swift` | `StudioCanonProposal`: Stage independently; only a trusted live seat decides canon. |

public enum StudioCanonProposal {
    /// Use a distinct action so pending canon cards and their executor agree.
    public static let approvalAction = "studio.canon"
    public static let payloadSchema = "studio-canon-proposal.v1"
    public static let pendingProposalCap = 4

    /// One proposal gets one card; staging cannot decide canon membership.
    @discardableResult
    public static func stage(
        turn: Turn?, handsBack: Bool,
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
            // Verbatim evidence lets the agent inspect the cited entries before deciding.
            "payloadPreview": .string(preview(draft)),
            "payload": binding(draft),
        ]), turn: turn, handsBack: handsBack)
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

    /// Pending cards dedupe by action/work; settled cards dedupe by evidence fingerprint, allowing new evidence. A damaged card blocks only its own work;
    /// unrelated or unidentifiable cards leave named gaps.
    public static func isAlreadyFiled(
        draft: StudioCanonProposalDraft,
        records: [ApprovalRecord],
        gaps: inout [String]
    ) throws -> Bool {
        let workKey = StudioCanonLaw.workKey(title: draft.workTitle, creator: draft.workCreator)
        var alreadyFiled = false
        func noteGap(_ error: any Error) {
            let gap = error.localizedDescription
            if !gaps.contains(gap) { gaps.append(gap) }
        }
        for record in records {
            let work: (title: String, creator: String?)
            do { work = try savedWork(of: record) }
            catch { noteGap(error); continue }
            let sameWork = StudioCanonLaw.workKey(title: work.title, creator: work.creator) == workKey
            do {
                let saved = try self.draft(of: record)
                guard sameWork else { continue }
                if record.status == "pending" {
                    if saved.key == draft.key { alreadyFiled = true }
                } else if evidenceFingerprint(of: record) == draft.evidenceFingerprint {
                    alreadyFiled = true
                }
            } catch {
                if sameWork { throw error }
                noteGap(error)
            }
        }
        return alreadyFiled
    }

    private static func invalid(_ field: String, record: ApprovalRecord) -> ToolFailureError {
        ToolFailureError("Canon proposal \(record.id): saved payload field \(field) is missing or malformed. The card was preserved for reconciliation.",
            effects: .none, owner: "Studio canon proposal \(record.id)",
            code: "studio_canon_payload_unavailable", status: .failed,
            instruction: """
                Inspect the existing approval's original payload and cited entries; repair only from that evidence before resolving. Do not invent \
                missing evidence or stage a replacement decision.
                """, recovery: .repair)
    }

    private static func savedWork(of record: ApprovalRecord) throws -> (title: String, creator: String?) {
        guard case .object(let payload) = record.payload,
              case .object(let work)? = payload["work"],
              case .string(let title)? = work["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("work.title", record: record)
        }
        var creator: String?
        if let value = work["creator"] {
            guard case .string(let text) = value, !text.isEmpty else { throw invalid("work.creator", record: record) }
            creator = text
        }
        return (title, creator)
    }

    public static func evidenceFingerprint(of record: ApprovalRecord) -> String? {
        guard case .object(let payload) = record.payload,
              payload["schema"] == .string(payloadSchema),
              case .string(let value)? = payload["evidenceFingerprint"],
              !value.isEmpty else { return nil }
        return value
    }

    public static func draft(of record: ApprovalRecord) throws -> StudioCanonProposalDraft {
        func invalid(_ field: String) -> ToolFailureError {
            Self.invalid(field, record: record)
        }
        guard case .object(let payload) = record.payload,
              record.action == approvalAction,
              payload["schema"] == .string(payloadSchema), payload["kind"] == .string(approvalAction),
              payload["soleApprover"] == .string(StudioCanonSeat.agent),
              payload["ownerMayApprove"] == .bool(false), payload["autoCanonization"] == .bool(false) else {
            throw invalid("schema/kind/authority")
        }
        func string(_ key: String, emptyAllowed: Bool = false) throws -> String {
            guard case .string(let text)? = payload[key], emptyAllowed || !text.isEmpty else { throw invalid(key) }
            return text
        }
        guard let action = StudioCanonAction(rawValue: try string("canonAction")),
              let evidenceKind = StudioCanonEvidenceKind(rawValue: try string("evidenceKind")) else { throw invalid("canonAction/evidenceKind") }
        let work = try savedWork(of: record)
        guard case .array(let values)? = payload["evidenceEntryIds"],
            values.count <= StudioCanonRow.maximumEvidenceEntryIDs else { throw invalid("evidenceEntryIds") }
        let entryIDs: [String] = try values.map {
            guard case .string(let id) = $0, !id.isEmpty else { throw invalid("evidenceEntryIds[]") }
            return id
        }
        func int(_ key: String) throws -> Int {
            guard case .int(let value)? = payload[key], value >= 0, let count = Int(exactly: value) else { throw invalid(key) }
            return count
        }
        let draft = try StudioCanonProposalDraft(
            action: action, workTitle: work.title, workCreator: work.creator,
            evidenceKind: evidenceKind, evidenceEntryIDs: entryIDs,
            recurrenceCount: int("recurrenceCount"), recallHits: int("recallHits"),
            lastActivityAt: string("lastActivityAt", emptyAllowed: true), reasonLine: record.reason
        )
        guard try string("proposalKey") == draft.key else { throw invalid("proposalKey") }
        _ = try string("evidenceFingerprint")
        return draft
    }

    public enum Outcome: Sendable, Equatable {
        /// Approval records a landed or already-present canon row.
        case applied(workTitle: String, action: StudioCanonAction, rowWritten: Bool)
        /// Denial and cancellation leave entries untouched.
        case declined(workTitle: String)
    }

    /// Apply a resolved card only from the agent's seat; owner decisions throw for annotation. Provenance comes from `StudioCanonSeatGate` in the agent's live
    /// turn and cannot be reconstructed by an executor replay; `ApprovalExecution` refuses and annotates.
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
        let draft = try draft(of: record)
        guard record.localOnly, !record.remoteResolvable else {
            throw StudioCanonError.approvalNotFromAgentSeat(record.decidedBy ?? "remote")
        }
        // Only the agent's seat may decide canon membership.
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

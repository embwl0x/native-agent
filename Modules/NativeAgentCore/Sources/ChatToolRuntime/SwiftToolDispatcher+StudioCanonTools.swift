import ApprovalInbox
import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `SwiftToolDispatcher+StudioCanonTools.swift` | `SwiftToolDispatcher`: `impl_studio_canon`, `impl_studio_canon_resolve`; canon membership and proposal reads, agent-only live-turn resolution and idempotent action results |

extension SwiftToolDispatcher {
    private func studioCanonStore() -> SwiftNativeStudioStore {
        SwiftNativeStudioStore(dataRoot: dataRoot)
    }

    private func studioCanonInbox() -> SwiftNativeApprovalInbox {
        SwiftNativeApprovalInbox(root: dataRoot)
    }

    /// Read membership and pending proposals with the journal entry ids supporting them.
    func impl_studio_canon(input: [String: JSONValue]) async throws -> JSONValue {
        let store = studioCanonStore()
        let rows: [StudioCanonRow]
        do {
            rows = try await store.readCanon()
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string("The canon could not be read. Its file has been left unchanged."),
            ])
        }
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
        let includeProposals: Bool = {
            if case .some(.bool(let value)) = input["include_proposals"] { return value }
            return true
        }()
        if includeProposals {
            let pending: [ApprovalRecord]
            do {
                pending = try await studioCanonInbox().list(filter: ApprovalFilter(
                    status: "pending", action: StudioCanonProposal.approvalAction
                ))
            } catch {
                result["status"] = .string("failed")
                result["reason"] = .string("Pending canon proposals could not be read: \(error.localizedDescription)")
                return .object(result)
            }
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

    /// Resolve only in her live turn, cross-checking the runtime dispatch surface.
    /// This is the sole proposal-to-row path that stamps `StudioCanonSeat.agent`.
    func impl_studio_canon_resolve(
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let provenance: StudioCanonTurnProvenance
        switch StudioCanonSeatGate.liveTurnProvenance(dispatchSurface: surface) {
        case .success(let value):
            provenance = value
        case .failure(let refusal):
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
            // Repeating an idempotent apply cannot flip a terminal decision.
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
                if !written {
                    guard let persisted = try await studioCanonStore().readCanon().first(where: { $0.proposalID == proposalID }) else {
                        throw StudioCanonError.unknownProposal(proposalID)
                    }
                    standing = persisted.standing
                }
                return .object([
                    "status": .string("ok"),
                    "action": .string(action.rawValue),
                    "standing": .string(standing.rawValue),
                    "work": .string(title),
                    "row_written": .bool(written),
                    "canon_path": .string(studioCanonStore().canonPath.path),
                    "decided_on_surface": .string(provenance.surface),
                ])
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
}

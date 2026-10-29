// SwiftToolDispatcher+ProposalReview.swift
// Her review seat over memory proposals.
//
// A fact from the owner, a trusted agent or her own words is kept at once
// (MemoryV2+AdaptivePromoter). What an untrusted peer said, and what
// consolidation proposes, waits here: `memory_proposals_pending` lists every
// proposal the Memories page offers (the same awaitsReview rule), and
// `memory_proposal_review` decides one with the page's own accept/reject;
// `status: rejected` is the page's "things I let go" history. A kept fact is
// reworded afterwards with the app door's memory.rewrite.
//
import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
// Blueprint: | `SwiftToolDispatcher+ProposalReview.swift` | `SwiftToolDispatcher`: `impl_memory_proposals_pending`, `impl_memory_proposal_review` |

extension SwiftToolDispatcher {

    /// Most proposals listed in one pull. Bounded because the point is a
    /// review she can actually finish, not an inbox.
    static let maxPendingProposalsListed = 10

    private static func awaitsReview(_ proposal: ProposalRecord) -> Bool {
        SwiftNativeMemoryV2.awaitsReview(content: proposal.content, source: proposal.source, metadata: proposal.metadata)
    }

    private static func permitsProposalDisclosure(_ proposal: ProposalRecord, surface: String, persona: String?) -> Bool {
        MemoryRecordDisclosurePolicy.classify(
            personaID: proposal.personaId, status: "active", lifecycle: nil,
            tags: nil, metadata: proposal.metadata
        )?.permits(surface: surface, personaID: persona) == true
    }

    func impl_memory_proposals_pending(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let status = (optionalString(input, "status") ?? "pending").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "pending" || status == "rejected" else {
            return .object(["status": .string("refused"), "reason": .string("status must be \"pending\" or \"rejected\".")])
        }
        let limit = min(50, max(1, Self.jsonInt(input["limit"]) ?? Self.maxPendingProposalsListed))
        let listed: [ProposalRecord]
        do {
            listed = try await memoryV2.listProposals(status: status)
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("\(error)"),
            ])
        }
        let all = listed.filter {
            Self.permitsProposalDisclosure($0, surface: surface, persona: nil)
                && (status == "rejected" || Self.awaitsReview($0))
        }
        let rows: [JSONValue] = all
            .sorted { ($0.resolvedAt ?? $0.createdAt) > ($1.resolvedAt ?? $1.createdAt) }
            .prefix(limit)
            .map { proposal in
                var row: [String: JSONValue] = [
                    "id": .string(proposal.id),
                    "staged_at": .string(proposal.createdAt),
                    "content": .string(proposal.content),
                ]
                if let kind = proposal.metadata?.objectValue?["kind"]?.stringValue { row["kind"] = .string(kind) }
                if status == "rejected" {
                    if let at = proposal.resolvedAt { row["rejected_at"] = .string(at) }
                    if let why = proposal.rejectionReason { row["reason"] = .string(why) }
                }
                return .object(row)
            }
        let recovery = await MemoryRecoveryReadout.afterTurnRecovery(dataRoot: dataRoot)
        return .object([
            "status": .string("ok"),
            "proposals": .array(rows),
            "count": .int(Int64(rows.count)),
            status == "rejected" ? "total_rejected" : "total_pending": .int(Int64(all.count)),
            "after_turn_memory": .object([
                "status": .string(recovery.status),
                "owed_count": recovery.owedCount.map { .int(Int64($0)) } ?? .null,
                "detail": .array(recovery.lines.map(JSONValue.string)),
            ]),
        ])
    }

    func impl_memory_proposal_review(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Bad input is REFUSED, not thrown. A strict provider schema routinely
        // materializes an omitted optional as "" or null, and a thrown
        // toolDenied reads to the model as a policy block rather than "you left
        // the id out" — so both malformed shapes come back as a refusal
        // envelope that says exactly what to send instead.
        let id = (optionalString(input, "id") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return .object([
                "status": .string("refused"),
                "reason": .string("memory_proposal_review needs the proposal 'id' from memory_proposals_pending."),
            ])
        }
        let decision = (optionalString(input, "decision") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard decision == "accept" || decision == "reject" else {
            return .object([
                "status": .string("refused"),
                "reason": .string("memory_proposal_review 'decision' must be exactly \"accept\" or \"reject\"."),
            ])
        }
        let reason = optionalString(input, "reason")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Off the pending list: a proposal she can review is by definition
        // still pending and offered by the page's own rule.
        let pending: [ProposalRecord]
        do {
            pending = try await memoryV2.listProposals(status: "pending")
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
        guard let proposal = pending.first(where: { $0.id == id && Self.awaitsReview($0) }) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("No proposal with that id is waiting on review. Pull memory_proposals_pending for the current list."),
            ])
        }
        guard Self.permitsProposalDisclosure(proposal, surface: surface,
            persona: nil) else {
            return .object([
                "status": .string("refused"),
                "reason": .string("This proposal is not available on this surface; nothing changed."),
            ])
        }

        if decision == "reject" {
            do {
                _ = try await memoryV2.rejectProposal(id: id, reason: reason)
            } catch {
                return .object(["status": .string("failed"), "reason": .string("\(error)")])
            }
            return .object([
                "status": .string("ok"),
                "decision": .string("reject"),
                "id": .string(id),
            ])
        }

        // Accepts exactly as the Memories page's Keep does.
        do {
            let record = try await memoryV2.acceptProposal(id: id)
            return .object([
                "status": .string("ok"),
                "decision": .string("accept"),
                "id": .string(record.id),
                "content": .string(record.text),
            ])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
    }
}

// SwiftToolDispatcher+MomentTools.swift
// THE MOMENTS LANE · her review seat (2026-09-02)
//
// The post-turn promoter stages lived moments as proposals and stops there.
// NOTHING in the moments lane auto-accepts — a moment is a claim about what
// happened between two people, and the only one who can say whether it is true
// is the one who was there. These two tools are that seat, and they are hers:
// `memory_moments_pending` shows what is waiting, `memory_moment_review`
// decides one, in her words if the wording came out wrong.
//
// LAZY-LOADED, deliberately. Reviewing moments is something she does a handful
// of times a day, not every turn, so the pair costs zero prompt bytes until she
// pulls it — the same reach `studio_canon` has. The per-turn nudge line (see
// ChatOrchestration+TurnEngine) is the only thing that rides every turn, and it
// is one bounded line in the VOLATILE block, never the cached prefix.
//
// User, 2026-10-01: her memory reviews are hers. `lane: all` lists every
// proposal the Memories page offers (the same awaitsReview rule) and the review
// decides any of them with the page's own accept/reject; `status: rejected` is
// the page's "things I let go" history. Rewording stays moments-only: a fact
// proposal is kept as staged, then rewritten with the app door's memory.rewrite.

import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2

extension SwiftToolDispatcher {

    /// Most pending moments listed in one pull. Bounded because the point is a
    /// review she can actually finish, not an inbox.
    static let maxPendingMomentsListed = 10

    /// A pending proposal the Memories page offers for review: every moment,
    /// and any other lane's row that passes the page's awaitsReview rule.
    private static func awaitsReview(_ proposal: ProposalRecord) -> Bool {
        MemoryMoments.isMoment(proposal.metadata)
            || SwiftNativeMemoryV2.awaitsReview(content: proposal.content, source: proposal.source, metadata: proposal.metadata)
    }

    private static func permitsProposalDisclosure(_ proposal: ProposalRecord, surface: String, persona: String?) -> Bool {
        MemoryRecordDisclosurePolicy.classify(
            personaID: proposal.personaId, status: "active", lifecycle: nil,
            tags: nil, metadata: proposal.metadata
        )?.permits(surface: surface, personaID: persona) == true
    }

    func impl_memory_moments_pending(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let lane = (optionalString(input, "lane") ?? "moments").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let status = (optionalString(input, "status") ?? "pending").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lane == "moments" || lane == "all" else {
            return .object(["status": .string("refused"), "reason": .string("lane must be \"moments\" or \"all\".")])
        }
        guard status == "pending" || status == "rejected" else {
            return .object(["status": .string("refused"), "reason": .string("status must be \"pending\" or \"rejected\".")])
        }
        let limit = min(50, max(1, optionalInt(input, "limit") ?? Self.maxPendingMomentsListed))
        let listed: [ProposalRecord]
        do {
            listed = try await memoryV2.listProposals(status: status)
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("\(error)"),
            ])
        }
        let persona = memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID)
        let allMoments = listed.filter {
            Self.permitsProposalDisclosure($0, surface: surface,
                persona: persona) && (lane == "all"
                ? (status == "rejected" || Self.awaitsReview($0))
                : MemoryMoments.isMoment($0.metadata))
        }
        let moments = allMoments
            .sorted { ($0.resolvedAt ?? $0.createdAt) > ($1.resolvedAt ?? $1.createdAt) }
            .prefix(limit)
        let rows: [JSONValue] = moments.map { proposal in
            var row: [String: JSONValue] = [
                "id": .string(proposal.id),
                "staged_at": .string(proposal.createdAt),
                "content": .string(proposal.content),
            ]
            if let lane = MemoryMoments.laneName(proposal.metadata) { row["lane"] = .string(lane) }
            if let kind = MemoryMoments.metadataString(proposal.metadata, "kind") { row["kind"] = .string(kind) }
            if status == "rejected" {
                if let at = proposal.resolvedAt { row["rejected_at"] = .string(at) }
                if let why = proposal.rejectionReason { row["reason"] = .string(why) }
            }
            if let valence = MemoryMoments.metadataNumber(proposal.metadata, "valence") {
                row["valence"] = .double(valence)
            }
            if let salience = MemoryMoments.metadataNumber(proposal.metadata, "salience") {
                row["salience"] = .double(salience)
            }
            if let surface = MemoryMoments.metadataString(proposal.metadata, "surface") {
                row["surface"] = .string(surface)
            }
            if let author = MemoryMoments.metadataString(proposal.metadata, "author") {
                row["author"] = .string(author)
            }
            if let quote = MemoryMoments.metadataString(proposal.metadata, "quote") {
                row["quote"] = .string(quote)
            }
            return .object(row)
        }
        let totalPendingMoments = allMoments.count
        return .object([
            "status": .string("ok"),
            "moments": .array(rows),
            "count": .int(Int64(rows.count)),
            status == "rejected" ? "total_rejected" : "total_pending": .int(Int64(totalPendingMoments)),
        ])
    }

    func impl_memory_moment_review(input: [String: JSONValue], surface: String) async throws -> JSONValue {
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
                "reason": .string("memory_moment_review needs the moment 'id' from memory_moments_pending."),
            ])
        }
        let decision = (optionalString(input, "decision") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard decision == "accept" || decision == "reject" else {
            return .object([
                "status": .string("refused"),
                "reason": .string("memory_moment_review 'decision' must be exactly \"accept\" or \"reject\"."),
            ])
        }
        let reason = optionalString(input, "reason")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = optionalString(input, "content")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Lane check FIRST, and off the pending list: a moment she can review is
        // by definition still pending, and a fact proposal reached through this
        // door would bypass the fact queue's own review semantics.
        let pending: [ProposalRecord]
        do {
            pending = try await memoryV2.listProposals(status: "pending")
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
        guard let proposal = pending.first(where: { $0.id == id && Self.awaitsReview($0) }) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("No proposal with that id is waiting on review. Pull memory_moments_pending lane all for the current list."),
            ])
        }
        guard Self.permitsProposalDisclosure(proposal, surface: surface,
            persona: memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID)) else {
            return .object([
                "status": .string("refused"),
                "reason": .string("This proposal is not available on this surface; nothing changed."),
            ])
        }
        let isMoment = MemoryMoments.isMoment(proposal.metadata)

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

        // Another lane accepts exactly as the Memories page's Keep does.
        if !isMoment {
            if let edited, !edited.isEmpty {
                return .object([
                    "status": .string("refused"),
                    "reason": .string("content rewords moments only. Accept without content, then app memory.rewrite the id that comes back."),
                ])
            }
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

        // Accept the final wording once. A failed edit must never publish the
        // staged wording as a successful fallback.
        let finalContent = edited.flatMap { $0.isEmpty ? nil : $0 }
            .map { MemoryTextClip.sentenceClip($0, cap: MemoryMoments.contentCap) }
            ?? proposal.content
        let record: MemoryRecord
        do {
            record = try await memoryV2.acceptReviewedMoment(id: id, content: finalContent)
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
        return .object([
            "status": .string("ok"),
            "decision": .string("accept"),
            "id": .string(record.id),
            "content": .string(record.text),
            "edited": .bool(record.text != proposal.content),
            "edit_note": .null,
        ])
    }
}

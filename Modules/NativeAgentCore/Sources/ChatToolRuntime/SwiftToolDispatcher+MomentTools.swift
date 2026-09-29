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
// The review tools refuse any id whose lane is not "moment". These are not a
// second door onto the fact-proposal queue — that queue has its own review
// surface and its own approval semantics.

import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2

extension SwiftToolDispatcher {

    /// Most pending moments listed in one pull. Bounded because the point is a
    /// review she can actually finish, not an inbox.
    static let maxPendingMomentsListed = 10

    func impl_memory_moments_pending() async throws -> JSONValue {
        let pending: [ProposalRecord]
        do {
            pending = try await memoryV2.listProposals(status: "pending")
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("\(error)"),
            ])
        }
        let allMoments = pending.filter { MemoryMoments.isMoment($0.metadata) }
        let moments = allMoments
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.maxPendingMomentsListed)
        let rows: [JSONValue] = moments.map { proposal in
            var row: [String: JSONValue] = [
                "id": .string(proposal.id),
                "staged_at": .string(proposal.createdAt),
                "content": .string(proposal.content),
            ]
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
            "total_pending": .int(Int64(totalPendingMoments)),
        ])
    }

    func impl_memory_moment_review(input: [String: JSONValue]) async throws -> JSONValue {
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
        guard let proposal = pending.first(where: { $0.id == id }) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("No pending proposal with that id. Pull memory_moments_pending for the current list."),
            ])
        }
        guard MemoryMoments.isMoment(proposal.metadata) else {
            return .object([
                "status": .string("refused"),
                "reason": .string("That proposal is not in the moments lane (lane: \(MemoryMoments.laneName(proposal.metadata) ?? "none")). memory_moment_review only decides moments."),
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

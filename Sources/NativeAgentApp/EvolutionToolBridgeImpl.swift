import Foundation
import NativeAgentCore
import ChatOrchestration
import PersistenceCore
import SelfImprovement
import ApprovalInbox

// MARK: - EvolutionToolBridgeImpl (2026-06-11, U2b)
//
// App-side backend for the three privileged self-evolution chat tools. The
// dispatch cases + Full-Mac gate + autonomy `confirm` gate live in the core
// ChatOrchestration module (SwiftToolDispatcher); this struct is injected as
// the EvolutionToolBridge so those cases can reach the EvolutionProposalStore
// (SelfImprovement module) and the install-card stager
// (BackgroundLoopsAssembly) — neither of which ChatOrchestration may import.
//
// SAFETY: evolutionStageInstall NEVER installs. It validates a candidate_green
// proposal, then calls BackgroundLoopsAssembly.stageEvolutionApprovals
// (idempotent) which only STAGES a self_evolution.apply approval card a human
// still approves — it never calls SystemOps.systemRebuild or
// applyApprovedSelfEvolution.
struct EvolutionToolBridgeImpl: EvolutionToolBridge {
    let dataRoot: URL

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    private var store: EvolutionProposalStore { EvolutionProposalStore(dataRoot: dataRoot) }

    // In-flight = the active pipeline statuses (excludes terminal
    // verified/reverted/denied and the done-ish installed).
    private static let inFlightStatuses: Set<EvolutionProposalStatus> = [
        .needsDiff, .proposed, .building, .candidateGreen, .candidateFailed, .staged, .approved,
    ]

    // MARK: - evolution_propose

    // Input caps (gpt-5.5 SHOULD-FIX): bound attacker/LLM-controllable inputs so
    // a runaway call can't bloat proposals.json. Over-cap → honest refusal, not
    // silent truncation (a truncated diff would mis-apply downstream).
    private static let maxTitle = 300
    private static let maxEvidence = 8_000
    private static let maxDiffBytes = 1_000_000  // 1 MB unified diff ceiling

    func evolutionPropose(input: [String: JSONValue]) async throws -> JSONValue {
        guard let title = nonEmptyString(input["title"]) else {
            return failed(reason: "missing_title", fix: "Pass a non-empty 'title'.")
        }
        guard title.count <= Self.maxTitle else {
            return failed(reason: "title_too_long", fix: "Keep 'title' under \(Self.maxTitle) characters.")
        }
        guard let evidence = nonEmptyString(input["evidence"]) else {
            return failed(reason: "missing_evidence", fix: "Pass non-empty 'evidence' — why this change is warranted.")
        }
        guard evidence.count <= Self.maxEvidence else {
            return failed(reason: "evidence_too_long", fix: "Keep 'evidence' under \(Self.maxEvidence) characters.")
        }
        let diffText = nonEmptyString(input["diff_text"])
        if let diffText, diffText.utf8.count > Self.maxDiffBytes {
            return failed(reason: "diff_too_large", fix: "Diff exceeds \(Self.maxDiffBytes) bytes; split it into smaller proposals.")
        }
        let expectedHead = nonEmptyString(input["expected_head"])
        let proposal = try await store.propose(
            source: .chat,
            title: title,
            evidence: evidence,
            diffText: diffText,
            expectedHead: expectedHead
        )
        return .object([
            "status": .string("ok"),
            "id": .string(proposal.id),
            "proposal_status": .string(proposal.status.rawValue),
            "has_diff": .bool(proposal.diffText != nil),
            "note": .string(proposal.status == .needsDiff
                ? "Filed without a diff (needs_diff). Attach a diff before it can build."
                : "Filed as 'proposed' — eligible to build+test in an isolated worktree."),
        ])
    }

    // MARK: - evolution_status

    func evolutionStatus(input: [String: JSONValue]) async throws -> JSONValue {
        // Cap the caller-supplied id at extraction (gpt-5.5 review-3): it is
        // the only unbounded LLM-controllable field, and it is echoed back on
        // not-found. A legit evo_ id is ~30 chars; an over-long forged id is
        // truncated (and then can't match a real record).
        if let id = nonEmptyString(input["proposal_id"]).map({ Self.truncate($0, 128) }) {
            guard let proposal = try await store.get(id: id) else {
                return .object([
                    "status": .string("not_found"),
                    "id": .string(id),
                ])
            }
            return .object([
                "status": .string("ok"),
                "proposal": summary(proposal, includeReceipts: true),
            ])
        }
        let proposals = try await store.list(statuses: Self.inFlightStatuses)
        // gpt-5.5 review-2: bound the list output (most-recent 50) so a backlog
        // can't dump unbounded rows into the chat turn. count reports the true
        // total; `truncated` flags when rows were dropped.
        let capped = proposals.suffix(50)
        return .object([
            "status": .string("ok"),
            "count": .int(Int64(proposals.count)),
            "truncated": .bool(proposals.count > capped.count),
            "proposals": .array(capped.map { summary($0, includeReceipts: false) }),
        ])
    }

    // MARK: - self_install (stage only — never installs)

    func evolutionStageInstall(input: [String: JSONValue]) async throws -> JSONValue {
        // Cap the caller-supplied id at extraction (gpt-5.5 review-3) — echoed
        // back on several paths; truncate so it can't bloat the chat turn.
        guard let id = nonEmptyString(input["proposal_id"]).map({ Self.truncate($0, 128) }) else {
            return failed(reason: "missing_proposal_id", fix: "Pass the 'proposal_id' (evo_…) to stage for install.")
        }
        guard let proposal = try await store.get(id: id) else {
            return .object([
                "status": .string("not_found"),
                "id": .string(id),
            ])
        }
        guard proposal.status == .candidateGreen else {
            // Honest refusal — staging an install card requires a GREEN
            // candidate. Anything else (needs_diff/proposed/building/failed/
            // already staged/installed/denied) is reported back verbatim.
            return .object([
                "status": .string("not_installable"),
                "id": .string(id),
                "proposal_status": .string(proposal.status.rawValue),
                "reason": .string("not installable yet: status=\(proposal.status.rawValue)"),
                "fix": .string("self_install requires status=candidate_green (the proposal must build+test GREEN in an isolated worktree first)."),
            ])
        }
        // Idempotent + targeted: stage ONLY this proposal's card (gpt-5.5
        // SHOULD-FIX — the chat trigger named one id; don't silently stage
        // unrelated green candidates). Reuses the single card-staging path.
        await BackgroundLoopsAssembly.stageEvolutionApprovals(dataRoot: dataRoot, onlyProposalId: id)

        // Report the staged self_evolution.apply card for THIS proposal.
        let card = await latestEvolutionApproval(proposalId: id)
        let postStatus = (try? await store.get(id: id))?.status.rawValue ?? proposal.status.rawValue
        if let card {
            return .object([
                "status": .string("staged"),
                "id": .string(id),
                "proposal_status": .string(postStatus),
                "approval_id": .string(card.id),
                "approval_status": .string(card.status),
                "approval_decision": card.decision.map { JSONValue.string($0) } ?? .null,
                "note": .string("A self_evolution.apply approval card is staged. It only commits + self-installs after approval (and the install fires only once systemRebuild is enabled). This tool did NOT install anything."),
            ])
        }
        // Stager ran but no card surfaced (e.g. missing candidateRunId/diff on
        // the record) — report honestly rather than implying a card exists.
        return .object([
            "status": .string("stage_incomplete"),
            "id": .string(id),
            "proposal_status": .string(postStatus),
            "reason": .string("stageEvolutionApprovals ran but no self_evolution.apply card was found for this proposal (it may lack a candidate run id / diff)."),
        ])
    }

    // MARK: - Helpers

    private func latestEvolutionApproval(proposalId: String) async -> ApprovalRecord? {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        guard let records = try? await inbox.list(
            filter: ApprovalFilter(action: NativeClient.selfEvolutionAction)) else { return nil }
        return records
            .filter { rec in
                guard case .object(let p) = rec.payload,
                      case .string(let pid)? = p["proposalId"] else { return false }
                return pid == proposalId
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private func summary(_ p: EvolutionProposal, includeReceipts: Bool) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(p.id),
            // gpt-5.5 review-2: title/deny_reason are stored text — bound them on
            // the way out too (input caps title at 300, but a record can predate
            // the cap or be filed by another source).
            "title": .string(Self.truncate(p.title, 300)),
            "status": .string(p.status.rawValue),
            "source": .string(p.source.rawValue),
            "risk": .string(p.risk),
            "has_diff": .bool(p.diffText != nil),
            "created_at": .string(p.createdAt),
            "updated_at": .string(p.updatedAt),
        ]
        if let runId = p.candidateRunId { obj["candidate_run_id"] = .string(runId) }
        if let deny = p.denyReason { obj["deny_reason"] = .string(Self.truncate(deny, 500)) }
        if includeReceipts {
            // Truncate stored text on the way OUT (gpt-5.5 SHOULD-FIX): a large
            // proposal must not dump unbounded evidence/receipts back into the
            // chat turn. Last 20 receipts, detail capped.
            obj["evidence"] = .string(Self.truncate(p.evidence, 2_000))
            obj["receipts"] = .array(p.receipts.suffix(20).map {
                .object([
                    "at": .string($0.at),
                    "kind": .string($0.kind),
                    "detail": .string(Self.truncate($0.detail, 500)),
                ])
            })
        } else if let last = p.receipts.last {
            obj["last_receipt"] = .string(Self.truncate("\(last.kind): \(last.detail)", 500))
        }
        return .object(obj)
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "… (truncated)"
    }

    private func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func failed(reason: String, fix: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string(reason),
            "fix": .string(fix),
        ])
    }
}

import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import TrustCenter
import ToolRegistry
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `ApprovalSubjects.swift` | Existing proposal subject applications |
extension ApprovalExecution {
    /// Applies an approved self-improvement proposal. The op vocabulary is
    /// deliberately tiny + safe + reversible (every op is an existing
    /// user-triggerable action), and nothing here runs without the explicit
    /// approval that called it. Unknown/blank ops are a logged no-op.
    func applyApprovedSelfImprovement(from rec: ApprovalRecord) async {
        // Self-defensive: only ever applies a resolved + approved
        // self_improvement.apply record, regardless of caller.
        guard rec.action == "self_improvement.apply",
              rec.status == "resolved",
              rec.decision == "approved" else { return }
        guard case .object(let payload) = rec.payload,
              case .object(let apply)? = payload["apply"],
              case .string(let op)? = apply["op"] else { return }
        let target: String? = {
            if case .string(let t)? = apply["target"], !t.isEmpty { return t }
            return nil
        }()
        var outcomeFields: [String: JSONValue] = [:]
        do {
            switch op {
            case "disable_skill":
                guard let target else {
                    // Annotate, don't just return — an approved record with no
                    // executable target must never read as silently applied.
                    nativeLog("[selfImprovement] missing target for op: \(op)")
                    try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object(["op": .string(op), "error": .string("missing target")]),
                        detail: "self-improvement \(op) FAILED: missing target for \(op)")
                    return
                }
                try await effects.disableSkill(name: target)
            case "enable_skill":
                guard let target else {
                    nativeLog("[selfImprovement] missing target for op: \(op)")
                    try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object(["op": .string(op), "error": .string("missing target")]),
                        detail: "self-improvement \(op) FAILED: missing target for \(op)")
                    return
                }
                let reviewedDigest: String?
                switch apply["reviewedDigest"] {
                case .string(let digest)? where !digest.isEmpty: reviewedDigest = digest
                // Old cards and explicit null authorize Markdown guidance only.
                // Parts refuses code; never fill this from the current catalog.
                case nil, .null?: reviewedDigest = nil
                default: throw ApprovalInboxError.malformedResponse("the card has no valid reviewed digest")
                }
                try await effects.enableSkill(name: target, reviewedDigest: reviewedDigest)
                outcomeFields["reviewedDigest"] = reviewedDigest.map(JSONValue.string) ?? .null
            default:
                nativeLog("[selfImprovement] unknown apply op: \(op)")
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object(["op": .string(op), "error": .string("unknown op")]),
                    detail: "self-improvement apply FAILED: unknown op '\(op)'")
                return
            }
            var executed: [String: JSONValue] = [
                "op": .string(op),
                "target": .string(target ?? ""),
            ]
            executed.merge(outcomeFields) { _, new in new }
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object(executed),
                detail: "self-improvement \(op) applied")
        } catch {
            // Don't leave an approved-but-silently-failed record: annotate the
            // failure so the UI shows it didn't apply.
            nativeLog("[selfImprovement] apply failed for op \(op): \(error)")
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object(["op": .string(op), "error": .string("\(error)")]),
                detail: "self-improvement \(op) FAILED: \(error.localizedDescription)")
        }
    }
    /// Applies a resolved rem.proposal record to the canonical store
    /// (<dataRoot>/rem_proposals.jsonl). Approved → status pending→approved +
    /// rem_pins.json re-emit (the chat injector reads it next turn). Denied →
    /// REMTombstoneStore.record + status→denied + re-emit. Canceled → clear
    /// the staging stamp so the next REM pass re-stages instead of leaving a
    /// dead row. Every branch annotates the approval record; failures
    /// annotate FAILED — approval alone never implies application.
    func applyResolvedREMProposal(from rec: ApprovalRecord) async {
        // Self-defensive: only ever acts on a resolved rem.proposal record,
        // regardless of caller.
        guard rec.action == "rem.proposal",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        guard case .object(let payload) = rec.payload,
              case .object(let proposal)? = payload["proposal"],
              case .string(let proposalId)? = proposal["id"],
              !proposalId.isEmpty else {
            nativeLog("[remProposal] missing proposal id on approval \(rec.id)")
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object(["error": .string("missing proposal id")]),
                detail: "REM proposal \(decision) FAILED: payload carries no proposal id")
            return
        }
        let store = REMProposalStore(dataRoot: dataRoot)
        do {
            switch decision {
            case "approved":
                // Append to GROWTH before approving; failure clears staging for a fresh card.
                // Exact-text idempotency prevents duplicate lessons during reconciliation.
                var proposalText: String = {
                    if case .string(let t)? = proposal["proposalText"] { return t }
                    return ""
                }()
                if proposalText.isEmpty {
                    // Cards without payload text read the canonical row; missing text must not become approval.
                    proposalText = store.loadAll()
                        .first { $0.id == proposalId }?.proposalText ?? ""
                }
                guard !proposalText.isEmpty else {
                    throw NSError(
                        domain: "REMProposalApprove", code: -301,
                        userInfo: [NSLocalizedDescriptionKey:
                            "no proposal text in payload OR store row \(proposalId) — "
                            + "refusing to flip approved without the GROWTH write"])
                }
                let row = store.loadAll().first(where: { $0.id == proposalId })
                let graduating = (row?.support == .standing ? row?.supportingPassages ?? [] : []).flatMap { passage in
                    passage.sourceRefs.filter { $0.hasPrefix("memory:") }
                        .map { (id: String($0.dropFirst("memory:".count)), quote: passage.quote) }
                }
                // A standing card quotes its correction as it was offered. One
                // rewritten, corrected or let go since is stale: nothing lands,
                // and the card is closed without refusing the lesson.
                for item in graduating {
                    let memory = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot).memory(id: item.id)
                    guard let memory, memory.status == "active", MemoryLifecycle.isRecallEligible(memory.lifecycle),
                          memory.content == item.quote else {
                        _ = try await store.applyDenial(proposalId: proposalId, reason: "stale", tombstone: false)
                        try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                            rec.id,
                            executedAction: .object(["op": .string("rem_proposal_stale"), "proposalId": .string(proposalId),
                                                     "error": .string("stale")]),
                            detail: "Standing lesson stale — the correction it came from changed since this card was "
                                + "offered. Nothing was added to GROWTH and the memory was not graduated.")
                        return
                    }
                }
                let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
                let appended = try await REMGrowthWriter.appendApprovedLesson(
                    personaRoot: personaRoot, proposalText: proposalText)
                // A standing lesson lives in GROWTH now: the correction it came
                // from graduates — kept as history, never recalled. Before the
                // flip, so a failure leaves the row to be re-staged and retried.
                for item in graduating {
                    _ = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).updateMemory(
                        id: item.id, update: .object(["lifecycle": .string(MemoryLifecycle.graduated)]))
                }
                _ = try await store.applyApproval(proposalId: proposalId)
                // Lesson-origin recording is best-effort and cannot undo approval.
                if let row {
                    do {
                        try await REMLessonOrigin.record(
                            row, memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot), dataRoot: dataRoot)
                    } catch {
                        nativeLog("[remProposal] lesson origin not kept for \(proposalId): \(error)")
                    }
                }
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "op": .string("rem_proposal_approve"),
                        "proposalId": .string(proposalId),
                        "growthAppended": .bool(appended),
                    ]),
                    detail: appended
                        ? "REM proposal approved — appended to GROWTH.md + pinned for chat injection"
                        : "REM proposal approved — pinned; GROWTH already carried this lesson")
            case "denied":
                _ = try await store.applyDenial(
                    proposalId: proposalId,
                    reason: "denied via approval inbox")
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "op": .string("rem_proposal_deny"),
                        "proposalId": .string(proposalId),
                    ]),
                    detail: "REM proposal denied — tombstoned")
            default: // canceled
                try await store.clearApprovalStamp(proposalId: proposalId)
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "op": .string("rem_proposal_cancel"),
                        "proposalId": .string(proposalId),
                    ]),
                    detail: "REM proposal canceled — left pending; next REM pass re-stages it")
            }
        } catch {
            nativeLog("[remProposal] \(decision) failed for proposal \(proposalId): \(error)")
            // Clear staging after failed application so pending rows can receive a fresh card.
            // Approved rows are not re-staged.
            try? await store.clearApprovalStamp(proposalId: proposalId)
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "proposalId": .string(proposalId),
                    "error": .string("\(error)"),
                ]),
                detail: "REM proposal \(decision) FAILED: \(error.localizedDescription) — "
                    + "stamp cleared; next REM pass re-stages it")
        }
    }
    /// User's answer to a skill script install card. Approved admits exactly
    /// the digest the card showed, through the Skills page's own Install
    /// (`enableSkill(name:reviewedDigest:)`), which refuses a script changed
    /// since; denied or withdrawn leaves it drafted. Every branch annotates.
    public func applyResolvedSkillScriptInstall(from rec: ApprovalRecord) async {
        guard rec.action == SwiftNativeApprovalInbox.skillScriptInstallAction, rec.status == "resolved" else { return }
        let root = dataRoot
        guard let (skill, digest) = SwiftNativeApprovalInbox.skillScriptInstallBinding(rec) else {
            try? await SwiftNativeApprovalInbox(root: root).annotateExecution(rec.id,
                executedAction: .object(["installed": .bool(false), "error": .string("no skill or digest bound")]),
                detail: "Nothing was installed: the card names no skill and digest.")
            return
        }
        var done: [String: JSONValue] = ["skill": .string(skill), "digest": .string(digest), "installed": .bool(false)]
        var detail = "Not approved: \(skill)'s script was not turned on; it stays drafted."
        if rec.decision == ApprovalDecision.approved.rawValue {
            do {
                try await effects.enableSkill(name: skill, reviewedDigest: digest)
                done["installed"] = .bool(true)
                detail = "Installed \(skill)'s script, digest \(digest.prefix(12))."
            } catch {
                done["error"] = .string(error.localizedDescription)
                detail = "Nothing was installed: \(error.localizedDescription)"
            }
        }
        try? await SwiftNativeApprovalInbox(root: root).annotateExecution(
            rec.id, executedAction: .object(done), detail: detail)
    }
    /// Canon writes require her agent seat and live-turn provenance from `StudioCanonSeatGate`.
    /// This executor only annotates: owner resolutions are refused; missing approved rows
    /// require her idempotent `studio.canon_resolve` in chat.
    public func applyResolvedStudioCanonProposal(
        from rec: ApprovalRecord,
        dataRoot requestedRoot: URL? = nil
    ) async {
        let dataRoot = requestedRoot ?? self.dataRoot
        guard rec.action == StudioCanonProposal.approvalAction,
              rec.status == "resolved", let decision = rec.decision else { return }
        let workTitle = StudioCanonProposal.draft(of: rec)?.workTitle ?? "(unnamed work)"
        guard decision == ApprovalDecision.approved.rawValue else {
            // Denied or canceled: nothing to write from any seat, which is the
            // one outcome this executor can state without qualification.
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "op": .string("studio_canon_\(decision)"),
                    "work": .string(workTitle),
                    "rowWritten": .bool(false),
                ]),
                detail: "Canon proposal \(decision) — nothing written; "
                    + "the journal entries and the graph are untouched")
            return
        }
        let landed = (try? await SwiftNativeStudioStore(dataRoot: dataRoot).readCanon())?
            .contains { $0.proposalID == rec.id } ?? false
        if landed {
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "op": .string("studio_canon_already_applied"),
                    "work": .string(workTitle),
                    "rowWritten": .bool(false),
                ]),
                detail: "Canon row for \(workTitle) is already on the ledger")
            return
        }
        let herSeat = StudioCanonSeat.isAgent(rec.decidedBy)
        nativeLog("[studioCanon] not applying \(rec.id) from an executor "
            + "(decidedBy=\(rec.decidedBy ?? "unknown"))")
        try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
            rec.id,
            executedAction: .object([
                "op": .string(herSeat ? "studio_canon_needs_her_turn" : "studio_canon_refused"),
                "decidedBy": .string(rec.decidedBy ?? ""),
                "work": .string(workTitle),
                "rowWritten": .bool(false),
            ]),
            detail: herSeat
                ? "Canon proposal approved by the agent but the row did not land; an executor has "
                    + "no live turn to record, so nothing was written. Re-run "
                    + "app studio.canon_resolve in chat — it is idempotent by proposal id."
                : "Canon proposal NOT applied: "
                    + (StudioCanonError.approvalNotFromAgentSeat(rec.decidedBy ?? "unknown")
                        .errorDescription ?? "the canon is the agent's to tend"))
    }
    func retireSelfEvolutionApproval(from rec: ApprovalRecord) async {
        try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
            rec.id, executedAction: .object(["op": .string("self_evolution_retired")]),
            detail: "Code evolution is no longer available; no code was changed or installed.")
    }
    /// A Desk item that waits on an approval names it in its blocked reason or
    /// waiting-on, by full id or its first eight characters; nothing else links
    /// the two. Once that approval is decided the wait is over and the item
    /// says so: the decision as a note, then back to todo when approved, or
    /// blocked on a new plan otherwise. An item naming more than one approval
    /// stays its owner's call.
}

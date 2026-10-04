import SelfImprovement
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import ChatOrchestration
import TrustCenter
import ToolRegistry
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import TelegramBot

private final class ChatToolApprovalExecutionOwners: @unchecked Sendable {
    private struct Key: Hashable {
        let root: String
        let approvalID: String
    }

    static let shared = ChatToolApprovalExecutionOwners()
    static let continuations = ChatToolApprovalExecutionOwners()
    private let lock = NSLock()
    private var active: Set<Key> = []

    func acquire(root: URL, approvalID: String) -> Bool {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return lock.withLock { active.insert(key).inserted }
    }

    func release(root: URL, approvalID: String) {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        _ = lock.withLock { active.remove(key) }
    }
}

public struct ApprovalTransactionCoordinator: Sendable {
    let effects: any ApprovalTransactionEffects
    let dataRootOverride: URL?

    public init(effects: any ApprovalTransactionEffects, dataRootOverride: URL? = nil) {
        self.effects = effects
        self.dataRootOverride = dataRootOverride
    }

    public static func jsonString(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let obj) = value else { return nil }
        if case .string(let s)? = obj[key] { return s }
        return nil
    }

    /// Applies an approved self-improvement proposal. The op vocabulary is
    /// deliberately tiny + safe + reversible (every op is an existing
    /// user-triggerable action), and nothing here runs without the explicit
    /// approval that called it. Unknown/blank ops are a logged no-op.
    private func applyApprovedSelfImprovement(from rec: ApprovalRecord) async {
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
        // What the op actually did, for the receipt. "applied" is reserved for
        // the canonical application receipt — consolidation's own outcome is
        // staged / refused / ok / partial, and before 2026-09-11 this executor
        // discarded it and wrote "applied" regardless (audit finding 8).
        var outcomeFields: [String: JSONValue] = [:]
        var outcomeDetail: String?
        do {
            switch op {
            case "run_memory_hygiene":
                let receipt = Self.memoryHygieneReceipt(try await effects.runMemoryHygiene())
                outcomeFields = receipt.fields
                outcomeDetail = receipt.detail
            case "disable_skill":
                guard let target else {
                    // Annotate, don't just return — an approved record with no
                    // executable target must never read as silently applied.
                    NSLog("[selfImprovement] missing target for op: \(op)")
                    try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object(["op": .string(op), "error": .string("missing target")]),
                        detail: "self-improvement \(op) FAILED: missing target for \(op)")
                    return
                }
                try await effects.disableSkill(name: target)
            case "enable_skill":
                guard let target else {
                    NSLog("[selfImprovement] missing target for op: \(op)")
                    try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object(["op": .string(op), "error": .string("missing target")]),
                        detail: "self-improvement \(op) FAILED: missing target for \(op)")
                    return
                }
                try await effects.enableSkill(name: target, reviewedDigest: nil)
            default:
                NSLog("[selfImprovement] unknown apply op: \(op)")
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object(["op": .string(op), "error": .string("unknown op")]),
                    detail: "self-improvement apply FAILED: unknown op '\(op)'")
                return
            }
            var executed: [String: JSONValue] = [
                "op": .string(op),
                "target": .string(target ?? ""),
            ]
            executed.merge(outcomeFields) { _, new in new }
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(executed),
                detail: outcomeDetail ?? "self-improvement \(op) applied")
        } catch {
            // Don't leave an approved-but-silently-failed record: annotate the
            // failure so the UI shows it didn't apply.
            NSLog("[selfImprovement] apply failed for op \(op): \(error)")
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["op": .string(op), "error": .string("\(error)")]),
                detail: "self-improvement \(op) FAILED: \(error.localizedDescription)")
        }
    }

    /// What an approved `run_memory_hygiene` actually did, for the approval
    /// receipt. Consolidation from this path NEVER applies: it stages a card for
    /// approval, is refused by the probe gate, or finds nothing to do — so the
    /// word "applied" is reserved for the canonical application receipt and the
    /// run's real status + ids ride the annotation (2026-09-11 audit finding 8).
    public static func memoryHygieneReceipt(
        _ report: ApprovalMemoryHygieneResult
    ) -> (fields: [String: JSONValue], detail: String) {
        let status = report.status ?? "unknown"
        var fields: [String: JSONValue] = ["outcome": .string(status)]
        if let runId = report.consolidationRunId, !runId.isEmpty {
            fields["consolidation_run_id"] = .string(runId)
        }
        if let id = report.id, !id.isEmpty { fields["hygiene_report_id"] = .string(id) }
        if let reason = report.reason, !reason.isEmpty { fields["reason"] = .string(reason) }
        let phrase: String
        switch status {
        case "staged": phrase = "staged a consolidation card for approval — the store is unchanged until that card is approved"
        case "refused": phrase = "refused by the probe gate — the store is unchanged"
        case "ok": phrase = "ran with no changes to apply"
        case "partial": phrase = "ran with errors; see reason"
        case "dry_run": phrase = "preview only — nothing changed"
        default: phrase = "ran; outcome \(status)"
        }
        let detail = "self-improvement run_memory_hygiene \(phrase)"
            + (report.reason.map { ": \($0)" } ?? "")
        return (fields, detail)
    }

    /// Applies a resolved rem.proposal record to the canonical store
    /// (<dataRoot>/rem_proposals.jsonl). Approved → status pending→approved +
    /// rem_pins.json re-emit (the chat injector reads it next turn). Denied →
    /// REMTombstoneStore.record + status→denied + re-emit. Canceled → clear
    /// the staging stamp so the next REM pass re-stages instead of leaving a
    /// dead row. Every branch annotates the approval record; failures
    /// annotate FAILED — an approved record must never read as silently
    /// applied (W8 lesson).
    private func applyResolvedREMProposal(from rec: ApprovalRecord) async {
        // Self-defensive: only ever acts on a resolved rem.proposal record,
        // regardless of caller.
        guard rec.action == "rem.proposal",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        guard case .object(let payload) = rec.payload,
              case .object(let proposal)? = payload["proposal"],
              case .string(let proposalId)? = proposal["id"],
              !proposalId.isEmpty else {
            NSLog("[remProposal] missing proposal id on approval \(rec.id)")
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["error": .string("missing proposal id")]),
                detail: "REM proposal \(decision) FAILED: payload carries no proposal id")
            return
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        let store = REMProposalStore(dataRoot: dataRoot)
        do {
            switch decision {
            case "approved":
                // GROWTH.md append FIRST (2026-07-03 — User approved a card,
                // watched GROWTH not change, and caught that this write never
                // existed; the card's own text promises it). Append-before-flip
                // ordering: an append failure throws into the catch below,
                // which clears the staging stamp so the next REM pass
                // re-stages — the row is never left approved-but-unwritten.
                // The writer is idempotent (exact-text check), so a reconcile
                // re-fire after the flip can't double-append.
                var proposalText: String = {
                    if case .string(let t)? = proposal["proposalText"] { return t }
                    return ""
                }()
                if proposalText.isEmpty {
                    // Legacy cards staged before the payload carried text:
                    // the canonical store row is the source of truth
                    // (gpt-5.5 HIGH — silently flipping approved here would
                    // recreate approved-but-unwritten permanently, with a
                    // success annotation blocking the reconcile).
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
                let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
                let appended = try await REMGrowthWriter.appendApprovedLesson(
                    personaRoot: personaRoot, proposalText: proposalText)
                _ = try await store.applyApproval(proposalId: proposalId)
                // Phase 5 C1: the lesson keeps the moment that taught it.
                // Best-effort: the approval stands whatever happens here.
                if let row = store.loadAll().first(where: { $0.id == proposalId }) {
                    do {
                        try await REMLessonOrigin.record(
                            row, memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot), dataRoot: dataRoot)
                    } catch {
                        NSLog("[remProposal] lesson origin not kept for \(proposalId): \(error)")
                    }
                }
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: rec.id,
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
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("rem_proposal_deny"),
                        "proposalId": .string(proposalId),
                    ]),
                    detail: "REM proposal denied — tombstoned")
            default: // canceled
                try await store.clearApprovalStamp(proposalId: proposalId)
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("rem_proposal_cancel"),
                        "proposalId": .string(proposalId),
                    ]),
                    detail: "REM proposal canceled — left pending; next REM pass re-stages it")
            }
        } catch {
            NSLog("[remProposal] \(decision) failed for proposal \(proposalId): \(error)")
            // The approval record is already terminal (resolve preceded this
            // executor), so a stamped-but-unapplied row would be a permanent
            // dead-end: stagePendingApprovals skips stamped rows. Clear the
            // stamp so the next REM pass re-stages a fresh approval. Harmless
            // when the status flip already landed (staging only touches
            // status=="pending" rows). gpt-5.5 review 2026-06-10.
            try? await store.clearApprovalStamp(proposalId: proposalId)
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
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
        let root = dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
        guard let (skill, digest) = SwiftNativeApprovalInbox.skillScriptInstallBinding(rec) else {
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(id: rec.id,
                executedAction: .object(["installed": .bool(false), "error": .string("no skill or digest bound")]),
                detail: "Nothing was installed: the card names no skill and digest.", root: root)
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
        try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
            id: rec.id, executedAction: .object(done), detail: detail, root: root)
    }

    /// Applies a resolved `studio.canon` card (desk 903 phase 4) — the ONE card
    /// in this app the owner may not approve, and the one executor that can
    /// never write anything.
    ///
    /// Her line: "my taste, not User's to sign off." A canon row now requires two
    /// things a resolver must HAVE, not claim: her agent seat, and the live-turn
    /// provenance `StudioCanonSeatGate` derives from a running chat turn. An
    /// executor has neither — it runs after the turn, from the approval inbox —
    /// so this branch's only job is the honest, annotated refusal:
    ///
    ///   * an owner-resolved card (Activity UI, desk click, Full Mac YOLO, a
    ///     signed iOS operator) → refused, annotated, no row;
    ///   * a card she resolved whose row never landed (the crash window) →
    ///     annotated as needing her to run `studio_canon_resolve` again, which
    ///     is idempotent by proposal id. Inventing a provenance here so the
    ///     replay could write the row would forge exactly the evidence the seat
    ///     exists to require.
    public func applyResolvedStudioCanonProposal(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard rec.action == StudioCanonProposal.approvalAction,
              rec.status == "resolved", let decision = rec.decision else { return }
        let workTitle = StudioCanonProposal.draft(of: rec)?.workTitle ?? "(unnamed work)"
        guard decision == ApprovalDecision.approved.rawValue else {
            // Denied or canceled: nothing to write from any seat, which is the
            // one outcome this executor can state without qualification.
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
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
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("studio_canon_already_applied"),
                    "work": .string(workTitle),
                    "rowWritten": .bool(false),
                ]),
                detail: "Canon row for \(workTitle) is already on the ledger")
            return
        }
        let herSeat = StudioCanonSeat.isAgent(rec.decidedBy)
        NSLog("[studioCanon] not applying \(rec.id) from an executor "
            + "(decidedBy=\(rec.decidedBy ?? "unknown"))")
        try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
            id: rec.id,
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

    // MARK: - U5 W-A item 3: generic resolve→execute crash-window reconcile

    /// One reconcilable approval kind: the action string, an eligibility/
    /// idempotency predicate, and the executor to re-fire.
    public struct ApprovalExecutionReconcileKind {
        let action: String
        /// Per-kind eligibility hook — `false` skips the record.
        let shouldReconcile: (ApprovalRecord) -> Bool
        let execute: (ApprovalRecord) async -> Void

        public init(action: String, shouldReconcile: @escaping (ApprovalRecord) -> Bool,
                    execute: @escaping (ApprovalRecord) async -> Void) {
            self.action = action
            self.shouldReconcile = shouldReconcile
            self.execute = execute
        }
    }

    /// Generic launch reconcile for approval kinds whose executors
    /// had NO crash-window coverage (rem.proposal, execution.step,
    /// self_improvement.apply, browser.open_url). `resolveApproval`
    /// persists the record terminal BEFORE its executor runs; a crash in
    /// that window leaves a resolved record whose work never happened.
    /// Every one of these executors stamps `executedAction` on every branch
    /// (success AND failure), so "resolved + no executedAction annotation"
    /// identifies the crash window exactly — the same key the shipped
    /// per-kind reconciles (reconcileUnappliedMemoryRepairs /
    /// reconcileUnappliedKindBackfills) use.
    ///
    /// The SECOND crash window (executor finished, annotation write
    /// crashed) means a reconcile may RE-RUN an executor, so every kind
    /// carries an idempotency mechanism:
    ///   - rem.proposal: REMProposalStore.setStatus no-ops when the row
    ///     already holds the target status, and applyDenial early-returns
    ///     on an already-denied row — a re-fire just heals the annotation.
    ///   - execution.step: the executor consults the EXECUTION'S OWN STATE —
    ///     an in-lock `blocked_on_approval` precondition (staleApproval
    ///     throw) plus step-record guards — so a step that already executed
    ///     is refused and annotated honestly, never blind-rerun (the plan's
    ///     load-bearing requirement for side-effecting step executors).
    ///   - self_improvement.apply: only `approved` records reconcile
    ///     (denied/canceled records never receive an executor or annotation
    ///     by design — they are not a gap); the allow-listed ops are
    ///     idempotent-shaped (hygiene re-run is itself an approved direct
    ///     run; skill enable/disable are status flips).
    ///   - browser.open_url: approved re-fire is capped at ONCE — the
    ///     preflight in `reconcileResolvedBrowserRun` checks runs.json for
    ///     the payload's runId in a TERMINAL state (the executor persists
    ///     the run BEFORE annotating) and, when found, heals the missing
    ///     annotation from the persisted run WITHOUT re-opening the URL.
    public func reconcileUnappliedApprovalExecutions() async {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let records = await Self.resolvedApprovalsForReconciliation(dataRoot: dataRoot)
        await Self.reconcileUnappliedApprovalExecutions(
            dataRoot: dataRoot,
            kinds: productionApprovalReconcileKinds(), records: records)
        let receiptFailures = await reconcileUnappliedChatToolApprovalExecutions(dataRoot: dataRoot, records: records)
        await reconcileUnappliedConnectorActionApprovals(dataRoot: dataRoot, records: records)
        await checkpointApprovalReconciliation(dataRoot: dataRoot, records: records, retry: receiptFailures)
    }

    struct ApprovalReconciliationCursor: Codable {
        var stamp = ""
        // Optional so old (stamp, id) cursors safely revisit the boundary.
        var boundaryIDs: Set<String>?
        var retry: [String] = []

        static func path(_ root: URL) -> URL {
            root.appendingPathComponent("workflows/approvals/reconciliation-cursor.json")
        }

        static func read(_ root: URL) throws -> Self {
            let path = path(root)
            guard FileManager.default.fileExists(atPath: path.path) else { return Self() }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        }
    }

    // 2026-09-18: walk oldest first using resolution time, not creation time:
    // an old pending card resolved tomorrow must still cross the cursor.
    // Failed effects/receipts retain explicit retries; they cannot pin history.
    public static func resolvedApprovalsForReconciliation(
        dataRoot: URL, records: [ApprovalRecord]? = nil
    ) async -> [ApprovalRecord] {
        if let records { return records }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        do {
            try await TelegramPollLoop.importLegacyApprovalContinuations(dataRoot: dataRoot, inbox: inbox)
        } catch {
            NSLog("[approvalReconcile] legacy Telegram continuation import failed; file preserved: \(String(describing: error))")
        }
        do {
            let cursor = try ApprovalReconciliationCursor.read(dataRoot)
            let rows = try await inbox.list(filter: .resolved)
            // 2026-09-19: UUID order is not resolution order. Keep the timestamp
            // boundary open for rows resolved during/after this page's snapshot.
            let page = rows.filter {
                let stamp = $0.resolvedAt ?? $0.createdAt
                return stamp > cursor.stamp || (stamp == cursor.stamp
                    && !(cursor.boundaryIDs ?? []).contains($0.id))
            }.sorted {
                ($0.resolvedAt ?? $0.createdAt, $0.id) < ($1.resolvedAt ?? $1.createdAt, $1.id)
            }.prefix(SwiftNativeApprovalInbox.storedApprovalCap)
            let ids = Set(page.map(\.id))
            let retainedIDs = Set(rows.map(\.id))
            let retryIDs = Set(cursor.retry.filter { retainedIDs.contains($0) }
                .prefix(SwiftNativeApprovalInbox.storedApprovalCap))
            return Array(page) + rows.filter { record in
                guard !ids.contains(record.id) else { return false }
                if retryIDs.contains(record.id) { return true }
                // Continuity is a separate commit from the replay cursor.
                // Include owed turns and abandoned claims independently of age
                // and the execution cursor. A started turn must be settled.
                guard let replay = Self.chatToolApprovalReplay(from: record),
                      let session = NativeAgentChatSessionID.normalizedPathComponent(replay.sessionId),
                      !(replay.surface == "connector_action" && session.hasPrefix("ephemeral:connector_action:")) else { return false }
                if case .object(let state)? = record.chatContinuation,
                   state["started"] != nil, state["done"] != .bool(true) { return true }
                return SwiftNativeApprovalInbox.continuationIsPending(record)
            }
        } catch {
            NSLog("[approvalReconcile] scan failed: \(String(describing: error))")
            return []
        }
    }

    public func checkpointApprovalReconciliation(
        dataRoot: URL, records: [ApprovalRecord], retry: Set<String> = []
    ) async {
        guard !records.isEmpty else { return }
        do {
            var cursor = try ApprovalReconciliationCursor.read(dataRoot)
            let refreshed = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: .resolved)
            let selected = Set(records.map(\.id))
            // 2026-09-19: a deferred install has an annotation but still needs
            // the later self-evolution launch pass, including after relaunch.
            let unresolved = refreshed.filter {
                selected.contains($0.id) && (($0.decision == "approved" && $0.executedAction == nil)
                    || SelfEvolutionApprovalExecutor.isDeferredEvolutionInstall($0) || retry.contains($0.id))
            }.map(\.id)
            let retainedIDs = Set(refreshed.map(\.id))
            cursor.retry.removeAll { selected.contains($0) || !retainedIDs.contains($0) }
            cursor.retry.append(contentsOf: unresolved)
            for row in records {
                let stamp = row.resolvedAt ?? row.createdAt
                if stamp > cursor.stamp {
                    cursor.stamp = stamp
                    cursor.boundaryIDs = []
                }
                if stamp == cursor.stamp {
                    cursor.boundaryIDs = (cursor.boundaryIDs ?? []).union([row.id])
                }
            }
            cursor.boundaryIDs?.formIntersection(Set(refreshed.map(\.id)))
            try JSONEncoder().encode(cursor).write(to: ApprovalReconciliationCursor.path(dataRoot), options: .atomic)
        } catch {
            NSLog("[approvalReconcile] checkpoint failed: \(error)")
        }
    }

    /// Scan core, split out so tests can run it against a fixture root with
    /// recording executors (the production executors are hardwired to the
    /// default data root).
    public static func reconcileUnappliedApprovalExecutions(
        dataRoot: URL,
        kinds: [ApprovalExecutionReconcileKind],
        records: [ApprovalRecord]? = nil
    ) async {
        let resolved = await Self.resolvedApprovalsForReconciliation(dataRoot: dataRoot, records: records)
        for kind in kinds {
            for rec in resolved where rec.executedAction == nil
                && ExecutionEventVocabulary.matches(rec.action, kind.action) {
                guard kind.shouldReconcile(rec) else { continue }
                NSLog("[approvalReconcile] reconciling unexecuted resolved \(kind.action) "
                    + "\(rec.id) (decision: \(rec.decision ?? "?"))")
                await kind.execute(rec)
            }
        }
    }

    /// self_improvement.apply eligibility: resolve only ever runs the
    /// executor on APPROVED records; denied/canceled records carry no
    /// annotation by design and must not be re-scanned forever.
    public static func selfImprovementReconcileEligible(_ rec: ApprovalRecord) -> Bool {
        rec.decision == "approved"
    }

    public func productionApprovalReconcileKinds() -> [ApprovalExecutionReconcileKind] {
        // The instance executors never touch transport state — any client
        // value reaches the same Swift-native paths resolveApproval uses.
        let client = self
        return [
            ApprovalExecutionReconcileKind(
                action: "rem.proposal",
                shouldReconcile: { _ in true },
                execute: { await client.applyResolvedREMProposal(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: WorkshopStepApprovalAction.canonical,
                shouldReconcile: { _ in true },
                execute: { await client.applyResolvedWorkshopStep(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: "self_improvement.apply",
                shouldReconcile: { Self.selfImprovementReconcileEligible($0) },
                execute: { await client.applyApprovedSelfImprovement(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: "browser.open_url",
                shouldReconcile: { _ in true },
                execute: { await self.reconcileResolvedBrowserRun(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: "agentmail.send",
                shouldReconcile: { _ in true },
                execute: { await self.applyResolvedAgentMailSend(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: ExternalSendApprovalRequest.approvalAction,
                shouldReconcile: { _ in true },
                execute: { _ = await effects.applyResolvedExternalSend(from: $0) }),
            // Desk 903 phase 4. Reconcilable like the rest, and refusing like
            // nothing else: an owner-resolved canon card replays into the same
            // annotated refusal rather than into her museum.
            ApprovalExecutionReconcileKind(
                action: StudioCanonProposal.approvalAction,
                shouldReconcile: { _ in true },
                execute: { await self.applyResolvedStudioCanonProposal(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: SwiftNativeApprovalInbox.skillScriptInstallAction,
                shouldReconcile: { _ in true },
                execute: { await self.applyResolvedSkillScriptInstall(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction,
                shouldReconcile: { _ in true },
                execute: {
                    await Self.applyResolvedProcedureExactActivation(from: $0, dataRoot: PersistenceCore.defaultDataRoot())
                }),
        ]
    }

    /// Executes the pre-external_send_v1 AgentMail approval shape so older
    /// pending cards can still be replayed safely/idempotently.
    public func applyResolvedAgentMailSend(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        guard rec.action == "agentmail.send",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        guard decision == "approved" else {
            let op = decision == "denied" ? "agentmail_send_denied" : "agentmail_send_canceled"
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string(op),
                    "actionId": .string("agentmail.send"),
                ]),
                detail: "AgentMail send \(decision); no email sent.",
                root: dataRoot)
            return
        }

        if let existing = await AgentMailActions.succeededReceiptForApproval(rec.id, dataRoot: dataRoot) {
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: existing,
                detail: "AgentMail send receipt healed; email was not re-sent.",
                root: dataRoot)
            return
        }

        let result = await AgentMailActions.executeApprovedSend(from: rec, dataRoot: dataRoot)
        let status = Self.jsonString(result, "status") ?? "unknown"
        let detail: String
        if status == "failed" {
            let error = Self.jsonString(result, "error") ?? "failed"
            detail = "AgentMail send FAILED: \(error)"
        } else {
            detail = "AgentMail send \(status)."
        }
        try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
            id: rec.id,
            executedAction: result,
            detail: detail,
            root: dataRoot)
    }

    private struct ChatToolApprovalReplay: Sendable {
        let toolName: String
        let surface: String
        let input: [String: JSONValue]
        let sessionId: String?
        let telegramChatId: String?
        let verifiedUserId: String?
        let replyRoute: ChatToolSessionContext.ReplyRoute?
        let envelope: TurnEnvelope
    }

    private static func chatToolApprovalReplay(from rec: ApprovalRecord) -> ChatToolApprovalReplay? {
        guard case .object(let payload) = rec.payload else { return nil }
        let kind: String = {
            if case .string(let value)? = payload["kind"] { return value }
            return ""
        }()
        guard kind == "chat_tool_approval" || kind == "telegram_tool_approval" else {
            return nil
        }
        guard case .string(let toolName)? = payload["toolName"],
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .string(let surface)? = payload["surface"],
              !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .object(let input)? = payload["input"] else {
            return nil
        }
        let telegram: [String: JSONValue] = {
            guard case .object(let obj)? = payload["telegram"] else { return [:] }
            return obj
        }()
        let origin: [String: JSONValue] = {
            guard case .object(let obj)? = payload["origin"] else { return [:] }
            return obj
        }()
        let sessionId = Self.nonEmptyPayloadString(origin["sessionId"])
            ?? Self.nonEmptyPayloadString(telegram["sessionId"])
        let chatId = Self.nonEmptyPayloadString(origin["chatId"])
            ?? Self.nonEmptyPayloadString(telegram["chatId"])
        let verifiedUserId = Self.nonEmptyPayloadString(origin["userId"])
        let destinationId = Self.nonEmptyPayloadString(origin["destinationId"])
            ?? (surface == "telegram" ? chatId : nil)
        let threadId = Self.nonEmptyPayloadString(origin["threadId"])
            ?? Self.nonEmptyPayloadString(telegram["threadId"])
        let sourceKey = Self.nonEmptyPayloadString(origin["sourceKey"])
        let replyTo = Self.nonEmptyPayloadString(origin["replyTo"])
        let correlationId = Self.nonEmptyPayloadString(origin["correlationId"])
        let replyRoute: ChatToolSessionContext.ReplyRoute? = [
            destinationId, threadId, sourceKey, replyTo, correlationId,
        ].contains(where: { $0 != nil })
            ? ChatToolSessionContext.ReplyRoute(
                surface: Self.nonEmptyPayloadString(origin["surface"]) ?? surface,
                destinationId: destinationId,
                threadId: threadId,
                sourceKey: sourceKey,
                replyTo: replyTo,
                correlationId: correlationId
            )
            : nil
        return ChatToolApprovalReplay(
            toolName: toolName,
            surface: surface,
            input: input,
            sessionId: sessionId,
            telegramChatId: chatId,
            verifiedUserId: verifiedUserId,
            replyRoute: replyRoute,
            envelope: TurnEnvelope(
                surface: surface,
                agent: Self.nonEmptyPayloadString(origin["agent"]),
                verifiedChatId: chatId,
                verifiedUserId: verifiedUserId,
                deliveryRoute: replyRoute,
                declaredRemote: origin["declaredRemote"] == .bool(true) ? true : nil
            )
        )
    }

    private static func nonEmptyPayloadString(_ value: JSONValue?) -> String? {
        let raw: String?
        switch value {
        case .string(let s)?: raw = s
        case .int(let i)?: raw = String(i)
        case .double(let d)?: raw = Int(exactly: d.rounded(.towardZero)).map { String($0) }
        default: raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isRemoteChatApprovalSurface(_ surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isRemote
    }

    private func evolutionBridgeEnabledForApprovalReplay(surface: String) -> Bool {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == effects.telegramSurface {
            return effects.telegramIncludesEvolutionBridge
        }
        // Sol, 2026-09-15: `agent-bridge` is a remote surface, so this returned
        // false and an approved `self_install` / `evolution_*` replay reached a
        // DISABLED backend — the person clicked Approve and nothing happened.
        // Reaching this replay at all already means the approval record exists,
        // was resolved-approved for this exact tool and body, and was spent by
        // the executor; the peer authenticated with its own scoped credential.
        // That is the person's own decision, so it gets the real backend.
        if PeerTurnEffectPolicy.isPeerBridge(surface: surface) { return true }
        return !Self.isRemoteChatApprovalSurface(surface)
    }

    @discardableResult
    public func reconcileUnappliedChatToolApprovalExecutions(
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        records: [ApprovalRecord]? = nil,
        continuation: ChatApprovalContinuation? = nil
    ) async -> Set<String> {
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, envelope, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, envelope: envelope, prompt: prompt)
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        var failures: Set<String> = []
        let resolved = await Self.resolvedApprovalsForReconciliation(dataRoot: dataRoot, records: records)
        for rec in resolved where Self.chatToolApprovalReplay(from: rec) != nil {
            if Self.chatToolApprovalReplayNeedsExecution(rec) {
                NSLog("[approvalReconcile] reconciling eligible resolved chat tool approval "
                    + "\(rec.id) action=\(rec.action) decision=\(rec.decision ?? "?")")
                await applyResolvedChatToolApproval(from: rec, dataRoot: dataRoot, continuation: continuation)
            }
            // Execution truth and conversational continuity are separate
            // commits. Heal the latter too: an approved tool that ran before a
            // crash must still leave one resident tool receipt in the original
            // session so the next turn knows it completed and does not retry.
            if let refreshed = try? await inbox.get(rec.id) {
                if !(await ensureChatToolApprovalOutcomeReceipt(
                    from: refreshed, dataRoot: dataRoot, continuation: continuation)) {
                    failures.insert(rec.id)
                }
            } else {
                failures.insert(rec.id)
            }
        }
        return failures
    }

    public func reconcileUnappliedConnectorActionApprovals(
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        records: [ApprovalRecord]? = nil
    ) async {
        let resolved = await Self.resolvedApprovalsForReconciliation(dataRoot: dataRoot, records: records)
        let client = self
        for record in resolved
        where record.action.hasPrefix("connector.action.") && record.executedAction == nil {
            _ = await client.applyResolvedConnectorAction(from: record, dataRoot: dataRoot)
        }
    }

    public struct ConnectorActionApprovalReplay: Sendable {
        public let actionID: String
        public let connectorID: String
        public let surface: String
        public let input: [String: JSONValue]
    }

    public static func connectorActionApprovalReplay(from record: ApprovalRecord) -> ConnectorActionApprovalReplay? {
        guard record.action.hasPrefix("connector.action."),
              case .object(let payload) = record.payload,
              payload["kind"] == .string("connector_action_v1"),
              case .string(let actionID)? = payload["actionId"],
              record.action == "connector.action.\(actionID)",
              case .string(let connectorID)? = payload["connectorId"],
              case .string(let surface)? = payload["surface"],
              surface == "connector_action",
              case .object(let input)? = payload["input"] else {
            return nil
        }
        return ConnectorActionApprovalReplay(
            actionID: actionID,
            connectorID: connectorID,
            surface: surface,
            input: input
        )
    }

    /// Execute the exact bounded connector input carried by the approval. The
    /// return value controls visible-card archival: an uncertain or refused
    /// effect stays visible instead of presenting an approved card as done.
    private func applyResolvedConnectorAction(
        from record: ApprovalRecord,
        dataRoot: URL
    ) async -> Bool {
        guard record.status == "resolved", let decision = record.decision else { return false }
        guard decision == "approved" else {
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(record.action),
                    "status": .string(decision),
                ]),
                detail: "Connector action \(decision); no connector call ran.",
                root: dataRoot
            )
            return true
        }

        guard let replay = Self.connectorActionApprovalReplay(from: record),
              let descriptor = connectorActionDescriptors().first(where: {
                  $0.id == replay.actionID && $0.connectorId == replay.connectorID
              }) else {
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(record.action),
                    "status": .string("failed"),
                    "error": .string("approval has no valid bounded replay payload or registered executor"),
                ]),
                detail: "FAILED: connector approval has no valid bounded replay payload or registered executor; no connector call ran.",
                root: dataRoot
            )
            return false
        }

        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        switch await inbox.consumeApprovedEffect(
            id: record.id,
            digest: ApprovalInboxApprovedReplayVerifier.effectDigest(record.payload),
            action: replay.actionID,
            surface: replay.surface
        ) {
        case .spent:
            break
        case .alreadySpent:
            if (try? await inbox.get(record.id).executedAction) == nil {
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: record.id,
                    executedAction: .object([
                        "op": .string("connector_action_replay"),
                        "action": .string(replay.actionID),
                        "status": .string("outcome_unknown"),
                        "error": .string("execution already started; automatic replay refused"),
                    ]),
                    detail: "Connector action may have started before interruption; it was not replayed automatically.",
                    root: dataRoot
                )
            }
            return false
        case .unavailable:
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(replay.actionID),
                    "status": .string("blocked"),
                    "error": .string("durable execution fence unavailable"),
                ]),
                detail: "Connector action was blocked before execution because its durable replay fence was unavailable.",
                root: dataRoot
            )
            return false
        }

        do {
            let receipt = try await effects.runConnectorAction(
                descriptor: descriptor,
                dryRun: false,
                input: replay.input,
                approvedReplayApprovalID: record.id,
                dataRoot: dataRoot
            )
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(replay.actionID),
                    "status": .string(receipt.status),
                    "receiptId": .string(receipt.id),
                ]),
                detail: "Connector action \(replay.actionID) finished after approval with status \(receipt.status).",
                root: dataRoot
            )
            return ["completed", "succeeded", "ok"].contains(
                receipt.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        } catch {
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(replay.actionID),
                    "status": .string("outcome_unknown"),
                    "error": .string(String(describing: error)),
                ]),
                detail: "Connector action did not produce a verified receipt after approval; outcome is unknown and it was not retried.",
                root: dataRoot
            )
            return false
        }
    }

    /// Recover only the historical failure where a resolved persona approval
    /// was rejected before the inner tool ran because replay asked the dynamic
    /// persona guard for a second approval without a filer. Other failed side
    /// effects remain terminal: blindly retrying those could duplicate work.
    private static func chatToolApprovalReplayNeedsExecution(_ rec: ApprovalRecord) -> Bool {
        if rec.executedAction == nil { return true }
        guard rec.status == "resolved",
              rec.decision == "approved",
              let replay = Self.chatToolApprovalReplay(from: rec),
              replay.toolName == "persona_write" || replay.toolName == "persona_append_section",
              case .object(let executed)? = rec.executedAction,
              executed["op"] == .string("chat_tool_approval_replay"),
              executed["status"] == .string("failed"),
              case .string(let error)? = executed["error"]
        else { return false }
        return error.contains("approval required, no filer is available on this noninteractive surface")
            && error.contains("source=\(PersonaWriteGuard.autonomySource)")
    }

    public func applyResolvedChatToolApproval(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        continuation: ChatApprovalContinuation? = nil
    ) async {
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, envelope, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, envelope: envelope, prompt: prompt)
        }
        // Recovery may annotate an abandoned durable spend, but must never
        // annotate a spend whose executor is still awaiting its verifier.
        let owners = ChatToolApprovalExecutionOwners.shared
        guard owners.acquire(root: dataRoot, approvalID: rec.id) else { return }
        defer { owners.release(root: dataRoot, approvalID: rec.id) }

        guard rec.status == "resolved",
              let decision = rec.decision,
              let replay = Self.chatToolApprovalReplay(from: rec) else { return }

        guard decision == "approved" else {
            let op = decision == "denied"
                ? "chat_tool_approval_denied"
                : "chat_tool_approval_canceled"
            let outcome: ToolNotRunStatus = decision == "denied" ? .personDenied : .approvalCanceled
            if replay.toolName == "agent_message" {
                do {
                    _ = try AgentConversationStore(dataRoot: dataRoot).records()
                } catch {
                    NSLog("[approvals] conversation decision write failed for \(rec.id): \(error)")
                    return
                }
            }
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: outcome.reporting(.object([
                    "op": .string(op),
                    "tool": .string(replay.toolName),
                    "surface": .string(replay.surface),
                ])),
                detail: outcome.sentence(),
                root: dataRoot)
            if let refreshed = try? await SwiftNativeApprovalInbox(root: dataRoot).get(rec.id) {
                await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot, continuation: continuation)
            }
            return
        }

        // Injection approvals have their own capability-specific durable spend
        // inside InjectionApprovalVerifier. Every other generic approved tool
        // spends here, immediately before dispatch. A crash can therefore
        // leave an unknown outcome, but it cannot turn one approval into a
        // second effect after restart.
        if !MacInjectionToolNames.isInjectionTool(replay.toolName) {
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            let digest = ApprovalInboxApprovedReplayVerifier.effectDigest(rec.payload)
            switch await inbox.consumeApprovedEffect(
                id: rec.id,
                digest: digest,
                action: replay.toolName,
                surface: replay.surface
            ) {
            case .spent:
                break
            case .alreadySpent:
                if (try? await inbox.get(rec.id).executedAction) == nil {
                    try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object([
                            "op": .string("chat_tool_approval_replay"),
                            "tool": .string(replay.toolName),
                            "surface": .string(replay.surface),
                            "status": .string("outcome_unknown"),
                            "error": .string("execution already started; automatic replay refused"),
                        ]),
                        detail: "\(replay.toolName) may have started before interruption; it was not replayed automatically.",
                        root: dataRoot
                    )
                }
                if let refreshed = try? await inbox.get(rec.id) {
                    await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot, continuation: continuation)
                }
                return
            case .unavailable:
                if (try? await inbox.get(rec.id).executedAction) == nil {
                    try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object([
                            "op": .string("chat_tool_approval_replay"),
                            "tool": .string(replay.toolName),
                            "surface": .string(replay.surface),
                            "status": .string("blocked"),
                            "error": .string("durable execution fence unavailable"),
                        ]),
                        detail: "\(replay.toolName) was blocked before execution because its durable replay fence was unavailable.",
                        root: dataRoot
                    )
                }
                if let refreshed = try? await inbox.get(rec.id) {
                    await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot, continuation: continuation)
                }
                return
            }
        }

        do {
            // Raw built-in bridge approvals retain their original file and
            // external-MCP envelope after the person resolves the card.
            let isBuiltInBridge = ["codex-bridge", "claude-bridge"].contains(
                replay.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
            let tools = effects.toolDispatchClient(
                includeEvolutionBridge: evolutionBridgeEnabledForApprovalReplay(
                    surface: replay.surface
                ),
                denyExternalMcp: isBuiltInBridge,
                enforceAppAutonomy: false
            )
            let trust = SingleApprovedToolAutonomyResolver(
                dataRoot: dataRoot,
                approvedTool: replay.toolName,
                approvedSurface: replay.surface
            )
            let gated = makeGatedToolDispatchClient(
                tools: tools,
                fileAccess: isBuiltInBridge ? "read_only" : "auto",
                approvalFiler: nil,
                dataRoot: dataRoot,
                trust: trust,
                verifiedSessionId: replay.sessionId,
                approvedReplay: ApprovedChatToolReplay(
                    approvalID: rec.id,
                    tool: replay.toolName,
                    surface: replay.surface,
                    input: replay.input,
                    verifiedSessionID: replay.sessionId,
                    verifiedChatID: replay.telegramChatId,
                    verifiedUserID: replay.verifiedUserId
                )
            )
            // Approval replay is a fresh detached dispatch, not the original
            // provider turn. Rehydrate only the approved lazy tool for this
            // dispatch so the lazy gate cannot answer `not_loaded`, while no
            // sibling tool receives an accidental capability grant.
            let result = try await LLMCallContext.$turnActiveTools.withValue([replay.toolName]) {
                try await ChatToolSessionContext.$commandSignatureVerified.withValue(true) {
                    try await ChatToolSessionContext.$verifiedChatId.withValue(replay.telegramChatId) {
                        try await ChatToolSessionContext.$verifiedUserId.withValue(replay.verifiedUserId) {
                            // ROUTE THROUGH withReplyRoute, NOT $replyRoute ALONE.
                            // The replay's trace rows carried surface and session
                            // but no destinationId/threadId, so the thread this
                            // approval came from was unrecoverable afterwards.
                            // A nil route has nothing to mirror — unbound branch.
                            let dispatch: @Sendable () async throws -> JSONValue = {
                                try await ChatToolSessionContext
                                    .$verifiedSessionId.withValue(replay.sessionId) {
                                        let send: @Sendable () async throws -> JSONValue = {
                                            try await gated.dispatch(tool: replay.toolName, input: replay.input, surface: replay.surface)
                                        }
                                        if replay.toolName == "agent_message" {
                                            let exactProtocol = if case .object(let payload) = rec.payload {
                                                payload["agentExactProtocol"] == .bool(true)
                                            } else { false }
                                            return try await AgentConversationApproval.replay(id: rec.id, dataRoot: dataRoot,
                                                exactProtocol: exactProtocol, perform: send)
                                        }
                                        return try await send()
                                    }
                            }
                            if let route = replay.replyRoute {
                                return try await ChatToolSessionContext
                                    .withReplyRoute(route) {
                                        try await dispatch()
                                    }
                            }
                            return try await dispatch()
                        }
                    }
                }
            }
            let receipt = Self.chatToolApprovalExecutionReceipt(
                toolName: replay.toolName, surface: replay.surface, result: result)
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: receipt.action,
                detail: "\(replay.toolName) executed after approval: \(receipt.preview)",
                root: dataRoot)
            if let refreshed = try? await SwiftNativeApprovalInbox(root: dataRoot).get(rec.id) {
                await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot, continuation: continuation)
            }
        } catch {
            NSLog("[approvals] approved chat tool replay failed for \(rec.id): \(error)")
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("chat_tool_approval_replay"),
                    "tool": .string(replay.toolName),
                    "surface": .string(replay.surface),
                    "status": .string("failed"),
                    "error": .string("\(error)"),
                ]),
                detail: "\(replay.toolName) approved replay FAILED: \(error.localizedDescription)",
                root: dataRoot)
            if let refreshed = try? await SwiftNativeApprovalInbox(root: dataRoot).get(rec.id) {
                await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot, continuation: continuation)
            }
        }
    }

    /// Persist exactly one compact tool receipt into the conversation that
    /// originated a generic approval, then claim one follow-up turn on
    /// that same surface. A refused turn leaves the receipt as recovery evidence.
    @discardableResult
    public func ensureChatToolApprovalOutcomeReceipt(
        from record: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        continuation: ChatApprovalContinuation? = nil
    ) async -> Bool {
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, envelope, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, envelope: envelope, prompt: prompt)
        }
        // Hold ownership through delivery and settlement. A concurrent scan
        // must not retire a live claim and make its row evictable mid-turn.
        let owners = ChatToolApprovalExecutionOwners.continuations
        guard owners.acquire(root: dataRoot, approvalID: record.id) else { return true }
        defer { owners.release(root: dataRoot, approvalID: record.id) }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let rec: ApprovalRecord
        do {
            rec = try await inbox.get(record.id)
        } catch {
            NSLog("[approvals] continuation record read failed: \(error)")
            return false
        }
        guard rec.status == "resolved",
              let decision = rec.decision,
              let replay = Self.chatToolApprovalReplay(from: rec),
              let executedAction = rec.executedAction,
              let safeSessionID = NativeAgentChatSessionID.normalizedPathComponent(replay.sessionId)
        else { return true }

        // Page-owned ephemeral requests retain their result on the approval
        // itself. There is no conversation to append to or wake with an LLM.
        if replay.surface == "connector_action",
           safeSessionID.hasPrefix("ephemeral:connector_action:") { return true }

        // A durable queued delivery survives downtime. Historical conversations
        // without one remain bounded. Existing claims settle without resending.
        let continueConversation = SwiftNativeApprovalInbox.continuationIsPending(rec)

        // Missing evidence is NOT a success. An annotation with no status and no
        // retained class tells us only that the replay ran; the outcome is
        // unconfirmed and every sentence below says so.
        let recordedStatus = Self.jsonString(executedAction, "status")
        let normalizedStatus = (recordedStatus ?? "outcome_unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resultClass: ChatToolOutcome.ExactResultClass = {
            if let raw = Self.jsonString(executedAction, "resultClass"),
               let recorded = ChatToolOutcome.ExactResultClass(rawValue: raw) {
                return recorded
            }
            // Legacy execution annotations retained status, not the original
            // result envelope. That typed field is the available evidence;
            // diagnostic prose and a clipped preview cannot reconstruct it.
            guard let status = recordedStatus else { return .unknown }
            return ChatToolOutcome.exactResultClass(.object(["status": .string(status)]))
        }()
        // THE SAME TRUTH THE ENVELOPE CARRIES (2026-09-13). Spelling-matching
        // the status word got this backwards in both directions: an
        // `outcome_unknown` annotation read ok=false (a failure that never
        // happened — the word is in the deny list) while `timed_out` read
        // ok=true (a success that never happened — the word is not). The
        // result CLASS is the evidence; derive from it, as the envelope does.
        // Cancelled and unknown get NO bit at all — unconfirmed is neither.
        let ok: Bool? = {
            switch resultClass {
            case .succeeded: return true
            case .failed, .timeout: return false
            case .cancelled, .unknown: return nil
            }
        }()
        let resultPreview = (Self.jsonString(executedAction, "resultPreview")
            ?? Self.jsonString(executedAction, "error")).map(TurnTraceRedactor.redactText)
        let outcomeDescription: String
        switch resultClass {
        case .unknown: outcomeDescription = "Outcome unconfirmed"
        case .cancelled: outcomeDescription = "Cancelled"
        case .timeout: outcomeDescription = "Timed out"
        case .failed: outcomeDescription = "Failed"
        case .succeeded: outcomeDescription = "Completed"
        }
        let statusSummary = decision == "approved"
            ? "\(outcomeDescription) after approval (\(rec.id)); status=\(normalizedStatus)."
            : "Approval \(rec.id) was \(decision). The tool did not run; status=\(normalizedStatus)."
        let prose = resultPreview.map { "\(statusSummary) Result: \($0)" } ?? statusSummary
        // 2026-09-13, the 0.4.12 drive: a bot_create that failed after Approve
        // showed NOTHING in the transcript — the failure lived in metadata
        // alone. Both readers (ToolPillPresentation.outcome and the shell row)
        // classify a tool result by PARSING resultSummary as the dispatch
        // envelope, exactly as appendToolMessage writes it; prose parses to
        // nothing and renders as "completion not confirmed". Write the envelope
        // instead, with the prose kept inside it. The preview is already
        // redacted — no raw payload joins it.
        // The envelope is built from the PRESERVED result class, never from the
        // coarse `ok` bit: `timed_out` is not a success, and a class the pill
        // has no state for (cancelled, unknown) must read as unconfirmed rather
        // than as a failure. These status strings round-trip: each one classifies
        // back to the same ExactResultClass it came from.
        var envelope: [String: JSONValue] = ["detail": .string(prose)]
        if case .object(let execution) = executedAction,
           let notRun = execution["not_run_status"] {
            envelope["not_run_status"] = notRun
        }
        let failureDetail = JSONValue.string(resultPreview ?? outcomeDescription)
        switch resultClass {
        case .succeeded:
            envelope["status"] = .string("succeeded")
            envelope["ok"] = .bool(true)
        case .failed:
            envelope["status"] = .string("failed")
            envelope["ok"] = .bool(false)
            envelope["error"] = failureDetail
        case .timeout:
            envelope["status"] = .string("timed_out")
            envelope["ok"] = .bool(false)
            envelope["error"] = failureDetail
        case .cancelled:
            // No "ok" and no "error": the pill reads it as unconfirmed, which is
            // the truth — nothing failed, the call never finished.
            envelope["status"] = .string("cancelled")
        case .unknown:
            // The recorded status round-trips back to .unknown; keep the exact
            // word ("queued", "outcome_unknown") rather than flattening it.
            envelope["status"] = .string(normalizedStatus)
        }
        let summary = (try? JSONValue.object(envelope).serialize(pretty: false)) ?? prose
        // Wave 2 #8: the steps queued for after this card, read fresh (a
        // decline drops them here), and the steer the card and they carried.
        let resume = await HerScreen.resume(card: rec.id, decision: decision, completed: resultClass == .succeeded,
                                            dataRoot: dataRoot)
        let payload: [String: JSONValue] = if case .object(let fields) = rec.payload { fields } else { [:] }
        // No record at all: a card filed before cards kept one (`unrecorded`).
        let carried = PeerDataTaint.steer(in: payload["peer"])
        let steer = PeerDataTaint(restoring: carried.sources + resume.sources, elevated: carried.elevated + resume.elevated)
        // The filing turn's file access; nil for an older card (the host's chat default).
        let fileAccess: String? = if case .string(let mode)? = payload["fileAccess"] { mode } else { nil }
        do {
            let legacyStartedAt = try await inbox.writeChatReceipt(
                approvalID: rec.id, sessionID: safeSessionID, toolName: replay.toolName,
                surface: replay.surface, summary: summary, resultClass: resultClass.rawValue,
                ok: ok, resultPreview: resultPreview,
                returnedID: Self.jsonString(executedAction, "returned_id"),
                effects: Self.jsonString(executedAction, "effects"),
                recoveredAt: continueConversation ? nil : (rec.resolvedAt ?? rec.createdAt))
            let abandonedClaim: Bool = {
                guard case .object(let state)? = rec.chatContinuation else { return false }
                return state["started"] != nil && state["done"] != .bool(true)
            }()
            // The receipt is durable before any claim becomes evictable. A
            // prior process may have delivered already, so never resend it.
            if abandonedClaim || legacyStartedAt != nil {
                if legacyStartedAt != nil {
                    _ = try await inbox.annotateChatContinuation(
                        rec.id, done: false, legacyStartedAt: legacyStartedAt)
                }
                _ = try await inbox.annotateChatContinuation(rec.id, done: true, settlement: "interrupted")
            } else if continueConversation,
               try await inbox.annotateChatContinuation(
                rec.id, done: false, clearQueuedDelivery: true) {
                var settlement = "completed"
                do {
                    try await PeerDataTaint.$current.withValue(steer) {
                        try await ChatToolSessionContext.$fileAccess.withValue(fileAccess) {
                        try await continuation(dataRoot, safeSessionID, replay.envelope, """
                            The approval for \(replay.toolName) was decided. This is its receipt, not a new user request:
                            \(summary)\(resume.text.isEmpty ? "" : "\n" + resume.text)
                            Verify the outcome as needed, then briefly tell the user what happened, including any failure or uncertainty. Do not repeat the approved action or ask to approve this card again.
                            """)
                        }
                    }
                } catch {
                    settlement = "failed"
                    NSLog("[approvals] continuation failed for \(rec.id); receipt retained: \(error)")
                }
                _ = try await inbox.annotateChatContinuation(rec.id, done: true, settlement: settlement)
            }
        } catch {
            NSLog("[approvals] outcome receipt or continuation failed for \(rec.id): \(error)")
            return false
        }
        // The row is on disk; nothing re-read it. Resolving an approval refreshes
        // the approvals list and the badges only, so the open transcript still
        // showed the card's "Done." and never this receipt (2026-09-13). This is
        // the same edge a remote turn posts — ChatView re-reads the active
        // session's messages from disk and the tool result appears.
        await effects.chatTurnCompleted(sessionID: replay.sessionId)
        return true
    }

    public typealias ChatApprovalContinuation = @Sendable (URL, String, TurnEnvelope, String) async throws -> Void

    /// The follow-up after User decides runs with her normal tools (Wave 2 #8),
    /// under the steer the card and its queued steps carried: the caller binds
    /// it as `PeerDataTaint.current`, and the host turn keeps it.
    public func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String) async throws {
        try await effects.continueChatToolApproval(dataRoot: dataRoot, sessionID: sessionID, envelope: envelope, prompt: prompt)
    }

    /// The actual replay writer's projection, shared with injected fixtures.
    /// Preserve outcome and receipt fields from the complete result before the
    /// privacy-safe preview is clipped; never persist the full result.
    public static func chatToolApprovalExecutionReceipt(
        toolName: String,
        surface: String,
        result: JSONValue
    ) -> (action: JSONValue, preview: String) {
        // Approval records sync across surfaces. Tool-specific redaction must
        // remove literal values typed by ax_act before general redaction/caps.
        let redactedResult = MacInjectionResultRedaction.redacted(tool: toolName, result: result)
        let returnedID = SessionHistoryPromptRenderer.returnedIdentifier(redactedResult)
            .map(TurnTraceRedactor.redactText)
        let resultEffects = SessionHistoryPromptRenderer.receiptField("effects", in: redactedResult).map {
            String(SessionHistoryPromptRenderer.receiptValue(TurnTraceRedactor.redactValue($0)).prefix(512))
        }
        let preview = Self.approvalResultPreview(redactedResult)
        // The outcome is derived from the COMPLETE original result and retained
        // here, before the preview clips it. A result without a `status` field
        // still carries evidence (ok/success/error); it is never assumed to have
        // succeeded, and an unreadable one is recorded as unconfirmed.
        let resultClass = ChatToolOutcome.exactResultClass(result)
        let canonicalStatus: String = {
            switch resultClass {
            case .succeeded: return "succeeded"
            case .failed: return "failed"
            case .cancelled: return "cancelled"
            case .timeout: return "timed_out"
            case .unknown: return "outcome_unknown"
            }
        }()
        var action: [String: JSONValue] = [
            "op": .string("chat_tool_approval_replay"),
            "tool": .string(toolName),
            "surface": .string(surface),
            "status": .string(Self.jsonString(result, "status") ?? canonicalStatus),
            "resultClass": .string(resultClass.rawValue),
            "resultPreview": .string(preview),
        ]
        if let returnedID { action["returned_id"] = .string(returnedID) }
        if let resultEffects { action["effects"] = .string(resultEffects) }
        if toolName == "agent_connect" || toolName == "agent_message" {
            action["contactResult"] = Self.agentContactReceipt(TurnTraceRedactor.redactValue(result))
        }
        return (.object(action), preview)
    }

    public static func agentContactReceipt(_ result: JSONValue) -> JSONValue {
        guard case .object(let value) = result else { return .null }
        var display: [String: JSONValue] = [:]
        for key in ["status", "reply", "detail", "reason", "error", "connection_check", "connection_reply_received",
                    "sent", "completed", "terminal", "needs_input", "needs_authentication", "task_id",
                    "message_id", "conversation_id", "run_id", "local_request_id", "read_with"] {
            if case .string(let text)? = value[key] {
                display[key] = .string(String(text.prefix(4096)) + (text.count > 4096 ? "\nAnswer shortened." : ""))
            } else if let item = value[key] { display[key] = item }
        }
        if let probe = value["probe"] { display["probe"] = agentContactReceipt(probe) }
        if let remote = value["remote_evidence"] { display["remote_evidence"] = agentContactReceipt(remote) }
        return .object(display)
    }

    private static func approvalResultPreview(_ value: JSONValue, limit: Int = 1400) -> String {
        let redacted = TurnTraceRedactor.redactValue(value)
        let raw = (try? redacted.serialize(pretty: false)) ?? String(describing: redacted)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }

    /// Browser re-fire path with the at-most-once navigation cap.
    /// `runsPath`/`dataRoot` are injectable for tests; production callers
    /// use the live browser store + approval inbox.
    public func reconcileResolvedBrowserRun(
        from rec: ApprovalRecord,
        runsPath: URL = SwiftNativeBrowserClient.defaultClient().runsPath,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        guard rec.action == "browser.open_url",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        if decision == "approved" {
            do {
                if case .object(let payload) = rec.payload,
                   case .string(let runID)? = payload["runId"] ?? payload["run_id"],
                   let run = try await Self.terminalBrowserRun(runID: runID, runsPath: runsPath) {
                    // Navigation already happened (the run persisted in a
                    // terminal state before the crash); only the annotation
                    // write was lost. Heal it WITHOUT re-opening the URL.
                    let status = Self.jsonString(run, "status") ?? "succeeded"
                    try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: run,
                        detail: "Browser navigation \(status) "
                            + "(annotation healed by launch reconcile; URL not re-opened)",
                        root: dataRoot)
                    await effects.observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
                    return
                }
                try await effects.executeApprovedBrowserRun(from: rec)
            } catch {
                NSLog("[approvalReconcile] browser re-run failed for \(rec.id): \(String(describing: error))")
            }
        } else {
            do {
                try await effects.finishRejectedBrowserRun(
                    from: rec, status: decision == "denied" ? "denied" : "canceled")
            } catch {
                NSLog("[approvalReconcile] browser rejected-finish failed for \(rec.id): \(String(describing: error))")
            }
        }
    }

    /// The persisted run for `runID` iff its status is terminal. A
    /// `waiting_approval` row (persisted at approval-creation time) is NOT
    /// terminal — the navigation never ran and a reconcile may execute it.
    public static func terminalBrowserRun(runID: String, runsPath: URL) async throws -> JSONValue? {
        guard !runID.isEmpty else { return nil }
        let raw = try await SwiftNativePersistenceCore().readJSON(runsPath, ifMissing: .array([]))
        guard case .array(let rows) = raw else { return nil }
        let terminal: Set<String> = ["succeeded", "failed", "denied", "canceled"]
        for row in rows where Self.jsonString(row, "id") == runID {
            if let status = Self.jsonString(row, "status"), terminal.contains(status) {
                return row
            }
            return nil
        }
        return nil
    }

    /// Resumes an execution blocked on a step approval (executor port,
    /// 2026-06-10 — mirror of applyResolvedREMProposal's shape). Approved →
    /// WorkshopExecutorLoop.resumeAfterApproval actually EXECUTES the blocked
    /// step (W6: resume must never mark-without-executing) and continues the
    /// plan; denied → step rejected + execution failed (also via the
    /// executor, so the timeline + step record stay daemon-shaped). Every
    /// completed branch annotates the approval record executed/FAILED. Capacity
    /// deferral leaves the resolved approval unannotated for the executor drain. On an
    /// infrastructure failure the blocked step's approval_id claim is
    /// CLEARED so a later pass can re-stage a fresh approval instead of
    /// dead-ending on a stamp that no longer matches anything.
    private func applyResolvedWorkshopStep(from rec: ApprovalRecord) async {
        // Self-defensive: only ever acts on a resolved workshop-step record,
        // in EITHER vocabulary — a step blocked before the 0.3.8 upgrade is
        // resolved by the new binary and must still execute (P2-4).
        guard ExecutionEventVocabulary.matches(rec.action, WorkshopStepApprovalAction.canonical),
              rec.status == "resolved",
              let decision = rec.decision else { return }
        // P2-2 de-mission: the stager writes "execution_id"; this reader
        // resolves through the shared vocabulary (canonical first, legacy
        // fallback). The fallback is PERMANENT — an approval staged by an older
        // binary and resolved by this one must still execute, and
        // requests.json is never rewritten.
        guard case .object(let payload) = rec.payload,
              let executionId = WorkshopStepApprovalPayload.executionId({ key in
                  if case .string(let s)? = payload[key] { return s }
                  return nil
              }),
              case .string(let stepId)? = payload["step_id"], !stepId.isEmpty else {
            NSLog("[workshopStep] missing execution_id/step_id on approval \(rec.id)")
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["error": .string("missing execution_id/step_id")]),
                detail: "Desk step \(decision) FAILED: payload carries no execution_id/step_id")
            return
        }
        // Prefer the SAME executor INSTANCE the background drain loop uses
        // (WorkshopExecutorRef.shared). The fallback builds a fresh instance
        // only when the ref isn't configured yet — and at cold start it CAN be
        // nil here, because this approval-reconcile path and the loop-assembly
        // that configures the ref are independent detached launch tasks with no
        // ordering guarantee (NativeAgentApp.swift). The fallback is safe REGARD-
        // LESS: the executor's startup orphan-reclaim barrier is memoized
        // per-DATA-ROOT (not per-instance), so a fallback instance and the drain
        // instance share ONE reclaim — the drain's first reclaim can never fail
        // an execution this resume flipped blocked→running (gpt-5.5 re-review). The
        // shared instance is still preferred to keep one actor serializing all
        // Workshop work. makeWorkshopExecutor wires the same LLM/tool/stager
        // closures the drain uses.
        let executor = effects.workshopExecutor()
        // FROZEN WIRE — deliberate keep, do NOT de-mission these (P2-8 owns any
        // future move).
        //
        // The `"missionId"` keys and `mission_step_*` `op` labels here and in
        // the executor's approved-step annotation are PERSISTED AUDIT ANNOTATIONS: they are written into
        // the approval record's `executedAction` and land in
        // `workflows/approvals/requests.json`, which is append-and-amend and is
        // never rewritten. A rename here does not migrate the ~thousands of
        // rows already on disk — it forks the audit vocabulary so a single
        // query can no longer answer "what happened to this approval", which is
        // the entire point of the annotation. `missionStatus` is in the same
        // class.
        //
        // These are ANNOTATIONS, not a read seam: nothing branches on them, so
        // there is no fallback to widen and no correctness risk in leaving them
        // alone. When P2-8 schedules the move it takes the reader, the writer,
        // and a fixture of live rows together.
        do {
            switch decision {
            case "approved":
                _ = try await executor.resumeAfterApproval(
                    executionId: executionId, stepId: stepId, approved: true, approvalId: rec.id)
            case "denied":
                let record = try await executor.resumeAfterApproval(
                    executionId: executionId, stepId: stepId, approved: false, approvalId: rec.id)
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("mission_step_reject"),
                        "missionId": .string(executionId),
                        "stepId": .string(stepId),
                        "missionStatus": .string(record.status),
                    ]),
                    detail: "Desk step denied — step rejected; Desk execution now \(record.status)")
            default: // canceled — leave the Workshop execution blocked; clear the claim
                // so a later executor pass can re-stage a fresh approval.
                await Self.clearWorkshopStepApprovalClaim(executionId: executionId, stepId: stepId)
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("mission_step_cancel"),
                        "missionId": .string(executionId),
                        "stepId": .string(stepId),
                    ]),
                    detail: "Desk step approval canceled — claim cleared; Desk execution stays blocked")
            }
        } catch WorkshopExecutionError.approvalDeferred {
            // Preserve the resolved decision and approval_id. Capacity-opening
            // execution events wake the drain, which retries this exact approval.
            return
        } catch WorkshopExecutionError.staleApproval(let detail) {
            // gpt-5.5 executor-port blocker #3 (2026-06-10): stale card —
            // the execution is no longer blocked_on_approval (cancelled/
            // failed/completed since the card was staged). The executor
            // refused to run the step; annotate the approval record
            // honestly. Do NOT clear the claim (the execution is not coming
            // back to this approval) and do NOT report a generic failure.
            NSLog("[workshopStep] \(decision) skipped for \(executionId)/\(stepId): \(detail)")
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("mission_step_stale"),
                    "missionId": .string(executionId),
                    "stepId": .string(stepId),
                ]),
                detail: "Desk step \(decision) — \(detail)")
        } catch {
            NSLog("[workshopStep] \(decision) failed for \(executionId)/\(stepId): \(error)")
            // The approval record is already terminal; a stamped-but-
            // unresumed step would dead-end (resume guards reject a stale
            // approval_id). Clear the claim so re-staging works (mirror of
            // the REM clearApprovalStamp failure path).
            await Self.clearWorkshopStepApprovalClaim(executionId: executionId, stepId: stepId)
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "missionId": .string(executionId),
                    "stepId": .string(stepId),
                    "error": .string("\(error)"),
                ]),
                detail: "Desk step \(decision) FAILED: \(error.localizedDescription) — "
                    + "claim cleared; a later executor pass can re-stage it")
        }
    }

    /// Clear the approval_id stamp on a blocked step record (execution.json,
    /// whole RMW under the cross-process flock) so a future stage isn't
    /// rejected by the resume guard's approval_id mismatch check.
    private static func clearWorkshopStepApprovalClaim(executionId: String, stepId: String) async {
        let path = ExecutionRecordFile.resolve(
            in: PersistenceCore.defaultDataRoot()
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("executions", isDirectory: true)
                .appendingPathComponent(executionId, isDirectory: true))
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                let raw = try await persistence.readJSON(path, ifMissing: .null)
                guard case .object(var obj) = raw,
                      case .array(var steps)? = obj["steps_completed"] else { return }
                var changed = false
                for idx in steps.indices {
                    guard case .object(var sr) = steps[idx],
                          case .string(let sid)? = sr["step_id"], sid == stepId,
                          case .string(let st)? = sr["status"], st == "blocked_on_approval" else { continue }
                    sr["approval_id"] = .string("")
                    steps[idx] = .object(sr)
                    changed = true
                }
                guard changed else { return }
                obj["steps_completed"] = .array(steps)
                try await persistence.writeJSON(.object(obj), to: path)
            }
        } catch {
            NSLog("[workshopStep] claim clear failed for \(executionId)/\(stepId): \(error)")
        }
    }

    public func resolveApproval(
        id: String,
        decision: String,
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui")
    ) async throws -> ApprovalRecord {
        // F6 (eval E06 fix-2): unify on the SwiftNativeApprovalInbox actor
        // (Modules/.../ApprovalInbox), which reads/writes
        // <dataRoot>/workflows/approvals/requests.json under flock. The
        // prior R-M-W in this method targeted <dataRoot>/approvals/requests.json
        // — a different file from the one the LIST path (ApprovalInbox + the
        // list helper at L9637) reads from, so resolve writes never landed
        // where the UI was looking.
        let inbox = SwiftNativeApprovalInbox(
            root: dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
        )
        let decisionEnum: ApprovalDecision
        switch decision {
        case "approve", "approved": decisionEnum = .approved
        case "deny", "denied", "reject", "rejected": decisionEnum = .denied
        case "cancel", "canceled": decisionEnum = .canceled
        default:
            throw NSError(domain: "NativeAgentApprovals", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "unknown decision verb: \(decision)"
            ])
        }
        let rec = try await inbox.resolve(
            id,
            decision: decisionEnum,
            provenance: provenance
        )
        var shouldArchiveVisibleCard = true
        if rec.action == "browser.open_url" {
            if decisionEnum == .approved {
                try await effects.executeApprovedBrowserRun(from: rec)
            } else {
                try await effects.finishRejectedBrowserRun(from: rec, status: decisionEnum == .denied ? "denied" : "canceled")
            }
        } else if rec.action == "self_improvement.apply", decisionEnum == .approved {
            await applyApprovedSelfImprovement(from: rec)
        } else if rec.action == "rem.proposal" {
            // No decision filter: deny ACTS too (tombstone + status flip),
            // and cancel clears the staging stamp. The executor self-guards.
            await applyResolvedREMProposal(from: rec)
        } else if ExecutionEventVocabulary.matches(rec.action, WorkshopStepApprovalAction.canonical) {
            // Executor port (2026-06-10): approve EXECUTES the blocked step
            // and continues the execution; deny rejects the step and fails the
            // execution; cancel clears the claim. The executor self-guards.
            await applyResolvedWorkshopStep(from: rec)
        } else if rec.action == "memory.repair" {
            // U3 wave-1 item 3: approve applies the one-shot repair (backup
            // first, store's own write path); deny leaves the store
            // untouched; cancel clears the staging stamp so it re-stages.
            // The executor self-guards. NOTE the crash window: resolve
            // persisted the record terminal ABOVE — a crash before this
            // executor finishes is healed by the on-launch
            // reconcileUnappliedMemoryRepairs pass.
            await MemoryApprovalTransactions.applyResolvedMemoryRepair(from: rec)
        } else if rec.action == MemoryKindBackfill.action {
            // U3 wave-2 item 5: approve stamps the LLM-proposed kinds
            // through the store's own write path (content-hash stale
            // guard); deny leaves rows untouched (never re-proposed);
            // cancel clears the staging stamp so the next launch
            // re-stages. Self-guarding; crash window healed by the
            // on-launch reconcileUnappliedKindBackfills pass.
            await MemoryApprovalTransactions.applyResolvedKindBackfill(from: rec)
        } else if rec.action == MemoryConsolidationGate.approvalAction {
            // U3 wave-2 item 7: approve applies the staged candidate-store
            // swap (atomic transaction, live backed up first). reconcile()
            // re-reads the approval record itself and refuses non-approved
            // ones, and it also cleans denied/orphaned candidates — so it
            // runs on every decision (rem.proposal pattern), not just
            // approve. Crash window healed by the same reconcile at launch
            // and at the start of every gated consolidation.
            _ = await MemoryConsolidationGate.reconcile(
                dataRoot: PersistenceCore.defaultDataRoot())
        } else if rec.action == SelfEvolutionApprovalExecutor.selfEvolutionAction {
            // U2b wave 2: approve runs the green-candidate-gated promote and
            // stops at the systemRebuild boundary (annotated deferred —
            // op evolution_install_deferred — while the per-action flag is
            // off; the launch reconcile resumes the install once the gate
            // opens); deny marks the proposal denied (never
            // re-proposed); cancel leaves it staged for a fresh card. The
            // executor self-guards and annotates every terminal; crash
            // window healed by reconcileUnappliedSelfEvolution at launch.
            // NEVER auto-approved: this branch only runs from an explicit
            // human resolve (no auto-approve path consults evolution cards).
            await SelfEvolutionApprovalExecutor.applyResolvedSelfEvolution(from: rec, deps: effects.selfEvolutionDependencies())
        } else if rec.action == SwiftNativeApprovalInbox.procedureExactActivationApprovalAction {
            await Self.applyResolvedProcedureExactActivation(
                from: rec,
                dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
            )
        } else if rec.action == "skill.proposal" {
            // The procedural lane that filed these is retired (skills-as-code
            // 4b): an old card resolves with a result line, never silently.
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id, executedAction: .object(["op": .string("skill_proposal_retired")]),
                detail: "The old skill-proposal flow is retired; nothing was saved. Agent writes skills herself now.")
        } else if rec.action == SwiftNativeApprovalInbox.skillScriptInstallAction {
            await applyResolvedSkillScriptInstall(from: rec)
        } else if rec.action == StudioCanonProposal.approvalAction {
            // Desk 903 phase 4, and the one inverted card in the app: SHE is the
            // sole approver of her own canon. Resolving from an owner surface
            // reaches here and is REFUSED with an annotation — no canon row, no
            // silent success. Her own `studio_canon_resolve` applies its own
            // resolution; this branch is the honest refusal for everyone else
            // and the crash-window replay for her.
            await self.applyResolvedStudioCanonProposal(
                from: rec,
                dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
            )
        } else if rec.action == ExternalSendApprovalRequest.approvalAction {
            let outcome = await effects.applyResolvedExternalSend(from: rec)
            shouldArchiveVisibleCard = outcome
        } else if rec.action == "agentmail.send" {
            // Legacy AgentMail cards use their original payload shape. New Slack
            // and AgentMail sends share connector.external_send above.
            await self.applyResolvedAgentMailSend(from: rec)
        } else if Self.chatToolApprovalReplay(from: rec) != nil {
            // Generic chat-tool approvals are the ApprovalFiler path used by
            // chat surfaces: resolve the durable inbox record here, then
            // replay only the exact approved tool/input through the normal
            // gated dispatcher. Telegram/iOS/Mac all enter through this same
            // resolver instead of owning transport-specific replay logic.
            await self.applyResolvedChatToolApproval(from: rec)
        } else if rec.action.hasPrefix("nextgen.action."), decisionEnum == .approved {
            // No executor is wired for nextgen actions: annotate the record so
            // an approved request never reads as silently applied.
            NSLog("[approvals] no executor wired for nextgen action: \(rec.action)")
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "action": .string(rec.action),
                    "error": .string("no executor wired"),
                ]),
                detail: "FAILED: no executor wired for nextgen actions")
        } else if rec.action.hasPrefix("connector.action.") {
            shouldArchiveVisibleCard = await applyResolvedConnectorAction(
                from: rec,
                dataRoot: SwiftNativeApprovalInbox.defaultDataRoot()
            )
        }
        // Retire the visible inbox CARD carrying this approval (card id ==
        // approval id for rem.proposal / self-improvement cards). Lives HERE,
        // not in inboxAction, so ALL resolve callers retire the card too —
        // ApprovalsView, chat approval pills, sidebar, and the iOS bridge
        // path resolve directly (gpt-5.5 review 2026-06-10). Best-effort: a
        // missing card or transient decline leaves a re-tappable card (which
        // then hits alreadyResolved → success), never a lost resolve.
        if shouldArchiveVisibleCard {
            // A5.2 (2026-07-24): live store only — the legacy silo fallback is
            // retired. Best-effort stands: a declined write leaves a
            // re-tappable card (alreadyResolved → success), never a lost resolve.
            if await effects.updateVisibleNotificationInboxStatus(id: rec.id, action: "archive") == false {
                NSLog("[NativeClient] resolve(\(rec.id)): visible-card archive declined — card stays re-tappable")
            }
        }
        // The record as the executor left it, execution annotations included.
        return (try? await inbox.get(rec.id)) ?? rec
    }
}

private struct SingleApprovedToolAutonomyResolver: AutonomyResolver {
    let delegate: SwiftNativeTrustCenter
    let approvedTool: String
    let approvedSurface: String

    init(dataRoot: URL, approvedTool: String, approvedSurface: String) {
        self.delegate = SwiftNativeTrustCenter(dataRoot: dataRoot)
        self.approvedTool = approvedTool
        self.approvedSurface = approvedSurface
    }

    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
        // A saved approval cannot override a later Trust revocation.
        let currentLevel = try await delegate.autonomyLevel(forTool: toolName, surface: surface)
        if currentLevel == "blocked" || currentLevel == "deny" {
            return currentLevel
        }
        // 2026-09-06: `approvedTool` is the PERSISTED spelling (`save.skill`),
        // and the gated chain canonicalizes before this resolver is consulted,
        // so a pre-upgrade dotted approval no longer recognized its own tool.
        // Compare canonical names on both sides.
        if CanonicalToolNameDispatcher.canonical(toolName)
            == CanonicalToolNameDispatcher.canonical(approvedTool),
           surface == approvedSurface {
            return "auto"
        }
        return currentLevel
    }
}

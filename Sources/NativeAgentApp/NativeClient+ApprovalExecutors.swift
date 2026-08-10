import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

// W-H Band 1 (U5 decomposition, move-only): approval executors +
// reconciles extracted verbatim from NativeClient.swift (formerly the
// applyApprovedSelfImprovement → resolveApproval cluster). Pure relocation
// into a same-module extension; no logic, signature, or visibility changes
// except the four documented private→internal lifts that stay in the root
// file (annotateApprovalExecution, executeApprovedBrowserRun,
// finishRejectedBrowserRun, jsonString(JSONValue,String)).
extension NativeClient {
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
        do {
            switch op {
            case "run_memory_hygiene":
                _ = try await runMemoryHygiene()
            case "disable_skill":
                guard let target else {
                    // Annotate, don't just return — an approved record with no
                    // executable target must never read as silently applied.
                    NSLog("[selfImprovement] missing target for op: \(op)")
                    try? await Self.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object(["op": .string(op), "error": .string("missing target")]),
                        detail: "self-improvement \(op) FAILED: missing target for \(op)")
                    return
                }
                try await disableSkill(name: target)
            case "enable_skill":
                guard let target else {
                    NSLog("[selfImprovement] missing target for op: \(op)")
                    try? await Self.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object(["op": .string(op), "error": .string("missing target")]),
                        detail: "self-improvement \(op) FAILED: missing target for \(op)")
                    return
                }
                try await enableSkill(name: target)
            default:
                NSLog("[selfImprovement] unknown apply op: \(op)")
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object(["op": .string(op), "error": .string("unknown op")]),
                    detail: "self-improvement apply FAILED: unknown op '\(op)'")
                return
            }
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["op": .string(op), "target": .string(target ?? "")]),
                detail: "self-improvement \(op) applied")
        } catch {
            // Don't leave an approved-but-silently-failed record: annotate the
            // failure so the UI shows it didn't apply.
            NSLog("[selfImprovement] apply failed for op \(op): \(error)")
            try? await Self.annotateApprovalExecution(
                id: rec.id,
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
            try? await Self.annotateApprovalExecution(
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
                    proposalText = await store.loadAll()
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
                try? await Self.annotateApprovalExecution(
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
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("rem_proposal_deny"),
                        "proposalId": .string(proposalId),
                    ]),
                    detail: "REM proposal denied — tombstoned")
            default: // canceled
                try await store.clearApprovalStamp(proposalId: proposalId)
                try? await Self.annotateApprovalExecution(
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
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "proposalId": .string(proposalId),
                    "error": .string("\(error)"),
                ]),
                detail: "REM proposal \(decision) FAILED: \(error.localizedDescription) — "
                    + "stamp cleared; next REM pass re-stages it")
        }
    }

    // MARK: - U5 W-A item 3: generic resolve→execute crash-window reconcile

    /// One reconcilable approval kind: the action string, an eligibility/
    /// idempotency predicate, and the executor to re-fire.
    struct ApprovalExecutionReconcileKind {
        let action: String
        /// Per-kind eligibility hook — `false` skips the record.
        let shouldReconcile: (ApprovalRecord) -> Bool
        let execute: (ApprovalRecord) async -> Void
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
    static func reconcileUnappliedApprovalExecutions() async {
        let dataRoot = PersistenceCore.defaultDataRoot()
        await reconcileUnappliedApprovalExecutions(
            dataRoot: dataRoot,
            kinds: productionApprovalReconcileKinds())
        await reconcileUnappliedChatToolApprovalExecutions(dataRoot: dataRoot)
    }

    /// Scan core, split out so tests can run it against a fixture root with
    /// recording executors (the production executors are hardwired to the
    /// default data root).
    static func reconcileUnappliedApprovalExecutions(
        dataRoot: URL,
        kinds: [ApprovalExecutionReconcileKind]
    ) async {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        for kind in kinds {
            let resolved: [ApprovalRecord]
            do {
                resolved = try await inbox.list(
                    filter: ApprovalFilter(status: "resolved", action: kind.action))
            } catch {
                NSLog("[approvalReconcile] \(kind.action) scan failed: \(String(describing: error))")
                continue
            }
            for rec in resolved where rec.executedAction == nil {
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
    static func selfImprovementReconcileEligible(_ rec: ApprovalRecord) -> Bool {
        rec.decision == "approved"
    }

    static func productionApprovalReconcileKinds() -> [ApprovalExecutionReconcileKind] {
        // The instance executors never touch transport state — any client
        // value reaches the same Swift-native paths resolveApproval uses.
        let client = NativeClient(baseURL: "")
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
                execute: { await Self.reconcileResolvedBrowserRun(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: "agentmail.send",
                shouldReconcile: { _ in true },
                execute: { await Self.applyResolvedAgentMailSend(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: ExternalSendApprovalRequest.approvalAction,
                shouldReconcile: { _ in true },
                execute: { _ = await Self.applyResolvedExternalSend(from: $0) }),
            ApprovalExecutionReconcileKind(
                action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction,
                shouldReconcile: { _ in true },
                execute: {
                    await Self.applyResolvedProcedureExactActivation(from: $0)
                }),
        ]
    }

    /// Executes the pre-external_send_v1 AgentMail approval shape so older
    /// pending cards can still be replayed safely/idempotently.
    static func applyResolvedAgentMailSend(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        guard rec.action == "agentmail.send",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        guard decision == "approved" else {
            let op = decision == "denied" ? "agentmail_send_denied" : "agentmail_send_canceled"
            try? await Self.annotateApprovalExecution(
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
            try? await Self.annotateApprovalExecution(
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
        try? await Self.annotateApprovalExecution(
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
        let sessionId = nonEmptyPayloadString(origin["sessionId"])
            ?? nonEmptyPayloadString(telegram["sessionId"])
        let chatId = nonEmptyPayloadString(origin["chatId"])
            ?? nonEmptyPayloadString(telegram["chatId"])
        let verifiedUserId = nonEmptyPayloadString(origin["userId"])
        let destinationId = nonEmptyPayloadString(origin["destinationId"])
        let threadId = nonEmptyPayloadString(origin["threadId"])
        let sourceKey = nonEmptyPayloadString(origin["sourceKey"])
        let replyTo = nonEmptyPayloadString(origin["replyTo"])
        let correlationId = nonEmptyPayloadString(origin["correlationId"])
        let replyRoute: ChatToolSessionContext.ReplyRoute? = [
            destinationId, threadId, sourceKey, replyTo, correlationId,
        ].contains(where: { $0 != nil })
            ? ChatToolSessionContext.ReplyRoute(
                surface: surface,
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
            replyRoute: replyRoute
        )
    }

    private static func nonEmptyPayloadString(_ value: JSONValue?) -> String? {
        let raw: String?
        switch value {
        case .string(let s)?: raw = s
        case .int(let i)?: raw = String(i)
        case .double(let d)?: raw = String(Int(d))
        default: raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isRemoteChatApprovalSurface(_ surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isRemote
    }

    static func reconcileUnappliedChatToolApprovalExecutions(
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let resolved: [ApprovalRecord]
        do {
            resolved = try await inbox.list(filter: .resolved)
        } catch {
            NSLog("[approvalReconcile] chat tool approval scan failed: \(String(describing: error))")
            return
        }
        for rec in resolved where chatToolApprovalReplay(from: rec) != nil {
            if chatToolApprovalReplayNeedsExecution(rec) {
                NSLog("[approvalReconcile] reconciling eligible resolved chat tool approval "
                    + "\(rec.id) action=\(rec.action) decision=\(rec.decision ?? "?")")
                await applyResolvedChatToolApproval(from: rec, dataRoot: dataRoot)
            }
            // Execution truth and conversational continuity are separate
            // commits. Heal the latter too: an approved tool that ran before a
            // crash must still leave one resident tool receipt in the original
            // session so the next turn knows it completed and does not retry.
            if let refreshed = try? await inbox.get(rec.id) {
                await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot)
            }
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
              let replay = chatToolApprovalReplay(from: rec),
              replay.toolName == "persona_write" || replay.toolName == "persona_append_section",
              case .object(let executed)? = rec.executedAction,
              executed["op"] == .string("chat_tool_approval_replay"),
              executed["status"] == .string("failed"),
              case .string(let error)? = executed["error"]
        else { return false }
        return error.contains("approval required, no filer is available on this noninteractive surface")
            && error.contains("source=\(PersonaWriteGuard.autonomySource)")
    }

    static func applyResolvedChatToolApproval(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        guard rec.status == "resolved",
              let decision = rec.decision,
              chatToolApprovalReplay(from: rec) != nil else { return }

        guard let replay = chatToolApprovalReplay(from: rec) else {
            try? await annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("chat_tool_approval_replay"),
                    "status": .string("failed"),
                    "error": .string("malformed approval payload"),
                ]),
                detail: "Approved tool replay FAILED: malformed approval payload",
                root: dataRoot)
            return
        }

        guard decision == "approved" else {
            let op = decision == "denied"
                ? "chat_tool_approval_denied"
                : "chat_tool_approval_canceled"
            try? await annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string(op),
                    "tool": .string(replay.toolName),
                    "surface": .string(replay.surface),
                ]),
                detail: "\(replay.toolName) \(decision); no tool execution run.",
                root: dataRoot)
            return
        }

        do {
            let tools = makeNativeAgentAppToolDispatchClient(
                includeEvolutionBridge: !isRemoteChatApprovalSurface(replay.surface),
                denyExternalMcp: false,
                enforceAppAutonomy: false,
                dataRoot: dataRoot
            )
            let trust = SingleApprovedToolAutonomyResolver(
                dataRoot: dataRoot,
                approvedTool: replay.toolName,
                approvedSurface: replay.surface
            )
            let gated = makeGatedToolDispatchClient(
                tools: tools,
                fileAccess: "auto",
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
            let result = try await ChatToolSessionContext.$commandSignatureVerified.withValue(true) {
                try await ChatToolSessionContext.$verifiedChatId.withValue(replay.telegramChatId) {
                    try await ChatToolSessionContext.$verifiedUserId.withValue(replay.verifiedUserId) {
                        try await ChatToolSessionContext.$replyRoute.withValue(replay.replyRoute) {
                            try await ChatToolSessionContext.$verifiedSessionId.withValue(replay.sessionId) {
                                try await gated.dispatch(
                                    tool: replay.toolName,
                                    input: replay.input,
                                    surface: replay.surface
                                )
                            }
                        }
                    }
                }
            }
            let status = Self.jsonString(result, "status") ?? "succeeded"
            let preview = approvalResultPreview(result)
            try? await annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("chat_tool_approval_replay"),
                    "tool": .string(replay.toolName),
                    "surface": .string(replay.surface),
                    "status": .string(status),
                    "resultPreview": .string(preview),
                ]),
                detail: "\(replay.toolName) executed after approval: \(preview)",
                root: dataRoot)
            if let refreshed = try? await SwiftNativeApprovalInbox(root: dataRoot).get(rec.id) {
                await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot)
            }
        } catch {
            NSLog("[approvals] approved chat tool replay failed for \(rec.id): \(error)")
            try? await annotateApprovalExecution(
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
                await ensureChatToolApprovalOutcomeReceipt(from: refreshed, dataRoot: dataRoot)
            }
        }
    }

    /// Persist exactly one compact tool receipt into the conversation that
    /// originated a generic approval. This is resident continuity, not another
    /// model turn: it lets Mac, Telegram, iOS, Slack, and bridge history all
    /// observe the verified post-approval outcome without dumping the raw
    /// replay payload into user-visible chat.
    static func ensureChatToolApprovalOutcomeReceipt(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        guard rec.status == "resolved",
              rec.decision == "approved",
              let replay = chatToolApprovalReplay(from: rec),
              let executedAction = rec.executedAction,
              let safeSessionID = NativeAgentChatSessionID.normalizedPathComponent(replay.sessionId)
        else { return }

        let resultStatus = jsonString(executedAction, "status") ?? "succeeded"
        let normalizedStatus = resultStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ok = !["failed", "error", "denied", "rejected", "canceled", "cancelled"].contains(normalizedStatus)
        let resultPreview = jsonString(executedAction, "resultPreview")
            .map(TurnTraceRedactor.redactText)
        let statusSummary = ok
            ? "Completed after approval (\(rec.id)); status=\(normalizedStatus)."
            : "Failed after approval (\(rec.id)); status=\(normalizedStatus)."
        let summary = resultPreview.map { "\(statusSummary) Result: \($0)" } ?? statusSummary
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionID).jsonl")
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                let rows = (try? await persistence.readJSONL(path)) ?? []
                let existingIndex = rows.firstIndex { row in
                    guard case .object(let object) = row,
                          case .object(let metadata)? = object["metadata"],
                          case .string(let approvalID)? = metadata["approvalId"]
                    else { return false }
                    return approvalID == rec.id
                }
                let now = ISO8601DateFormatter().string(from: Date())
                let inputJSON = (try? JSONValue.object([
                    "approvalId": .string(rec.id),
                ]).serialize(pretty: false)) ?? "{}"
                let priorObject: [String: JSONValue] = existingIndex.flatMap { index in
                    guard case .object(let object) = rows[index] else { return nil }
                    return object
                } ?? [:]
                let row: JSONValue = .object([
                    "id": priorObject["id"] ?? .string(UUID().uuidString.lowercased()),
                    "sessionId": .string(safeSessionID),
                    "role": .string("tool"),
                    "content": .string(""),
                    "createdAt": priorObject["createdAt"] ?? .string(now),
                    "source": .string(replay.surface),
                    "runId": .string("approval-\(rec.id)"),
                    "metadata": .object([
                        "kind": .string("tool_use"),
                        "toolName": .string(replay.toolName),
                        "inputJSON": .string(inputJSON),
                        "resultSummary": .string(summary),
                        "ok": .bool(ok),
                        "approvalId": .string(rec.id),
                        "postApproval": .bool(true),
                    ]),
                ])
                if let existingIndex {
                    // A narrowly recoverable pre-dispatch failure can later
                    // succeed. Keep one canonical receipt, but replace its
                    // stale failure result so conversation continuity agrees
                    // with the approval store's latest execution truth.
                    if rows[existingIndex] != row {
                        var updated = rows
                        updated[existingIndex] = row
                        try await persistence.replaceJSONL(updated, to: path)
                    }
                } else {
                    try await persistence.appendJSONL(row, to: path)
                }
            }
        } catch {
            NSLog("[approvals] outcome receipt persist failed for \(rec.id): \(error)")
        }
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
    static func reconcileResolvedBrowserRun(
        from rec: ApprovalRecord,
        runsPath: URL = SwiftNativeBrowserClient.defaultClient().runsPath,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        guard rec.action == "browser.open_url",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        if decision == "approved" {
            if case .object(let payload) = rec.payload,
               case .string(let runID)? = payload["runId"] ?? payload["run_id"],
               let run = await Self.terminalBrowserRun(runID: runID, runsPath: runsPath) {
                // Navigation already happened (the run persisted in a
                // terminal state before the crash); only the annotation
                // write was lost. Heal it WITHOUT re-opening the URL.
                let status = Self.jsonString(run, "status") ?? "succeeded"
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: run,
                    detail: "Browser navigation \(status) "
                        + "(annotation healed by launch reconcile; URL not re-opened)",
                    root: dataRoot)
                await Self.observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
                return
            }
            do {
                try await Self.executeApprovedBrowserRun(from: rec)
            } catch {
                NSLog("[approvalReconcile] browser re-run failed for \(rec.id): \(String(describing: error))")
            }
        } else {
            do {
                try await Self.finishRejectedBrowserRun(
                    from: rec, status: decision == "denied" ? "denied" : "canceled")
            } catch {
                NSLog("[approvalReconcile] browser rejected-finish failed for \(rec.id): \(String(describing: error))")
            }
        }
    }

    /// The persisted run for `runID` iff its status is terminal. A
    /// `waiting_approval` row (persisted at approval-creation time) is NOT
    /// terminal — the navigation never ran and a reconcile may execute it.
    static func terminalBrowserRun(runID: String, runsPath: URL) async -> JSONValue? {
        guard !runID.isEmpty else { return nil }
        let raw = await SwiftNativePersistenceCore().readJSON(runsPath, defaultValue: .array([]))
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
    /// branch annotates the approval record executed/FAILED. On an
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
            try? await Self.annotateApprovalExecution(
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
        let executor = WorkshopExecutorRef.shared.current()
            ?? BackgroundLoopsAssembly.makeWorkshopExecutor()
        // FROZEN WIRE — deliberate keep, do NOT de-mission these (P2-8 owns any
        // future move).
        //
        // The five `"missionId"` keys and the three `mission_step_*` `op`
        // labels below are PERSISTED AUDIT ANNOTATIONS: they are written into
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
                let record = try await executor.resumeAfterApproval(
                    executionId: executionId, stepId: stepId, approved: true, approvalId: rec.id)
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("mission_step_resume"),
                        "missionId": .string(executionId),
                        "stepId": .string(stepId),
                        "missionStatus": .string(record.status),
                    ]),
                    detail: "Desk step approved — executed; Desk execution now \(record.status)")
            case "denied":
                let record = try await executor.resumeAfterApproval(
                    executionId: executionId, stepId: stepId, approved: false, approvalId: rec.id)
                try? await Self.annotateApprovalExecution(
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
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("mission_step_cancel"),
                        "missionId": .string(executionId),
                        "stepId": .string(stepId),
                    ]),
                    detail: "Desk step approval canceled — claim cleared; Desk execution stays blocked")
            }
        } catch WorkshopExecutionError.staleApproval(let detail) {
            // gpt-5.5 executor-port blocker #3 (2026-06-10): stale card —
            // the execution is no longer blocked_on_approval (cancelled/
            // failed/completed since the card was staged). The executor
            // refused to run the step; annotate the approval record
            // honestly. Do NOT clear the claim (the execution is not coming
            // back to this approval) and do NOT report a generic failure.
            NSLog("[workshopStep] \(decision) skipped for \(executionId)/\(stepId): \(detail)")
            try? await Self.annotateApprovalExecution(
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
            try? await Self.annotateApprovalExecution(
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
                let raw = await persistence.readJSON(path, defaultValue: .null)
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

    func resolveApproval(id: String, decision: String) async throws -> ApprovalRequest {
        // F6 (eval E06 fix-2): unify on the SwiftNativeApprovalInbox actor
        // (Modules/.../ApprovalInbox), which reads/writes
        // <dataRoot>/workflows/approvals/requests.json under flock. The
        // prior R-M-W in this method targeted <dataRoot>/approvals/requests.json
        // — a different file from the one the LIST path (ApprovalInbox + the
        // list helper at L9637) reads from, so resolve writes never landed
        // where the UI was looking.
        let inbox = SwiftNativeApprovalInbox(root: SwiftNativeApprovalInbox.defaultDataRoot())
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
        let rec = try await inbox.resolve(id, decision: decisionEnum, decidedBy: "mac_ui")
        var shouldArchiveVisibleCard = true
        if rec.action == "browser.open_url" {
            if decisionEnum == .approved {
                try await Self.executeApprovedBrowserRun(from: rec)
            } else {
                try await Self.finishRejectedBrowserRun(from: rec, status: decisionEnum == .denied ? "denied" : "canceled")
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
            await Self.applyResolvedMemoryRepair(from: rec)
        } else if rec.action == MemoryKindBackfill.action {
            // U3 wave-2 item 5: approve stamps the LLM-proposed kinds
            // through the store's own write path (content-hash stale
            // guard); deny leaves rows untouched (never re-proposed);
            // cancel clears the staging stamp so the next launch
            // re-stages. Self-guarding; crash window healed by the
            // on-launch reconcileUnappliedKindBackfills pass.
            await Self.applyResolvedKindBackfill(from: rec)
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
        } else if rec.action == Self.selfEvolutionAction {
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
            await Self.applyResolvedSelfEvolution(from: rec, deps: .production())
        } else if rec.action == SwiftNativeApprovalInbox.procedureExactActivationApprovalAction {
            await Self.applyResolvedProcedureExactActivation(from: rec)
        } else if rec.action == ExternalSendApprovalRequest.approvalAction {
            let outcome = await Self.applyResolvedExternalSend(from: rec)
            shouldArchiveVisibleCard = outcome.shouldArchiveVisibleCard
        } else if rec.action == "agentmail.send" {
            // Legacy AgentMail cards use their original payload shape. New Slack
            // and AgentMail sends share connector.external_send above.
            await Self.applyResolvedAgentMailSend(from: rec)
        } else if Self.chatToolApprovalReplay(from: rec) != nil {
            // Generic chat-tool approvals are the ApprovalFiler path used by
            // chat surfaces: resolve the durable inbox record here, then
            // replay only the exact approved tool/input through the normal
            // gated dispatcher. Telegram/iOS/Mac all enter through this same
            // resolver instead of owning transport-specific replay logic.
            await Self.applyResolvedChatToolApproval(from: rec)
        } else if rec.action.hasPrefix("nextgen.action."), decisionEnum == .approved {
            // No executor is wired for nextgen actions: annotate the record so
            // an approved request never reads as silently applied.
            NSLog("[approvals] no executor wired for nextgen action: \(rec.action)")
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "action": .string(rec.action),
                    "error": .string("no executor wired"),
                ]),
                detail: "FAILED: no executor wired for nextgen actions")
        } else if rec.action.hasPrefix("connector.action."), decisionEnum == .approved {
            // Older generic connector cards carried only labels, not replay
            // input. They cannot execute safely; keep the card visible and say
            // so instead of archiving an approved-but-never-run action.
            shouldArchiveVisibleCard = false
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "action": .string(rec.action),
                    "status": .string("failed"),
                    "error": .string("legacy connector approval has no replay payload"),
                ]),
                detail: "FAILED: legacy connector approval has no bounded replay payload; no connector call ran")
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
            if await Self.updateVisibleNotificationInboxStatus(id: rec.id, action: "archive") == false {
                NSLog("[NativeClient] resolve(\(rec.id)): visible-card archive declined — card stays re-tappable")
            }
        }
        let finalRecord = (try? await inbox.get(rec.id)) ?? rec
        return ApprovalRequest(
            id: finalRecord.id,
            title: finalRecord.title,
            action: finalRecord.action,
            risk: finalRecord.risk,
            reason: finalRecord.reason,
            status: finalRecord.status,
            createdAt: finalRecord.createdAt,
            resolvedAt: finalRecord.resolvedAt,
            decision: finalRecord.decision,
            payloadPreview: finalRecord.payloadPreview,
            localOnly: finalRecord.localOnly,
            remoteResolvable: finalRecord.remoteResolvable
        )
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
        if toolName == approvedTool && surface == approvedSurface {
            return "auto"
        }
        return try await delegate.autonomyLevel(forTool: toolName, surface: surface)
    }
}

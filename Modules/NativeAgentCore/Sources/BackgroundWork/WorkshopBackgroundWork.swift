import Foundation
import NativeAgentCore
import ChatOrchestration
import PersistenceCore
import ProviderRouting
import ApprovalInbox
import Cognition
import WorkshopExecution
import TrustCenter
import NotificationInbox

public typealias WorkshopInboxNotification = @Sendable (URL, String, String, String, String, String) async -> Void

public enum WorkshopBackgroundWork {
    /// Build the fully wired executor. ONE construction point: the
    /// background drain loop AND NativeClient's execution.step
    /// resume-on-approve executor both come through here so resume runs
    /// with the exact closures the original drain ran with.
    public static func makeWorkshopExecutor(
        dataRoot: URL,
        cognition: NativeCognitionRuntime,
        planner: SwiftNativeWorkshopPlannerLLM,
        chatClient: @escaping @Sendable (any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient,
        gatedTools: any ToolDispatchClient,
        approvedTools: @escaping @Sendable (ApprovedChatToolReplay) -> any ToolDispatchClient,
        notify: @escaping WorkshopInboxNotification
    ) -> WorkshopExecutorLoop {
        let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
        let measuredLLMStep: WorkshopStepMeasuredLLM = { prompt in
            let (model, output) = try await planner.runCodex(
                prompt: prompt, surface: WorkshopSurfaceVocabulary.canonical,
                timeoutSeconds: 120)
            return WorkshopStepLLMCompletion(
                model: model,
                text: output,
                providerCallCount: 1,
                removableOrchestrationProviderCallCount: 0
            )
        }
        // TOOL-CAPABLE synthesize turn (synthesize-quality fix, 2026-06-11).
        // Found live by Agent on execution 752636c5: a bare completion has no
        // tool access, so the synthesize model refused ("I can't access your
        // filesystem") and the refusal scored `succeeded`. Route synthesize
        // steps through the production chat tool loop over a RESTRICTED,
        // READ-ONLY dispatcher (WorkshopSynthesizeReadOnlyToolDispatcher) so
        // the model can actually read what it's asked to synthesize. The
        // autonomy gate still governs the surviving read tools (the chat
        // client wires AutonomyGatedDispatcher internally). fileAccess
        // "read_only" blocks write-class tools at the FileAccess layer too —
        // belt-and-suspenders with the name allowlist. surface "missions"
        // resolves the per-surface model via the same picker the planner uses.
        // This is an EPHEMERAL execution turn: it does not mint a random chat
        // session, read chat history, autocompact, or append transcript state.
        // Model, provider, Think, and Fast all resolve from the executions surface.
        let measuredTooledLLMStep: WorkshopStepMeasuredLLM = { prompt in
            let restricted = WorkshopSynthesizeReadOnlyToolDispatcher(
                inner: SwiftToolDispatcher(
                    dataRoot: dataRoot,
                    allowProcessGlobalTools: usesLiveAppBody,
                    agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
                ))
            // A test-root executor gets its own bodiless engine, as its planner
            // gets the unavailable LLM above.
            let client = chatClient(restricted)
            let response = try await client.runEphemeralToolTurn(
                message: prompt,
                fileAccess: "read_only",
                requireCompleted: true,
                surface: WorkshopSurfaceVocabulary.canonical
            )
            guard let providerCallCount = response.providerCallCount else {
                throw NSError(domain: "WorkshopExecutor", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "Desk task synthesis completed without exact provider accounting",
                ])
            }
            return WorkshopStepLLMCompletion(
                model: response.model,
                text: response.output,
                providerCallCount: providerCallCount,
                removableOrchestrationProviderCallCount: 0
            )
        }
        // Tool steps go through the SAME gated chain chat uses
        // (fileAccess gate → autonomy gate → real tools). approvalFiler nil
        // → CONFIRM-tier tools fail closed at the dispatch layer; the
        // execution-level approval staging (trustRequired / needs_approval)
        // happens ABOVE this in the executor via the stager below.
        // fileAccess "auto" resolves from the Trust policy (full-mac under
        // wide-open/yolo) — matching chat, so an execution can write outside the
        // workspace (e.g. ~/Desktop) when the user's posture allows. Was "workspace"
        // (daemon-era workspace-write sandbox), which silently confined execution
        // file writes and is why a "create ~/Desktop/x" execution never landed
        // the file (2026-06-15, the user: full-mac yolo, "she does everything").
        // Inject the MacIntegrationToolBridge so execution tool steps can run the
        // Mac-integration tools (calendar/mail/contacts/reminders/etc.) — chat
        // wires this; executions used a bare SwiftToolDispatcher(), so those tools
        // failed with "MacIntegrationToolBridge not injected" (2026-06-15, found
        // live: a morning-brief execution planned mac_calendar_list_upcoming then
        // failed at execution). file/shell tools don't need it; mac_* do.
        let toolStep: WorkshopStepToolDispatch = { tool, args in
            guard case .object(let dict) = args else {
                throw NSError(domain: "WorkshopExecutor", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "step args must be a JSON object",
                ])
            }
            if let schema = try await gatedTools.listAvailableToolSchemas().first(where: { $0.name == tool }) {
                try WorkshopArgumentValidation.validate(args, schema: JSONValue.parse(schema.parametersJSON))
            }
            return try await gatedTools.dispatch(tool: tool, input: dict, surface: "mission")
        }
        return WorkshopExecutorLoop(
            root: dataRoot,
            measuredLLMStep: measuredLLMStep,
            measuredTooledLLMStep: measuredTooledLLMStep,
            toolDispatch: toolStep,
            approvedToolDispatch: { tool, args, approvalId in
                guard case .object(let input) = args,
                      let approval = try? await SwiftNativeApprovalInbox(root: dataRoot).get(approvalId),
                      ExecutionEventVocabulary.matches(approval.action, WorkshopStepApprovalAction.canonical),
                      case .object(let payload) = approval.payload,
                      payload["tool"] == .string(tool), payload["args"] == args,
                      approval.status == "resolved", approval.decision == "approved" else {
                    throw WorkshopExecutionError.forbidden("Workshop approval arguments do not match")
                }
                let inbox = SwiftNativeApprovalInbox(root: dataRoot)
                guard await inbox.consumeApprovedEffect(
                    id: approvalId, digest: ApprovalInboxApprovedReplayVerifier.effectDigest(approval.payload),
                    action: tool, surface: "mission") == .spent else {
                    throw WorkshopExecutionError.forbidden("Workshop approval was already spent or is unavailable")
                }
                let dispatcher = approvedTools(ApprovedChatToolReplay(
                    approvalID: approvalId, tool: tool, surface: "mission", input: input,
                    verifiedSessionID: nil, verifiedChatID: nil, verifiedUserID: nil))
                if let schema = try await dispatcher.listAvailableToolSchemas().first(where: { $0.name == tool }) {
                    try WorkshopArgumentValidation.validate(args, schema: JSONValue.parse(schema.parametersJSON))
                }
                return try await dispatcher.dispatch(tool: tool, input: input, surface: "mission")
            },
            stageApproval: makeWorkshopStepApprovalStager(dataRoot: dataRoot, notify: notify),
            isEnabled: { await workshopExecutorGate(dataRoot: dataRoot) },
            // An admitted, active Full Mac grant flattens all Workshop
            // approval-only posture (planner hints, intrinsic confirm tiers,
            // and explicit trustRequired). Domain/tool dispatch still owns
            // hard blocks and effect-time validation.
            stepApprovalEnforced: { await !isWideOpenTrust(dataRoot: dataRoot) },
            terminalEventSink: { record, reason in
                await WorkshopDeskReceiptBridge.recordTerminal(
                    record,
                    reason: reason,
                    dataRoot: dataRoot
                )
                await cognition.observeMotorActionState(
                    SwiftNativeWorkshopRunner.motorActionReadModel(record: record)
                )
            }
        )
    }

    /// THE unattended-work gate. Every lane that works while nobody is looking
    /// — standing bots (scheduled and event-woken), the Workshop pump, the
    /// Workshop executor, background self-improvement proposals — asks this one
    /// function, so "may the agent work unattended" has a single answer.
    ///
    /// Open when ANY of three hold (User, 2026-09-13: "Full Mac YOLO should open
    /// up everything, nothing held back"):
    ///   1. `enableAutonomy` is a literal boolean true (the Trust toggle), or
    ///   2. the saved policy IS Full Mac — the same isFullMac rule the policy
    ///      normalizer uses (`TrustCenter+PolicyLoading`), or
    ///   3. checked Full Mac YOLO authority is admitted on this data root.
    ///
    /// Fails closed on a damaged policy: `loadTrustPolicy()` returns the
    /// fail-closed shape (balanced / enableAutonomy false) and the YOLO door
    /// refuses an unreadable snapshot.
    public static func unattendedWorkAllowed(dataRoot: URL) async -> Bool {
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policy = await trust.loadTrustPolicy()
        if case .bool(true) = policy["enableAutonomy"] ?? .null { return true }
        if isFullMacPolicy(policy) { return true }
        return await isWideOpenTrust(dataRoot: dataRoot)
    }

    /// The isFullMac rule from `SwiftNativeTrustCenter.normalizedTrustPolicy`,
    /// read off an already-loaded policy. Kept identical on purpose: the card
    /// the person sees ("Full Mac") and the gate must agree.
    public static func isFullMacPolicy(_ policy: [String: JSONValue]) -> Bool {
        let permissionLevel: String = {
            if case .string(let s)? = policy["permissionLevel"] { return s }
            return ""
        }()
        if permissionLevel == "full_mac_os" { return true }
        guard permissionLevel == "wide_open_receipts",
              case .object(let filePolicy)? = policy["filePolicy"],
              case .string("allow")? = filePolicy["outsideWorkspaceDefault"]
        else { return false }
        return true
    }

    /// True only for the canonical checked, active and unexpired Full Mac
    /// authority grant on the local Workshop surface. A permission label by
    /// itself is not authority, and corrupt/unavailable policy fails closed.
    public static func isWideOpenTrust(dataRoot: URL) async -> Bool {
        let assessment = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                tool: "workshop.execution",
                origin: SecurityOriginContext(
                    surface: WorkshopSurfaceVocabulary.canonical,
                    source: "background_workshop_executor",
                    isRemote: false
                )
            )
        return assessment.admitted
    }

    /// enableAutonomy + missionPolicy gate, mirroring the daemon's posture:
    /// the executor only RUNS executions when the trust policy explicitly has
    /// enableAutonomy on, AND the missionPolicy half allows.
    ///
    /// gpt-5.5 executor-port blocker #7 (2026-06-10): this gate used to (a)
    /// construct SwiftNativeTrustCenter() on the DEFAULT data root, ignoring
    /// the dataRoot the whole assembly was built against, and (b) treat a
    /// present-but-malformed missionPolicy (string/array/scalar) as ALLOW
    /// while the submit-side gate (SwiftNativeWorkshopRunner.workshopExecutionsAllowed)
    /// denies it. Fixed: dataRoot is passed through, and the missionPolicy
    /// half is evaluated by the SAME shared rule submit uses —
    /// SwiftNativeWorkshopRunner.missionPolicyAllows (developerMode pyTruthy
    /// → allow; missionPolicy absent → allow; present-non-object → DENY;
    /// enabled absent → allow; else pyTruthy(enabled)) — one source of
    /// truth, no second drift.
    ///
    /// 2026-09-13 (User: "Full Mac YOLO should open up everything"): the
    /// autonomy half is now the shared `unattendedWorkAllowed` gate, so Full
    /// Mac opens this lane the same way it opens bots and the Workshop pump.
    /// The missionPolicy half is unchanged.
    public static func workshopExecutorGate(dataRoot: URL) async -> Bool {
        guard await unattendedWorkAllowed(dataRoot: dataRoot) else { return false }
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policy = await trust.loadTrustPolicy()
        return SwiftNativeWorkshopRunner.workshopPolicyAllows(policy)
    }

    /// execution.step approval stager: ONE ApprovalInbox record per blocked
    /// step (NativeClient.resolveApproval's "execution.step" executor resumes
    /// the Workshop execution on approve/deny) plus a card in
    /// notifications/inbox.jsonl with card id == approval id — the exact
    /// REM-stager contract. Dedupe: an existing PENDING execution.step
    /// approval for the same Workshop execution+step is reused (a re-staged step after
    /// a failed resume must not double-file). Fails closed (nil) on any
    /// list/create/card error — the executor then FAILS the step honestly.
    public static func makeWorkshopStepApprovalStager(dataRoot: URL, notify: @escaping WorkshopInboxNotification) -> WorkshopStepApprovalStager {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        return { req in
            let pending: [ApprovalRecord]
            do {
                pending = try await inbox.list(
                    filter: ApprovalFilter(
                        status: "pending",
                        action: WorkshopStepApprovalAction.canonical))
            } catch {
                FileHandle.standardError.write(Data(
                    "WorkshopStepStager: dedupe list failed for \(req.executionId)/\(req.stepId): \(error)\n".utf8))
                return nil
            }
            // P2-2 de-mission: the stager now WRITES "execution_id" (below).
            // This dedupe read resolves through the shared vocabulary so a
            // pending approval staged by an older binary still matches —
            // without the fallback it would miss and the stager would append a
            // duplicate approval for the same step.
            if let existing = pending.first(where: { rec in
                guard case .object(let p) = rec.payload,
                      let mid = WorkshopStepApprovalPayload.executionId({ key in
                          if case .string(let s)? = p[key] { return s }
                          return nil
                      }),
                      case .string(let sid)? = p["step_id"] else { return false }
                return mid == req.executionId && sid == req.stepId
                    && p["tool"] == .string(req.tool) && p["args"] == req.args
            }) {
                do {
                    try await ensureWorkshopStepInboxCard(
                        dataRoot: dataRoot, approvalId: existing.id, req: req, notify: notify)
                    return existing.id
                } catch {
                    FileHandle.standardError.write(Data(
                        "WorkshopStepStager: card ensure failed for \(req.executionId)/\(req.stepId): \(error)\n".utf8))
                    return nil
                }
            }
            let body: JSONValue = .object([
                "title": .string(req.title),
                "action": .string(WorkshopStepApprovalAction.canonical),
                "risk": .string("medium"),
                "reason": .string(req.reason),
                // Sweep R4 B2: ApprovalInbox fails CLOSED on an undeclared
                // `remoteResolvable`. A workshop step parks the execution until
                // User answers, and answering from the phone was already
                // supported — declare it explicitly to preserve that.
                "remoteResolvable": .bool(true),
                "payload": .object([
                    "kind": .string(WorkshopStepApprovalAction.canonical),
                    WorkshopStepApprovalPayload.canonicalExecutionIdKey: .string(req.executionId),
                    "step_id": .string(req.stepId),
                    "tool": .string(req.tool),
                    "args": req.args,
                ]),
                "payloadPreview": .string("[\(req.tool)] " + String(req.title.prefix(180))),
            ])
            do {
                let rec = try await inbox.create(body)
                // Card failure FAILS the stage (nil) — same rule as the REM
                // stager: an approval with no visible card is a dead-end.
                try await ensureWorkshopStepInboxCard(
                    dataRoot: dataRoot, approvalId: rec.id, req: req, notify: notify)
                return rec.id
            } catch {
                FileHandle.standardError.write(Data(
                    "WorkshopStepStager: stage failed for \(req.executionId)/\(req.stepId): \(error)\n".utf8))
                return nil
            }
        }
    }

    /// Card id == approval id (InboxView approve/reject → inboxAction(id) →
    /// resolveApproval(id)). Idempotent whole-file scan before append, under
    /// the same flock — mirror of ensureREMProposalInboxCard.
    private static func ensureWorkshopStepInboxCard(
        dataRoot: URL,
        approvalId: String,
        req: WorkshopStepApprovalRequest,
        notify: WorkshopInboxNotification
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = "To continue \(req.taskTitle), approve: \(req.actionDescription)"
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(fmt.string(from: Date())),
            "source": .string("workshop"),
            "severity": .string("actionable"),
            "title": .string(req.title),
            "summary": .string(summary),
            "detail": .string(
                "Approve to execute the blocked step and continue the Desk task; "
                + "deny to reject the step and fail the Desk task.\n\n\(req.reason)"),
            "related_mission_id": .string(req.executionId),
            "related_approval_id": .string(approvalId),
            "related_paths": .array([
                .string(ExecutionRecordFile.resolve(
                    in: dataRoot.appendingPathComponent(
                        "workshop/executions/\(req.executionId)", isDirectory: true)).path),
            ]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Execute the blocked step and continue the Desk task")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Reject the step and fail the Desk task")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let inserted = try await LiveNotificationInbox(path: inboxPath)
            .appendUnique(card, id: approvalId)
        if inserted {
            await notify(
                dataRoot,
                approvalId,
                req.title,
                summary,
                "workshop",
                "actionable"
            )
        }
    }

}

import Foundation
import NativeAgentShared
import NativeAgentCore
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import PersistenceCore
import ApprovalInbox
import Cognition
import WorkshopExecution
import TrustCenter
import NotificationInbox
import AgentWorkspace
// Blueprint: | `WorkshopBackgroundWork.swift` | `WorkshopBackgroundWork` enum; `makeWorkshopExecutor`, `unattendedWorkAllowed`, Full Mac unattended override |

public typealias WorkshopInboxNotification = @Sendable (URL, String, String, String, String, String) async -> Void

public enum WorkshopBackgroundWork {
    /// Build the fully wired executor. ONE construction point: the
    /// background drain loop AND ApprovalExecution's execution.step
    /// resume-on-approve executor both come through here so resume runs
    /// with the exact closures the original drain ran with.
    public static func makeWorkshopExecutor(
        dataRoot: URL,
        cognition: NativeCognitionRuntime,
        chatClient: @escaping @Sendable () -> SwiftNativeChatOrchestrationClient,
        toolDispatch: @escaping @Sendable (String, [String: JSONValue], ApprovedChatToolReplay?) async throws -> JSONValue,
        notify: @escaping WorkshopInboxNotification
    ) -> WorkshopExecutorLoop {
        // Synthesis uses the ephemeral tool turn under the executions surface;
        // it creates no session or transcript and retains provider accounting.
        let measuredTooledLLMStep: WorkshopStepMeasuredLLM = { prompt in
            let client = chatClient()
            let response = try await LLMCallContext.$purpose.withValue("workshop") {
            try await client.runEphemeralToolTurn(
                message: prompt,
                fileAccess: "auto",
                requireCompleted: true,
                surface: WorkshopSurfaceVocabulary.canonical
            )
            }
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
        // Direct and approved steps enter the originating door under Trust.
        let toolStep: WorkshopStepToolDispatch = { tool, args in
            guard case .object(let dict) = args else {
                throw NSError(domain: "WorkshopExecutor", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "step args must be a JSON object",
                ])
            }
            return try await toolDispatch(tool, dict, nil)
        }
        return WorkshopExecutorLoop(
            root: dataRoot,
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
                return try await toolDispatch(tool, input, ApprovedChatToolReplay(
                    approvalID: approvalId, tool: tool, surface: "mission", input: input,
                    verifiedSessionID: ResidentWake.session, verifiedChatID: nil, verifiedUserID: nil))
            },
            stageApproval: makeWorkshopStepApprovalStager(dataRoot: dataRoot, notify: notify),
            isEnabled: { await workshopExecutorGate(dataRoot: dataRoot) },
            // An admitted, active Full Mac grant flattens all Workshop
            // approval-only posture (planner hints, intrinsic confirm tiers,
            // and explicit trustRequired). Domain/tool dispatch still owns
            // hard blocks and effect-time validation.
            stepApprovalEnforced: { await !isWideOpenTrust(dataRoot: dataRoot) },
            terminalEventSink: { record, reason in
                NotificationCenter.default.post(name: DeskContinuationScheduler.ownerReceiptChanged, object: dataRoot)
                await WorkshopDeskReceiptBridge.recordTerminal([record], reason: reason, dataRoot: dataRoot)
                await cognition.observeMotorActionState(
                    SwiftNativeWorkshopRunner.motorActionReadModel(record: record)
                )
            }
        )
    }

    /// Shared unattended admission: explicit autonomy, a saved Full Mac choice,
    /// or checked YOLO authority. Partial saved pairs require checked authority;
    /// damaged policy fails closed.
    public static func unattendedWorkAllowed(dataRoot: URL) async -> Bool {
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policy = await trust.loadTrustPolicy()
        if case .bool(true) = policy["enableAutonomy"] ?? .null { return true }
        if policy["permissionLevel"] == .string("full_mac_os") { return true }
        if policy["permissionLevel"] == .string("wide_open_receipts"),
           case .object(let filePolicy)? = policy["filePolicy"],
           filePolicy["outsideWorkspaceDefault"] == .string("allow") { return true }
        return await isWideOpenTrust(dataRoot: dataRoot)
    }

    /// True only for the canonical checked, active and unexpired Full Mac
    /// authority grant on the local Workshop surface. A permission label by
    /// itself is not authority, and corrupt/unavailable policy fails closed.
    public static func isWideOpenTrust(dataRoot: URL) async -> Bool {
        let assessment = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                origin: SecurityOriginContext(
                    surface: WorkshopSurfaceVocabulary.canonical,
                    source: "background_workshop_executor",
                    isRemote: false
                )
            )
        return assessment.admitted
    }

    /// Require shared unattended authority and the submit-side workshop policy on this data root.
    public static func workshopExecutorGate(dataRoot: URL) async -> Bool {
        guard await unattendedWorkAllowed(dataRoot: dataRoot) else { return false }
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policy = await trust.loadTrustPolicy()
        return SwiftNativeWorkshopRunner.workshopPolicyAllows(policy)
    }

    /// execution.step approval stager: ONE ApprovalInbox record per blocked
    /// step (ApprovalExecution.resolveApproval's "execution.step" executor resumes
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
            // Saved execution identities retain their shared wire vocabulary.
            if let existing = pending.first(where: { rec in
                guard case .object(let p) = rec.payload,
                      let mid = WorkshopStepApprovalPayload.executionId({ key in
                          if case .string(let s)? = p[key] { return s }
                          return nil
                      }),
                      case .string(let sid)? = p["step_id"] else { return false }
                return mid == req.executionId && sid == req.stepId
                    && p["tool"] == .string(req.tool) && p["args"] == req.args
                    && (p["source_args"] ?? p["args"]) == req.sourceArgs
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
                // Workshop decisions may be answered from the paired phone.
                "remoteResolvable": .bool(true),
                "payload": .object([
                    "kind": .string(WorkshopStepApprovalAction.canonical),
                    WorkshopStepApprovalPayload.canonicalExecutionIdKey: .string(req.executionId),
                    "step_id": .string(req.stepId),
                    "tool": .string(req.tool),
                    "args": req.args,
                    "source_args": req.sourceArgs,
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
        let summary = "To continue \(req.taskTitle), approve: \(req.actionDescription)"
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(NativeTimestampFormat.fractionalZulu(Date())),
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
                .string(ExecutionRecordFile.canonicalPath(
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
        let inserted = try await LiveNotificationInbox.live(dataRoot: dataRoot)
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

/// Process-wide handle to the assembled WorkshopExecutorLoop. Approval
/// continuations reuse the executor configured by the app's background loop.
/// Synchronous NSLock instead of an actor so the boot-path factory
/// (makeWorkshopExecutorLoopRunner, a sync function) can configure it
/// race-free without spawning a Task.
public final class WorkshopExecutorRef: @unchecked Sendable {
    public static let shared = WorkshopExecutorRef()

    private let lock = NSLock()
    private var executor: WorkshopExecutorLoop?

    public func configure(_ executor: WorkshopExecutorLoop) {
        lock.lock()
        defer { lock.unlock() }
        self.executor = executor
    }

    /// The assembled executor, or nil when no background-loop assembly has
    /// run in this process yet.
    public func current() -> WorkshopExecutorLoop? {
        lock.lock()
        defer { lock.unlock() }
        return executor
    }

}

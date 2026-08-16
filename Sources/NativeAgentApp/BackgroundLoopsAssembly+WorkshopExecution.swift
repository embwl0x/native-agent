import Foundation
import Darwin
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import DoctorChecks
import MemoryV2
import PersistenceCore
import ProviderRouting
import DreamREMCycle
import TelegramBot
import ApprovalInbox
import WorkshopExecution
import TrustCenter
import MacControl
import SelfImprovement
import NotificationInbox

// MARK: - Workshop Executor

extension BackgroundLoopsAssembly {
    // MARK: - Execution executor (executor port, 2026-06-10)
    //
    // Production wiring for WorkshopExecutorLoop (Executions+Executor.swift):
    // the module stays ApprovalInbox/ChatOrchestration-free, so the LLM
    // call, the gated tool-dispatch chain, the approval stager, and the
    // enableAutonomy+missionPolicy gate are all injected here — the same
    // shape as makeREMProposalStager / makeWeeklySelfImprovementLoop.

    /// Build the fully wired executor. ONE construction point: the
    /// background drain loop AND NativeClient's execution.step
    /// resume-on-approve executor both come through here so resume runs
    /// with the exact closures the original drain ran with.
    static func makeWorkshopExecutor(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> WorkshopExecutorLoop {
        let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
        let cognition = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        // LLM steps route through the SAME per-surface planner client the
        // execution planner uses ("missions" surface picker, OAuth-direct
        // adapters, 120s timeout — daemon run_codex(timeout=120) parity).
        let plannerRouter = SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        )
        let planner = SwiftNativeWorkshopPlannerLLM(
            llm: usesLiveAppBody ? nil : AlternateRootUnavailableBackgroundLLMClient(),
            router: plannerRouter,
            connectorActionsProvider: makeWorkshopPlannerConnectorActionsProvider(dataRoot: dataRoot),
            lifecycleObserver: cognition,
            // Ledger rows follow this executor's root — a test-root executor
            // must not append to the live runs ledger (gpt-5.5 review
            // BLOCKING, 2026-07-02).
            runLedgerDataRoot: dataRoot)
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
                    allowProcessGlobalTools: usesLiveAppBody
                ))
            let client = makeChatOrchestrationClient(
                tools: restricted,
                dataRoot: dataRoot,
                cognitiveObserver: cognition,
                cognitiveContextProvider: cognition,
                providerLifecycleObserver: cognition,
                contextFlow: usesLiveAppBody ? NativeContextFlowRuntime.shared : nil,
                memoryAtomTranslator: usesLiveAppBody
                    ? NativeContextFlowRuntime.memoryRecordAtomID(forRecordID:)
                    : nil
            )
            let response = try await client.runEphemeralToolTurn(
                message: prompt,
                fileAccess: "read_only",
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
        let gatedTools = makeGatedToolDispatchClient(
            tools: SwiftToolDispatcher(
                dataRoot: dataRoot,
                allowProcessGlobalTools: usesLiveAppBody,
                providerLifecycleObserver: cognition,
                macIntegrationBridge: usesLiveAppBody ? MacIntegrationBridgeImpl() : nil
            ),
            fileAccess: "auto",
            approvalFiler: nil,
            dataRoot: dataRoot
        )
        let toolStep: WorkshopStepToolDispatch = { tool, args in
            guard case .object(let dict) = args else {
                throw NSError(domain: "WorkshopExecutor", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "step args must be a JSON object",
                ])
            }
            return try await gatedTools.dispatch(tool: tool, input: dict, surface: "mission")
        }
        return WorkshopExecutorLoop(
            root: dataRoot,
            measuredLLMStep: measuredLLMStep,
            measuredTooledLLMStep: measuredTooledLLMStep,
            toolDispatch: toolStep,
            stageApproval: makeWorkshopStepApprovalStager(dataRoot: dataRoot),
            isEnabled: { await workshopExecutorGate(dataRoot: dataRoot) },
            // YOLO: under wide-open trust, don't gate the planner's per-tool
            // needs_approval default — Workshop executions run unattended. An explicit
            // per-Workshop execution trustRequired still gates inside the executor.
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

    /// True when the Trust policy is a wide-open / full-mac "yolo" posture, in
    /// which Workshop execution tool steps should run unattended (no per-step approval).
    static func isWideOpenTrust(dataRoot: URL) async -> Bool {
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policy = await trust.loadTrustPolicy()
        if case .string(let level) = policy["permissionLevel"] ?? .null {
            return level == "full_mac_os" || level == "wide_open_receipts"
        }
        return false
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
    static func workshopExecutorGate(dataRoot: URL) async -> Bool {
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policy = await trust.loadTrustPolicy()
        guard case .bool(true) = policy["enableAutonomy"] ?? .null else {
            return false
        }
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
    static func makeWorkshopStepApprovalStager(dataRoot: URL) -> WorkshopStepApprovalStager {
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
            }) {
                do {
                    try await ensureWorkshopStepInboxCard(
                        dataRoot: dataRoot, approvalId: existing.id, req: req)
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
                    dataRoot: dataRoot, approvalId: rec.id, req: req)
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
        req: WorkshopStepApprovalRequest
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(fmt.string(from: Date())),
            "source": .string("workshop"),
            "severity": .string("actionable"),
            "title": .string(req.title),
            "summary": .string("Desk execution \(req.executionId) is blocked on step \(req.stepId) (\(req.tool))."),
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
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: approvalId,
                title: req.title,
                summary: "Desk execution \(req.executionId) is blocked on step \(req.stepId) (\(req.tool)).",
                source: "workshop",
                severity: "actionable"
            )
        }
    }

    /// Drain-loop wrapper for the scheduler (LoopRunner lives in
    /// BackgroundLoops; WorkshopExecutorLoop deliberately doesn't import it).
    ///
    /// gpt-5.5 executor-port blocker #1 (2026-06-10): the ASSEMBLED executor
    /// instance is also published to WorkshopExecutorRef.shared here, so
    /// NativeClient.startWorkshopExecution can route explicit "Start execution" requests
    /// through the SAME actor (same injected LLM/tool/stager closures, same
    /// actor serialization) the background drain loop runs — mirror of the
    /// AppRestartCoordinator.shared.configure app-boot wiring pattern.
    /// assembleAllLoops → BackgroundLoopsManager.start() calls this once at
    /// app launch; until then the ref is unconfigured and startWorkshopExecution
    /// throws an honest "executor not running" error.
    static func makeWorkshopExecutorLoopRunner(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> some LoopRunner {
        let executor = makeWorkshopExecutor(
            dataRoot: dataRoot,
            cognitionRuntime: cognitionRuntime
        )
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            WorkshopExecutorRef.shared.configure(executor)
        }
        return WorkshopExecutorDrainRunner(dataRoot: dataRoot, executor: executor)
    }
}

/// Process-wide handle to the ASSEMBLED WorkshopExecutorLoop (gpt-5.5
/// executor-port blocker #1, 2026-06-10). The executor actor is constructed
/// with injected closures in BackgroundLoopsAssembly.makeMissionExecutor and
/// registered as a background loop at app boot; NativeClient.startWorkshopExecution
/// needs that SAME instance to serve the UI "Start execution" path (the
/// WorkshopRunnerClient protocol's start() deliberately throws — the runner
/// holds no executor closures). Same shared-singleton wiring shape as
/// AppRestartCoordinator.shared.configure: the app layer configures it at
/// boot, and an UNCONFIGURED ref makes callers throw an honest "executor
/// not running" error — never a silent no-op (headless/test builds).
/// Synchronous NSLock instead of an actor so the boot-path factory
/// (makeMissionExecutorLoopRunner, a sync function) can configure it
/// race-free without spawning a Task.
final class WorkshopExecutorRef: @unchecked Sendable {
    static let shared = WorkshopExecutorRef()

    private let lock = NSLock()
    private var executor: WorkshopExecutorLoop?

    func configure(_ executor: WorkshopExecutorLoop) {
        lock.lock()
        defer { lock.unlock() }
        self.executor = executor
    }

    /// The assembled executor, or nil when no background-loop assembly has
    /// run in this process yet.
    func current() -> WorkshopExecutorLoop? {
        lock.lock()
        defer { lock.unlock() }
        return executor
    }

    /// Test seam — restore the unconfigured boot state.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        executor = nil
    }
}

/// Event/deadline adapter for WorkshopExecutorLoop. Canonical execution-file
/// mutations wake the queue immediately; configured approval timeouts own one
/// exact persisted deadline. The daily interval is only a crash/missed-event
/// integrity pass. A drained execution may still run multi-minute LLM/tool
/// steps, so the 1800s timeout remains.
private struct WorkshopExecutorDrainRunner: EventDeadlineLoopRunner {
    let loopId = "mission_executor"
    let interval: TimeInterval = 24 * 60 * 60
    var tickTimeoutOverride: TimeInterval? { 1800 }
    let dataRoot: URL
    let executor: WorkshopExecutorLoop

    func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("workshop/executions", isDirectory: true),
        ])
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        await executor.nextMeaningfulDeadline(after: now)
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        await executor.drainOnce()
        if Task.isCancelled { return .skipped(reason: "Desk executor canceled") }
        return .completed(result: "Desk execution drain completed")
    }
}

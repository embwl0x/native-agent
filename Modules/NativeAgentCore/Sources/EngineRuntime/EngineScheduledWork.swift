import Foundation
import NativeAgentCore
import AgentConversations
import AppToolRuntime
import AttentionRouting
import AuthoredCapabilities
import BackgroundLoops
import BackgroundWork
import ChatToolParsing
import ChatToolRuntime
import ChatTurnRuntime
import Cognition
import Desk
import DoctorChecks
import MemoryV2
import PersistenceCore
import SchedulerExecution
import StandingBots
import TelegramBot
import ToolExecution
import TriggerScheduler
import WorkshopExecution
// Blueprint: | `EngineScheduledWork.swift` | NativeAgentEngine trigger scheduler and Workshop composition; SchedulerDueJobRunner native effects; scheduled reads enter withPartDoor and watchRefusal before dispatch |

// User schedules stay canonical in scheduler/jobs.json and the trigger stores.
// BackgroundLoopLifetimes owns lifecycle, single-flight execution and deadlines.

extension NativeAgentEngine {
    public static func makeNativeTriggerScheduler(dataRoot: URL) -> SwiftNativeTriggerScheduler {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let workshopRunner: SwiftNativeWorkshopRunner? = isLiveRoot
            ? makeWorkshopRunner(lifecycleObserver: NativeAgentEngine.liveCognition)
            : nil
        let notifier: TriggerNotifier? = isLiveRoot
            ? NativeAgentEngine.live.ports.backgroundWork.triggerNotifier
            : nil
        return SwiftNativeTriggerScheduler(
            root: standardized,
            workshopRunner: workshopRunner,
            notifier: notifier,
            worklogPath: isLiveRoot
                ? AgentConversationView.claudeWorklogURL
                : standardized.appendingPathComponent("no-such-worklog.jsonl"),
            morningBriefPart: { input in
                if !isLiveRoot, input.objectValue?["operation"] == .string("brief") {
                    throw TriggerSchedulerError.persistenceFailure("A secondary root cannot spend the live morning-brief model route.")
                }
                let engine = NativeAgentEngine.forRoot(standardized)
                return try await engine.tools.withPartDoor(envelope: .native("trigger:morning_brief"), fileAccess: "read_only") {
                    switch await Parts(root: standardized).call(id: "native-morning-brief", input: input, as: JSONValue.self) {
                    case .success(let value): return value
                    case .failure(let error): throw error
                    }
                }
            }
        )
    }

    public static func makeTriggerSchedulerLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized == PersistenceCore.defaultDataRoot().standardizedFileURL
        let native = makeNativeTriggerScheduler(dataRoot: standardized)
        let dueJobRunner = SchedulerDueJobRunner(root: standardized)
        let runDueJobs: @Sendable () async -> [String]
        let shutdownJobs: @Sendable () async -> Void
        let schedulerActivityFailure: @Sendable () async -> String?
        let nextJobDeadline: @Sendable (Date) async -> Date?
        if isLiveRoot {
            // Scheduled bot spend shares Workshop's Autonomy gate; manual requests
            // are admitted inside the scheduler without this gate.
            let work = TriggerSchedulerBackgroundWork.makeJobWork(
                runDueJobs: { await dueJobRunner.runDueJobs(maxJobs: $0) },
                activityFailure: { await dueJobRunner.activityFeedError },
                nextDeadline: { await dueJobRunner.nextMeaningfulDeadline(after: $0) },
                bots: NativeAgentEngine.live.bots,
                continuations: makeTurnContinuationRuntime(dataRoot: standardized).makeDeskContinuationScheduler()
            )
            runDueJobs = work.runDueJobs
            shutdownJobs = work.shutdown
            schedulerActivityFailure = work.activityFailure
            nextJobDeadline = work.nextDeadline
        } else {
            // Scheduler jobs can dispatch process-global notification,
            // connector, provider, and sync owners. Secondary/test roots may
            // inspect their own files but never borrow those live effects.
            runDueJobs = { [] }
            shutdownJobs = {}
            schedulerActivityFailure = { nil }
            nextJobDeadline = { _ in nil }
        }
        return TriggerSchedulerEventDeadlineRunner(
            dataRoot: standardized,
            events: { paths, loopId in
                EventDeadlinePhysiology.storeAndFileEvents(paths: paths, notifications: [
                    BotRunQueue.didChange,
                    DeskContinuationScheduler.ownerReceiptChanged,
                    SwiftNativeTriggerScheduler.dueWorkRemaining,
                    // A part's `schedule:` wakes are its own jobs, kept with its header.
                    AbilityStore.didChange,
                    // Clock and time-zone changes invalidate absolute local-time deadlines.
                    .NSSystemClockDidChange,
                    .NSSystemTimeZoneDidChange,
                ], loopId: loopId)
            },
            schedulerJobsPath: dueJobRunner.jobsPath,
            triggerScheduler: native,
            runDueJobs: runDueJobs,
            shutdownJobs: shutdownJobs,
            schedulerActivityFailure: schedulerActivityFailure,
            nextSchedulerJobDeadline: nextJobDeadline
        )
    }

}

// The pump makes no provider call on a quiet day; sessions use WorkshopToolProfile.

extension NativeAgentEngine {

    /// Compose Desk, the shared work lease and receipts, bounded sessions,
    /// organism posture and unattended-work admission.
    public static func makeWorkshopPump(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> WorkshopPump {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let cognition = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return WorkshopPump(
            dataRoot: dataRoot,
            store: store,
            lease: BackgroundWorkLease(dataRoot: dataRoot),
            receiptLog: WorkshopReceiptLog(dataRoot: dataRoot),
            sessionRunner: WorkshopSession(
                dataRoot: dataRoot, store: store,
                effects: EngineWorkshopSessionEffects()
            ),
            posture: { await cognition.organismBehaviorPosture() },
            isEnabled: { await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) }
        )
    }

    /// Event/deadline wrapper. Desk/trust/body mutations reconcile after one
    /// coalesced edge; the next persisted cadence or two-hour Workshop window
    /// owns one exact deadline. The daily interval is only missed-event
    /// integrity recovery. tickTimeoutOverride remains 1800s because a run may
    /// execute one multi-minute bounded LLM session.
    public static func makeWorkshopPumpLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> some LoopRunner {
        WorkshopPumpLoopRunner(dataRoot: dataRoot, pump: makeWorkshopPump(
            dataRoot: dataRoot,
            cognitionRuntime: cognitionRuntime
        ))
    }
}

extension NativeAgentEngine {
    public static func makeWorkshopExecutor(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> WorkshopExecutorLoop {
        let cognition = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        // Steps, synthesize turns and the swarm workers a step starts enter a
        // turn's app door (its authored-program host included). The gate in
        // front resolves autonomy once; the door keeps SecurityCenter's hard checks.
        let engine = NativeAgentEngine.forRoot(dataRoot)
        return WorkshopBackgroundWork.makeWorkshopExecutor(
            dataRoot: dataRoot, cognition: cognition,
            chatClient: { engine.chatClient(tools: engine.toolDispatchClient(enforceAppAutonomy: false)) },
            toolDispatch: { tool, input, replay in
                try await engine.tools.withPartDoor(envelope: .native("workshop:step", surface: "mission"), approvedReplay: replay) {
                    if let schema = try await engine.toolDispatchClient(enforceAppAutonomy: false).listAvailableToolSchemas().first(where: { $0.name == tool }) {
                        try WorkshopArgumentValidation.validate(.object(input), schema: JSONValue.parse(schema.parametersJSON))
                    }
                    guard let dispatch = AppDoorReentry.perform else {
                        throw PartCallError(code: "door_unavailable", message: "The Workshop step has no originating app door.")
                    }
                    return try await dispatch(tool, input)
                }
            },
            notify: workshopInboxNotification
        )
    }

    public static let workshopInboxNotification: WorkshopInboxNotification = { root, id, title, summary, source, severity in
        await NativeAgentEngine.live.ports.backgroundWork.attention.notifyIfAttentionWorthy(
            dataRoot: root, itemId: id, title: title, summary: summary, source: source, severity: severity
        )
    }

    /// A fresh root-bound runner for Desk submission and step decisions; its planner uses the real tool catalog.
    public static func makeWorkshopExecutionRunner(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> WorkshopExecution.SwiftNativeWorkshopRunner {
        let connectorActions = makeWorkshopPlannerConnectorActionsProvider(dataRoot: dataRoot)
        let cognition = cognitionRuntime(for: dataRoot)
        let isLiveRoot = dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
        return WorkshopExecution.SwiftNativeWorkshopRunner(
            root: dataRoot,
            planner: isLiveRoot
                ? SwiftNativeWorkshopPlannerLLM(connectorActionsProvider: connectorActions, lifecycleObserver: cognition)
                : SwiftNativeWorkshopPlannerLLM(dataRoot: dataRoot, connectorActionsProvider: connectorActions,
                                                lifecycleObserver: cognition))
    }

    public static func makeWorkshopExecutorLoopRunner(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> some LoopRunner {
        let executor = makeWorkshopExecutor(
            dataRoot: dataRoot,
            cognitionRuntime: cognitionRuntime
        )
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            // Approvals and background drains share this assembled executor actor.
            WorkshopExecutorRef.shared.configure(executor)
        }
        return WorkshopExecutorDrainRunner(dataRoot: dataRoot, executor: executor)
    }
}

extension SchedulerDueJobRunner {
    public static let shared = SchedulerDueJobRunner()

    public init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.init(root: root, platform: EngineSchedulerExecutionPlatform())
    }
}

struct EngineSchedulerExecutionPlatform: SchedulerExecutionPlatform {
    var attentionRouter: AttentionRouter { NativeAgentEngine.live.ports.backgroundWork.attention }

    func postNotification(title: String, body: String) async -> NativeAgentNotificationPostResult {
        await NativeAgentEngine.live.ports.backgroundWork.postMacNotification(title: title, body: body, userInfo: [:], soundName: nil)
    }

    func sendTelegramMessage(message: String) async throws {
        _ = try await SwiftNativeTelegramBot().sendTestMessage(message: message, chatId: nil)
    }

    func notifyInboxIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String, summary: String,
        source: String, severity: String
    ) async {
        await NativeAgentEngine.live.ports.backgroundWork.attention.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity
        )
    }

    /// Judged inside the door, once its chain (and so the action table) is assembled:
    /// a part rewritten since it was scheduled is held to what it is now.
    func read(action: String, input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeAgentEngine.live.tools.withPartDoor(envelope: .native("scheduler:watch:" + action)) {
            if let refusal = SwiftNativeTriggerScheduler.watchRefusal(action: action, input: input) {
                throw PartCallError(code: "not_a_read", message: refusal)
            }
            guard let dispatch = AppDoorReentry.perform else {
                throw PartCallError(code: "door_unavailable", message: "The scheduled read of \(action) has no originating app door.")
            }
            let result = try await dispatch("app", ["action": .string(action), "args": .object(input)])
            guard ChatToolOutcome.outputLooksSuccessful(result) else {
                throw PartCallError(code: "read_failed", message: "\(action) did not read: "
                    + ChatToolOutcome.displaySummary(outcome: .failed, input: nil, result: result)
                    + (ChatToolOutcome.remedy(result).map { " " + $0 } ?? ""))
            }
            return result
        }
    }

    func runDream(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runDream(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runRem(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runRem(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runHarnessBenchmark() async throws -> (id: String, status: String?) {
        let root = PersistenceCore.defaultDataRoot()
        let run = await HarnessBenchmarkRun.run(
            authoredToolCount: { try await ToolsFacade(dataRoot: root).listAuthored().count },
            embeddingRuntimeAvailable: { await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() != nil },
            doctorStatuses: { await makeDoctorChecks().runAll().map(\.status) }
        )
        return (run.id, run.status)
    }

    func createWorkshopTask(
        title: String, objective: String, projectSpaceId: String?
    ) async throws -> (id: String, status: String) {
        let execution = try await NativeAgentEngine.submitDeskTask(
            title: title, objective: objective, projectSpaceId: projectSpaceId
        ).execution
        return (execution.id, execution.status)
    }

    func runScheduledTurn(name: String, prompt: String) async throws -> (model: String, output: String) {
        let root = PersistenceCore.defaultDataRoot()
        let tools = EngineWorkshopSessionEffects().makeToolDispatcher(dataRoot: root)
        let client = NativeAgentEngine.live.chatClient(tools: tools)
        let response = try await LLMCallContext.$purpose.withValue("scheduled_turn") {
            try await client.runEphemeralToolTurn(
                message: prompt, fileAccess: "auto", requireCompleted: true, surface: "chat")
        }
        return (response.model, response.output)
    }
}

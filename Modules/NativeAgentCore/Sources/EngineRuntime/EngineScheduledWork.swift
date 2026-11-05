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
// Blueprint: | `EngineScheduledWork.swift` | Canonical job deadlines and gated reads; the due-job owner tells scheduled matters |

// Keep schedules canonical in their stores; BackgroundLoopLifetimes owns execution and deadlines.

extension NativeAgentEngine {
    public static func makeNativeTriggerScheduler(dataRoot: URL) -> SwiftNativeTriggerScheduler {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let notifier: TriggerNotifier? = isLiveRoot
            ? NativeAgentEngine.live.ports.backgroundWork.triggerNotifier
            : nil
        return SwiftNativeTriggerScheduler(
            root: standardized,
            notifier: notifier,
            worklogPath: isLiveRoot
                ? AgentConversationView.claudeWorklogURL
                : standardized.appendingPathComponent("no-such-worklog.jsonl"),
            morningBriefPart: { input in
                if !isLiveRoot, input.objectValue?["operation"] == .string("brief") {
                    throw TriggerSchedulerError.persistenceFailure("A secondary root cannot spend the live morning-brief model route.")
                }
                let engine = NativeAgentEngine.forRoot(standardized)
                return try await engine.tools.withPartDoor(envelope: .native("trigger:morning_brief"), fileAccess: "read_only") { door in
                    switch await Parts(root: standardized).call(id: "native-morning-brief", input: input, invocation: door.invocation, as: JSONValue.self) {
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
            // Gate scheduled bot spend by Autonomy; explicit manual requests are admitted by the scheduler.
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
            // Only the installed root may use process-global live effects; secondary roots remain file-scoped.
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
                    // Scheduled wakes belong to the part header’s own jobs.
                    AbilityStore.didChange,
                    // Clock and zone changes invalidate local-time deadlines.
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

extension SchedulerDueJobRunner {
    public static let shared = SchedulerDueJobRunner()

    public init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.init(root: root, platform: EngineSchedulerExecutionPlatform(dataRoot: root))
    }
}

struct EngineSchedulerExecutionPlatform: SchedulerExecutionPlatform {
    let dataRoot: URL
    var attentionRouter: AttentionRouter { NativeAgentEngine.forRoot(dataRoot).ports.backgroundWork.attention }

    func postNotification(title: String, body: String) async -> NativeAgentNotificationPostResult {
        await NativeAgentEngine.live.ports.backgroundWork.postMacNotification(title: title, body: body, userInfo: [:], soundName: nil)
    }

    /// Admit scheduled parts against their current contract after assembling the gate chain.
    func read(action: String, input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeAgentEngine.live.tools.withPartDoor(envelope: .native("scheduler:watch:" + action)) { door in
            if let refusal = SwiftNativeTriggerScheduler.watchRefusal(action: action, input: input, turn: door.turn) {
                throw PartCallError(code: "not_a_read", message: refusal)
            }
            let result = try await door.perform("app", ["action": .string(action), "args": .object(input)])
            let reply = ToolResult(result)
            // The old predicate lowercased status but did not trim it or read state.
            let exactStatus = reply.payload.objectValue?["status"]?.stringValue?.lowercased() == reply.status
            let skipped = exactStatus && (reply.said("skipped") || reply.said("needs_input"))
            guard !reply.outcome.isFailure && !(reply.outcome == .unknown && skipped) else {
                throw PartCallError(code: "read_failed", message: "\(action) did not read: "
                    + ChatToolOutcome.displaySummary(outcome: .failed, input: nil, result: reply.payload)
                    + (ChatToolOutcome.remedy(reply.payload).map { " " + $0 } ?? ""))
            }
            return reply.payload
        }
    }

    func runDream(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runDream(dataRoot: dataRoot, force: force)
    }

    func runRem(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runRem(dataRoot: dataRoot, force: force)
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

}

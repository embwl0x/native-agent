import AuthoredCapabilities
import ActivityWatch
import Foundation
import Context
import OSLog
import ApprovalTransactions
import BackgroundLoops
import BackgroundWork
import Browser
import ChatTurnRuntime
import ChatToolParsing
import ChatToolRuntime
import ChatSessionWork
import Cognition
import Connectors
import ContextFlow
import Desk
import MemoryV2
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import Procedures
import PersonaEngine
import Transcripts
import TurnTrace
import WorkshopExecution
import AgentConversations
import Agents
import AppToolRuntime
import ApprovalInbox
import AttentionRouting
import CognitiveSubstrate
import DeviceSync
import DoctorChecks
import MacControl
import ProviderRouting
import SchedulerExecution
import SlackBot
import StandingBots
import TelegramBot
import TriggerScheduler
import TrustCenter
import TrustPersistence
import AgentWorkspace
import Privacy
import Darwin
import NativeAgentShared
import Senses
import ToolExecution
import Studio
// Blueprint: | `EngineComposition.swift` | Concrete runtime and background-work composition through the existing root-bound engine ports |

extension NativeAgentEngine {

    /// Resolve the one cognition owner for a loop body. Alternate roots must never observe or mutate the process-global personal runtime.
    public static func cognitionRuntime(
        for dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> NativeCognitionRuntime {
        let standardized = dataRoot.standardizedFileURL
        return standardized == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? NativeAgentEngine.liveCognition
            : NativeCognitionRuntime(dataRoot: standardized, host: NativeAgentEngine.live.ports.cognitionHost,
                                     contextFlow: NativeContextFlowRuntime(dataRoot: standardized))
    }

    /// Body work shares the resident turn provider assembly and its exact credential/routing resolution. PersonaBackedBackgroundLLMClient supplies persona, user-memory core and organism posture when persona context is absent. Background
    /// calls carry the same idle and wall as resident turns, so one stalled call cannot hold the memory promotion chain forever.
    public static func makeSharedLLMClient(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> any LLMClient {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        let inner = makeResidentProviderLLMClient(dataRoot: dataRoot, lifecycleObserver: runtime)
        return PersonaBackedBackgroundLLMClient(
            inner: inner,
            dataRoot: dataRoot,
            cognitionRuntime: runtime
        )
    }
    /// Full loop manifest for BackgroundLoopLifetimes: doctor, memory, self-improvement, Workshop execution executor, heartbeat, and hooks. A periodic dream wrapper is intentionally absent from this manifest: unattended dreams have exactly
    /// one owner, the `nativeagent-nightly-dream` TriggerScheduler job at 03:30 Mac-local. A periodic REM wrapper is absent for the same reason: `nativeagent-weekly-rem` at 04:30 Mac-local on Sundays owns weekly REM.
    public static func assembleAllLoops(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [LoopRegistration] {
        let cognition = cognitionRuntime(for: dataRoot)
        let llm = makeSharedLLMClient(dataRoot: dataRoot, cognitionRuntime: cognition)
        let runners: [any LoopRunner] = [
            makeAutoDoctorLoop(dataRoot: dataRoot),
            makeTurnTraceRetentionLoop(dataRoot: dataRoot),
            makeOffDiskBackupLoop(dataRoot: dataRoot),
            // Disk hygiene detects oversize files and files one card; never deletes.
            makeDataRootDiskHygieneLoop(dataRoot: dataRoot),
            makeWeeklySelfImprovementLoop(dataRoot: dataRoot, llm: llm),
            // No `rem_cycle` entry: the `nativeagent-weekly-rem` TriggerScheduler job is the sole owner of weekly REM (see the manifest note above). User-authored scheduler jobs and time/idle triggers use exact persisted deadlines plus
            // config/activity invalidations. Core owns the only lifecycle; the six-hour cadence is missed-event repair.
            makeTriggerSchedulerLoop(dataRoot: dataRoot),
            makeWorkshopExecutorLoopRunner(dataRoot: dataRoot, cognitionRuntime: cognition),
            // The pump reserves a Desk slot before one bounded self-pursuit session.
            makeWorkshopPumpLoop(dataRoot: dataRoot, cognitionRuntime: cognition),
            CognitiveMaintenanceLoop(interval: 24 * 60 * 60, runtime: cognition),
            CognitiveReplayLoop(interval: 24 * 60 * 60, runtime: cognition),
            CognitiveReflectionLoop(interval: 24 * 60 * 60, llm: llm, runtime: cognition),
            // Cue authoring is manual-only; production scheduling requires a live consumer.
            makeHeartbeatLoop(dataRoot: dataRoot),
            // Desk notifications read marked items without touching cognition.
            makeDeskNotifyLoop(dataRoot: dataRoot),
            // A durable cursor files each delegation terminal card once.
            makeDelegationOutcomeLoop(dataRoot: dataRoot),
        ]
        var loops = runners.map(LoopRegistration.enabled)
        loops.append(makeTelegramPollLane(dataRoot: dataRoot))
        loops.append(makeSlackSocketModeLane(dataRoot: dataRoot))
        return loops
    }
}

extension NativeAgentEngine {
    public static func makeTurnContinuationRuntime(dataRoot: URL) -> TurnContinuationRuntime {
        TurnContinuationRuntime(dataRoot: dataRoot, engine: .forRoot(dataRoot),
            telegramApprovalFiler: { ApprovalChatCards.runningTelegram },
            makeSender: { silent, notificationID, authorize in
                NativeAgentEngine.live.ports.backgroundWork.makeCompletionSender(dataRoot: dataRoot, silentTelegram: silent,
                    requestedResultDeliveryID: notificationID, authorizeTelegramReply: authorize)
            })
    }
}

extension NativeAgentEngine {
    public static func makeDelegationOutcomeLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configRoot: URL? = nil
    ) -> some EventDeadlineLoopRunner {
        DelegationBackgroundWork(port: EngineBackgroundWorkPort()).makeDelegationOutcomeLoop(dataRoot: dataRoot, configRoot: configRoot)
    }
}

extension EngineBackgroundWorkPort: DelegationBackgroundWorkPort {
    func letGoReplies(deliveryIDs: Set<String>, outcome: String, dataRoot: URL, configRoot: URL) async throws {
        try await CodexCompletionLifecycle.letGoReplies(deliveryIDs: deliveryIDs, outcome: outcome,
            dataRoot: dataRoot, configRoot: configRoot)
    }

    func reconcileReplyDeliveries(dataRoot: URL) async throws {
        try await NativeAgentEngine.live.agents.continuation.reconcileReplies()
        try await NativeAgentEngine.makeTurnContinuationRuntime(dataRoot: dataRoot).reconcileReplyMirror()
        if let telegram = await BackgroundLoops.BackgroundLoopLifetimes.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop {
            try await telegram.reconcileSavedReplies()
        }
        if let slack = await BackgroundLoops.BackgroundLoopLifetimes.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop {
            try await slack.reconcileSavedReplies()
        }
    }
    func retryRequestedResults(dataRoot: URL) async throws {
        try await NativeAgentEngine.live.ports.backgroundWork.attention.retryRequestedResults(dataRoot: dataRoot)
    }

    var agentSubject: String { NativeAgentEngine.live.ports.backgroundWork.agentSubject }

    func observeMotorActionState(_ model: MotorActionReadModel) async {
        await NativeAgentEngine.liveCognition.observeMotorActionState(model)
    }

    func reconcileAgentConversations() async throws {
        try await NativeAgentEngine.live.agents.continuation.tick()
    }

    func stopAgentConversations() async {
        await NativeAgentEngine.live.agents.continuation.stop()
    }

    func nextConversationDeadline(after now: Date) -> Date? {
        NativeAgentEngine.live.agents.continuation.nextDeadline(after: now)
    }
}

// MARK: - Desk notifications
// The part selects changed work; native owners gate cooldown/quiet hours, deliver Mac and paired-device
// pushes, and stamp lastNotifiedAt to prevent duplicates, without touching CognitiveSubstrate.

extension NativeAgentEngine {
    public static func makeDeskNotifyLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        postMacNotification: @escaping @Sendable (String, String, [String: String], String?) async -> Bool = { title, body, userInfo, sound in
            await NativeAgentEngine.live.ports.backgroundWork.postMacNotification(title: title, body: body, userInfo: userInfo, soundName: sound).posted
        }
    ) -> some LoopRunner {
        DeskNotifyRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot,
            attention: NativeAgentEngine.live.ports.backgroundWork.attention,
            propose: { input in
                try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native("background:desk_notify")) {
                    switch await Parts(root: dataRoot).call(id: "desk-notify", input: input, as: DeskNotificationProposal.self) {
                    case .success(let proposal): return proposal
                    case .failure(let error): throw error
                    }
                }
            },
            postMacNotification: postMacNotification,
            postNagNotification: { title, body, handle in
                await NativeAgentEngine.live.ports.backgroundWork.postMacNotification(
                    title: title, body: body,
                    userInfo: handle.map { [NativeAgentNotificationRoute.deskHandleKey: $0] } ?? [:],
                    soundName: nil
                ).posted
            }
        )
    }
}

extension NativeAgentEngine {
    public static func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> HeartbeatLoop {
        HeartbeatBackgroundWork(port: EngineBackgroundWorkPort()).makeHeartbeatLoop(dataRoot: dataRoot)
    }
}

struct EngineBackgroundWorkPort: BackgroundWorkNotificationPort {
    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String,
        summary: String, source: String, severity: String
    ) async {
        await NativeAgentEngine.live.ports.backgroundWork.attention.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title,
            summary: summary, source: source, severity: severity
        )
    }
}

extension NativeAgentEngine {
    public static func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil,
        freshMeasurement: Bool = false
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeAutoDoctorLoop(dataRoot: dataRoot, intervalSeconds: intervalSeconds, freshMeasurement: freshMeasurement)
    }

    public static func makeTurnTraceRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeTurnTraceRetentionLoop(dataRoot: dataRoot, intervalSeconds: intervalSeconds)
    }

    public static func makeOffDiskBackupLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeOffDiskBackupLoop(dataRoot: dataRoot)
    }

    public static func makeWeeklySelfImprovementLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> WeeklySelfImprovementLoop {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeWeeklySelfImprovementLoop(
            dataRoot: dataRoot, llm: llm, workshopOutcomes: {
                let engine = NativeAgentEngine.forRoot(dataRoot)
                return try await engine.tools.withPartDoor(envelope: .native("maintenance:self_improvement_sweep:weekly-outcomes")) {
                    let input = try await SwiftNativeWorkshopRunner(root: dataRoot).weeklyOutcomeInput()
                    let result = await Parts(root: dataRoot).call(id: "weekly-outcomes", input: input, as: String.self)
                    try Task.checkCancellation()
                    switch result {
                    case .success(let text): return text
                    case .failure(let error): throw error
                    }
                }
            })
    }

    public static func makeDataRootDiskHygieneLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DataRootDiskHygieneCheck {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeDataRootDiskHygieneLoop(dataRoot: dataRoot)
    }

    public static func cleanUpDiskHygiene(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        try await MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).cleanUpDiskHygiene(dataRoot: dataRoot)
    }
}

extension EngineBackgroundWorkPort: MaintenanceBackgroundWorkPort {
    func diskStorageOwners(dataRoot: URL) -> [DiskStorageOwner] {
        [TrustBackupPersistence.diskStorageOwner(dataRoot: dataRoot), ChatSessionRetention.diskStorageOwner,
         ContextSQLiteStore.diskStorageOwner]
    }

    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> [CheckResult] {
        // An automatic run (launch, first turn, the weekly sweep) takes the same lifecycle as Run: admitted only when no run is in flight, and its report is the one the Doctor page and the pill read, so a relaunch is never left at "no
        // report" while one ran.
        let doctor = NativeAgentEngine.live.doctor
        let owned = doctor.dataRoot == dataRoot
        if owned, !(await doctor.admitRun()) { return [] }
        do {
            let report = try await NativeAgentEngine.live.ports.backgroundWork.runAutoDoctor(checks: checks, dataRoot: dataRoot)
            if owned {
                let rows = await DoctorReadout.repairProjection(report.checks, dataRoot: dataRoot)
                await doctor.finishRun(DoctorReport(status: DoctorReadout.doctorRollup(rows.map(\.status)),
                                                    repaired: report.repaired, checks: rows))
            }
            return report.checks
        } catch {
            if owned { await doctor.finishRun(nil) }
            throw error
        }
    }

    func routeDoctorAsk(eventID: String, title: String, detail: String) async throws {
        try await NativeAgentEngine.live.ports.backgroundWork.attention.route(
            eventId: eventID, importance: .ownerWaiting, title: title, body: detail,
            userInfo: ["screen": "inbox", "source": "doctor_ask", "itemId": "doctor-ask", "dedupKey": eventID]
        )
    }

    var unavailableSkipPrefix: String { DoctorLoopHealth.unavailableSkipPrefix }

    func offDiskBackupParent() -> URL { TrustBackupPersistence.offDiskBackupParent() }

    func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)] {
        try TrustBackupPersistence.offDiskAutomaticBackups(in: parent)
    }

    func createOffDiskBackup(reason: String, dataRoot: URL, parent: URL, now: Date) async throws -> URL {
        try await TrustBackupPersistence.createOffDiskBackup(
            reason: reason, dataRoot: dataRoot, parent: parent, now: now
        )
    }
}

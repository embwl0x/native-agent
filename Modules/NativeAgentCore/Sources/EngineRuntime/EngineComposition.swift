import AuthoredCapabilities
import ActivityWatch
import Foundation
import ChatTurnContracts
import Experiences
import Context
import OSLog
import ApprovalTransactions
import BackgroundLoops
import BackgroundWork
import DreamREMCycle
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
import PersonaEngine
import Transcripts
import TurnTrace
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
// Blueprint: | `EngineComposition.swift` | Root-bound body ports forward typed matters to the attention router |

extension NativeAgentEngine {

    /// Alternate roots must never observe or mutate the process-global personal cognition runtime.
    public static func cognitionRuntime(
        for dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> NativeCognitionRuntime {
        let standardized = dataRoot.standardizedFileURL
        return standardized == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? NativeAgentEngine.liveCognition
            : NativeCognitionRuntime(dataRoot: standardized, host: NativeAgentEngine.live.ports.cognitionHost,
                                     contextFlow: NativeContextFlowRuntime(dataRoot: standardized))
    }

    /// Share resident routing, credentials and call limits so a stalled background call cannot hold memory promotion forever.
    public static func makeSharedLLMClient(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil,
        assembly: PrivateWorkContextAssembly
    ) -> any LLMClient {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        let inner = makeResidentProviderLLMClient(dataRoot: dataRoot, lifecycleObserver: runtime)
        return PersonaBackedBackgroundLLMClient(
            inner: inner,
            dataRoot: dataRoot,
            cognitionRuntime: runtime, assembly: assembly
        )
    }
    /// The night owns dreams and REM; registered loops serve their own evidence.
    public static func assembleAllLoops(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [LoopRegistration] {
        let cognition = cognitionRuntime(for: dataRoot)
        let runners: [any LoopRunner] = [
            makeAutoDoctorLoop(dataRoot: dataRoot),
            makeOffDiskBackupLoop(dataRoot: dataRoot),
            // Disk hygiene files an oversize notice; it never deletes.
            makeDataRootDiskHygieneLoop(dataRoot: dataRoot),
            CognitiveMaintenanceLoop(interval: NativeCognitionRuntime.substrateClockCadence, runtime: cognition),
            CognitiveReplayLoop(interval: NativeCognitionRuntime.substrateClockCadence, runtime: cognition),
            // Cue authoring requires a live consumer before production scheduling.
            makeHeartbeatLoop(dataRoot: dataRoot),
            // Desk notifications must not touch cognition.
            makeDeskNotifyLoop(dataRoot: dataRoot),
            // A durable cursor prevents duplicate delegation terminal cards.
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
        _ = try await CodexCompletionLifecycle.letGoReplies(deliveryIDs: deliveryIDs, outcome: outcome,
            dataRoot: dataRoot, configRoot: configRoot)
    }

    /// Run every reply owner independently before reporting failures so one cannot suppress its siblings.
    func reconcileReplyDeliveries(dataRoot: URL) async throws {
        var failures: [String] = []
        func run(_ owner: String, _ body: () async throws -> Void) async {
            do { try await body() } catch { failures.append("\(owner): \(error.localizedDescription)") }
        }
        await run("agent replies") { try await NativeAgentEngine.live.agents.continuation.reconcileReplies() }
        await run("Telegram mirror") { try await NativeAgentEngine.makeTurnContinuationRuntime(dataRoot: dataRoot).reconcileReplyMirror() }
        if let telegram = await BackgroundLoops.BackgroundLoopLifetimes.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop {
            await run("Telegram replies") { try await telegram.reconcileSavedReplies() }
        }
        if let slack = await BackgroundLoops.BackgroundLoopLifetimes.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop {
            await run("Slack replies") { try await slack.reconcileSavedReplies() }
        }
        guard failures.isEmpty else {
            throw NSError(domain: "NativeAgent.ReplyReconciliation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }
    func retryRequestedResults(dataRoot: URL) async throws {
        try await NativeAgentEngine.live.ports.backgroundWork.attention.retryRequestedResults(dataRoot: dataRoot)
    }

    var agentSubject: String { NativeAgentEngine.live.ports.backgroundWork.agentSubject }

    func observeMotorActionState(_ model: MotorActionReadModel) async {
        await NativeAgentEngine.liveCognition.observeMotorActionState(model)
    }

    /// The contact doors' transports (their start, queued sends, reply reads) and the Desk waits that settled. Neither decides that the agent thinks:
    /// what comes back is a `returned` happening.
    func reconcileAgentConversations() async throws {
        let engine = NativeAgentEngine.live
        // Reconciliation is the background owner's operation, outside a chat turn.
        let workspace = ChatWorkspaceBinding.operation(turn: nil, invocation: .init())
        // A contact read failure must not keep a settled Desk wait from returning.
        var firstError: Error?
        do { try await engine.agents.continuation.tick(workspace: workspace) }
        catch is CancellationError { throw CancellationError() }
        catch { firstError = error }
        do { try await NativeAgentEngine.makeTurnContinuationRuntime(dataRoot: engine.dataRoot).returnSettledDeskWaits() }
        catch is CancellationError { throw CancellationError() }
        catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    func stopAgentConversations() async {
        await NativeAgentEngine.live.agents.continuation.stop()
    }

    /// Conversation-owner changes wake reconciliation; no clock declares a reply due.
    func nextConversationDeadline(after _: Date) -> Date? { nil }
}

// MARK: - Desk notifications
// Native owners gate and deliver selected Desk work, stamping `lastNotifiedAt` to prevent duplicates without touching cognition.

extension NativeAgentEngine {
    public static func makeDeskNotifyLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        DeskNotifyRunner(
            dataRoot: dataRoot,
            attention: NativeAgentEngine.live.ports.backgroundWork.attention,
            propose: { input in
                try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native("background:desk_notify")) { door in
                    switch await Parts(root: dataRoot).call(id: "desk-notify", input: input, invocation: door.invocation, as: DeskNotificationProposal.self) {
                    case .success(let proposal): return proposal
                    case .failure(let error): throw error
                    }
                }
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
    func tell(_ matter: Matter, dataRoot: URL, reach: AttentionRouter.Reach, turn: Turn?) async throws -> AttentionOutcome {
        try await NativeAgentEngine.forRoot(dataRoot).ports.backgroundWork.attention.tell(matter, reach: reach, turn: turn)
    }
}

extension NativeAgentEngine {
    public static func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil,
        freshMeasurement: Bool = false
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeAutoDoctorLoop(dataRoot: dataRoot, intervalSeconds: intervalSeconds,
            freshMeasurement: freshMeasurement)
    }

    public static func makeOffDiskBackupLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeOffDiskBackupLoop(dataRoot: dataRoot)
    }

    public static func makeDataRootDiskHygieneLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DataRootDiskHygieneCheck {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeDataRootDiskHygieneLoop(dataRoot: dataRoot)
    }

    public static func cleanUpDiskHygiene(
        dataRoot: URL = PersistenceCore.defaultDataRoot(), matterID: String? = nil
    ) async throws -> String {
        try await MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).cleanUpDiskHygiene(dataRoot: dataRoot, matterID: matterID)
    }
}

extension EngineBackgroundWorkPort: MaintenanceBackgroundWorkPort {
    func diskStorageOwners(dataRoot: URL) -> [DiskStorageOwner] {
        [TrustBackupPersistence.diskStorageOwner(dataRoot: dataRoot), ChatSessionRetention.diskStorageOwner,
         ContextSQLiteStore.diskStorageOwner]
    }

    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> [CheckResult] {
        // Automatic and manual runs share single-flight lifecycle and published reports so relaunches retain completed evidence.
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
            if owned { await doctor.finishRun(nil, failure: error.localizedDescription) }
            throw error
        }
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

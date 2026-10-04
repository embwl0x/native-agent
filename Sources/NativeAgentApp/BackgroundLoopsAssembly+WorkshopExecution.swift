import BackgroundWork
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
import Cognition
import WorkshopExecution
import TrustCenter
import MacControl
import SelfImprovement
import NotificationInbox


extension BackgroundLoopsAssembly {
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
        let gatedTools = makeGatedToolDispatchClient(
            tools: SwiftToolDispatcher(
                dataRoot: dataRoot,
                allowProcessGlobalTools: usesLiveAppBody,
                providerLifecycleObserver: cognition,
                macIntegrationBridge: usesLiveAppBody ? MacIntegrationBridgeImpl() : nil,
                agentBridgeConfigRoot: NativeAgentPaths.bridgeConfigRoot(dataRoot: dataRoot)
            ),
            fileAccess: "auto",
            approvalFiler: nil,
            dataRoot: dataRoot
        )
        return WorkshopBackgroundWork.makeWorkshopExecutor(
            dataRoot: dataRoot, cognition: cognition, planner: planner,
            chatClient: { tools in
                let engine = usesLiveAppBody ? NativeAgentEngine.live : NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot), hasBody: false)
                return engine.chatClient(tools: tools)
            },
            gatedTools: gatedTools,
            approvedTools: { replay in
                makeGatedToolDispatchClient(
                    tools: SwiftToolDispatcher(
                        dataRoot: dataRoot, allowProcessGlobalTools: usesLiveAppBody,
                        providerLifecycleObserver: cognition,
                        macIntegrationBridge: usesLiveAppBody ? MacIntegrationBridgeImpl() : nil,
                        agentBridgeConfigRoot: NativeAgentPaths.bridgeConfigRoot(dataRoot: dataRoot)),
                    fileAccess: "auto", dataRoot: dataRoot, approvedReplay: replay)
            },
            notify: workshopInboxNotification
        )
    }

    static let workshopInboxNotification: WorkshopInboxNotification = { root, id, title, summary, source, severity in
        await InboxPushNotifier.notifyIfAttentionWorthy(
            dataRoot: root, itemId: id, title: title, summary: summary, source: source, severity: severity
        )
    }

    static func isWideOpenTrust(dataRoot: URL) async -> Bool {
        await WorkshopBackgroundWork.isWideOpenTrust(dataRoot: dataRoot)
    }

    static func workshopExecutorGate(dataRoot: URL) async -> Bool {
        await WorkshopBackgroundWork.workshopExecutorGate(dataRoot: dataRoot)
    }

    static func makeWorkshopStepApprovalStager(dataRoot: URL) -> WorkshopStepApprovalStager {
        WorkshopBackgroundWork.makeWorkshopStepApprovalStager(dataRoot: dataRoot, notify: workshopInboxNotification)
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

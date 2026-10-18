import BackgroundWork
import ApprovalTransactions
import AppToolRuntime
import Foundation
import NotificationInbox
import AttentionRouting
import Agents
import ChatOrchestration
import ChromeControl
import Cognition
import MacControl
import CognitiveSubstrate
import Context
import ContextFlow
import DeviceSync
import NativeAgentCore
import PersistenceCore
import Desk
import StandingBots
import TrustCenter
import WorkshopExecution

// MARK: - Engine root

/// The one composition root: every chat client and tool chain the app runs is
/// built here, from one data root and the app's ports.
///
/// `live` is the running app's engine. A root built with `hasBody: false` has no
/// Mac/iPhone body: the same root-scoped autonomy membrane, no app-owned
/// schemas, no process-global tools, and never the live organism or Context
/// projections. Construction policy only: authority stays with SecurityCenter,
/// TrustCenter, and the per-turn gated dispatcher.
public final class NativeAgentEngine: Sendable {
    public let dataRoot: URL
    public let ports: NativeAgentEnginePorts
    public let hasBody: Bool
    /// The resident mind: cognitive events and capsule, provider lifecycle,
    /// organism posture and motor-outcome evidence. Only a root with a body
    /// has one.
    public let cognition: NativeCognitionRuntime?
    /// Observable cognition pages and the dream diary, in core types.
    public let cognitionView: CognitionViewFacade
    /// Doctor, this runtime's health and the loop watchdog, in core types;
    /// Diagnostics, Status and the health pill observe it.
    public let doctor: DoctorFacade
    /// Device sync: the phone's bridge, snapshots, signed inbox, pairing and
    /// APNs. Only a root with a body has one.
    public let deviceSync: DeviceSync?
    /// Pairing and device status for Settings, over the same sync owner.
    public let sync: SyncFacade
    /// MemoryV2 and the Knowledge Graph for this root, in core types; the
    /// Memories and Knowledge Graph pages observe it.
    public let memory: MemoryFacade
    /// The ApprovalInbox and the live notification inbox for this root, in
    /// core types; every approval and inbox surface observes them.
    public let approvals: ApprovalsFacade
    public let inbox: InboxFacade
    /// Chrome control: the socket the bundled relay dials, its handshake,
    /// Chrome's tabs, and the native-host registration.
    public let chrome: ChromeControlRuntime
    /// TrustCenter (policy, backups, capability trust) and provider routing
    /// (connections, the model catalog, each surface's pick) for this root,
    /// in core types; the Trust Center, Providers and picker surfaces observe
    /// them.
    public let trust: TrustFacade
    public let providers: ProvidersFacade
    /// The tool catalog (load state and trust per tool) and the authored-tool
    /// registry; the Desk board, the schedule and research lab runs. In core
    /// types; the Tools, Desk, Schedule and Capabilities pages observe them.
    public let telegram: TelegramFacade
    public let tools: ToolsFacade
    public let desk: DeskFacade
    /// The chat session index and transcripts, and the running turns, for
    /// this root, in core types; every chat surface observes them.
    public let transcripts: TranscriptsFacade
    public let turns: TurnsFacade
    /// Agent contacts: A2A tasks, the desktop route, human replies, Grok's
    /// inbound answers and the reply/notice continuation, on this root's clients.
    public let agents: AgentContacts
    /// ContextFlow: turn preparation and memory-record → atom-id translation.
    /// Chat clients reach it only on a root with a body.
    public let contextFlow: NativeContextFlowRuntime

    public init(
        dataRoot: URL,
        ports: NativeAgentEnginePorts,
        hasBody: Bool = true
    ) {
        self.dataRoot = dataRoot
        self.ports = ports
        self.hasBody = hasBody
        PeerTrust.install(dataRoot: dataRoot)
        CapabilityLifecycle.keepAuthority = { root in
            if case .present(let policy) = SavedTrustPolicyAuthority.read(dataRoot: root),
               AppToolExecutor.lockedPolicyIsFullMac(policy) { return true }
            return PeerDataTaint.ownerAuthorized
        }
        self.memory = MemoryFacade(dataRoot: dataRoot)
        self.approvals = ApprovalsFacade(dataRoot: dataRoot)
        self.inbox = InboxFacade(dataRoot: dataRoot)
        let chromeInbox = self.inbox.store
        self.chrome = ChromeControlRuntime(dataRoot: dataRoot, signatureFailureNote: { id, message in
            try await chromeInbox.appendUnique(.object([
                "id": .string(id),
                "created_at": .string(NotificationInboxClock.nowISO()),
                "source": .string("chrome"),
                "severity": .string("important"),
                "title": .string("Chrome link blocked by browser signature validation"),
                "summary": .string(message),
                "status": .string("unread"),
                "actions": .array([]),
            ]), id: id)
        })
        self.trust = TrustFacade(dataRoot: dataRoot, connectorActionStatuses: ports.connectorActionStatuses)
        self.providers = ProvidersFacade(dataRoot: dataRoot)
        self.telegram = TelegramFacade(dataRoot: dataRoot)
        self.tools = ToolsFacade(dataRoot: dataRoot, ports: ports)
        self.desk = DeskFacade(dataRoot: dataRoot)
        self.transcripts = TranscriptsFacade(dataRoot: dataRoot)
        self.turns = TurnsFacade(dataRoot: dataRoot)
        self.doctor = DoctorFacade(dataRoot: dataRoot)
        let contextFlow = NativeContextFlowRuntime(dataRoot: dataRoot)
        self.contextFlow = contextFlow
        let cognition = (hasBody ? ports : nil).map {
            NativeCognitionRuntime(dataRoot: dataRoot, host: $0.cognitionHost, contextFlow: contextFlow)
        }
        self.cognition = cognition
        self.cognitionView = CognitionViewFacade(dataRoot: dataRoot, runtime: cognition)
        let deviceSync = (hasBody ? ports : nil).map {
            DeviceSync(dataRoot: dataRoot, host: $0.deviceSyncHost, cognition: cognition!)
        }
        self.deviceSync = deviceSync
        self.sync = SyncFacade(owner: deviceSync)
        let clients = EngineAgentContactClients()
        AgentHostLaunches.install { AgentRecipeStore.launch($0) }
        self.agents = AgentContacts(dataRoot: dataRoot, clients: clients,
                                    completionSender: ports.completionSender(dataRoot))
        clients.attach(self)
    }

    /// The app's tool chain.
    public func toolDispatchClient(
        enforceAppAutonomy: Bool = true,
        swarmApprovalFiler: (any ApprovalFiler)? = nil
    ) -> any ToolDispatchClient {
        let dataRoot = self.dataRoot
        // The app's own tools reach Core's one catalog through this port; a
        // root with no body has none of them.
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let appToolExecutor: AppToolExecutor? = (hasBody ? ports : nil).map { ports in
            ports.appTools(securityCenter, enforceAppAutonomy)
        }
        let inner = SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: hasBody,
            providerLifecycleObserver: cognition,
            swarmApprovalFiler: swarmApprovalFiler,
            // The 5 Phase-1 Mac integration chat tools reach their app-side
            // backends instead of returning `bridge_not_wired`.
            macIntegrationBridge: hasBody ? ports.macIntegration : nil,
            appTools: appToolExecutor,
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
            a2aPushConfiguration: (hasBody ? ports : nil).map { ports in { @Sendable peer in
                await ports.agentBridge.a2aPushConfiguration(for: peer)
            } },
            standingBotRunEnqueue: (hasBody ? ports : nil).map { ports in { @Sendable id, question in
                try ports.standingBotQueue.enqueueRun(bot: id, question: question)
            } },
            standingBotSession: standingBotSession()
        )
        let appTools: AppChatToolDispatcher
        if let cognition {
            appTools = AppChatToolDispatcher(
                inner: inner,
                securityCenter: securityCenter,
                enforceAutonomySecurity: enforceAppAutonomy,
                appTools: appToolExecutor,
                motorOutcomeObserver: { reference in
                    let model: MotorActionReadModel?
                    switch reference.domain {
                    case .workshopExecution:
                        let runner = SwiftNativeWorkshopRunner(root: dataRoot)
                        if let record = try? await runner.getWorkshopExecution(reference.ownerActionID) {
                            model = SwiftNativeWorkshopRunner.motorActionReadModel(record: record)
                        } else {
                            model = nil
                        }
                    case .macControl:
                        model = try? await MacControlOperationStore(dataRoot: dataRoot)
                            .motorActionReadModel(actionId: reference.ownerActionID)
                    case .externalSend:
                        model = try? await ExternalSendMotorActionReadModelProvider(
                            dataRoot: dataRoot
                        ).motorActionReadModel(actionId: reference.ownerActionID)
                    case .agentBridge:
                        let row = DelegationStatusProjector(
                            configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
                        ).allJobs(now: Date()).first {
                            $0.id == reference.ownerActionID
                        }
                        if let row {
                            model = DelegationBackgroundWork.delegationJobSnapshot(from: row)
                                .motorActionReadModel()
                        } else {
                            // The durable inbox receipt can become visible a few
                            // milliseconds before the wake-job writer. Preserve
                            // the exact owner identity without inventing progress.
                            model = MotorActionReadModel(
                                domain: "agent_bridge",
                                actionIdentity: reference.actionIdentity,
                                phase: .waitingExternal,
                                domainState: "accepted",
                                verification: .pending,
                                expectedNextEvidence: "A canonical bridge job record tied to this message id.",
                                updatedAt: nil
                            )
                        }
                    case .browser:
                        // BrowserActionRunner already rereads the Browser owner
                        // and returns its canonical consequence to cognition.
                        model = nil
                    }
                    guard let model else { return }
                    await cognition.observeMotorActionState(model)
                },
                interactions: ports.interactions, platform: ports.chatPlatform
            )
        } else {
            appTools = AppChatToolDispatcher(
                inner: inner,
                securityCenter: securityCenter,
                enforceAutonomySecurity: enforceAppAutonomy,
                includeAppOwnedTools: false,
                interactions: ports.interactions, platform: ports.chatPlatform
            )
        }
        // 2026-09-15: the inbound-peer tool fence that used to wrap this chain is
        // gone. A peer turn loads her whole tool set; an EFFECT it asks for raises
        // the person's permission card in AutonomyGatedDispatcher rather than
        // running. See AgentBridgeSurface and PeerTurnEffectPolicy.
        return appTools
    }

    /// The raw bridge tool RPC: the same app tool chain chat uses, inside the
    /// bridge's conservative read-only/autonomy envelope, with ordinary
    /// nonblocking approval filing when the caller supplies a filer.
    public func bridgeToolDispatchClient(
        fileAccess: String = "read_only",
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        verifiedSessionId: String? = nil
    ) -> any ToolDispatchClient {
        let tools = toolDispatchClient()
        return makeGatedToolDispatchClient(
            tools: tools,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            verifiedSessionId: verifiedSessionId
        )
    }

    /// Both scheduled turns and bot_ask construct the same ordinary app chat client.
    public func standingBotSession() -> BotRunnerSession {
        { [self] bot, message in
            let client = chatClient(
                tools: toolDispatchClient(),
                approvalFiler: NativeAgentChatApprovalFiler(dataRoot: dataRoot),
                continuationCapabilityProfile: .mac)
            return try await StandingBotContinuity.session(client: client, dataRoot: dataRoot)(bot, message)
        }
    }

    /// Bind any purpose-built dispatcher to the same app-owned mind/body assembly
    /// used by Mac, iOS, Telegram, Slack, bridge, and background turns. Restricted
    /// Workshop dispatchers keep their own smaller tool inventory while cognition,
    /// ContextFlow, memory projection, and provider lifecycle remain one shared
    /// contract instead of being rebuilt at each caller. Public first-run safety
    /// stays with the canonical ContextFlow and cognition owners.
    public func chatClient(
        tools: any ToolDispatchClient,
        approvalFiler: (any ApprovalFiler)? = nil,
        continuationCapabilityProfile: NativeAgentAppChatSurfaceProfile? = nil
    ) -> SwiftNativeChatOrchestrationClient {
        let contextFlow = hasBody ? self.contextFlow : nil
        return makeChatOrchestrationClient(
            tools: tools,
            dataRoot: dataRoot,
            continuationCapabilityProfile: continuationCapabilityProfile?.rawValue,
            approvalFiler: approvalFiler,
            cognitiveObserver: cognition,
            cognitiveContextProvider: cognition,
            providerLifecycleObserver: cognition,
            contextFlow: contextFlow,
            memoryAtomTranslator: contextFlow.map { runtime in { @Sendable recordID in
                runtime.memoryRecordAtomID(forRecordID: recordID)
            } }
        )
    }

    /// Surface-profiled entry point used by every production chat surface.
    /// Keep these policy choices in one place so a new call site cannot silently
    /// drift from its siblings by relying on Boolean defaults.
    public func chatClient(
        profile: NativeAgentAppChatSurfaceProfile,
        approvalFiler: (any ApprovalFiler)? = nil
    ) -> SwiftNativeChatOrchestrationClient {
        // User conversation surfaces get the same durable nonblocking inbox.
        // Telegram supplies its inline-button wrapper. Background execution
        // has no user at the trigger and therefore fails confirm-tier work
        // closed unless a caller explicitly supplies a filer.
        let resolvedApprovalFiler: (any ApprovalFiler)? = approvalFiler
            ?? (profile.filesApprovalsByDefault
                ? NativeAgentChatApprovalFiler(dataRoot: dataRoot)
                : nil)
        let tools = toolDispatchClient(
            // The shared ChatOrchestration membrane resolves autonomy once, after
            // SecurityCenter authenticates the exact origin, and owns approval
            // filing/replay. Keep the inner app dispatcher on hard SecurityCenter
            // checks without re-running the autonomy decision from a reconstructed
            // origin. Direct/raw app-tool clients retain the default `true`.
            enforceAppAutonomy: false,
            swarmApprovalFiler: resolvedApprovalFiler
        )
        return chatClient(
            tools: tools,
            approvalFiler: resolvedApprovalFiler,
            continuationCapabilityProfile: profile
        )
    }
}

/// This root's chat and tool clients, handed to the agent contacts it owns.
/// Attached once the root is built; held weakly, since the root owns them.
private final class EngineAgentContactClients: AgentContactClients, @unchecked Sendable {
    private let lock = NSLock()
    private weak var attached: NativeAgentEngine?
    func attach(_ engine: NativeAgentEngine) { lock.withLock { attached = engine } }
    private var engine: NativeAgentEngine { lock.withLock { attached! } }

    func bridgeChatClient() -> SwiftNativeChatOrchestrationClient { engine.chatClient(profile: .bridge) }
    func backgroundChatClient() -> SwiftNativeChatOrchestrationClient { engine.chatClient(profile: .background) }
    func chatClient(tools: any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient {
        engine.chatClient(tools: tools)
    }
    func toolDispatchClient(enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        engine.toolDispatchClient(enforceAppAutonomy: enforceAppAutonomy)
    }
    func bridgeToolDispatchClient(fileAccess: String, verifiedSessionId: String?) -> any ToolDispatchClient {
        engine.bridgeToolDispatchClient(fileAccess: fileAccess, verifiedSessionId: verifiedSessionId)
    }
    func deliverReach(reply: String, itemID: String, turnID: String) async {
        await engine.cognition?.deliverReach(reply: reply, itemID: itemID, turnID: turnID, chat: bridgeChatClient())
    }
    func cognitionChanges() async -> AsyncStream<NativeCognitionRuntimeChange>? {
        await engine.cognition?.changes()
    }
}

extension NativeAgentEngine {
    public static let live: NativeAgentEngine = {
        let dataRoot = PersistenceCore.defaultDataRoot()
        return NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot))
    }()
    /// The running app's mind. The live root is built with the app's body.
    public static var liveCognition: NativeCognitionRuntime { live.cognition! }
    /// The running app's device sync; the live root is built with a body.
    public static var liveDeviceSync: DeviceSync { live.deviceSync! }

    /// The engine for one root: the live one at the default root, otherwise a
    /// bodiless engine that reads and writes only that root.
    public static func forRoot(_ dataRoot: URL) -> NativeAgentEngine {
        dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? live : NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot), hasBody: false)
    }
}

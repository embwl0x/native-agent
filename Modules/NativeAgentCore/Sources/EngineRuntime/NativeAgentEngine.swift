import BackgroundWork
import ApprovalTransactions
import AppToolRuntime
import Foundation
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
    public let activeToolsStore: ActiveToolsStore
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
    /// Chrome's leases, and the native-host registration.
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
    /// ContextFlow: turn preparation, settled-tool prewarm and memory-record →
    /// atom-id translation. Chat clients and prewarm reach it only on a root
    /// with a body.
    public let contextFlow: NativeContextFlowRuntime

    public init(
        dataRoot: URL,
        activeToolsStore: ActiveToolsStore? = nil,
        ports: NativeAgentEnginePorts,
        hasBody: Bool = true
    ) {
        self.dataRoot = dataRoot
        self.activeToolsStore = activeToolsStore ?? ActiveToolsStore(dataRoot: dataRoot)
        self.ports = ports
        self.hasBody = hasBody
        self.memory = MemoryFacade(dataRoot: dataRoot)
        self.approvals = ApprovalsFacade(dataRoot: dataRoot)
        self.inbox = InboxFacade(dataRoot: dataRoot)
        self.chrome = ChromeControlRuntime()
        self.trust = TrustFacade(dataRoot: dataRoot)
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
        self.agents = AgentContacts(dataRoot: dataRoot, clients: clients,
                                    completionSender: ports.completionSender(dataRoot))
        clients.attach(self)
    }

    /// The app's tool chain.
    ///
    /// `includeEvolutionBridge` (2026-06-11, U4 Wave D): the self-evolution chat
    /// tools (evolution_propose / evolution_status / self_install) reach their
    /// backend only when this is true. FULLY-AUTONOMOUS turns with no human anywhere
    /// in the loop — the reflection/dream/REM background loops, Slack, and iOS —
    /// pass `false`, so those clients return a `bridge_not_wired`
    /// envelope rather than reaching the store/stager. The claude/codex bridge
    /// `/claude/message` path
    /// keeps the default `true` as of the user's 2026-06-13 "open the bridges" call: it
    /// IS Claude/codex collaborating as a team, and self_install there still only
    /// STAGES a local-only confirm card the user resolves (never auto-installs). Genuine
    /// local Mac desktop chat also keeps the default `true`. Telegram keeps the
    /// bridge so authenticated Full Mac YOLO turns can use read-only
    /// `evolution_status`; mutation tools still cross the ordinary TrustCenter and
    /// approval floors before this backend can run.
    ///
    /// `denyExternalMcp` (2026-06-13): on human-OUT-of-the-loop bridge clients the
    /// external MCP namespace (`mcp__*` — third-party connectors, including a wired
    /// real-money brokerage) must stay closed. A bridge turn has no human at the
    /// trigger and those connectors run side effects we cannot gate from here, so
    /// pass `true` to wrap the tool set in `ClaudeBridgeDenyDispatcher` (now an
    /// mcp__-only guard). NativeAgent-NATIVE tools — builder (shell/git/…),
    /// integration-send, self-evolution — are FULLY available on the bridge per
    /// the user's 2026-06-13 call ("the bridges should be open"); they stay gated by the
    /// SAME yolo window / Trust Center / self_install card path as local Mac chat,
    /// not by a bridge-specific fence. Genuine local Mac chat (NativeClient) keeps
    /// the default `false`: MCP tools available, consent-gated, the user present.
    public func toolDispatchClient(
        includeEvolutionBridge: Bool = true,
        denyExternalMcp: Bool = false,
        enforceAppAutonomy: Bool = true,
        enforceLazyToolLoading: Bool? = nil,
        swarmApprovalFiler: (any ApprovalFiler)? = nil,
        innerTools: (any ToolDispatchClient)? = nil
    ) -> any ToolDispatchClient {
        let dataRoot = self.dataRoot
        let evolutionBridge: (any EvolutionToolBridge)? = includeEvolutionBridge
            ? ports.evolutionBridge(dataRoot)
            : nil
        // The app's own tools reach Core's one catalog through this port; a
        // root with no body has none of them.
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let appToolExecutor: AppToolExecutor? = (hasBody ? ports : nil).map { ports in
            ports.appTools(securityCenter, enforceAppAutonomy)
        }
        // Keep the injection seam below AppChatToolDispatcher. Hermetic boundary
        // tests can replace the core tool body without bypassing app-owned
        // interception, SecurityCenter, or the bridge chain's wrapper order.
        let inner: any ToolDispatchClient = innerTools ?? SwiftToolDispatcher(
            dataRoot: dataRoot,
            activeToolsStore: activeToolsStore,
            allowProcessGlobalTools: hasBody,
            enforceLazyToolLoading: enforceLazyToolLoading,
            providerLifecycleObserver: cognition,
            swarmApprovalFiler: swarmApprovalFiler,
            // The 5 Phase-1 Mac integration chat tools reach their app-side
            // backends instead of returning `bridge_not_wired`.
            macIntegrationBridge: hasBody ? ports.macIntegration : nil,
            evolutionBridge: evolutionBridge,
            appTools: appToolExecutor,
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
            a2aPushConfiguration: (hasBody ? ports : nil).map { ports in { @Sendable peer in
                await ports.agentBridge.a2aPushConfiguration(for: peer)
            } },
            standingBotRunEnqueue: (hasBody ? ports : nil).map { ports in { @Sendable id in
                try ports.standingBotQueue.enqueueRun(bot: id)
            } },
            standingBotSession: standingBotSession()
        )
        let appTools: AppChatToolDispatcher
        if let cognition {
            let contextFlow = self.contextFlow
            appTools = AppChatToolDispatcher(
                inner: inner,
                activeToolsStore: activeToolsStore,
                securityCenter: securityCenter,
                enforceAutonomySecurity: enforceAppAutonomy,
                appTools: appToolExecutor,
                organismPostureProvider: {
                    await cognition.organismBehaviorPosture()
                },
                contextPrewarm: { kind, id, terms in
                    await contextFlow.prewarm(kind: kind, id: id, terms: terms)
                },
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
                activeToolsStore: activeToolsStore,
                securityCenter: securityCenter,
                enforceAutonomySecurity: enforceAppAutonomy,
                includeAppOwnedTools: false,
                organismPostureProvider: { nil },
                contextPrewarm: { _, _, _ in },
                interactions: ports.interactions, platform: ports.chatPlatform
            )
        }
        // Bridge clients pass denyExternalMcp:true so the external `mcp__*`
        // namespace is stripped at dispatch AND in the catalog; everything
        // NativeAgent-native passes straight through to the normal gated chain.
        // 2026-09-15: the inbound-peer tool fence that used to wrap this chain is
        // gone. A peer turn loads her whole tool set; an EFFECT it asks for raises
        // the person's permission card in AutonomyGatedDispatcher rather than
        // running. See AgentBridgeSurface and PeerTurnEffectPolicy.
        return denyExternalMcp
            ? ClaudeBridgeDenyDispatcher(inner: appTools)
            : appTools
    }

    /// The raw bridge tool RPC: the same app tool chain chat uses, inside the
    /// bridge's conservative read-only/autonomy envelope.
    /// `ClaudeBridgeDenyDispatcher` intentionally stays outermost: external MCP
    /// names are rejected before they can probe TrustCenter or the inner catalog.
    public func bridgeToolDispatchClient(
        appInnerTools: (any ToolDispatchClient)? = nil,
        fileAccess: String = "read_only",
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        trust: (any AutonomyResolver)? = nil,
        verifiedSessionId: String? = nil
    ) -> any ToolDispatchClient {
        let tools = toolDispatchClient(
            includeEvolutionBridge: NativeAgentAppChatSurfaceProfile.bridge.includesEvolutionBridge,
            denyExternalMcp: false,
            innerTools: appInnerTools
        )
        return makeGatedToolDispatchClient(
            tools: tools,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            trust: trust,
            verifiedSessionId: verifiedSessionId,
            restrictBeforeGates: { ClaudeBridgeDenyDispatcher(inner: $0) }
        )
    }

    /// Both scheduled turns and bot_ask construct the same ordinary app chat client.
    public func standingBotSession() -> BotRunnerSession {
        { [self] bot, message in
            let client = chatClient(
                tools: toolDispatchClient(denyExternalMcp: false),
                approvalFiler: NativeAgentChatApprovalFiler(dataRoot: dataRoot))
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
        toolLoopMaxIterations: Int? = nil,
        turnWallClockSeconds: TimeInterval? = nil
    ) -> SwiftNativeChatOrchestrationClient {
        let contextFlow = hasBody ? self.contextFlow : nil
        return makeChatOrchestrationClient(
            tools: tools,
            dataRoot: dataRoot,
            toolLoopMaxIterations: toolLoopMaxIterations,
            turnWallClockSeconds: turnWallClockSeconds,
            approvalFiler: approvalFiler,
            cognitiveObserver: cognition,
            cognitiveContextProvider: cognition,
            providerLifecycleObserver: cognition,
            contextFlow: contextFlow,
            memoryAtomTranslator: contextFlow.map { _ in { @Sendable recordID in
                NativeContextFlowRuntime.memoryRecordAtomID(forRecordID: recordID)
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
            includeEvolutionBridge: profile.includesEvolutionBridge,
            denyExternalMcp: profile.deniesExternalMCP,
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
            toolLoopMaxIterations: profile.toolLoopMaxIterations,
            turnWallClockSeconds: profile.turnWallClockSeconds
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
    func chatClient(tools: any ToolDispatchClient, toolLoopMaxIterations: Int?,
                    turnWallClockSeconds: TimeInterval?) -> SwiftNativeChatOrchestrationClient {
        engine.chatClient(tools: tools, toolLoopMaxIterations: toolLoopMaxIterations, turnWallClockSeconds: turnWallClockSeconds)
    }
    func toolDispatchClient(denyExternalMcp: Bool, enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        engine.toolDispatchClient(denyExternalMcp: denyExternalMcp, enforceAppAutonomy: enforceAppAutonomy)
    }
    func bridgeToolDispatchClient(fileAccess: String, verifiedSessionId: String?) -> any ToolDispatchClient {
        engine.bridgeToolDispatchClient(fileAccess: fileAccess, verifiedSessionId: verifiedSessionId)
    }
}

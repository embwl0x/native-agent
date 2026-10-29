import BackgroundWork
import AgentWorkspace
import Studio
import ApprovalTransactions
import AppToolRuntime
import Foundation
import NotificationInbox
import AttentionRouting
import Agents
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import ChromeControl
import Cognition
import MacControl
import MemoryV2
import CognitiveSubstrate
import Context
import ContextFlow
import DeviceSync
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Desk
import StandingBots
import ToolExecution
import TurnTrace
import TrustCenter
import WorkshopExecution
// Blueprint: | `NativeAgentEngine.swift` | Core live/isolated root selection, chat/tool and manifest composition retained independently by contact clients (no borrowed engine lifetime); resident service facades, shared persona/configuration/runs projections and `ConnectorReadiness`; Desk receives the engine's inbox, approvals and bots; owns root-scoped contact/crew and layout observation plus Activity invalidations and the bot scheduler shared by deadlines and read projections |

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
    /// Keep the body's paired owners typed together, including the live root.
    private struct Body: Sendable {
        let contextFlow: NativeContextFlowRuntime
        let cognition: NativeCognitionRuntime
        let deviceSync: DeviceSync

        init(dataRoot: URL, ports: NativeAgentEnginePorts) {
            let contextFlow = NativeContextFlowRuntime(dataRoot: dataRoot)
            let cognition = NativeCognitionRuntime(dataRoot: dataRoot, host: ports.cognitionHost, contextFlow: contextFlow)
            self.contextFlow = contextFlow
            self.cognition = cognition
            self.deviceSync = DeviceSync(dataRoot: dataRoot, host: ports.deviceSyncHost, cognition: cognition)
        }
    }
    public let dataRoot: URL
    public let layout: SurfaceLayoutLive
    public let ports: NativeAgentEnginePorts
    private let clients: EngineAgentContactClients
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
    /// Persisted turn evidence shared by Mac Inspector and phone summaries.
    public let trace: TurnInspectorFeed
    /// Device sync: the phone's bridge, snapshots, signed inbox, pairing and
    /// APNs. Only a root with a body has one.
    public let deviceSync: DeviceSync?
    /// Pairing and device status for Settings, over the same sync owner.
    public let sync: SyncFacade
    /// MemoryV2 and the Knowledge Graph for this root, in core types; the
    /// Memories and Knowledge Graph pages observe it.
    public let memory: MemoryFacade
    /// One saved persona presentation for the Mac and phone.
    public let persona: PersonaFacade
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
    public let macIntegration: MacIntegrationFacade
    public let providers: ProvidersFacade
    public let configuration = RuntimeReadouts.Configuration()
    public let runs = RuntimeReadouts.Runs()
    public let connectors: ConnectorReadiness
    public func setSurfaceExpanded(_ open: Bool, surface: String, block: String) async {
        await layout.setExpanded(open, surface: surface, block: block)
    }
    /// The tool catalog (load state and trust per tool) and the authored-tool
    /// registry; the Desk board, the schedule and research lab runs. In core
    /// types; the Tools, Desk, Schedule and Capabilities pages observe them.
    public let telegram: TelegramFacade
    public let tools: ToolsFacade
    public let contacts: ContactListFacade
    public let senses: SensesFacade
    public let make: MakeStudio.Shelf
    public let today: TodayReadout
    public let desk: DeskFacade
    public let bots: BotRunnerScheduler
    /// The chat session index and transcripts, and the running turns, for
    /// this root, in core types; every chat surface observes them.
    public let transcripts: TranscriptsFacade
    public let turns: TurnsFacade
    /// Agent contacts: A2A tasks, the desktop route, human replies, Grok's
    /// inbound answers and the reply/notice continuation, on this root's clients.
    public let agents: AgentContacts
    public let contactThreads: ContactThreadReadouts
    /// ContextFlow: turn preparation and memory-record → atom-id translation.
    /// Chat clients reach it only on a root with a body.
    public let contextFlow: NativeContextFlowRuntime

    public convenience init(
        dataRoot: URL,
        ports: NativeAgentEnginePorts,
        hasBody: Bool = true
    ) {
        self.init(dataRoot: dataRoot, ports: ports,
                  body: hasBody ? Body(dataRoot: dataRoot, ports: ports) : nil)
    }

    private init(dataRoot: URL, ports: NativeAgentEnginePorts, body: Body?) {
        let hasBody = body != nil
        self.dataRoot = dataRoot
        self.layout = SurfaceLayoutLive(dataRoot: dataRoot)
        self.ports = ports
        self.hasBody = hasBody
        let contextFlow = body?.contextFlow ?? NativeContextFlowRuntime(dataRoot: dataRoot)
        let clients = EngineAgentContactClients(dataRoot: dataRoot, ports: ports, hasBody: hasBody,
            cognition: body?.cognition, contextFlow: contextFlow)
        self.clients = clients
        self.bots = BotRunnerScheduler(dataRoot: dataRoot,
            session: { bot, message in try await clients.standingBotSession()(bot, message) },
            isAutonomyEnabled: { await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) })
        PeerTrust.install(dataRoot: dataRoot)
        // Keeping is hers under Full Mac; a trusted agent's turn is hers too,
        // never the owner's (his acts come through his own surfaces).
        CapabilityLifecycle.keepAuthority = { root in
            if case .present(let policy) = SavedTrustPolicyAuthority.read(dataRoot: root),
               AppToolExecutor.lockedPolicyIsFullMac(policy) { return true }
            return false
        }
        self.memory = MemoryFacade(dataRoot: dataRoot)
        self.persona = PersonaFacade(dataRoot: dataRoot, isolated: !hasBody)
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
        self.trust = TrustFacade(dataRoot: dataRoot, connectorActionStatuses: {
            try await ConnectorActionRecord.checkedStatuses(root: dataRoot, platform: ports.connectorStatus)
        })
        self.providers = ProvidersFacade(dataRoot: dataRoot)
        self.connectors = ConnectorReadiness(root: dataRoot, platform: ports.connectorStatus)
        self.telegram = TelegramFacade(dataRoot: dataRoot)
        self.tools = ToolsFacade(dataRoot: dataRoot) { detail in
            try await clients.toolDispatchClient().toolManifest(detail: detail)
        }
        self.desk = DeskFacade(dataRoot: dataRoot, inbox: self.inbox, approvals: self.approvals, bots: self.bots)
        self.contacts = ContactListFacade(dataRoot: dataRoot)
        self.contactThreads = ContactThreadReadouts(dataRoot: dataRoot, contacts: self.contacts)
        self.senses = SensesFacade()
        let makeTools = self.tools
        self.make = MakeStudio.Shelf(dataRoot: dataRoot) { id, input, version in
            do {
                return try await makeTools.withPartDoor(envelope: .native("mac_ui:make.preview")) {
                    await Parts(root: dataRoot).face(id: id, input: input, version: version)
                }
            } catch { return .failure(.init(code: "door_unavailable", message: error.localizedDescription)) }
        }
        self.today = TodayReadout()
        let turns = TurnsFacade(dataRoot: dataRoot)
        self.turns = turns
        self.transcripts = TranscriptsFacade(turns: turns)
        self.doctor = DoctorFacade(dataRoot: dataRoot)
        let trace = TurnInspectorFeed(dataRootOverride: dataRoot)
        self.trace = trace
        if hasBody { Task { @MainActor in trace.start() } }
        self.contextFlow = contextFlow
        let cognition = body?.cognition
        self.cognition = cognition
        self.cognitionView = CognitionViewFacade(dataRoot: dataRoot, runtime: cognition)
        let deviceSync = body?.deviceSync
        self.deviceSync = deviceSync
        self.sync = SyncFacade(owner: deviceSync)
        self.macIntegration = MacIntegrationFacade(dataRoot: dataRoot, deviceSync: deviceSync, platform: ports.connectorStatus)
        AgentHostLaunches.install { AgentRecipeStore.launch($0) }
        self.agents = AgentContacts(dataRoot: dataRoot, clients: clients,
                                    completionSender: ports.completionSender(dataRoot))
        clients.attach(self.agents)
        Task { @MainActor [layout] in layout.start() }
    }

    /// The app's tool chain.
    public func toolDispatchClient(
        enforceAppAutonomy: Bool = true, swarmApprovalFiler: (any ApprovalFiler)? = nil
    ) -> AppChatToolDispatcher {
        clients.toolDispatchClient(enforceAppAutonomy: enforceAppAutonomy, swarmApprovalFiler: swarmApprovalFiler)
    }

    public func bridgeToolDispatchClient(
        fileAccess: String = "read_only", approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30, verifiedSessionId: String? = nil
    ) -> any ToolDispatchClient {
        clients.bridgeToolDispatchClient(fileAccess: fileAccess, approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds, verifiedSessionId: verifiedSessionId)
    }

    public func standingBotSession(admitted: Bool = false, attachments: [MultimodalAttachment] = [],
                                  fileAccess: String = "auto", progress: TurnEventSink? = nil) -> BotRunnerSession {
        clients.standingBotSession(admitted: admitted, attachments: attachments, fileAccess: fileAccess, progress: progress)
    }

    public func chatClient(tools: any ToolDispatchClient, approvalFiler: (any ApprovalFiler)? = nil,
                           continuationCapabilityProfile: NativeAgentAppChatSurfaceProfile? = nil) -> SwiftNativeChatOrchestrationClient {
        clients.chatClient(tools: tools, approvalFiler: approvalFiler, continuationCapabilityProfile: continuationCapabilityProfile)
    }

    public func chatClient(profile: NativeAgentAppChatSurfaceProfile, approvalFiler: (any ApprovalFiler)? = nil) -> SwiftNativeChatOrchestrationClient {
        clients.chatClient(profile: profile, approvalFiler: approvalFiler)
    }
}

/// Contacts and the engine retain the same immutable client dependencies.
/// Clients never borrow the engine's lifetime. Only a helper's callback to
/// contacts is weak to avoid a cycle; its throwing run binds that owner before use.
private final class EngineAgentContactClients: AgentContactClients, @unchecked Sendable {
    let dataRoot: URL
    let ports: NativeAgentEnginePorts
    let hasBody: Bool
    let cognition: NativeCognitionRuntime?
    let contextFlow: NativeContextFlowRuntime
    private let lock = NSLock()
    private weak var contacts: AgentContacts?

    init(dataRoot: URL, ports: NativeAgentEnginePorts, hasBody: Bool,
         cognition: NativeCognitionRuntime?, contextFlow: NativeContextFlowRuntime) {
        self.dataRoot = dataRoot; self.ports = ports; self.hasBody = hasBody
        self.cognition = cognition; self.contextFlow = contextFlow
    }

    func attach(_ contacts: AgentContacts) { lock.withLock { self.contacts = contacts } }

    func bridgeChatClient() -> SwiftNativeChatOrchestrationClient { chatClient(profile: .bridge) }
    func backgroundChatClient() -> SwiftNativeChatOrchestrationClient { chatClient(profile: .background) }
    func chatClient(tools: any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient {
        chatClient(tools: tools, approvalFiler: nil, continuationCapabilityProfile: nil)
    }
    func toolDispatchClient(enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        toolDispatchClient(enforceAppAutonomy: enforceAppAutonomy, swarmApprovalFiler: nil)
    }
    func bridgeToolDispatchClient(fileAccess: String, verifiedSessionId: String?) -> any ToolDispatchClient {
        bridgeToolDispatchClient(fileAccess: fileAccess, approvalFiler: nil,
            approvalTimeoutSeconds: 30, verifiedSessionId: verifiedSessionId)
    }
    func deliverReach(reply: String, itemID: String, turnID: String) async {
        await cognition?.deliverReach(reply: reply, itemID: itemID, turnID: turnID, chat: bridgeChatClient())
    }
    func cognitionChanges() async -> AsyncStream<NativeCognitionRuntimeChange>? {
        await cognition?.changes()
    }

    func toolDispatchClient(
        enforceAppAutonomy: Bool = true,
        swarmApprovalFiler: (any ApprovalFiler)? = nil
    ) -> AppChatToolDispatcher {
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
            a2aPushConfiguration: (hasBody ? ports : nil).map { $0.a2aPushConfiguration },
            standingBotRunEnqueue: (hasBody ? ports : nil).map { ports in { @Sendable id, question in
                try ports.standingBotQueue.enqueue(bot: id, context: question)
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
                    case .agentBridge:
                        let row = DelegationStatusProjector(
                            configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
                        ).allJobs(now: Date()).first {
                            $0.id == reference.ownerActionID
                        }
                        if let row {
                            model = row.motorActionReadModel()
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
                platform: ports.chatPlatform
            )
        } else {
            appTools = AppChatToolDispatcher(
                inner: inner,
                securityCenter: securityCenter,
                enforceAutonomySecurity: enforceAppAutonomy,
                includeAppOwnedTools: false,
                platform: ports.chatPlatform
            )
        }
        // Peer turns load all tools; AutonomyGatedDispatcher raises the person's permission card for effects.
        return appTools
    }

    /// The raw bridge tool RPC: the same app tool chain chat uses, inside the
    /// bridge's conservative read-only/autonomy envelope, with ordinary
    /// nonblocking approval filing when the caller supplies a filer.
    func bridgeToolDispatchClient(
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

    /// Scheduled turns and bot_ask use the helper runner with the app's tool gates.
    func standingBotSession(admitted: Bool = false, attachments: [MultimodalAttachment] = [],
                                   fileAccess: String = "auto", progress: TurnEventSink? = nil) -> BotRunnerSession {
        // A returned session keeps its contact owner, including when callers
        // built it from a temporary alternate-root engine. The composition
        // itself stays weak so contacts do not own themselves through clients.
        let contacts = lock.withLock { self.contacts }
        return { [self, contacts] bot, message in
            guard let contacts else {
                throw PersistenceCoreError.ioFailure("The helper's contact owner has retired.")
            }
            let client = makeChatOrchestrationClient(
                tools: toolDispatchClient(), dataRoot: dataRoot,
                continuationCapabilityProfile: NativeAgentAppChatSurfaceProfile.mac.rawValue,
                approvalFiler: NativeAgentChatApprovalFiler(dataRoot: dataRoot))
            return try await HelperContact.$door.withValue(contacts.helperDoor(for: bot)) {
                try await StandingBotContinuity.session(client: client, dataRoot: dataRoot, admitted: admitted,
                    attachments: attachments, fileAccess: fileAccess, progress: progress)(bot, message)
            }
        }
    }

    /// Bind any purpose-built dispatcher to the same app-owned mind/body assembly
    /// used by Mac, iOS, Telegram, Slack, bridge, and background turns. A restricted
    /// dispatcher (studio wander's) keeps its own smaller tool inventory while cognition,
    /// ContextFlow, memory projection, and provider lifecycle remain one shared
    /// contract instead of being rebuilt at each caller. Public first-run safety
    /// stays with the canonical ContextFlow and cognition owners.
    func chatClient(
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
            cognitiveRuntime: cognition,
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
    func chatClient(
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
            // The shared ChatTurnRuntime membrane resolves autonomy once, after
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

extension NativeAgentEngine {
    /// The Activity badge follows this engine's authority sources while mounted.
    @MainActor
    public func watchActivityChanges(refresh: @escaping @MainActor @Sendable () async -> Void) async {
        let database = dataRoot.appendingPathComponent("memory/memory.sqlite")
        var paths = [
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            dataRoot.appendingPathComponent("notifications/inbox.jsonl"),
            database, URL(fileURLWithPath: database.path + "-wal"),
        ]
        if #available(macOS 27, *) {
            paths += [dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
                      dataRoot.appendingPathComponent("desk/desk_ops_base.json")]
        }
        await EventDeadlinePhysiology.refreshOnChanges(paths: paths, refresh: refresh)
    }

    private static let liveRoot: (engine: NativeAgentEngine, body: Body) = {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let ports = NativeAgentEnginePorts.app(dataRoot: dataRoot)
        let body = Body(dataRoot: dataRoot, ports: ports)
        return (NativeAgentEngine(dataRoot: dataRoot, ports: ports, body: body), body)
    }()
    public static var live: NativeAgentEngine { liveRoot.engine }
    /// The running app's mind. The live root is built with the app's body.
    public static var liveCognition: NativeCognitionRuntime { liveRoot.body.cognition }
    /// The running app's device sync; the live root is built with a body.
    public static var liveDeviceSync: DeviceSync { liveRoot.body.deviceSync }

    public static func forRoot(_ dataRoot: URL) -> NativeAgentEngine {
        SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot)
            ? live : NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot), hasBody: false)
    }
}

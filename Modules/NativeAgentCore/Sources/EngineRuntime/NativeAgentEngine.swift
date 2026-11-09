import BackgroundWork
import AgentWorkspace
import Studio
import ApprovalTransactions
import AppToolRuntime
import Foundation
import NativeAgentShared
import Experiences
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
// Blueprint: | `NativeAgentEngine.swift` | Root composition; Chrome refusals tell ForPerson and Activity follows its changes |

/// Contact callbacks retain the operation that supplied them, including when
/// the runtime adds its own tool-call state later.
private struct EngineContactToolDispatcher: ToolDispatchClient, PreApprovalToolValidating {
    let inner: any ToolDispatchClient
    var conversation: AgentConversationContext? = nil
    var didWrite: (@Sendable (URL) -> Void)? = nil

    private func held(_ invocation: ChatToolInvocation) -> ChatToolInvocation {
        var invocation = conversation.map { invocation.serving(conversation: $0) } ?? invocation
        if let didWrite { invocation.wrote = didWrite }
        return invocation
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
                  invocation: ChatToolInvocation) async throws -> JSONValue {
        try await inner.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: held(invocation))
    }

    func preApprovalRefusal(turn: Turn, invocation: ChatToolInvocation,
                            tool: String, input: [String: JSONValue], surface: String) async -> JSONValue? {
        await (inner as? any PreApprovalToolValidating)?.preApprovalRefusal(turn: turn, invocation: held(invocation),
            tool: tool, input: input, surface: surface)
    }

    func approvalCardReason(tool: String, input: [String: JSONValue], surface: String) async -> String? {
        await (inner as? any PreApprovalToolValidating)?.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await inner.listAvailableTools(turn: turn, surface: surface)
    }
    func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(turn: turn, surface: surface)
    }
    func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names, turn: turn, surface: surface)
    }
}

// MARK: - Engine root

/// Compose every chat client and tool chain from one root and native ports. Roots without bodies cannot borrow process-global tools, live organism or
/// Context projections; authority remains in SecurityCenter, TrustCenter and the per-turn gate.
public final class NativeAgentEngine: Sendable {
    /// Keep paired body owners typed together, including the live root.
    private struct Body: Sendable {
        let contextFlow: NativeContextFlowRuntime
        let cognition: NativeCognitionRuntime
        let deviceSync: DeviceSync

        init(dataRoot: URL, ports: NativeAgentEnginePorts) {
            let contextFlow = NativeContextFlowRuntime(dataRoot: dataRoot)
            let cognition = NativeCognitionRuntime(dataRoot: dataRoot, host: ports.cognitionHost, contextFlow: contextFlow)
            self.contextFlow = contextFlow
            self.cognition = cognition
            self.deviceSync = DeviceSync(host: ports.deviceSyncHost, cognition: cognition)
        }
    }
    public let dataRoot: URL
    /// What her faces draw: her owners post finished values here, and each face (the Mac window, the phone) applies them per frame.
    public let face = FaceFeedSource()
    @MainActor public lazy var faceActs = EngineFaceActs(engine: self)
    public let countsFeed: CountsFeedProjection
    public let settingsFeed: SettingsFeedProjection
    public let panelFreshness: PanelFreshnessOwner
    public let countsStatus: CountsStatusProjection
    @MainActor var countSources: CountSources?
    public let layout: SurfaceLayoutLive
    public let ports: NativeAgentEnginePorts
    private let clients: EngineAgentContactClients
    public let hasBody: Bool
    /// Only body-backed roots may own the resident mind.
    public let cognition: NativeCognitionRuntime?
    public let cognitionView: CognitionViewFacade
    public let doctor: DoctorFacade
    /// Share persisted turn evidence between Mac Inspector and phone summaries.
    public let trace: TurnInspectorFeed
    /// Only body-backed roots may own phone sync.
    public let deviceSync: DeviceSync?
    /// Settings projects the same canonical sync owner.
    public let sync: SyncFacade
    public let memory: MemoryFacade
    public let graphUpkeep: GraphUpkeepOwner
    /// Share one saved persona presentation between Mac and phone.
    public let persona: PersonaFacade
    /// Every approval and inbox surface observes the same root-specific owners.
    public let approvals: ApprovalsFacade
    public let inbox: InboxFacade
    public let chrome: ChromeControlRuntime
    public let trust: TrustFacade
    public let macIntegration: MacIntegrationFacade
    public let providers: ProvidersFacade
    public let configuration = RuntimeReadouts.Configuration()
    public let runs = RuntimeReadouts.Runs()
    public let connectors: ConnectorReadiness
    @discardableResult public func setSurfaceExpanded(_ open: Bool, surface: String, block: String) async -> Result<SurfaceLayout, SurfaceLayoutFailure> {
        await layout.setExpanded(open, surface: surface, block: block)
    }
    public let telegram: TelegramFacade
    public let tools: ToolsFacade
    public let contacts: ContactListFacade
    public let senses: SensesFacade
    public let make: MakeStudio.Shelf
    public let today: TodayReadout
    /// Every page's face (the agent's JS pages and the native ones) and the one port what a row does returns through, for every door.
    public let pages: PartFaces
    /// The same Memories part over the memory owner's ios-disclosed packet; never a copy of the unrestricted Mac face.
    let phoneMemoryPages: PartFaces
    public let desk: DeskFacade
    public let bots: BotRunnerScheduler
    /// Every chat surface observes the root’s same transcript and turn owners.
    public let transcripts: TranscriptsFacade
    public let turns: TurnsFacade
    public let agents: AgentContacts
    public let contactThreads: ContactThreadReadouts
    /// Chat clients may reach ContextFlow only through body-backed roots.
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
        let launchedAt = Date()
        let hasBody = body != nil
        self.dataRoot = dataRoot
        self.layout = SurfaceLayoutLive(dataRoot: dataRoot)
        self.ports = ports
        self.hasBody = hasBody
        let counts = CountsFeedProjection(feed: face)
        self.countsFeed = counts
        self.settingsFeed = SettingsFeedProjection(feed: face)
        self.panelFreshness = PanelFreshnessOwner(counts: counts)
        self.countsStatus = CountsStatusProjection(countsFeed: counts)
        let contextFlow = body?.contextFlow ?? NativeContextFlowRuntime(dataRoot: dataRoot)
        let clients = EngineAgentContactClients(dataRoot: dataRoot, ports: ports, hasBody: hasBody,
            cognition: body?.cognition, contextFlow: contextFlow)
        self.clients = clients
        self.bots = BotRunnerScheduler(dataRoot: dataRoot,
            session: { bot, message, turn, scope, options in
                try await clients.standingBotSession()(bot, message, turn, scope, options)
            },
            isAutonomyEnabled: { await UnattendedWork.allowed(dataRoot: dataRoot) })
        PeerTrust.install(dataRoot: dataRoot)
        // Full Mac keeps are the agent’s act even on trusted-agent turns; only the user’s surfaces establish their own acts.
        CapabilityLifecycle.keepAuthority = { root in
            do { return AppToolExecutor.lockedPolicyIsFullMac(try SwiftNativeTrustCenter(dataRoot: root).loadSavedPolicyChecked()) }
            catch { return false }
        }
        self.memory = MemoryFacade(dataRoot: dataRoot)
        self.graphUpkeep = GraphUpkeepOwner(dataRoot: dataRoot)
        self.persona = PersonaFacade(dataRoot: dataRoot, isolated: !hasBody)
        self.approvals = ApprovalsFacade(dataRoot: dataRoot, counts: counts)
        self.inbox = InboxFacade(dataRoot: dataRoot, counts: counts)
        self.chrome = ChromeControlRuntime(dataRoot: dataRoot, signatureFailureNote: { id, message in
            try await ForPerson.at(dataRoot).tell(Matter(id: id, form: .wentWrong, from: "chrome",
                title: "Chrome link blocked by browser signature validation", summary: message), doors: Door.person(thread: nil))
        })
        self.trust = TrustFacade(dataRoot: dataRoot, connectorActionStatuses: {
            try await ConnectorActionRecord.checkedStatuses(root: dataRoot, platform: ports.connectorStatus)
        })
        self.providers = ProvidersFacade(dataRoot: dataRoot, settingsFeed: settingsFeed)
        self.connectors = ConnectorReadiness(root: dataRoot, platform: ports.connectorStatus)
        self.telegram = TelegramFacade(dataRoot: dataRoot)
        self.tools = ToolsFacade(dataRoot: dataRoot) { detail, turn in
            try await clients.toolDispatchClient().toolManifest(detail: detail, turn: turn)
        }
        self.desk = DeskFacade(dataRoot: dataRoot, inbox: self.inbox, approvals: self.approvals, bots: self.bots)
        self.contacts = ContactListFacade(dataRoot: dataRoot)
        self.contactThreads = ContactThreadReadouts(dataRoot: dataRoot, contacts: self.contacts)
        self.senses = SensesFacade()
        let makeTools = self.tools
        self.make = MakeStudio.Shelf(dataRoot: dataRoot, feed: face) { id, input, version in
            do {
                return try await makeTools.withPartDoor(envelope: .personOnMac("mac_ui:make.preview")) { door in
                    await Parts(root: dataRoot).face(id: id, input: input, version: version, invocation: door.invocation)
                }
            } catch { return .failure(.init(code: "door_unavailable", message: error.localizedDescription)) }
        }
        self.today = TodayReadout()
        let faceTools = self.tools
        self.pages = PartFaces(dataRoot: dataRoot, feed: face) { id, input, version in
            await faceTools.face(id: id, input: input, version: version)
        }
        self.phoneMemoryPages = PartFaces(dataRoot: dataRoot, feed: face, key: { PageFaceKey.phone($0) }) { id, input, version in
            await faceTools.face(id: id, input: input, version: version)
        }
        let turns = TurnsFacade(dataRoot: dataRoot)
        self.turns = turns
        self.transcripts = TranscriptsFacade(turns: turns, feed: face)
        self.doctor = DoctorFacade(dataRoot: dataRoot, launchedAt: launchedAt)
        let trace = TurnInspectorFeed(dataRootOverride: dataRoot, feed: face)
        self.trace = trace
        if hasBody { Task { await trace.start() } }
        self.contextFlow = contextFlow
        let cognition = body?.cognition
        self.cognition = cognition
        self.cognitionView = CognitionViewFacade(dataRoot: dataRoot, runtime: cognition)
        let deviceSync = body?.deviceSync
        self.deviceSync = deviceSync
        self.sync = SyncFacade(owner: deviceSync)
        self.macIntegration = MacIntegrationFacade(dataRoot: dataRoot, deviceSync: deviceSync, platform: ports.connectorStatus)
        // This root-level classifier has no conversation operation or helper door.
        AgentHostLaunches.install { try AgentConversationRouting.messagesHostByCommand(conversation: .init(), $0, dataRoot: $1) }
        self.agents = AgentContacts(dataRoot: dataRoot, clients: clients,
                                    completionSender: ports.completionSender(dataRoot))
        clients.attach(self.agents)
        installSessionDelivery()
        Task { @MainActor [turns, face, approvals, persona, transcripts] in
            turns.bindTurnFaces(source: face, approvals: approvals, persona: persona, transcripts: transcripts)
        }
        Task { @MainActor [layout] in layout.start() }
        Task { @MainActor [weak self, pages] in
            await self?.registerPages()
            await pages.finishRegistration()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            countSources = CountSources(engine: self)
            bindCountStatusSources()
            await trust.bindSettingsFeed(settingsFeed)
            await persona.bindSettingsFeed(settingsFeed)
            await connectors.bindSettingsFeed(settingsFeed)
            await macIntegration.bindSettingsFeed(settingsFeed)
            await configuration.bindSettingsFeed(settingsFeed)
        }
    }

    public func toolDispatchClient(
        enforceAppAutonomy: Bool = true,
        actionExecution: AppActionExecution? = nil
    ) -> AppChatToolDispatcher {
        clients.toolDispatchClient(enforceAppAutonomy: enforceAppAutonomy, actionExecution: actionExecution)
    }

    public func bridgeToolDispatchClient(
        fileAccess: String = "read_only", approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30, verifiedSessionId: String? = nil,
        conversation: AgentConversationContext = .init()
    ) -> any ToolDispatchClient {
        clients.bridgeToolDispatchClient(fileAccess: fileAccess, approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds, verifiedSessionId: verifiedSessionId, conversation: conversation)
    }

    public func standingBotSession(admitted: Bool = false, attachments: [MultimodalAttachment] = [],
                                  fileAccess: String = "auto", progress: TurnEventSink? = nil,
                                  continuation: DeskContinuationTurn? = nil) -> BotRunnerSession {
        clients.standingBotSession(admitted: admitted, attachments: attachments, fileAccess: fileAccess,
            progress: progress, continuation: continuation)
    }

    public func chatClient(tools: any ToolDispatchClient, approvalFiler: (any ApprovalFiler)? = nil,
                           continuationCapabilityProfile: NativeAgentAppChatSurfaceProfile? = nil) -> SwiftNativeChatOrchestrationClient {
        clients.chatClient(tools: tools, approvalFiler: approvalFiler, continuationCapabilityProfile: continuationCapabilityProfile)
    }

    public func chatClient(profile: NativeAgentAppChatSurfaceProfile, approvalFiler: (any ApprovalFiler)? = nil) -> SwiftNativeChatOrchestrationClient {
        clients.chatClient(profile: profile, approvalFiler: approvalFiler)
    }
}

/// Clients share immutable dependencies without borrowing engine lifetime; weak contact callbacks avoid cycles and bind their owner before use.
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
    func bridgeChatClient(didWrite: @escaping @Sendable (URL) -> Void) -> SwiftNativeChatOrchestrationClient {
        chatClient(tools: EngineContactToolDispatcher(inner: toolDispatchClient(), didWrite: didWrite))
    }
    func backgroundChatClient() -> SwiftNativeChatOrchestrationClient { chatClient(profile: .background) }
    func lineChatClient() -> SwiftNativeChatOrchestrationClient {
        chatClient(tools: toolDispatchClient(enforceAppAutonomy: false, actionExecution: nil),
            approvalFiler: NativeAgentChatApprovalFiler(dataRoot: dataRoot), continuationCapabilityProfile: nil)
    }
    func chatClient(tools: any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient {
        chatClient(tools: tools, approvalFiler: nil, continuationCapabilityProfile: nil)
    }
    func toolDispatchClient(enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        toolDispatchClient(enforceAppAutonomy: enforceAppAutonomy, actionExecution: nil)
    }
    func bridgeToolDispatchClient(fileAccess: String, verifiedSessionId: String?, conversation: AgentConversationContext) -> any ToolDispatchClient {
        bridgeToolDispatchClient(fileAccess: fileAccess, approvalFiler: nil,
            approvalTimeoutSeconds: 30, verifiedSessionId: verifiedSessionId, conversation: conversation)
    }
    func toolDispatchClient(
        enforceAppAutonomy: Bool = true,
        actionExecution suppliedExecution: AppActionExecution? = nil
    ) -> AppChatToolDispatcher {
        let dataRoot = self.dataRoot
        let actionExecution: AppActionExecution
        if let suppliedExecution {
            actionExecution = suppliedExecution
        } else {
            // A root client has no enclosing operation; its owners share this invocation's ceilings.
            let invocation = ChatToolInvocation()
            let work = ChatTurnWork(toolInvocation: invocation)
            actionExecution = AppActionExecution(invocation: invocation, deadlines: work.deadlines, turnWork: work)
        }
        // App tools reach the single Core catalog through this port; bodyless roots have none.
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let appToolExecutor: AppToolExecutor? = (hasBody ? ports : nil).map { ports in
            ports.appTools(securityCenter, enforceAppAutonomy)
        }
        let inner: @Sendable (AppActionExecution) -> any ToolDispatchClient = { [self] execution in SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: hasBody,
            providerLifecycleObserver: cognition,
            // Studio entries reach the mind through its own journal bus.
            studioJournalBus: cognition?.studioJournalBus,
            macIntegrationBridge: hasBody ? ports.macIntegration : nil,
            appTools: appToolExecutor?.withExecution(execution),
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
            a2aPushConfiguration: (hasBody ? ports : nil).map { $0.a2aPushConfiguration },
            standingBotRunEnqueue: (hasBody ? ports : nil).map { ports in { @Sendable id, question in
                try ports.standingBotQueue.enqueue(bot: id, context: question,
                    scope: .init(ancestry: execution.invocation.botAncestry))
            } },
            standingBotSession: standingBotSession()
        ) }
        let appTools: AppChatToolDispatcher
        if let cognition {
            appTools = AppChatToolDispatcher(
                securityCenter: securityCenter,
                enforceAutonomySecurity: enforceAppAutonomy,
                appTools: appToolExecutor,
                motorOutcomeObserver: { reference in
                    let model: MotorActionReadModel?
                    switch reference.domain {
                    case .macControl:
                        model = try? await MacControlOperationStore(dataRoot: dataRoot)
                            .motorActionReadModel(actionId: reference.ownerActionID)
                    case .browser:
                        // BrowserActionRunner already returns the browser owner’s canonical consequence to cognition.
                        model = nil
                    }
                    guard let model else { return }
                    await cognition.observeMotorActionState(model)
                },
                platform: ports.chatPlatform,
                scopedInner: inner, actionExecution: actionExecution
            )
        } else {
            appTools = AppChatToolDispatcher(
                securityCenter: securityCenter,
                enforceAutonomySecurity: enforceAppAutonomy,
                includeAppOwnedTools: false,
                platform: ports.chatPlatform,
                scopedInner: inner, actionExecution: actionExecution
            )
        }
        // Peer turns expose tools while AutonomyGatedDispatcher retains effect permission gating.
        return appTools
    }

    /// Raw bridge RPC shares chat’s app chain under conservative read-only/autonomy policy and caller-supplied nonblocking approval filing.
    func bridgeToolDispatchClient(
        fileAccess: String = "read_only",
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        verifiedSessionId: String? = nil,
        conversation: AgentConversationContext = .init()
    ) -> any ToolDispatchClient {
        let tools = EngineContactToolDispatcher(inner: toolDispatchClient(), conversation: conversation)
        return makeGatedToolDispatchClient(
            tools: tools,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            verifiedSessionId: verifiedSessionId
        )
    }

    /// Scheduled and explicit helper runs share app tool gates.
    func standingBotSession(admitted: Bool = false, attachments: [MultimodalAttachment] = [],
                                   fileAccess: String = "auto", progress: TurnEventSink? = nil,
                                   continuation: DeskContinuationTurn? = nil) -> BotRunnerSession {
        // Returned sessions retain contact owners even from temporary engines; weak composition avoids self-retention through clients.
        let contacts = lock.withLock { self.contacts }
        return { [self, contacts] bot, message, turn, scope, options in
            guard let contacts else {
                throw PersistenceCoreError.ioFailure("The helper's contact owner has retired.")
            }
            let client = makeChatOrchestrationClient(
                tools: toolDispatchClient(), dataRoot: dataRoot,
                continuationCapabilityProfile: NativeAgentAppChatSurfaceProfile.mac.rawValue,
                approvalFiler: NativeAgentChatApprovalFiler(dataRoot: dataRoot))
            var invocation = ChatToolInvocation()
            invocation.helperDoor = contacts.helperDoor(for: bot)
            return try await StandingBotContinuity.session(client: client, dataRoot: dataRoot, admitted: admitted,
                attachments: attachments, fileAccess: fileAccess, progress: progress,
                work: .init(journal: continuation, toolInvocation: invocation))(bot, message, turn, scope, options)
        }
    }

    /// Share mind/body, ContextFlow, memory and provider lifecycle across dispatchers while preserving restricted inventories and canonical first-run gates.
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

    /// Centralize production surface policy so new callers cannot drift through Boolean defaults.
    func chatClient(
        profile: NativeAgentAppChatSurfaceProfile,
        approvalFiler: (any ApprovalFiler)? = nil
    ) -> SwiftNativeChatOrchestrationClient {
        // Conversation surfaces share durable approval filing; background work without a user must fail confirmation closed unless supplied a filer.
        let resolvedApprovalFiler: (any ApprovalFiler)? = approvalFiler
            ?? (profile.filesApprovalsByDefault
                ? NativeAgentChatApprovalFiler(dataRoot: dataRoot)
                : nil)
        let tools = toolDispatchClient(
            // Authenticate origin before the shared runtime resolves autonomy once. Keep inner SecurityCenter hard checks; direct app clients retain their own
            // autonomy gate.
            enforceAppAutonomy: false,
            actionExecution: nil
        )
        return chatClient(
            tools: tools,
            approvalFiler: resolvedApprovalFiler,
            continuationCapabilityProfile: profile
        )
    }
}

extension NativeAgentEngine {
    /// Observe this engine’s authority sources only while Activity is mounted.
    @MainActor
    public func watchActivityChanges(refresh: @escaping @MainActor @Sendable () async -> Void) async {
        let database = dataRoot.appendingPathComponent("memory/memory.sqlite")
        var paths = [
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            database, URL(fileURLWithPath: database.path + "-wal"),
        ]
        if #available(macOS 27, *) {
            paths += [dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
                      dataRoot.appendingPathComponent("desk/desk_ops_base.json")]
        }
        let observedPaths = paths
        let forPerson = ForPerson.at(dataRoot)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await EventDeadlinePhysiology.refreshOnChanges(paths: observedPaths, refresh: refresh) }
            group.addTask {
                for await _ in await forPerson.changes() {
                    guard !Task.isCancelled else { return }
                    await refresh()
                }
            }
        }
    }

    private static let liveRoot: (engine: NativeAgentEngine, body: Body) = {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let ports = NativeAgentEnginePorts.app(dataRoot: dataRoot)
        let body = Body(dataRoot: dataRoot, ports: ports)
        return (NativeAgentEngine(dataRoot: dataRoot, ports: ports, body: body), body)
    }()
    public static var live: NativeAgentEngine { liveRoot.engine }
    public static var liveCognition: NativeCognitionRuntime { liveRoot.body.cognition }
    public static var liveDeviceSync: DeviceSync { liveRoot.body.deviceSync }

    public static func forRoot(_ dataRoot: URL) -> NativeAgentEngine {
        SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot)
            ? live : NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot), hasBody: false)
    }
}

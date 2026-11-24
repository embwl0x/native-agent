import SenseCore
import Foundation
import Synchronization
import NativeAgentShared
import DeskCore
import MindCore
import MacNerves
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeAgentEngine.swift` | Root composition; Chrome refusals tell ForPerson and Activity follows its changes |

// MARK: - Engine root

/// Compose every chat client and tool chain from one root and native ports. Roots without bodies cannot borrow process-global tools, live organism or
/// Context projections; authority remains in SecurityCenter, TrustCenter and the per-turn gate.
public final class NativeAgentEngine: Sendable {
    final class Reference: Sendable {
        private struct Owner { weak var engine: NativeAgentEngine? }
        private let owner = Mutex(Owner())

        fileprivate func bind(_ engine: NativeAgentEngine) {
            owner.withLock { $0.engine = engine }
        }

        func resolve() throws -> NativeAgentEngine {
            try owner.withLock {
                guard let engine = $0.engine else { throw PersistenceCoreError.ioFailure("The owning engine has retired.") }
                return engine
            }
        }
    }

    /// Keep paired body owners typed together, including the live root. The body owns its mind's lifetime, not a mind: there is none until setup
    /// has finished (`MindLifetime`).
    private struct Body: Sendable {
        let field: BodyField
        let contextFlow: NativeContextFlowRuntime
        let mind: MindLifetime
        let deviceSync: DeviceSync
        let engine = NativeAgentEngine.Reference()

        init(dataRoot: URL) {
            let contextFlow = NativeContextFlowRuntime(dataRoot: dataRoot)
            let field = BodyField()
            self.field = field
            let mind = MindLifetime(dataRoot: dataRoot, engine: engine, contextFlow: contextFlow, bodyField: field)
            self.contextFlow = contextFlow
            self.mind = mind
            self.deviceSync = DeviceSync(dataRoot: dataRoot, engine: engine, mind: { mind.runtime }, mindChanges: { mind.changes() })
        }
    }
    public let dataRoot: URL
    let partBinding: AppActionBinding.PartLookup
    let messagesByCommand: AgentHostLaunches.Reader
    /// What her faces draw: her owners post finished values here, and each face (the Mac window, the phone) applies them per frame.
    public let face = FaceFeedSource()
    @MainActor public lazy var faceActs = EngineFaceActs(engine: self)
    public let countsFeed: CountsFeedProjection
    public let settingsFeed: SettingsFeedProjection
    public let panelFreshness: PanelFreshnessOwner
    public let countsStatus: CountsStatusProjection
    @MainActor var countSources: CountSources?
    public let layout: SurfaceLayoutLive
    public let interactions: InlineInteractionCoordinator
    public let ports: NativeAgentEnginePorts
    public let hasBody: Bool
    public let bodyField: BodyField?
    /// Only body-backed roots own the resident mind's lifetime.
    public let mind: MindLifetime?
    /// The running mind, read when asked: nil before setup has finished, after a reset closed it, and on roots without a body.
    public var cognition: NativeCognitionRuntime? { mind?.runtime }
    public let cognitionView: CognitionViewFacade
    public let doctor: DoctorFacade
    /// Share persisted turn evidence between Mac Inspector and phone summaries.
    public let trace: TurnInspectorFeed
    let abandonedTurns: AbandonedTurnReconciliation
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
    let sessionDelivery: SessionTurnDelivery.Resolver?
    private let actionRuntime: ActionRuntime
    public let agents: AgentContacts
    public let agentJobs: AgentJobService
    public let contactThreads: ContactThreadReadouts
    /// Chat clients may reach ContextFlow only through body-backed roots.
    public let contextFlow: NativeContextFlowRuntime

    private init(dataRoot: URL, ports: NativeAgentEnginePorts, body: Body?) {
        let jobStore = AgentJobStore(dataRoot: dataRoot)
        let launchedAt = Date()
        let engine = body?.engine ?? Reference()
        let hasBody = body != nil
        self.dataRoot = dataRoot
        self.partBinding = { id, turn in try AppActions.action(id, dataRoot: dataRoot, turn: turn)?.binding }
        self.messagesByCommand = { try AgentConversationRouting.messagesHostByCommand(conversation: .init(), $0, dataRoot: dataRoot) }
        self.layout = SurfaceLayoutLive(dataRoot: dataRoot)
        self.ports = ports
        self.hasBody = hasBody
        self.bodyField = body?.field
        let counts = CountsFeedProjection(feed: face)
        self.countsFeed = counts
        self.settingsFeed = SettingsFeedProjection(feed: face)
        self.panelFreshness = PanelFreshnessOwner(counts: counts)
        self.countsStatus = CountsStatusProjection(countsFeed: counts)
        let contextFlow = body?.contextFlow ?? NativeContextFlowRuntime(dataRoot: dataRoot)
        let mind = body?.mind
        self.memory = MemoryFacade(dataRoot: dataRoot)
        self.graphUpkeep = GraphUpkeepOwner(dataRoot: dataRoot)
        self.persona = PersonaFacade(dataRoot: dataRoot, isolated: !hasBody)
        self.approvals = ApprovalsFacade(dataRoot: dataRoot, counts: counts)
        self.inbox = InboxFacade(dataRoot: dataRoot, counts: counts)
        let interactions = InlineInteractionCoordinator(dataRoot: dataRoot, engine: engine,
            platform: ports.interactionPlatform { try engine.resolve() })
        self.interactions = interactions
        let completionSender = ports.completionSender(dataRoot) { try engine.resolve() }
        self.agents = AgentContacts(dataRoot: dataRoot, engine: engine, hasBody: hasBody,
                                    completionSender: completionSender)
        self.bots = BotRunnerScheduler(dataRoot: dataRoot,
            providerCheck: { bot in
                do { _ = try await BotChatContract.choice(for: bot, dataRoot: dataRoot); return nil }
                catch { return String(describing: error) }
            },
            session: { bot, message, turn, scope, options in
                try await engine.resolve().standingBotSession()(bot, message, turn, scope, options)
            },
            isAutonomyEnabled: {
                // A body's helpers run unattended only while its mind runs: none before setup has finished or after a reset.
                if let mind, mind.runtime == nil { return false }
                return await UnattendedWork.allowed(dataRoot: dataRoot)
            })
        self.chrome = ChromeControlRuntime(dataRoot: dataRoot, signatureFailureNote: { id, message in
            try await ForPerson.at(dataRoot).tell(Matter(id: id, form: .wentWrong, from: "chrome",
                title: "Chrome link blocked by browser signature validation", summary: message), doors: Door.person(thread: nil))
        })
        self.trust = TrustFacade(dataRoot: dataRoot, connectorActionStatuses: {
            try await ConnectorActionRecord.checkedStatuses(root: dataRoot, platform: ports.connectorStatus)
        })
        self.providers = ProvidersFacade(dataRoot: dataRoot, settingsFeed: settingsFeed, interactions: interactions)
        self.connectors = ConnectorReadiness(root: dataRoot, platform: ports.connectorStatus, interactions: interactions)
        self.telegram = TelegramFacade(dataRoot: dataRoot)
        self.tools = ToolsFacade(dataRoot: dataRoot) { try engine.resolve() }
        self.desk = DeskFacade(dataRoot: dataRoot, inbox: self.inbox, approvals: self.approvals, bots: self.bots)
        self.contacts = ContactListFacade(dataRoot: dataRoot)
        self.contactThreads = ContactThreadReadouts(dataRoot: dataRoot, contacts: self.contacts)
        self.senses = SensesFacade()
        self.make = MakeStudio.Shelf(dataRoot: dataRoot, feed: face) { id, input, version in
            do {
                return try await engine.resolve().withPartDoor(envelope: .personOnMac("mac_ui:make.preview")) { door in
                    await Parts(root: dataRoot).face(id: id, input: input, version: version, invocation: door.invocation)
                }
            } catch { return .failure(.init(code: "door_unavailable", message: error.localizedDescription)) }
        }
        self.today = TodayReadout()
        let faceTools = self.tools
        self.pages = PartFaces(dataRoot: dataRoot, feed: face) { id, input, version in
            await faceTools.face(id: id, input: input, version: version)
        }
        self.phoneMemoryPages = PartFaces(dataRoot: dataRoot) { id, input, version in
            await faceTools.face(id: id, input: input, version: version)
        }
        let turns = TurnsFacade(dataRoot: dataRoot, pages: pages, jobStore: jobStore, bodyField: body?.field)
        self.turns = turns
        self.transcripts = TranscriptsFacade(turns: turns, feed: face, interactions: interactions, tools: tools)
        self.sessionDelivery = Self.makeSessionDelivery(deviceSync: body?.deviceSync, turns: turns, transcripts: transcripts)
        self.doctor = DoctorFacade(dataRoot: dataRoot, launchedAt: launchedAt)
        let trace = TurnInspectorFeed(dataRootOverride: dataRoot, feed: face)
        self.trace = trace
        self.abandonedTurns = AbandonedTurnReconciliation(dataRoot: dataRoot, traceBus: makeChatTurnTraceBus(dataRoot: dataRoot))
        self.contextFlow = contextFlow
        self.mind = mind
        self.cognitionView = CognitionViewFacade(dataRoot: dataRoot, mind: mind)
        let deviceSync = body?.deviceSync
        self.deviceSync = deviceSync
        self.sync = SyncFacade(owner: deviceSync)
        self.macIntegration = MacIntegrationFacade(dataRoot: dataRoot, deviceSync: deviceSync, platform: ports.connectorStatus)
        self.agentJobs = Self.makeAgentJobs(dataRoot: dataRoot, store: jobStore, own: self.agents.ownLineDoor())
        self.actionRuntime = ActionRuntime(
            dataRoot: dataRoot,
            bodyField: bodyField,
            allowProcessGlobalTools: hasBody,
            dotTransport: agents.dotTransport, jobStore: agentJobs.store,
            providerLifecycleObserver: mind,
            studioJournalBus: mind?.journal,
            macIntegrationBridge: hasBody ? ports.macIntegration : nil,
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
            a2aPushConfiguration: (hasBody ? ports : nil).map { $0.a2aPushConfiguration },
            standingBotRunEnqueue: (hasBody ? ports : nil).map { ports in { @Sendable id, question, turn, ancestry in
                try ports.standingBotQueue.enqueue(bot: id, context: question, steeringSources: turn.peerSteering.map { taint in taint.checkpointSources.filter { !taint.elevatedSources.contains($0) } } ?? [],
                    scope: .init(ancestry: ancestry))
            } },
            standingBotRunner: bots.runner
        )
        engine.bind(self)
        if hasBody {
            Task { await trace.start() }
            _ = AppToolExecutor.appToolSchemas()
            CapabilityLifecycle.keepAuthority = { root in
                do { return AppToolExecutor.lockedPolicyIsFullMac(try SwiftNativeTrustCenter(dataRoot: root).loadSavedPolicyChecked()) }
                catch { return false }
            }
        }
        AgentConversationStore.restoreProjections(engine: self)
        mind?.attach(stream: { MindStream(dataRoot: dataRoot, engine: engine, completionSender: completionSender) })
        Task { @MainActor [turns, face, approvals, persona, transcripts] in
            turns.bindTurnFaces(source: face, approvals: approvals, persona: persona, transcripts: transcripts)
        }
        Task { @MainActor [layout] in layout.start() }
        Task { @MainActor [weak self] in
            await self?.registerPages()
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

    private static func makeAgentJobs(dataRoot: URL, store: AgentJobStore, own: OwnLineDoor) -> AgentJobService {
        AgentJobService(dataRoot: dataRoot, store: store, own: own) { id, executable, arguments in
            let job = try store.job(id)
            guard let origin = job.commission.origin else { throw JobRefusal("This job has no commissioning origin proof. Nothing ran.") }
            var permission = await SwiftNativeSecurityCenter(dataRoot: dataRoot).drivenAgentLaunchPermission(origin: origin, turn: nil)
            let steering = PeerDataTaint(dataRoot: dataRoot, restoring: job.peers ?? [], elevated: job.elevated ?? [])
            if permission == .fullMac, steering.isTainted(dataRoot: dataRoot)
                || (PeerTurnEffectPolicy.isPeerBridge(surface: origin.surface) && steering.checkpointSources.isEmpty) { permission = .restricted }
            let rule = await SwiftToolDispatcher.agentProgramLaunch(permission, dataRoot: dataRoot)
            switch rule.launch {
            case .run(let wrap): return wrap(executable, arguments)
            case .refused(let detail): throw JobRefusal(detail)
            }
        }
    }

    func lineChatClient() -> SwiftNativeChatOrchestrationClient {
        chatClient(tools: toolDispatchClient(enforceAppAutonomy: false),
            approvalFiler: NativeAgentChatApprovalFiler(dataRoot: dataRoot), continuationCapabilityProfile: nil)
    }

    public func toolDispatchClient(
        enforceAppAutonomy: Bool = true
    ) -> SwiftToolDispatcher {
        let dataRoot = self.dataRoot
        // App tools reach the single Core catalog through this port; bodyless roots have none.
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let appToolExecutor: AppToolExecutor? = (hasBody ? ports : nil).map { ports in
            ports.appTools(securityCenter, enforceAppAutonomy, self)
        }
        let environment = AppActionEnvironment(interactions: interactions, securityCenter: securityCenter,
            enforceAutonomySecurity: enforceAppAutonomy, includeAppOwnedTools: hasBody,
            motorOutcomeObserver: { [mind] reference in
                guard let mind, case .macControl = reference.domain,
                      let model = try? await MacControlOperationStore(dataRoot: dataRoot)
                        .motorActionReadModel(actionId: reference.ownerActionID) else { return }
                await mind.runtime?.observeMotorActionState(model)
            },
            platform: ports.chatPlatform)
        return SwiftToolDispatcher(runtime: actionRuntime, appTools: appToolExecutor, appEnvironment: environment)
    }

    /// Raw bridge RPC shares chat’s app chain under conservative read-only/autonomy policy and caller-supplied nonblocking approval filing.
    public func bridgeToolDispatchClient(
        fileAccess: String = "read_only",
        approvalFiler: (any ApprovalFiler)? = nil,
        approvalTimeoutSeconds: Double = 30,
        verifiedSessionId: String? = nil,
        conversation: AgentConversationContext = .init()
    ) -> any ToolDispatchClient {
        let tools = toolDispatchClient()
        return makeGatedToolDispatchClient(
            tools: tools, jobStore: agentJobs.store,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            verifiedSessionId: verifiedSessionId, conversation: conversation
        )
    }

    /// Scheduled and explicit helper runs share app tool gates.
    public func standingBotSession(admitted: Bool = false, attachments: [MultimodalAttachment] = [],
                                   fileAccess: String = "auto", progress: TurnEventSink? = nil,
                                   continuation: DeskContinuationTurn? = nil) -> BotRunnerSession {
        return { [self] bot, message, turn, scope, options in
            let client = makeChatOrchestrationClient(
                tools: toolDispatchClient(), jobStore: agentJobs.store, bodyField: bodyField, dataRoot: dataRoot, sessionDelivery: sessionDelivery, pages: pages,
                liveTurns: deviceSync?.liveTurns,
                continuationCapabilityProfile: NativeAgentAppChatSurfaceProfile.mac.rawValue,
                approvalFiler: NativeAgentChatApprovalFiler(dataRoot: dataRoot))
            var invocation = ChatToolInvocation()
            invocation.helperDoor = agents.helperDoor(for: bot)
            return try await StandingBotContinuity.session(client: client, dataRoot: dataRoot, admitted: admitted,
                attachments: attachments, fileAccess: fileAccess, progress: progress,
                work: .init(journal: continuation, toolInvocation: invocation))(bot, message, turn, scope, options)
        }
    }

    /// Share mind/body, ContextFlow, memory and provider lifecycle across dispatchers while preserving restricted inventories and canonical first-run gates.
    public func chatClient(
        tools: any ToolDispatchClient,
        approvalFiler: (any ApprovalFiler)? = nil,
        continuationCapabilityProfile: NativeAgentAppChatSurfaceProfile? = nil
    ) -> SwiftNativeChatOrchestrationClient {
        let contextFlow = hasBody ? self.contextFlow : nil
        return makeChatOrchestrationClient(
            tools: tools,
            jobStore: agentJobs.store, bodyField: bodyField,
            dataRoot: dataRoot,
            sessionDelivery: sessionDelivery, pages: pages,
            liveTurns: deviceSync?.liveTurns,
            continuationCapabilityProfile: continuationCapabilityProfile?.rawValue,
            approvalFiler: approvalFiler,
            cognitiveRuntime: mind,
            providerLifecycleObserver: mind,
            contextFlow: contextFlow,
            memoryAtomTranslator: contextFlow.map { runtime in { @Sendable recordID in
                runtime.memoryRecordAtomID(forRecordID: recordID)
            } }
        )
    }

    /// Centralize production surface policy so new callers cannot drift through Boolean defaults.
    public func chatClient(
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
            enforceAppAutonomy: false
        )
        return chatClient(
            tools: tools,
            approvalFiler: resolvedApprovalFiler,
            continuationCapabilityProfile: profile
        )
    }
}

extension Turn {
    public init(dataRoot: URL, id: String = Turn.mintID(), run: String = UUID().uuidString, session: String? = nil) {
        self.init(admitting: dataRoot, id: id, run: run, session: session)
        self[AppActionBinding.Parts.self] = { try NativeAgentEngine.forRoot(dataRoot).partBinding($0, $1) }
        self[AgentHostLaunches.self] = { try NativeAgentEngine.forRoot(dataRoot).messagesByCommand($0) }
    }
}

extension NativeAgentEngine {
    private static let liveRoot: (engine: NativeAgentEngine, body: Body) = {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let ports = NativeAgentEnginePorts.app(dataRoot: dataRoot)
        let body = Body(dataRoot: dataRoot)
        return (NativeAgentEngine(dataRoot: dataRoot, ports: ports, body: body), body)
    }()
    public static var live: NativeAgentEngine { liveRoot.engine }
    /// The running mind: nil before setup has finished and after a reset closed it. Reading it never makes one.
    public static var liveCognition: NativeCognitionRuntime? { liveRoot.body.mind.runtime }
    public static var liveDeviceSync: DeviceSync { liveRoot.body.deviceSync }

    private static let alternateEngines = Mutex<[String: NativeAgentEngine]>([:])

    public static func forRoot(_ dataRoot: URL) -> NativeAgentEngine {
        if SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot) { return live }
        let root = dataRoot.standardizedFileURL
        return alternateEngines.withLock { engines in
            if let engine = engines[root.path] { return engine }
            let engine = NativeAgentEngine(dataRoot: root, ports: .app(dataRoot: root), body: nil)
            engines[root.path] = engine
            return engine
        }
    }
}

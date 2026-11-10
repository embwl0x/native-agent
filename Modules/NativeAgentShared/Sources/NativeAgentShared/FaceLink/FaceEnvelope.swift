import Foundation
// Blueprint: | `FaceEnvelope.swift` | Complete typed act/call vocabulary and correlated replies on the body–face pipe |

public enum FaceEnvelope: Codable, Sendable {
    public static let protocolVersion = 1
    case feed(FaceBatch)
    case call(id: UUID, FaceCall)
    case reply(id: UUID, FaceReply)
    case act(id: UUID, FaceAct)
    case actReply(id: UUID, FaceActReply)

    private enum Payload: Codable {
        case feed(FaceBatch)
        case call(id: UUID, FaceCall)
        case reply(id: UUID, FaceReply)
        case act(id: UUID, FaceAct)
        case actReply(id: UUID, FaceActReply)
    }
    private enum CodingKeys: String, CodingKey { case payload }

    /// JSON bytes preserve Shared scalar nulls inside the binary property-list envelope.
    public func encode(to encoder: any Encoder) throws {
        let payload: Payload = switch self {
        case .feed(let batch): .feed(batch)
        case .call(let id, let call): .call(id: id, call)
        case .reply(let id, let reply): .reply(id: id, reply)
        case .act(let id, let act): .act(id: id, act)
        case .actReply(let id, let reply): .actReply(id: id, reply)
        }
        let json = JSONEncoder()
        json.userInfo = encoder.userInfo
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(json.encode(payload), forKey: .payload)
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let json = JSONDecoder()
        json.userInfo = decoder.userInfo
        let payload = try json.decode(Payload.self, from: fields.decode(Data.self, forKey: .payload))
        self = switch payload {
        case .feed(let batch): .feed(batch)
        case .call(let id, let call): .call(id: id, call)
        case .reply(let id, let reply): .reply(id: id, reply)
        case .act(let id, let act): .act(id: id, act)
        case .actReply(let id, let reply): .actReply(id: id, reply)
        }
    }
}

public enum FaceAct: Codable, Sendable {
    case savePageSecret(PageActRequest, secret: Data)
    case readCredential(FaceCredentialRead)
    case readProviderAccount(id: String)
    case attach(protocolVersion: Int)
    case observe(id: UUID, demand: FaceDemand)
    case unobserve(id: UUID)
    case refresh(FaceRefreshScope)
    case frameApplied(epoch: UUID, sequence: UInt64, barriers: [UUID])
    case cancelRequest(UUID)
    case restoreConversation
    case createConversation
    case selectConversation(session: String, userInitiated: Bool)
    case markConversationRead(session: String)
    case renameConversation(session: String, title: String)
    case archiveConversation(session: String)
    case clearConversation(session: String)
    case pinConversation(session: String)
    case unpinConversation(session: String)
    case send(SendRequest)
    case stop(session: String, expectedTurn: String?)
    case regenerate(session: String, message: String, choice: RetryChoice)
    case prepareRetryDraft(session: String, message: String)
    case exportConversation(ConversationExportRequest)
    case appendSlashHelp(session: String)
    case pageAct(PageActRequest)
    case requestDocument(DocumentRequest)
    case readRun(id: String)
    case requestCopy(keys: [String])
    case setSurfaceExpanded(surface: String, block: String, open: Bool)
    case openTranscriptReader(TranscriptReaderRequest)
    case resizeTranscriptReader(TranscriptReaderGeometry)
    case releaseTranscriptReader(reader: UUID)
    case transcriptReceipt(reader: UUID, receipt: TranscriptReceipt)
    case setTranscriptFold(reader: UUID, rows: [String], expanded: Bool)
    case firstVisibleReply(VisibleReplyReceipt)
    case declarePreferences(keys: [String])
    case setPreference(key: String, value: PartFace.Value)
    case saveChatChoice(ChatChoiceWrite)
    case saveProviderConnection(ProviderConnectionWrite)
    case testProvider(ProviderTestRequest)
    case disconnectProvider(id: String)
    case beginOAuth(provider: String)
    case signOutProvider(id: String)
    case decideCodexCLIConsent(allow: Bool)
    case repairCodexCLIConsent
    case saveAnthropicSetupToken(secret: Data)
    case answerCard(CardAnswer)
    case verifyCardOnReturn(card: String, session: String, revision: Int)
    case setConnectorEnabled(id: String, enabled: Bool)
    case disconnectConnector(id: String)
    case saveConnectorCredentials(ConnectorCredentialWrite)
    case configureTelegram(TelegramConfigurationWrite)
    case saveSlackIngress(SlackIngressWrite)
    case testTelegram
    case clearTelegramLogs
    case repairTelegram(inbox: String?)
    case removePhonePairing(id: String)
    case importGrokCredentials(GrokCredentialWrite)
    case setUpChrome
    case resolveApproval(id: String, decision: FaceApprovalDecision)
    case inboxAction(id: String, action: String, value: PartFace.Value?)
    case applyTrustPreset(TrustPresetRequest)
    case saveMemoryPolicy(MemoryPolicyPatch)
    case setAutonomyEnabled(Bool)
    case setChromeControlEnabled(Bool)
    case setKillSwitchEnabled(Bool)
    case saveMacIntegrationPreset(String)
    case saveMacControlPolicy(MacControlPolicyWrite)
    case saveMultimodalPolicy(MultimodalPolicyWrite)
    case authorizeSafePolicy
    case refreshPrivacyInventory
    case checkMail
    case requestMacOSAccess(targets: [String], card: CardIdentity?)
    case openMacOSSettings(capability: String)
    case runMacControl(MacControlRequest)
    case notify(title: String, message: String)
    case setActivityPolicy(ActivityPolicyWrite)
    case excludeActivityApp(bundleID: String, confirmed: Bool)
    case removeActivityExclusion(bundleID: String)
    case wipeActivity(confirmed: Bool)
    case setInboxTrigger(name: String, enabled: Bool)
    case createBackup(reason: String)
    case restoreBackup(id: String, confirmed: Bool)
    case createProductionExport(support: Bool)
    case runDoctor(DoctorRequest)
    case requestSupportSnapshot
    case setEmbeddingDownload(DownloadCommand)
    case setEmbeddingsEnabled(Bool)
    case reindexSpotlight
    case requestUpdate(UpdateCommand)
    case updateInteraction(operation: UUID, action: UpdateInteraction)
    case remember(text: String)
    case commitNote(text: String)
    case writeScratch(session: String?, key: String, value: String)
    case searchMemories(query: String)
    case pinMemory(id: String, pinned: Bool)
    case forgetMemory(id: String)
    case resolveMemoryProposal(id: String, decision: ProposalDecision)
    case readPersona(documents: Bool)
    case savePersonaProfile(PersonalityProfile)
    case savePersonaName(String)
    case savePersonaDocument(id: String, content: String, append: Bool, expectedContent: String? = nil)
    case createStarterPersona(StarterPersonaRequest)
    case onboarding(OnboardingAct)
    case cognition(CognitionAct)
    case runDream
    case runREM
    case setDreamCycleEnabled(Bool)
    case setREMCycleEnabled(Bool)
    case setInnerLifeEnabled(Bool)
    case setContextFlowMode(String)
    case createDeskTask(title: String, objective: String)
    case deskCommand(DeskCommandRequest)
    case addDeskNote(handle: String, text: String)
    case research(query: String)
    case exportMake(MakeExportRequest)
    case senseViewEvent(presentation: String, revision: String, event: PartFace.Value)
    case sendContactMessage(ContactSendRequest)
    case stopContactMessage(contact: String, record: String)
    case resendContactMessage(contact: String, item: String, session: String)
    case withdrawContactMessage(item: String, record: String)
    case ingestAttachment(AttachmentTransfer)
    case captureScreen(ScreenCaptureRequest)
    case openBrowser
    case voice(VoiceAct)
    case handBackMacControl(expectedGeneration: UInt64)
    case reportScene(SceneReport)
    case reportProtectedWindows(ProtectedWindowsReport)
    case reportOverlayWindow(number: Int?)
    case reportInspector(RendererInspectorReport)
    case reportRendererDiagnostic(RendererDiagnostic)
    case notificationResponse(NotificationResponse)
    case quitBody
    case restartBody
}

public enum TranscriptReceipt: Codable, Sendable {
    case complete
    case viewport(blocks: Set<String>)
    case applied(script: UUID)
    case painted(script: UUID)
    case rejected(script: UUID, cause: String)
    case rebase
    case revealed(row: String)
}

public enum RetryChoice: String, Codable, Sendable { case continueFromResults, restartConfirmed }
public enum DownloadCommand: String, Codable, Sendable { case pause, resume }
public enum UpdateCommand: String, Codable, Sendable {
    case check, probe, showAvailableUpdate, setAutomaticChecksOn, setAutomaticChecksOff
}

public enum OnboardingAct: Codable, Sendable {
    case start
    case greet
    case complete(agentName: String, personaType: String, userName: String)
    case resume
    case repairProfile(agentName: String, personaType: String, userName: String)
    case reset(confirmed: Bool)
}

public enum CognitionAct: Codable, Sendable {
    case runMicrocycle
    case runReflection
    case clearTransientState
    case settleContinuity
    case resetContinuity
    case setAblation(name: String, enabled: Bool)
    case setCapsuleEnabled(Bool)
    case setBackgroundEnabled(Bool)
    case setReflectionBudget(Int)
    case setLane(name: String, enabled: Bool)
}

public enum VoiceAct: Codable, Sendable {
    case beginDictation(id: UUID, session: String, composerRevision: UInt64)
    case finishDictation(id: UUID)
    case discardDictation(id: UUID)
    case speak(id: UUID, session: String?, message: String?, text: String)
    case stopSpeech(id: UUID)
}

public enum FaceActReply: Codable, Sendable {
    case acknowledged
    case accepted(session: String, turn: String?, operation: UUID?)
    case committed(CommittedResult)
    case result(PartFace.Value)
    case artifact(ArtifactGrant)
    case makeExportChoice(MakeExportChoice)
    case provider(ProviderSettingsFace)
    case providerTest(ProviderTestReply)
    case trust(TrustSettingsFace)
    case persona(PersonaSettingsFace)
    case card(CardActionResult)
    case observation(id: UUID)
    case voice(VoiceFace)
    case operation(FaceOperationResult)
    case refused(WireFailure)
    case failed(WireFailure)
}

public enum FaceCall: Codable, Sendable {
    case showMainWindow(destination: FaceDestination?)
    case navigate(FaceNavigationRequest)
    case readScene
    case openConversation(session: String, message: String?)
    case openDetachedConversation(session: String)
    case closeDetachedConversation(session: String)
    case readDetachedConversations
    case readComposer(session: String)
    case readComposerControls(turn: String?)
    case editComposer(ComposerEditRequest)
    case clearAcceptedComposer(ComposerAcceptedEdit)
    case focusComposer(session: String)
    case openComposerCard(name: String)
    case closeComposerCard
    case showCardControl(identity: CardIdentity, presentation: CardControlPresentation)
    case closeCardControl(CardIdentity)
    case showWorkPane(tab: String, reference: String?, turn: String?)
    case hideWorkPane
    case readWorkPane
    case desk(DeskPresentationRequest)
    case prepareChatDraft(text: String)
    case showProviderSetup(provider: String, operation: UUID)
    case showGrokSetup(contact: String, operation: UUID)
    case showMacControlWorkbench
    case chooseSharedFolder(operation: UUID)
    case chooseSenseDestination(operation: UUID, suggestedName: String)
    case chooseActivityExclusion(operation: UUID)
    case runOAuthSession(OAuthPresentationRequest)
    case showPermissionGuidance(capability: String, bodyBundleURL: String)
    case closePermissionGuidance(capability: String)
    case renderPage(PageRenderRequest)
    case stepAside(driver: DriverIdentity?)
    case toggleShotgun
    case agentHandsMoved(driver: DriverIdentity?)
    case agentPointerMoved(PointerPresentation)
    case passPointerThrough(operation: UUID, x: Double, y: Double, driver: DriverIdentity?)
    case restorePointerInteraction(operation: UUID)
    case waitForKeyboard
    case readInspectorHealth
    case rearmInspectorSubscription(view: UUID, subscription: UUID?)
    case presentFailure(title: String, detail: String)
    case confirmMissingRoots(paths: [String])
    case presentUpdate(UpdatePresentationRequest)
    case openBundledReference(name: String)
    case replayTour
    case copyText(String)
    case closeRenderer
    case cancelCall(UUID)
}

public enum DeskPresentationRequest: Codable, Sendable {
    case findItem, newTask, research
    case note(handle: String)
    case reply(handle: String)
    case copy(text: String)
    case select(handle: String?)
}

public enum FaceReply: Codable, Sendable {
    case acknowledged
    case navigation(NavigationReceipt)
    case scene(SceneReport)
    case composer(ComposerSnapshot)
    case composerControls(ComposerControlsSnapshot)
    case composerEdit(ComposerEditResult)
    case detachedSessions([String])
    case workPane(WorkPaneSnapshot)
    case folder(ChosenFolder?)
    case destination(ResourceGrant?)
    case exclusion(ChosenExclusion?)
    case oauthCallback(url: String)
    case cancelled
    case rendered(PageRenderResult)
    case effect(FaceEffectReceipt)
    case inspector(RendererInspectorReport)
    case confirmed(Bool)
    case refused(WireFailure)
    case failed(WireFailure)
}

public struct CardActionResult: Codable, Sendable {
    public var identity: CardIdentity
    public var controlIdentity: CardIdentity?
    public var verified: Bool
    public var effects: FaceEffects
    public var presentationOperation: UUID?
    public var failure: WireFailure?
    public init(identity: CardIdentity, effects: FaceEffects, presentationOperation: UUID?, failure: WireFailure?,
                controlIdentity: CardIdentity? = nil, verified: Bool = false) {
        self.identity = identity; self.effects = effects
        self.controlIdentity = controlIdentity; self.verified = verified
        self.presentationOperation = presentationOperation; self.failure = failure
    }
}

public enum FaceOperationResult: Codable, Sendable {
    case started(UUID)
    case busy(operation: UUID?)
    case completed(CommittedResult)
}

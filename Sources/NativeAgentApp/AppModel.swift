import Foundation
import AppIntents
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import DeviceSync

@MainActor
@Observable
final class AppModel: Sendable {
    /// Global toast/status surface. ContentView draws it in the one NoticeLane and
    /// any code path can call appModel.systemToasts.push(...).
    let systemToasts = SystemToastCenter()
    private var iCloudAccountToastID: UUID?

    func showICloudAccountFailure(_ failure: DeviceSyncAccountFailure?) {
        guard failure != nil else {
            if let id = iCloudAccountToastID { systemToasts.dismiss(id) }
            iCloudAccountToastID = nil
            return
        }
        guard iCloudAccountToastID == nil else { return }
        let toast = SystemToast(kind: .error, text: DeviceSyncAccountFailure.macMessage, autoDismissAfter: nil)
        iCloudAccountToastID = toast.id
        systemToasts.push(toast)
    }
    /// Central poll scheduler — replaces per-view sleep-loop `.task` blocks
    /// with one coordinated tick that pauses while chat is streaming or the
    /// app is unfocused. Local-state UI uses owner invalidations instead; see
    /// `PollScheduler.swift` for the narrow retained-liveness contract.
    let pollScheduler = PollScheduler()
    private let activeChatSessionIDWriter: @MainActor (String?) -> Void
    private let backgroundLoopsManager: BackgroundLoopsManager
    private let chatSnapshotPublisher: @MainActor () -> Void
    var approvalResolverOverride: (@MainActor (String, String) async throws -> ApprovalRecord)?
    var inboxActionOverride: (@MainActor (String, String) async throws -> Void)?
    var inboxSnapshotWriterOverride: (@MainActor () async -> Void)?
    var inboxReloadGeneration = 0
    let chatSessionTransactions = MacChatSessionTransactions()

    // PATCH-2026-05-07: model-default-bump. One-time migration for a saved
    // chatModel/telegramModel this build no longer carries.
    //
    // 2026-09-13 (User): it CLEARS the stale value instead of bumping it to a
    // model chosen in code. A saved id that is gone is not a pick, and an empty
    // pick is the honest state — the surface then follows its Providers group,
    // and the page says where the choice came from. Substituting a literal here
    // put people on a model they never chose and hid the retirement.
    static func _clearRetiredModelSelection(_ key: String) {
        let retired: Set<String> = [
            "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3", "gpt-4o", "gpt-4-turbo",
            "claude-sonnet-4-5", "claude-sonnet-4-6", "claude-haiku-4-5",
            "claude-opus-4-5", "claude-opus-4-6",
        ]
        let clearedKey = "\(key).retiredPickCleared.v3"
        if UserDefaults.standard.bool(forKey: clearedKey) { return }
        let current = UserDefaults.standard.string(forKey: key) ?? ""
        if retired.contains(current) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: clearedKey)
    }

    // PATCH-2026-05-07: observable-bindings All these were UserDefaults-only
    // computed properties — `@Observable` only tracks STORED properties so
    // SwiftUI bindings never propagated and onChange never fired. Converted
    // to stored with `didSet` UserDefaults persistence so settings panels
    // (Telegram and SearXNG) actually save when toggled.
    var searxngBaseURL: String = UserDefaults.standard.string(forKey: "searxngBaseURL") ?? "" {
        didSet { UserDefaults.standard.set(searxngBaseURL, forKey: "searxngBaseURL") }
    }

    /// A credential draft belongs only in the secure field until the user
    /// explicitly saves it through `telegram/config.json`.  In particular,
    /// never mirror it into UserDefaults while the user is typing.
    var telegramToken: String = ""

    var telegramAllowedChats: String = UserDefaults.standard.string(forKey: "telegramAllowedChats") ?? "" {
        didSet { UserDefaults.standard.set(telegramAllowedChats, forKey: "telegramAllowedChats") }
    }

    var telegramAllowedUsers: String = UserDefaults.standard.string(forKey: "telegramAllowedUsers") ?? "" {
        didSet { UserDefaults.standard.set(telegramAllowedUsers, forKey: "telegramAllowedUsers") }
    }

    var telegramRequireMention: Bool = (UserDefaults.standard.object(forKey: "telegramRequireMention") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(telegramRequireMention, forKey: "telegramRequireMention") }
    }

    // PATCH-2026-05-07: chat-binding-fix These are real stored properties
    // (with UserDefaults persistence as a side-effect) so @Observable can
    // actually track changes. The earlier UserDefaults-only computed
    // pattern wasn't observed, so picker selections never propagated and
    // onChange handlers never fired.
    /// Empty means "no pick of my own": the turn resolves through the Providers
    /// group like every other surface (`resolveRequestedModel` falls through on
    /// an empty id). 2026-09-13: this used to default to a literal primary model,
    /// which is a choice made in code rather than at the picker.
    var chatModel: String = {
        AppModel._clearRetiredModelSelection("chatModel")
        return UserDefaults.standard.string(forKey: "chatModel") ?? ""
    }() {
        didSet { UserDefaults.standard.set(chatModel, forKey: "chatModel") }
    }

    var chatReasoningEffort: String = UserDefaults.standard.string(forKey: "chatReasoningEffort") ?? "high" {
        didSet { UserDefaults.standard.set(chatReasoningEffort, forKey: "chatReasoningEffort") }
    }

    var chatFastMode: Bool = UserDefaults.standard.bool(forKey: "chatFastMode") {
        didSet { UserDefaults.standard.set(chatFastMode, forKey: "chatFastMode") }
    }

    var chatFileAccess: String = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto" {
        didSet { UserDefaults.standard.set(chatFileAccess, forKey: "chatFileAccess") }
    }

    /// Empty means "no pick of my own" — see `chatModel`.
    var telegramModel: String = {
        AppModel._clearRetiredModelSelection("telegramModel")
        return UserDefaults.standard.string(forKey: "telegramModel") ?? ""
    }() {
        didSet { UserDefaults.standard.set(telegramModel, forKey: "telegramModel") }
    }

    var telegramReasoningEffort: String = UserDefaults.standard.string(forKey: "telegramReasoningEffort") ?? "high" {
        didSet { UserDefaults.standard.set(telegramReasoningEffort, forKey: "telegramReasoningEffort") }
    }

    /// The bars cache the same checked selection every other door reads.
    @MainActor
    func refreshSurfacePickerCache() async {
        let saveGeneration = chatBrainSaveGeneration
        let chatWasSaving = isSavingChatBrain
        do {
            let snapshot = try await engine.providers.routing.checkedRoutingSnapshot()
            applySurfacePickerSnapshot(snapshot, applyChat: !chatWasSaving
                && !isSavingChatBrain && saveGeneration == chatBrainSaveGeneration)
        } catch {
            if !chatWasSaving && !isSavingChatBrain && saveGeneration == chatBrainSaveGeneration {
                chatModel = ""
                chatReasoningEffort = ""
                chatFastMode = false
                chatBrainCanonicalSelection = nil
            }
            telegramModel = ""
            telegramReasoningEffort = ""
            setFailureStatus(error, action: "read the model choices")
        }
    }

    func applySurfacePickerSnapshot(_ snapshot: ProviderRoutingSnapshot, applyChat: Bool = true) {
        if applyChat, let chat = snapshot.preferences["chat"] {
            chatModel = chat.model
            chatReasoningEffort = chat.reasoningEffort
            chatFastMode = chat.serviceTier == "priority"
            chatProvider = snapshot.activeProviders["chat"] ?? ""
            chatBrainCanonicalSelection = ChatBrainSelection(
                model: chat.model, reasoningEffort: chat.reasoningEffort, fastMode: chatFastMode
            )
        }
        if let telegram = snapshot.preferences["telegram"] {
            telegramModel = telegram.model
            telegramReasoningEffort = telegram.reasoningEffort
        }
    }

    var telegramTokenConfigured = false
    /// Last checked form values, used only to preserve unsaved UI edits.
    var telegramSettingsDraftBaseline: TelegramSettingsDraftSnapshot?
    var telegramSettingsReadID: UUID?
    /// The one "needs you" count (WorkOverviewRead's Needs you): Today's header
    /// and rail dot, the Simple card and the widget read it. Nil while part of
    /// the overview could not be read.
    var ownerWaitingCount: Int?
    /// Those rows counted by kind (Desk item, note, approval, run), so
    /// Today's card can name them. Nil when the count is nil or capped.
    var ownerWaitingKinds: [WorkOverviewReference.Kind: Int]?
    var telegramEnabled = false
    var isSavingTelegram = false
    /// The Telegram settings surface owns this receipt. `statusText` remains
    /// a cross-app activity line and may be replaced by an unrelated refresh.
    var telegramSettingsSaveOutcome: TelegramSettingsSaveOutcome?
    var isTestingTelegram = false
    var isClearingTelegramLogs = false
    var telegramClearLogsOutcome: TelegramClearLogsPresentation.Outcome?
    /// A failed status refresh does not erase the last readable Telegram
    /// receipt snapshot. The settings surface must mark that snapshot stale
    /// instead of presenting it as a current read.
    var telegramStatusRefreshError: String?
    // PATCH-2026-05-11: unified-session-v1 — on first launch after this change, drop any
    // stale Mac-only session ID so the daemon resolves via the configured mobile source key instead.
    var activeChatSessionId: String = {
        if !UserDefaults.standard.bool(forKey: "NativeAgent.unifiedSession.v1") {
            UserDefaults.standard.removeObject(forKey: "activeChatSessionId")
            UserDefaults.standard.set(true, forKey: "NativeAgent.unifiedSession.v1")
        }
        return UserDefaults.standard.string(forKey: "activeChatSessionId") ?? ""
    }() {
        didSet {
            guard activeChatSessionId != oldValue else { return }
            persistActiveChatSessionID(activeChatSessionId.isEmpty ? nil : activeChatSessionId)
            MacChatUnreadSessions.shared.markRead(activeChatSessionId)
            NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: true)
        }
    }
    /// The active session's loaded transcript (`engine.transcripts`).
    var chatMessages: [ChatMessage] {
        get { engine.transcripts.messages(for: activeChatSessionId) }
        set { engine.transcripts.setMessages(newValue, for: activeChatSessionId) }
    }
    // M12 (2026-07-09): `refreshForSidebarItem` is a wall of
    // `try? await api.getX() ?? existingValue`. When the backend is dead every
    // one of those falls back to the previous value and the panel renders
    // last-week's data as if it were fetched a moment ago. Record which
    // endpoints came back nil so the UI can say so instead of lying.
    typealias PanelRefreshStatus = EngineRuntime.PanelRefreshStatus

    enum CompactReadPresentationState: Equatable, Sendable {
        case loading, unavailable, stale, empty, content
    }

    static func compactReadPresentationState(
        hasContent: Bool,
        status: PanelRefreshStatus?
    ) -> CompactReadPresentationState {
        if status?.isStale == true { return hasContent ? .stale : .unavailable }
        if status == nil { return .loading }
        return hasContent ? .content : .empty
    }

    /// Last refresh outcome per sidebar panel. Written only by
    /// `refreshForSidebarItem`; read by views via `panelStaleNotice(for:)`.
    var panelRefreshStatus: [SidebarItem: PanelRefreshStatus] = [:]
    /// Pending scoped reads, counted so overlapping readers keep their signal.
    var panelRefreshCounts: [SidebarItem: Int] = [:]
    /// Small always-visible readers have lifecycles independent of the full
    /// Chat/Activity panels. Keep their freshness separate so one successful
    /// badge poll cannot erase a stale full-panel warning (or vice versa).
    var sidebarActivityRefreshStatus: PanelRefreshStatus?
    var detachedChatRefreshStatus: [String: PanelRefreshStatus] = [:]

    /// Set by `performLoadChatState` when the chat message/session fetch threw.
    /// Folded into the `.chat` panel's failed-endpoint list.
    var chatStateLoadFailed = false
    /// The event-driven session-index read failed, so shared Mac projections
    /// are retaining their last proven rows until the next canonical edge.
    var chatSessionIndexRefreshFailed = false

    /// Session rows may be retained after either the active chat-state load or
    /// the independent session-index refresh fails. Keep the visual projection
    /// beside those two authoritative flags so a successful full load can
    /// clear the same condition that the mounted sidebar reads.
    var chatSidebarSessionListOpacity: Double {
        chatStateLoadFailed || chatSessionIndexRefreshFailed ? 0.55 : 1
    }

    /// Called only after the full chat-state path has obtained the selected
    /// session's messages (or deliberately preserved an in-flight turn). A
    /// session-index-only refresh must not call this: it cannot prove that the
    /// active transcript is current.
    func markChatSidebarLoadSucceeded() {
        chatStateLoadFailed = false
        chatSessionIndexRefreshFailed = false
    }

    var compiledPersonality: CompiledPersonality?
    var privacyMap: PrivacyMap?
    var supportDiagnostics: SupportDiagnostics?
    /// Support Snapshot has its own bounded read pass. Keep its progress
    /// separate from Doctor so its button can be honest about a snapshot that
    /// is loading, unavailable, or failed.
    var supportDiagnosticsLoading = false
    var capabilityCatalogSourceSaveInFlight = false
    var activityEvents: [ActivityEvent] = []
    var runs: [RunRecord] = []
    /// App integration tests use the same native files behind a temporary
    /// root; production leaves this nil and resolves the ordinary data root.
    var dataRootOverride: URL?
    /// The engine for this model's root: the live one, or a body-less one
    /// over an override. The memory pages observe `engine.memory`.
    @ObservationIgnored let engine: NativeAgentEngine
    @ObservationIgnored var widgetContainerUnavailableLogged = false
    /// One overview read at a time; edges during a read ask for one more.
    @ObservationIgnored var workStatusInFlight = false
    @ObservationIgnored var workStatusDirty = false
    var personality: PersonalityProfile? {
        didSet {
            if oldValue?.name != personality?.name {
                NativeAgentShortcuts.updateAppShortcutParameters()
            }
        }
    }
    private var cachedAgentDisplayName = UserDefaults.standard.string(forKey: "cachedAgentDisplayName")

    /// Memory hygiene learns the name she goes by, so a fact "about Agent" is
    /// kept out of the user's profile whatever the persona is called. Called
    /// wherever the profile is assigned; a `didSet` on an @Observable stored
    /// property took the chat room down (2026-09-02), so it is explicit.
    func teachMemoryHygieneName() {
        if let personality {
            cachedAgentDisplayName = personality.name
            UserDefaults.standard.set(personality.name, forKey: "cachedAgentDisplayName")
        }
        let name = personality?.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !name.isEmpty { AdaptiveCandidateHygiene.insertAssistantName(name) }
        // Every sentence about the agent, wherever it is built, speaks in
        // the persona's name and the chosen pronoun.
        AgentVoice.live = AgentVoice.current(name: agentDisplayName)
    }
    var personalityDocs: [PersonalityDoc] = []
    var skills: [SkillRecord] = []
    /// Toolbar-specific single-flight state. Navigation may still perform its
    /// own scoped load, but repeated user taps cannot launch concurrent Tools
    /// refreshes that race to overwrite the visible receipt.
    var isRefreshingTools = false
    var toolsRefreshState: ToolsRefreshPresentation.State = .idle
    var routePlan: IntentRoutePlan?
    var routePresentation: IntentRoutePresentation = .idle
    var workflows: [WorkflowRecord] = []
    /// Shared by every mounted approval surface. This is UI coordination only;
    /// the ApprovalInbox actor remains the durable terminal-decision authority.
    var approvalResolutionInFlightIDs: Set<String> = []
    /// Retains the one resolver task so direct callers (chat cards included)
    /// join an active decision instead of re-entering NativeClient's executor.
    var approvalResolutionTasks: [String: Task<ApprovalRecord, Error>] = [:]
    /// The decision each in-flight resolution is carrying. 2026-09-06: joining
    /// by id alone handed the FIRST decision's result back to a second caller
    /// who asked for the opposite one, so a Deny pressed over a running Approve
    /// silently reported "approved".
    var approvalResolutionDecisions: [String: String] = [:]
    var mcpServers: [MCPServerRecord] = []
    var mcpConsent: [MCPConsentRecord] = []
    var mcpTools: [MCPToolRecord] = []
    var mcpToolReadState: MCPHubToolReadState = .notLoaded
    var mcpResources: [MCPResourceRecord] = []
    var mcpResourceReadState: MCPHubResourceReadState = .notLoaded
    var latestMCPCall: MCPCallResult?
    var mcpRecentCallState: MCPHubRecentCallState = .notLoaded
    var selectedMCPServerId: String?
    var traces: [RuntimeTrace] = []
    var capabilityTraceTimeline: CapabilityTraceFeed.State = .sourceAbsent
    var agentGraph: AgentGraph?
    var graphEntities: [GraphEntity] = []
    var graphStatus: GraphIndexStatus?
    /// Nil means no failed graph read has been observed. The Capability graph
    /// panel keeps this separate from a legitimately empty, checked graph.
    var graphLoadError: String?
    var graphSearchResults: [GraphSearchResult] = []
    var autonomyKernel: AutonomyKernelSummary?
    var personalOS: PersonalOSSummary?
    var capabilityCatalog: [CapabilityCatalogItem] = []
    var capabilityCatalogSources: [CapabilityCatalogSource] = []
    var capabilityPackInstalls: [CapabilityPackInstall] = []
    var capabilityCatalogInstallOutcome: CapabilityCatalogInstallOutcome?
    /// The signed demo action performs a multi-store durable install. Keep the
    /// mounted control single-flight so a second click cannot race the
    /// signature gate or make two receipts look like one successful install.
    var isInstallingDemoCapabilityPack = false
    var latestCapabilityTrustEvaluation: CapabilityTrustEvaluation?
    var latestCapabilityUpdateCheck: CapabilityUpdateCheck?
    var nextGenSummary: NextGenSummary?
    var nextGenPhases: [NextGenPhase] = []
    var nextGenReceipts: [NextGenReceipt] = []
    var latestNextGenReceipt: NextGenReceipt?
    var isRunningNextGenAction = false
    var personalityGrowth: PersonalityGrowthSummary?
    var nativeActions: [NativeActionRecord] = []
    var nativeActionReceipts: [NativeActionReceipt] = []
    var notificationStatus: NotificationRuntimeStatus?
    var browserRuntimeStatus: BrowserRuntimeStatus?
    var memoryVectorStatus: MemoryVectorStatus?
    var memoryV2Status: MemoryV2Status?
    var latestMemoryHygiene: MemoryHygieneReport?
    /// F2: when a memory feature throws/returns a `not_implemented` /
    /// `panelDisabled` envelope, the UI surfaces this badge instead of a
    /// success toast or red error. Cleared on the next successful run.
    var memoryFeatureDisabledMessage: String?
    /// W3 (eval5): generalised version of `memoryFeatureDisabledMessage` for
    /// non-memory panels (workflow run, eval run, capability pack install,
    /// MCP warm/refresh, etc.). When a Swift-native implementation is
    /// deliberately unavailable, the underlying call throws
    /// `NativeClient.notImplemented(...)` with a
    /// `panelDisabled` userInfo flag; AppModel converts that into this
    /// human-readable message so the UI can render a small orange badge
    /// instead of a fake success toast or a red error. Cleared by the next
    /// successful action on the affected panel.
    var disabledFeature: String?
    var connectorActionRegistry: ConnectorActionRegistry?
    var latestConnectorActionReceipt: ConnectorActionReceipt?
    var improvementGauntletStatus: ImprovementGauntletStatus?
    var latestBrowserRun: BrowserRun?
    var latestGauntletRun: ImprovementGauntletRun?
    var productionHardening: ProductionHardeningSummary?
    var productionExports: [ProductionExport] = []
    /// The last action initiated on the Trust surface. Unlike `statusText`, it
    /// cannot be overwritten by refreshes or work from another surface.
    var trustCenterActionOutcome: TrustCenterActionOutcome?
    var policySimulation: PolicySimulation?
    /// A transport/read failure is distinct from SecurityCenter's fail-closed
    /// unavailable-policy envelope. Keeping it separate prevents an old
    /// successful verdict from remaining visible after a later failed run.
    var policySimulationFailure: String?
    var connectors: [ConnectorRecord] = []
    var workspaces: [WorkspaceRecord] = []
    var workspaceSearchResults: [WorkspaceSearchResult] = []
    var evals: [EvalRun] = []
    var releaseChecklist: ReleaseChecklist?
    var trainingArtifacts: [TrainingArtifact] = []
    var improvements: [ImprovementRun] = []
    var improvementSummary: ImprovementSummary?
    var isSavingChatBrain = false
    /// One captured chat-brain tuple. Picker fields are optimistic UI caches;
    /// this value is updated only from a checked canonical read or a successful
    /// configure response. It lets a failed optimistic edit roll back without
    /// firing a second write for the rollback itself.
    struct ChatBrainSelection: Equatable, Sendable {
        var model: String
        var reasoningEffort: String
        var fastMode: Bool
    }

    enum ChatBrainSaveResult: Equatable, Sendable {
        case unchanged(ChatBrainSelection)
        case saved(ChatBrainSelection)
        case failed(message: String, rolledBackTo: ChatBrainSelection?, cause: String? = nil)

        var userMessage: String {
            switch self {
            case .unchanged(let selection), .saved(let selection):
                return "Chat brain saved: \(selection.model) / \(selection.reasoningEffort)\(selection.fastMode ? " / Fast" : "")"
            case .failed(let message, _, _):
                return "Couldn't save the model choice. \(message)"
            }
        }

        /// What the agent's tool result says: the same line plus the raw cause.
        var agentMessage: String {
            if case .failed(_, _, let cause) = self { return UserFacingError.forAgent(userMessage, cause: cause) }
            return userMessage
        }
    }

    struct ChatBrainWriteReceipt {
        var selection: ChatBrainSelection
        var catalog: ModelCatalogResponse?
    }

    @ObservationIgnored var chatBrainCanonicalSelection: ChatBrainSelection?
    @ObservationIgnored var chatBrainPendingSave: (generation: UInt64, selection: ChatBrainSelection)?
    @ObservationIgnored var chatBrainSaveGeneration: UInt64 = 0
    @ObservationIgnored var chatBrainLastSaveResult: (generation: UInt64, result: ChatBrainSaveResult)?
    @ObservationIgnored var chatBrainSaveTask: Task<Void, Never>?
    /// Hermetic seams for concurrency/failure tests. Production leaves both nil.
    @ObservationIgnored var chatBrainWriteOverride: (@MainActor @Sendable (ChatBrainSelection) async throws -> ChatBrainWriteReceipt)?
    @ObservationIgnored var chatBrainReadOverride: (@MainActor @Sendable () async throws -> ChatBrainSelection)?
    // PATCH-2026-05-07: chat-provider-picker Cache the active chat provider
    // so the chat screen can render a Provider→Model dual picker without
    // re-fetching every render (the list is `engine.providers.connections`).
    // PATCH-2026-05-07: chat-binding-fix Stored property (not computed)
    // so @Observable actually tracks changes. UserDefaults persistence is
    // a side effect of didSet.
    var chatProvider: String = UserDefaults.standard.string(forKey: "chatProvider") ?? "openai_oauth_direct" {
        didSet { UserDefaults.standard.set(chatProvider, forKey: "chatProvider") }
    }
    var statusText: String = "Not checked" {
        didSet { statusCause = nil }
    }
    /// The raw error behind a failure `statusText` names in plain words. User's
    /// screen shows `statusText` only; the agent's tool results read
    /// `statusForAgent`, which keeps the cause she needs to act on.
    var statusCause: String?
    var statusForAgent: String {
        UserFacingError.forAgent(statusText, cause: statusCause)
    }

    /// A failure on the status line: the plain line for User, the raw cause
    /// kept for the agent.
    func setFailureStatus(_ error: Error, action: String) {
        setFailureStatus(UserFacingError.message(error, action: action), cause: error)
    }

    func setFailureStatus(_ line: String, cause error: Error) {
        statusText = line
        statusCause = error.localizedDescription
    }
    /// The Desk item a notification click asked for, waiting for the Desk page
    /// to be able to show it. A click names the handle before the page is
    /// mounted or its rows are read, so the handle is stored rather than
    /// broadcast: DeskPageView takes it once its load has landed and clears it,
    /// so the click always opens the item instead of firing into no subscriber.
    var pendingDeskHandle: String?
    /// True while the Desk page is on screen. ⌘K there opens the one palette
    /// with the Desk's rows and verbs, so ContentView leaves the press to it.
    var deskHoldsCommandPalette = false
    /// Bounded, non-transient receipts for mutations initiated from Tools.
    /// Unlike `statusText`, repeated identical failures remain distinct rows.
    var toolOperationStatusReceipts: [ToolOperationStatusReceipt] = []
    // FIX: last decode/network failure seen during refreshAll, so swallowed
    // section failures are observable instead of silently blanking the UI.
    var lastRefreshError: String? = nil
    @ObservationIgnored let firstRunWelcomeTransaction = FirstRunWelcomeTransaction()
    /// Backing cache for `firstConversationReceiptTitle`. The recorded title
    /// never changes once the first conversation has armed its write token, so
    /// a positive answer is cached for the process; a negative one is re-read,
    /// because arming can happen mid-launch.
    @ObservationIgnored var firstConversationReceiptTitleCache: String?
    /// Hermetic first-run-greeting seams. Production uses the public-release
    /// bundle check, fresh provider read, and real chat-turn handoff below;
    /// isolated behavior evals exercise that same durable marker owner without
    /// touching a user's provider or transcript.
    @ObservationIgnored var firstRunGreetingPublicReleaseOverride: Bool?
    @ObservationIgnored var firstRunGreetingProviderReadyOverride: (@MainActor @Sendable () async -> Bool)?
    @ObservationIgnored var firstRunGreetingSendOverride: (@MainActor @Sendable (String, String, Bool) async -> ChatTurnAcceptance)?
    /// Completion receipt for the mounted onboarding wizard. The route records
    /// a deferred or rejected first greeting instead of silently dismissing
    /// into Chat as though the kickoff had happened.
    var onboardingWizardCompletionReceipt: OnboardingWizardCompletionReceipt?
    var chatTurnTranscriptProofReader: any MacChatTurnTranscriptProofReading {
        get { engine.turns.runtime.chatTurnTranscriptProofReader }
        set { engine.turns.runtime.chatTurnTranscriptProofReader = newValue }
    }
    var chatTurnLifecycleRepairCompleted: Bool {
        get { engine.turns.runtime.chatTurnLifecycleRepairCompleted }
        set { engine.turns.runtime.chatTurnLifecycleRepairCompleted = newValue }
    }
    /// User, 2026-09-06: a profile repair that landed while a turn was running.
    /// The resident refresh stops and restarts Context Flow and reloads
    /// cognition, so it waits for the last active turn to close rather than
    /// pulling the ground out from under a turn in flight.
    @ObservationIgnored var residentRefreshPendingAfterActiveTurns = false
    /// Hermetic queue-drain seam. Production leaves this nil and starts the
    /// real chat turn; tests can prove FIFO/promotion without touching a
    /// provider, transcript, or the user's runtime root.
    var queuedChatTurnStartOverride: (@MainActor @Sendable (QueuedChatTurn, String) async -> ChatTurnAcceptance)? {
        get { engine.turns.runtime.queuedChatTurnStartOverride }
        set { engine.turns.runtime.queuedChatTurnStartOverride = newValue }
    }
    var chatSelectionGeneration = 0

    /// Clear the per-session streaming-bubble state for `sessionId` BEFORE
    /// stashing a pending error on an inactive-session error path. Without
    /// this, selectChatSession's reinjection (gated on streamingSessions +
    /// these dicts) re-adds the empty optimistic assistant bubble during the
    /// post-stash awaits, the drain sees `last.role == "assistant"`, and
    /// silently suppresses the error.
    var chatPersona: String = {
        let saved = PersonaSelection.current()
        return NativeChatTurnOptions.normalizedPickerPersona(saved)
    }() {
        didSet {
            let normalized = NativeChatTurnOptions.normalizedPickerPersona(chatPersona)
            if normalized != chatPersona {
                chatPersona = normalized
                return
            }
            PersonaSelection.select(normalized)
            Task {
                await NativeAgentEngine.live.contextFlow.personaPickerDidChange()
            }
        }
    }
    var agentDisplayName: String {
        let profileName = (personality?.name ?? cachedAgentDisplayName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profileName.isEmpty { return profileName }
        return canonicalAgentDisplayName(chatPersona)
    }

    /// The agent's name for the surfaces that ADDRESS it — the window title and
    /// the composer placeholder.
    ///
    /// Unlike `agentDisplayName`, this folds the generic onboarding seed to the
    /// house fallback. Since 2026-09-15 a fresh install seeds `profile.name`
    /// with "agent" and the agent asks for its own name in the first
    /// conversation, so the window has to read "The agent" until it is named —
    /// not leak the seed label, and not invent a name nobody chose.
    /// `agentDisplayName` is left alone because its callers want the raw
    /// profile name.
    var agentAddressName: String {
        canonicalAgentDisplayName(personality?.name ?? cachedAgentDisplayName ?? chatPersona, fallback: "The agent")
    }
    // PATCH-2026-05-06: skill-ui AppModel state — skill lifecycle registry
    var skillManifests: [SkillInfo] = []
    var isLoadingSkillManifests = false
    var skillManifestError: String?
    /// Event-identified feedback for the mounted Skill Lifecycle banner/toast.
    var skillLifecycleFeedback: SkillLifecycleFeedback?

    // PATCH-2026-05-07: self-improvement-ui Beyond B.1/B.3 state
    var trainingRuns: [TrainingRunSummary] = []
    // F13: both feed `pendingSelfImprovementCount` → `pendingActivityCount`.
    var trainingProposals: [TrainingProposalSummary] = [] {
        didSet { recomputePendingActivityCount() }
    }
    var promotionCandidates: [PromotionCandidateSummary] = [] {
        didSet { recomputePendingActivityCount() }
    }
    var promotionPending: [PromotionCandidateSummary] = []
    var selfImprovementError: String?
    // PATCH-2026-05-29: dreams-tab error surface for the Dreams tab (kept separate
    // from selfImprovementError so a dream/REM failure doesn't bleed into the
    // Self-Improvement view's banner).
    var dreamError: String?
    var pendingMemoryProposalsCount: Int {
        engine.memory.proposals.filter { $0.status == "pending" }.count
    }

    // PATCH-2026-05-08: wave3 Feature A/B state
    @ObservationIgnored var healthCardRefreshGate = LatestSnapshotRefreshGate()

    @MainActor
    var chatDrafts: [String: String] = [:]
    var chatPendingAttachments: [String: [MultimodalAttachment]] = [:]
    // S.1: LRU tracking so we can cap chatDrafts at 50 entries
    var chatDraftLastTouched: [String: Date] = [:]
    /// 2026-09-06: when the text currently stored for a session was last
    /// TYPED, as opposed to when it was written through. `flushLiveChatDrafts`
    /// asks every live composer to commit inside one notification and observer
    /// order is arbitrary, so without this an older detached-panel edit could
    /// land on top of newer main-window typing. Nothing renders from it.
    @ObservationIgnored var chatDraftLastEdited: [String: Date] = [:]

    // H5 (2026-07-09): the composer no longer writes `chatDrafts` on every
    // keystroke — it keeps the in-progress text in view-local @State and
    // commits to `chatDrafts` only on send / session-switch / disappear.
    // Prefills that originate OUTSIDE the composer (skill-build starter,
    // suggestion chip, slash-command completion) bump this counter so the
    // composer can pull the new text without observing `chatDrafts` on the
    // keystroke path. See `injectChatDraft(_:sessionId:)`.
    private(set) var chatDraftInjectionGeneration: Int = 0

    /// Internal setter for the injection counter. `injectChatDraft` is the
    /// only intended caller.
    func bumpChatDraftInjectionGeneration() {
        chatDraftInjectionGeneration &+= 1
    }

    var pendingApprovalsCount: Int {
        engine.approvals.records.filter { $0.status.lowercased() == "pending" }.count
    }

    /// W6/G12: the badge counts the "For you" lane ONLY.
    ///
    /// The badge is an interrupt — it is the app claiming something needs User.
    /// System-health notices (background_loop, disk_hygiene, heartbeat, the
    /// self-referential proactive kinds) are readable in the System lane and
    /// still surfaced by Doctor; none of them should light up a count that
    /// means "you are needed". Lane membership is defined once on
    /// `InboxItemRecord` (`InboxView.swift`) and read here and by the list.
    var pendingInboxCount: Int {
        engine.inbox.items.filter { $0.isActivityPending && $0.isForYouLane }.count
    }

    var pendingTrainingProposalCount: Int {
        trainingProposals.filter(AppModel.isHumanActionableTrainingProposal).count
    }

    var pendingPromotionCandidateCount: Int {
        promotionCandidates.filter(AppModel.isHumanActionablePromotionCandidate).count
    }

    var pendingSelfImprovementCount: Int {
        pendingTrainingProposalCount + pendingPromotionCandidateCount
    }

    /// Render-cost audit F13 — the root `ContentView` observes ONE scalar.
    ///
    /// This used to be a computed property fanning out to five stored
    /// collections (`engine.approvals.records`, `engine.inbox.items`, `engine.memory.proposals`,
    /// `trainingProposals`, `promotionCandidates`). Reading it inside
    /// `ContentView.body` (`ContentView.swift:372`, the sidebar badge)
    /// registered an Observation dependency on all five, so ANY write to ANY
    /// of them re-ran the root body — which contains the whole
    /// `NavigationSplitView` and the inline `switch` that constructs the detail
    /// view, `case .chat: ChatView()` included.
    ///
    /// **Staleness invariant.** The scalar is not maintained by the badge
    /// refresh (that would go stale the moment any other path mutated a
    /// collection — approve an approval, mark an inbox item read, `refreshAll`
    /// landing new proposals). It is maintained by a `didSet` on each of the
    /// five backing collections, so it is recomputed by *every* write to *any*
    /// of them regardless of which code path performed it. Adding a sixth
    /// source to the sum without adding its `didSet` is the one way to break
    /// this; `SidebarBadgeScalarTests` pins each of the five and asserts the
    /// scalar equals the recomputed sum.
    private(set) var pendingActivityCount: Int = 0

    /// The authoritative sum. Kept as a separate computed property so tests
    /// (and the `didSet` invariant) have one place to compare against.
    var computedPendingActivityCount: Int {
        pendingApprovalsCount + pendingInboxCount + pendingMemoryProposalsCount + pendingSelfImprovementCount
    }

    /// Re-derive the badge scalar. Equality-gated so an unchanged badge after a
    /// changed collection still performs zero observable writes on the root.
    func recomputePendingActivityCount() {
        let next = computedPendingActivityCount
        if pendingActivityCount != next { pendingActivityCount = next }
    }

    /// PATCH-2026-06-06: activity-flatten — when Cmd+Shift+A / Cmd+Shift+I
    /// fires from another page, Today is not yet mounted and its
    /// `.onReceive(.openActivitySectionRequest)` cannot observe the
    /// notification. ContentView stashes the target section here before
    /// switching pages; Today consumes + clears it on appear. The
    /// notification path still works when Today is already in front.
    var pendingActivitySectionRaw: String? = nil

    static func isHumanActionableTrainingProposal(_ proposal: TrainingProposalSummary) -> Bool {
        let proposed = proposal.proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let rationale = proposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return proposal.status.lowercased() == "pending"
            && !proposed.isEmpty
            && !rationale.contains("proposal generation failed")
    }

    static func isHumanActionablePromotionCandidate(_ candidate: PromotionCandidateSummary) -> Bool {
        (candidate.decision ?? "").uppercased() == "STAGE_FOR_HUMAN"
            && candidate.source.lowercased() != "self_test"
    }

    /// Production starts its refresh work immediately. Tests and isolated
    /// presentation hosts can opt out so mounting a chat control never reads
    /// the user's live root behind its injected data root.
    init(
        dataRootOverride: URL? = nil,
        startBackgroundTasks: Bool = true,
        backgroundLoopsManager: BackgroundLoopsManager = .shared,
        activeChatSessionIDWriter: @escaping @MainActor (String?) -> Void = { id in
            if let id { UserDefaults.standard.set(id, forKey: "activeChatSessionId") }
            else { UserDefaults.standard.removeObject(forKey: "activeChatSessionId") }
        },
        chatSnapshotPublisher: @escaping @MainActor () -> Void = {
            NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
        }
    ) {
        // Earlier builds mirrored the secure-field draft into UserDefaults.
        // The canonical Telegram config is the sole durable credential owner;
        // discard that legacy plaintext draft on the first current launch.
        UserDefaults.standard.removeObject(forKey: "telegramToken")
        self.dataRootOverride = dataRootOverride
        self.engine = dataRootOverride.map { NativeAgentEngine(dataRoot: $0, ports: .app(dataRoot: $0), hasBody: false) } ?? .live
        self.backgroundLoopsManager = backgroundLoopsManager
        self.activeChatSessionIDWriter = activeChatSessionIDWriter
        self.chatSnapshotPublisher = chatSnapshotPublisher
        // Render-cost audit F13: these hooks keep `pendingActivityCount`
        // derived from EVERY mutation path, not just the badge refresh — see
        // the invariant note on `recomputePendingActivityCount()`.
        engine.approvals.recordsDidChange = { [weak self] in
            self?.recomputePendingActivityCount()
            Task { [weak self] in await self?.publishWorkStatus() }
        }
        engine.inbox.itemsDidChange = { [weak self] in
            self?.recomputePendingActivityCount()
            Task { [weak self] in await self?.publishWorkStatus() }
        }
        engine.turns.activityDidChange = { [weak self] in
            Task { [weak self] in await self?.publishWorkStatus() }
        }
        // Every policy read or write re-syncs the chat's access mode.
        engine.trust.policyDidChange = { [weak self] in
            guard let self, let policy = engine.trust.policy else { return }
            let syncedMode = Self.agentAccessMode(from: policy, fallback: chatFileAccess)
            if chatFileAccess != syncedMode {
                chatFileAccess = syncedMode
            }
        }
        engine.memory.proposalsDidChange = { [weak self] in
            guard let self else { return }
            recomputePendingActivityCount()
            MemoryReviewReminder.consider(pending: pendingMemoryProposalsCount, agentName: agentDisplayName)
        }
        guard startBackgroundTasks else { return }
        Task { @MainActor in await self.refreshSurfacePickerCache() }
        // Every Desk write in this process re-reads the overview, so a new
        // owner wait counts and pushes whether or not phone sync is on.
        Task { [weak self] in
            for await change in StoreChangeBus.shared.changes() where change.store == .desk {
                guard let self else { return }
                await publishWorkStatus()
            }
        }
        pollScheduler.bind(to: self)
    }

    var client: NativeClient {
        NativeClient(
            dataRootOverride: dataRootOverride,
            backgroundLoopsManager: backgroundLoopsManager
        )
    }

    func persistActiveChatSessionID(_ id: String?) {
        activeChatSessionIDWriter(id)
    }

    func publishChatSnapshot() {
        chatSnapshotPublisher()
    }

    var selectedMCPServer: MCPServerRecord? {
        if let selectedMCPServerId,
           let server = mcpServers.first(where: { $0.id == selectedMCPServerId }) {
            return server
        }
        return mcpServers.first
    }

    var refreshAllInFlight = false
    var refreshAllQueued = false
    // One refresh pass can lose several independent authority reads. Keep the
    // complete bounded set until the next pass so the status surface does not
    // turn a multi-lane outage into whichever error happened to finish last.
    var refreshAllFailureDetails: [String] = []
    var isRecordingRefreshAllFailures = false
    var chatStateLoadInFlight = false
    var chatStateLoadWaiters: [CheckedContinuation<Void, Never>] = []

    // FIX: refreshAll previously wrapped ~70 daemon calls in bare `try?`, so any
    // decode/network throw silently blanked that section with no log and no way
    // to tell "daemon empty" from "decode failed" — a bug class that already
    // shipped once. These helpers run the fetch and, on throw, LOG the error
    // (with the endpoint label) before returning the fallback, so failures stop
    // being invisible. Also records the last refresh error into statusText.
    @MainActor
    func decodeLogged<T>(_ label: String, _ fetch: () async throws -> T) async -> T? {
        do {
            return try await fetch()
        } catch {
            recordRefreshFailure(label, error: error)
            return nil
        }
    }

    @MainActor
    func decodeLogged<T>(_ label: String, default fallback: [T], _ fetch: () async throws -> [T]) async -> [T] {
        do {
            return try await fetch()
        } catch {
            recordRefreshFailure(label, error: error)
            return fallback
        }
    }

    /// Refresh-only collection/value reader. A thrown read is distinct from a
    /// successful empty response: preserve the last confirmed projection in
    /// the former case, while assigning `[]`/`nil` when the authoritative
    /// reader genuinely returned it.
    @MainActor
    func refreshPreserving<T>(
        _ label: String,
        current: T,
        _ fetch: () async throws -> T
    ) async -> T {
        do {
            return try await fetch()
        } catch {
            recordRefreshFailure(label, error: error)
            return current
        }
    }

    @MainActor
    private func recordRefreshFailure(_ label: String, error: Error) {
        let detail = "\(label): \(error.localizedDescription)"
        print("[NativeAgent] refreshAll/\(detail)")
        guard isRecordingRefreshAllFailures else {
            lastRefreshError = detail
            return
        }
        if !refreshAllFailureDetails.contains(detail) {
            refreshAllFailureDetails.append(detail)
        }
        lastRefreshError = refreshAllFailureDetails.joined(separator: "\n")
    }
}

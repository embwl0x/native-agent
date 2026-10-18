import EngineRuntime
import Foundation
import AttentionRouting
import ApprovalTransactions
import Privacy
import WidgetKit
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
import SchedulerExecution
import TrustPersistence

@MainActor
extension AppModel: FirstRunWelcomePort {
    var firstRunDataRoot: URL { dataRootOverride ?? PersistenceCore.defaultDataRoot() }
    var firstRunIsPublicRelease: Bool { InstallPaths.isPublicReleaseBundle }
    var firstRunSessionIsBusy: Bool { engine.turns.busySessions.contains(activeChatSessionId) }
    var firstRunSyntheticErrorIDPrefix: String { Self.syntheticErrorIDPrefix }

    func firstRunMessages(for sessionID: String) -> [ChatMessage] {
        engine.transcripts.messages(for: sessionID)
    }

    func markFirstRunWelcomePending() {
        firstRunWelcomeTransaction.markFirstRunWelcomePending(port: self)
    }

    @discardableResult
    func maybeSendFirstRunGreeting() async -> FirstRunGreetingOutcome {
        let outcome = await firstRunWelcomeTransaction.maybeSendFirstRunGreeting(port: self)
        // `.delivered` means the greeting turn has finished, whichever trigger
        // started it — only now may macOS post its "Login Item Added" banner.
        if case .delivered = outcome { AppDelegate.registerLoginItemInBackground() }
        return outcome
    }

    /// The exact section title the first conversation's write used, or nil when
    /// this persona has no first conversation on record.
    ///
    /// The settled receipt is restricted to writes matching this (Sol P2-10),
    /// so it is read here rather than in a view body: once it answers, it is
    /// answered for the process.
    var firstConversationReceiptTitle: String? {
        engine.transcripts.firstConversationReceiptTitle
    }

    /// The person's own name, as the persona documents know it — the only
    /// source for the exact section title the write must use.
    var firstConversationPersonName: String {
        engine.transcripts.firstConversationPersonName
    }

    /// Production requires a fresh successful provider read. An old cached
    /// ready row is not authority to create a first-run turn after a failed
    /// refresh.
    func firstRunGreetingHasReadyProvider() async -> Bool {
        if let firstRunGreetingProviderReadyOverride {
            return await firstRunGreetingProviderReadyOverride()
        }
        let providersFresh = await loadProvidersForChat()
        return providersFresh && engine.providers.hasReadyConnection
    }

    /// The injected handoff remains behind every real first-run gate and claim;
    /// production always reaches the normal `sendChat` turn owner.
    func sendFirstRunGreeting(
        _ kickoff: String,
        sessionID: String
    ) async -> ChatTurnAcceptance {
        if let firstRunGreetingSendOverride {
            return await firstRunGreetingSendOverride(kickoff, sessionID, true)
        }
        return await sendChat(kickoff, sessionId: sessionID, hideUserBubble: true, requireIdleAndEmpty: true)
    }

}

@MainActor
extension AppModel {
    /// Preserve the last committed endpoint when refreshed configuration is invalid.
    func applyRefreshedSearXNGBaseURL(_ value: String?) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            searxngBaseURL = try SwiftNativeResearchClient.normalizedSearXNGBaseURL(value)
        } catch {
            statusText = "SearXNG configuration unavailable: \(error.localizedDescription)"
        }
    }
}

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
    let backgroundLoopsManager: BackgroundLoopsManager
    private let chatSnapshotPublisher: @MainActor () -> Void
    var inboxActionOverride: (@MainActor (String, String) async throws -> Void)?
    var inboxSnapshotWriterOverride: (@MainActor () async -> Void)?
    var inboxReloadGeneration = 0


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
        ProvidersFacade.clearRetiredModelSelection("chatModel")
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
        ProvidersFacade.clearRetiredModelSelection("telegramModel")
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
        let saveGeneration = engine.providers.chatBrainSaveGeneration
        let chatWasSaving = isSavingChatBrain
        do {
            let snapshot = try await engine.providers.routing.checkedRoutingSnapshot()
            applySurfacePickerSnapshot(snapshot, applyChat: !chatWasSaving
                && !isSavingChatBrain && saveGeneration == engine.providers.chatBrainSaveGeneration)
        } catch {
            if !chatWasSaving && !isSavingChatBrain && saveGeneration == engine.providers.chatBrainSaveGeneration {
                chatModel = ""
                chatReasoningEffort = ""
                chatFastMode = false
                engine.providers.chatBrainCanonicalSelection = nil
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
            engine.providers.chatBrainCanonicalSelection = ProvidersFacade.ChatBrainSelection(
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
    // `try? await <read>() ?? existingValue`. When the backend is dead every
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

    var compiledPersonality: CompiledPersonalityWire?
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
    @ObservationIgnored private let workStatusPublication = WorkStatusPublication()
    /// The Mac surface keeps one immutable orchestration body resident. It
    /// owns no canonical mind state; it reuses the root's live cognition,
    /// memory, routing, TrustCenter and tool owners while preserving their
    /// per-turn reads and effect-time checks.
    @ObservationIgnored lazy var macChatClient = engine.chatClient(profile: .mac)
    var personality: PersonalityProfile? {
        didSet {
            if oldValue?.name != personality?.name {
                NativeAgentShortcuts.updateAppShortcutParameters()
            }
        }
    }

    /// Memory hygiene learns the name she goes by, so a fact "about Agent" is
    /// kept out of the user's profile whatever the persona is called. Called
    /// wherever the profile is assigned; a `didSet` on an @Observable stored
    /// property took the chat room down (2026-09-02), so it is explicit.
    func teachMemoryHygieneName() {
        engine.memory.teachAssistantName(personality)
        // Every sentence about the agent, wherever it is built, speaks in
        // the persona's name and the chosen pronoun.
        AgentVoice.live = AgentVoice.current(name: agentDisplayName)
    }
    var personalityDocs: [PersonaDocSpec] = []
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
    var mcpServers: [MCPServer] = []
    var mcpConsent: [MCPConsentRecord] = []
    var mcpTools: [MCPTool] = []
    var mcpToolReadState: MCPHubToolReadState = .notLoaded
    var mcpResources: [MCPResource] = []
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
    /// `NativeActionRouteSupport.notImplemented(...)` with a
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
    var connectors: [ConnectorRecord] = []
    var workspaces: [WorkspaceRecord] = []
    var workspaceSearchResults: [WorkspaceSearchResult] = []
    var evals: [EvalRun] = []
    var isSavingChatBrain: Bool {
        get { engine.providers.isSavingChatBrain }
        set { engine.providers.isSavingChatBrain = newValue }
    }
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
    /// The transcript message a link asked the chat to land on (a miss's
    /// `history:` locator), held the same way until ChatView reveals it.
    var pendingChatMessageID: String?
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
    /// Hermetic first-run-greeting seams. Production uses the public-release
    /// bundle check, fresh provider read, and real chat-turn handoff below;
    /// isolated behavior evals exercise that same durable marker owner without
    /// touching a user's provider or transcript.
    @ObservationIgnored var firstRunGreetingPublicReleaseOverride: Bool?
    @ObservationIgnored var firstRunGreetingProviderReadyOverride: (@MainActor @Sendable () async -> Bool)?
    @ObservationIgnored var firstRunGreetingSendOverride: (@MainActor @Sendable (String, String, Bool) async -> ChatTurnAcceptance)?
    var chatTurnTranscriptProofReader: any MacChatTurnTranscriptProofReading {
        get { engine.turns.runtime.chatTurnTranscriptProofReader }
        set { engine.turns.runtime.chatTurnTranscriptProofReader = newValue }
    }
    var chatTurnLifecycleRepairCompleted: Bool {
        get { engine.turns.runtime.chatTurnLifecycleRepairCompleted }
        set { engine.turns.runtime.chatTurnLifecycleRepairCompleted = newValue }
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
        let profileName = (personality?.name ?? engine.memory.cachedAgentDisplayName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profileName.isEmpty { return profileName }
        return NativeAgentIdentity.displayName(chatPersona)
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
        NativeAgentIdentity.displayName(personality?.name ?? engine.memory.cachedAgentDisplayName ?? chatPersona, fallback: "The agent")
    }
    // PATCH-2026-05-06: skill-ui AppModel state — skill lifecycle registry
    var skillManifests: [SkillInfo] = []
    var isLoadingSkillManifests = false
    var skillManifestError: String?
    /// Event-identified feedback for the mounted Skill Lifecycle banner/toast.
    var skillLifecycleFeedback: SkillLifecycleFeedback?

    /// The miss ledger, this week and last: the Self-Improvement page's first section.
    var missLessons: [MemoryMissLesson] = []
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

    private(set) var pendingActivityCount: Int = 0

    /// The authoritative sum. Kept as a separate computed property so tests
    /// (and the `didSet` invariant) have one place to compare against.
    var computedPendingActivityCount: Int {
        pendingApprovalsCount + pendingInboxCount + pendingMemoryProposalsCount
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
        engine.bindResidentPresentation(
            activityCountChanged: { [weak self] in self?.recomputePendingActivityCount() },
            publishWorkStatus: { [weak self] in await self?.publishWorkStatus() },
            policyChanged: { [weak self] in
                guard let self, let policy = engine.trust.policy else { return }
                let syncedMode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: chatFileAccess)
                if chatFileAccess != syncedMode { chatFileAccess = syncedMode }
            },
            memoryProposalsChanged: { [weak self] in
                guard let self else { return }
                recomputePendingActivityCount()
                if let reminder = engine.memory.reviewReminder(pending: pendingMemoryProposalsCount, agentName: agentDisplayName) {
                    NativeAgentNotifications.post(title: reminder.title, body: reminder.body)
                }
            }
        )
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

    func persistActiveChatSessionID(_ id: String?) {
        activeChatSessionIDWriter(id)
    }

    func publishChatSnapshot() {
        chatSnapshotPublisher()
    }

    var selectedMCPServer: MCPServer? {
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

extension AppModel {
    func publishWorkStatus() async {
        await workStatusPublication.publishWorkStatus(engine: engine, displayName: { self.agentDisplayName },
            publishAttention: { waiting, kinds in
                self.setIfChanged(\.ownerWaitingCount, waiting)
                self.setIfChanged(\.ownerWaitingKinds, kinds)
            }, reloadWidget: {
                if #available(macOS 27, *) {
                    WidgetCenter.shared.reloadTimelines(ofKind: NativeAgentWidgetSnapshot.kind)
                }
            })
    }
}

extension NightlyReflectionJobOutcome {
    var message: String {
        switch self {
        case .added:
            return "Nightly reflection added."
        case .alreadyPresent:
            return "Nightly reflection is already scheduled."
        case .repaired:
            return "Nightly reflection schedule repaired."
        case .failed(let message):
            return "Nightly reflection could not be added: \(message)"
        }
    }

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// The scheduler read result belongs to the scheduler surface. Its detail is
/// carried with the read rather than recovered later from AppModel.statusText,
/// which any unrelated operation may replace before SchedulerView renders.
enum SchedulerJobsRefreshResult: Equatable {
    case current
    case partial(detail: String)
    case unavailable(detail: String)

    var failureDetail: String? {
        switch self {
        case .current:
            nil
        case .partial(let detail), .unavailable(let detail):
            detail
        }
    }

    static func make(from feed: SchedulerJobsFeedState) -> Self {
        switch feed {
        case .current:
            return .current
        case .partial(let rows, let rejectedRows):
            return .partial(detail: SchedulerJobsFeedState.partial(rows, rejectedRows: rejectedRows).failureDetail
                ?? "Schedule is partially unavailable.")
        case .sourceAbsent:
            return .unavailable(detail: SchedulerJobsFeedState.sourceAbsent.failureDetail
                ?? "Schedule source is absent.")
        case .unavailable(let detail):
            return .unavailable(detail: SchedulerJobsFeedState.unavailable(detail).failureDetail
                ?? "Schedule source is unavailable.")
        }
    }
}

@MainActor
extension AppModel {
    @MainActor
    @discardableResult
    func refreshSchedulerJobs() async -> SchedulerJobsRefreshResult {
        let feed = await engine.desk.refreshJobs()
        let result = SchedulerJobsRefreshResult.make(from: feed)
        switch feed {
        case .current:
            return result
        case .partial:
            statusText = result.failureDetail ?? "Schedule is partially unavailable."
            return result
        case .sourceAbsent:
            statusText = result.failureDetail ?? "Schedule source is absent."
            return result
        case .unavailable:
            statusText = result.failureDetail ?? "Schedule source is unavailable."
            return result
        }
    }

    /// Pause / resume one scheduled job from the Scheduler screen (item 36).
    /// The row's state is not repainted from the click — it is repainted from
    /// the job the writer actually persisted, so a refused write can never
    /// leave the switch sitting in a position the store never accepted.
    @MainActor
    func setSchedulerJobEnabled(id: String, enabled: Bool) async -> SchedulerJobToggleOutcome {
        do {
            let job = try await engine.desk.setJobEnabled(id: id, enabled: enabled)
            await refreshSchedulerJobs()
            return .verified(job)
        } catch {
            // Re-read regardless: the switch must show the store's truth, not
            // the click's optimism.
            await refreshSchedulerJobs()
            return .failed(UserFacingError.cause(error, action: "change that job"))
        }
    }

    @MainActor
    func createDreamJob() async -> NightlyReflectionJobOutcome {
        do {
            let scheduler: SchedulerDueJobRunner
            if let dataRootOverride {
                scheduler = SchedulerDueJobRunner(root: dataRootOverride)
            } else {
                scheduler = .shared
            }
            let outcome = try await engine.desk.ensureNightlyReflection(scheduler: scheduler)
            if case .failed(let message) = outcome {
                statusText = "Nightly reflection failed: \(message)"
            } else {
                statusText = outcome.message
            }
            return outcome
        } catch {
            let outcome = NightlyReflectionJobOutcome.failed(UserFacingError.cause(error, action: "add nightly reflection"))
            statusText = outcome.message
            return outcome
        }
    }

    @MainActor
    func createWorkshopTask(title: String, objective: String) async {
        do {
            _ = try await NativeAgentEngine.submitDeskTask(title: title, objective: objective)
            statusText = NewDeskTaskPresentation.successStatus
            await refreshAll()
        } catch {
            setFailureStatus(NewDeskTaskPresentation.failureStatus(UserFacingError.cause(error, action: "create the Desk task")), cause: error)
        }
    }

    @MainActor
    func saveWorkshopPolicyToggle(enabled: Bool? = nil, showTimeline: Bool? = nil) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot)
                .saveWorkshopPolicyToggle(enabled: enabled, showTimeline: showTimeline)
            applySavedTrustPolicy(savedPolicy, status: "Desk execution policy saved")
        } catch {
            setFailureStatus(error, action: "save the Desk execution policy")
        }
    }

    @MainActor
    func saveMemoryPolicy(consolidationEnabled: Bool, crossSessionRecall: Bool) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMemoryPolicy(
                consolidationEnabled: consolidationEnabled,
                crossSessionRecall: crossSessionRecall
            )
            applySavedTrustPolicy(savedPolicy, status: "Memory policy saved")
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save the memory policy"), cause: error)
        }
    }

    @MainActor
    @discardableResult
    func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async -> Bool {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMultimodalPolicy(policy)
            applySavedTrustPolicy(savedPolicy, status: "Multimodal policy saved")
            return true
        } catch {
            // A failed canonical write can mean the underlying policy bytes
            // became unreadable between the UI read and this mutation. Do not
            // leave a stale OpenAI-voice grant available to playback.
            engine.trust.policy = nil
            recordTrustActionFailure(UserFacingError.message(error, action: "save the multimodal policy"), cause: error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func patchMemoryPolicy(
        knowledgeGraphEnabled: Bool? = nil,
        adaptivePromotion: Bool? = nil,
        hygieneEnabled: Bool? = nil
    ) async -> Bool {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).patchMemoryPolicy(
                knowledgeGraphEnabled: knowledgeGraphEnabled,
                adaptivePromotion: adaptivePromotion,
                hygieneEnabled: hygieneEnabled
            )
            applySavedTrustPolicy(savedPolicy, status: "Memory policy saved")
            return true
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save the memory policy"), cause: error)
            return false
        }
    }

    @MainActor
    func saveEnableAutonomy(_ enabled: Bool) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveEnableAutonomy(enabled)
            applySavedTrustPolicy(savedPolicy, status: enabled ? "Autonomy enabled" : "Autonomy disabled")
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save autonomy"), cause: error)
        }
    }

    @MainActor
    func saveChromeControlEnabled(_ enabled: Bool) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveChromeControlEnabled(enabled)
            applySavedTrustPolicy(
                savedPolicy,
                status: enabled ? "Chrome control enabled" : "Chrome control disabled"
            )
            await NativeAgentEngine.live.chrome.reconcilePolicy()
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save Chrome control"), cause: error)
        }
    }

    @MainActor
    func saveKillSwitchEnabled(_ enabled: Bool) async -> Bool {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveKillSwitchEnabled(enabled)
            applySavedTrustPolicy(savedPolicy, status: enabled ? "Everything paused" : "Pause lifted")
            return true
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save Pause everything"), cause: error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func saveAgentAccessMode(_ mode: String, developerMode: Bool? = nil) async -> Bool {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot)
                .saveAgentAccessMode(mode, currentPolicy: engine.trust.policy, developerMode: developerMode)
            let status = "Agent access saved: \(Self.agentAccessLabel(mode))"
            applySavedTrustPolicy(savedPolicy, status: status)
            chatFileAccess = TrustAccessModeCapabilityCatalog.normalizedMode(mode)
            return true
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save agent access"), cause: error)
            return false
        }
    }

    @MainActor
    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String? = nil) {
        engine.trust.policy = policy
        if let status {
            statusText = status
            trustCenterActionOutcome = .saved(status)
        }
    }

    func recordTrustActionFailure(_ message: String, cause: Error? = nil) {
        statusText = message
        statusCause = cause?.localizedDescription
        trustCenterActionOutcome = .failed(message)
    }

    nonisolated static func agentAccessLabel(_ mode: String) -> String {
        switch TrustAccessModeCapabilityCatalog.normalizedMode(mode) {
        case "read_only": return "Read"
        case "workspace": return "Workspace"
        case "full": return "Full Mac"
        default: return "Auto"
        }
    }

    /// The backup, or nil; either way `statusText` carries the receipt.
    @MainActor
    @discardableResult
    func createBackup(reason: String) async -> BackupRecord? {
        let receipt: String
        var cause: String?
        var created: BackupRecord?
        do {
            let backup = try await TrustBackupPersistence.createBackup(
                reason: reason, dataRoot: PersistenceCore.defaultDataRoot(), host: .app
            )
            created = backup
            receipt = "Backup created at \(backup.createdAt): \(backup.reason)"
        } catch {
            receipt = UserFacingError.message(error, action: "make a backup")
            cause = error.localizedDescription
        }
        await refreshBackupList(preserving: receipt, cause: cause)
        return created
    }

    @MainActor
    func restoreBackup(_ backup: BackupRecord) async {
        let receipt: String
        var cause: String?
        do {
            let result = try await TrustBackupPersistence.restoreBackup(
                id: backup.id, dataRoot: PersistenceCore.defaultDataRoot(), host: .app
            )
            if result.requiresRestart {
                statusText = "Restore validated and staged with safety backup \(result.safetyBackupId ?? "created"). NativeAgent is restarting to restore before any live state owner opens."
                AppRestartCoordinator.relaunchApp(terminate: {
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                    }
                }, onSpawnFailure: { error in
                    ModuleLog.app("[relaunch] failed to spawn relaunch helper for %@: %@", Bundle.main.bundlePath, "\(error)")
                })
                return
            }
            let scopes = TrustBackupPersistence.scopeNames(for: result.restored)
            let restoredDescription = scopes.isEmpty ? "no matching data scopes" : scopes.joined(separator: ", ")
            receipt = "Restore completed at \(result.restoredAt): \"\(backup.reason)\" from \(backup.createdAt). Safety backup created first. Restored: \(restoredDescription)."
        } catch {
            receipt = "Restore failed for \"\(backup.reason)\" from \(backup.createdAt). "
                + UserFacingError.cause(error, action: "restore that backup")
            cause = error.localizedDescription
        }
        await refreshBackupList(preserving: receipt, cause: cause)
    }

    @MainActor
    private func refreshBackupList(preserving receipt: String, cause: String? = nil) async {
        do {
            try await engine.trust.refreshBackups()
            statusText = receipt
            statusCause = cause
        } catch {
            statusText = "\(receipt) " + UserFacingError.message(error, action: "refresh the backup list")
            statusCause = [cause, error.localizedDescription].compactMap { $0 }.joined(separator: "; ")
        }
    }

}

@MainActor
extension AppModel {
    /// Guidance text to show in chat when no AI provider is usable at all;
    /// `nil` when at least one provider looks connected.
    func missingProviderChatGuidance() -> String? {
        guard !SwiftNativeProviderRouting(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()).hasUsableCredentials() else { return nil }
        return """
        No AI provider is connected yet, so I can't reply.

        Use Open Providers below to connect one.
        """
    }

    @MainActor
    @discardableResult
    func refreshToolsFromToolbar() async -> ToolsRefreshPresentation.State {
        guard !isRefreshingTools else {
            return .alreadyRefreshing
        }
        isRefreshingTools = true
        toolsRefreshState = .refreshing
        defer { isRefreshingTools = false }

        await refreshForSidebarItem(.tools)
        let result = ToolsRefreshPresentation.completion(
            panelRefresh: panelRefreshStatus[.tools],
            catalogLoadFailed: engine.tools.catalogLoadError != nil,
            hasCatalog: engine.tools.catalog != nil
        )
        toolsRefreshState = result
        if let message = ToolsRefreshPresentation.message(for: result) {
            statusText = message
        }
        return result
    }

    @discardableResult
    func enqueueChatBrainDefaultsSave() -> UInt64? {
        engine.providers.enqueueChatBrainSave(
            currentChatBrainSelection,
            failure: { UserFacingError.cause($0, action: "save the model choice") },
            completion: { [weak self] result, error in
                guard let self else { return }
                switch result {
                case .saved(let selection):
                    self.applyCanonicalChatBrainSelection(selection)
                    self.statusText = result.userMessage
                    self.publishProviderCatalogStatusAfterBrainSave()
                case .unchanged:
                    self.statusText = result.userMessage
                case .failed(_, let canonical, _):
                    if let canonical { self.applyCanonicalChatBrainSelection(canonical) }
                    if let error { self.setFailureStatus(result.userMessage, cause: error) }
                    else { self.statusText = result.userMessage }
                }
            }
        )
    }

    @discardableResult
    func saveChatBrainDefaults() async -> ProvidersFacade.ChatBrainSaveResult {
        guard let generation = enqueueChatBrainDefaultsSave() else {
            return .unchanged(currentChatBrainSelection)
        }
        let result = await engine.providers.awaitChatBrainSave(generation: generation)
        if case .failed(_, _, nil) = result { statusText = result.userMessage }
        return result
    }

    private var currentChatBrainSelection: ProvidersFacade.ChatBrainSelection {
        .init(model: chatModel, reasoningEffort: chatReasoningEffort, fastMode: chatFastMode)
    }

    private func applyCanonicalChatBrainSelection(_ selection: ProvidersFacade.ChatBrainSelection) {
        if chatModel != selection.model { chatModel = selection.model }
        if chatReasoningEffort != selection.reasoningEffort {
            chatReasoningEffort = selection.reasoningEffort
        }
        if chatFastMode != selection.fastMode { chatFastMode = selection.fastMode }
    }

    private func publishProviderCatalogStatusAfterBrainSave() {
        Task {
            _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus()
        }
    }

    /// PATCH-2026-05-07: chat-provider-picker Load + cache the providers
    /// list so the chat screen's Provider dropdown stays populated. Also
    /// reads the canonical providers/active.json owner for `chatProvider`.
    /// M12 (gpt-5.5 review, 2026-07-09): returns whether the provider list
    /// actually refreshed, so the chat panel's staleness tracking can record
    /// a carried-over dropdown instead of silently impersonating a live one.
    @MainActor
    @discardableResult
    func loadProvidersForChat() async -> Bool {
        defer { engine.providers.refreshAccountModelsInBackground() }
        let saveGeneration = engine.providers.chatBrainSaveGeneration
        let chatWasSaving = isSavingChatBrain
        var providersFresh = true
        do {
            let snapshot = try await engine.providers.routing.checkedProviderSnapshot()
            engine.providers.connections = try ProvidersFacade.connections(from: snapshot)
            applySurfacePickerSnapshot(snapshot.routing, applyChat: !chatWasSaving
                && !isSavingChatBrain && saveGeneration == engine.providers.chatBrainSaveGeneration)
            Task {
                _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus()
            }
        } catch {
            // keep prior list on screen, but say so
            providersFresh = false
        }
        return providersFresh
    }

    @MainActor
    func adoptProviderForBlankSurfaces(_ providerId: String) async {
        let adopted = await engine.providers.adoptProviderForBlankSurfaces(
            providerId, dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            failure: { error, action in setFailureStatus(error, action: action) }
        ) { surface in
            try await clearSurfaceOverride(surface: surface)
        }
        if adopted { await loadProvidersForChat() }
    }
}

extension ProvidersFacade.ChatBrainSaveResult {
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

extension AppModel {

    // MARK: Approvals
    /// Overload of the existing `resolveApproval(_:decision:)` for callers that
    /// hold only the approval id (inline cards, sidebar rows). Concurrent
    /// callers share one task because a terminal approval may start a real
    /// executor after its durable decision is written.
    func resolveApproval(id: String, decision: String) async throws -> ApprovalRecord {
        try await engine.approvals.resolveApproval(
            id: id, decision: decision,
            coordinator: .app(dataRootOverride: dataRootOverride)
        ) { id, active in
            if active { approvalResolutionInFlightIDs.insert(id) }
            else { approvalResolutionInFlightIDs.remove(id) }
        }
    }

    // MARK: Chat context / tools
    func getSessionContext(sessionId: String, model: String? = nil) async throws -> SessionContextStatus {
        try await RuntimeReadProjection.getSessionContext(
            sessionId: sessionId, model: model, dataRoot: engine.dataRoot, configuredThresholdTokens: nil)
    }

    /// ChatOrchestration's canonical transcript compactor, so automatic and
    /// manual requests share validation, verified backup, durable
    /// replacement, traces, and optional distillation.
    func compactSession(
        sessionId: String,
        model: String? = nil,
        providerID: String? = nil,
        force: Bool = false
    ) async throws -> ChatSessionCompactionOutcome {
        try await engine.compactSession(
            sessionId: sessionId, model: model, providerID: providerID, force: force, client: macChatClient
        )
    }

    /// A slash command's tool run. The caller serializes its input on the
    /// main actor so only Sendable data crosses into the dispatcher.
    func dispatchToolData(tool: String, inputData: Data, sessionId: String?) async throws -> DispatchResult {
        try await engine.dispatchToolData(tool: tool, inputData: inputData, sessionId: sessionId)
    }

    // MARK: Connectors
    func getConnectorRegistrationStatus(provider: String) async throws -> ConnectorRegistrationStatus {
        try await ConnectorWizardActions.getConnectorRegistrationStatus(provider: provider)
    }

    func registerConnectorApp(provider: String) async throws -> ConnectorRegisterAppResponse {
        try await ConnectorWizardActions.registerConnectorApp(provider: provider)
    }

    // MARK: Onboarding
    func startOnboarding() async throws -> OnboardingStartResult {
        try await engine.onboarding.startOnboarding()
    }

    func completeOnboarding(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResult {
        try await engine.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: agentName, personaType: personaType, userName: userName),
            resident: .live
        )
    }

    func resumePendingOnboarding() async throws -> OnboardingCompleteResult {
        try await engine.resumePendingOnboarding(resident: .live)
    }

    func repairOnboardingProfile(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResult {
        try await engine.repairOnboardingProfile(
            payload: OnboardingCompletePayload(agentName: agentName, personaType: personaType, userName: userName),
            publishProfile: { await self.reloadPersonality() }, resident: .live
        )
    }

    func resetOnboarding(confirm: Bool = true) async throws -> OnboardingResetResult {
        try await engine.resetOnboarding(confirm: confirm, resident: .live)
    }

    func refreshResidentMindAfterOnboardingTransition() async {
        await NativeAgentEngine.live.refreshResidentMindAfterOnboardingTransition()
    }

    // MARK: Mac assistant / Mac control
    func getMacAssistantStatus() async throws -> MacAssistantStatusResult {
        // UI consumes the full access/template lists — request non-lightweight.
        try await AppConnectorActionPlatform(dataRoot: engine.dataRoot).macAssistantStatusClient()
            .macAssistantStatus(lightweight: false)
    }

    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMacIntegrationPreset(preset, currentPolicy: currentPolicy)
    }

    /// Overload of the existing `runConnectorAction(_:)` for the id/dryRun/input
    /// call shape used by the Mac-data probe.
    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue] = [:]) async throws -> ConnectorActionReceipt {
        try await ConnectorActions(platform: AppConnectorActionPlatform(dataRoot: engine.dataRoot))
            .runConnectorAction(id: id, dryRun: dryRun, input: input)
    }

    func fullMacYoloAuthorityAdmitted(tool: String, surface: String) async -> Bool {
        await ConnectorActions.fullMacYoloAdmitted(tool: tool, surface: surface, dataRoot: engine.dataRoot)
    }

    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot)
            .saveMacControlPolicy(policy, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func macControlNotify(title: String, message: String) async throws -> Bool {
        try await engine.trust.notify(
            title: title, message: message, notificationCenterAdapter: NativeAgentMacControlNotificationAdapter()
        )
    }

    func macControlRun(path: String, bodyData: Data) async throws -> MacControlRunResult {
        try await engine.trust.runMacControl(
            path: path, bodyData: bodyData, notificationCenterAdapter: NativeAgentMacControlNotificationAdapter()
        )
    }

    // MARK: Providers
    func clearSurfaceOverride(surface: String) async throws {
        try await engine.clearSurfaceOverride(surface: surface) { preference in
            applySurfacePickerSelection(
                surface: surface, model: preference.model,
                reasoningEffort: preference.reasoningEffort, serviceTier: preference.serviceTier
            )
        }
    }

    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String? = nil, model: String? = nil,
        reasoningEffort: String? = nil, serviceTier: String? = nil, clearOverride: Bool = false
    ) async throws -> ProviderGroupWriteResult {
        try await engine.saveProviderGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride,
            applySnapshot: { applySurfacePickerSnapshot($0) }
        )
    }

    func configureSurfaceSelection(
        surface: String, providerID: String, model: String, reasoningEffort: String, serviceTier: String?
    ) async throws -> ModelCatalogResponse {
        try await engine.configureSurfaceSelection(
            surface: surface, providerID: providerID, model: model,
            reasoningEffort: reasoningEffort, serviceTier: serviceTier
        ) { response in
            applySurfacePickerSelection(
                surface: surface, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier
            )
            if surface == "chat" {
                chatProvider = providerID
                let canonical = response.current.chat
                engine.providers.chatBrainCanonicalSelection = ProvidersFacade.ChatBrainSelection(
                    model: canonical.model, reasoningEffort: canonical.reasoningEffort,
                    fastMode: canonical.serviceTier == "priority"
                )
            }
        }
    }

    private func applySurfacePickerSelection(
        surface: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String?
    ) {
        switch surface {
        case "chat":
            chatModel = model
            chatReasoningEffort = reasoningEffort
            chatFastMode = serviceTier == "priority"
        case "telegram":
            telegramModel = model
            telegramReasoningEffort = reasoningEffort
        default:
            break
        }
    }

    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String? = nil) async throws {
        try await engine.configureProvider(id, apiKey: apiKey, authMode: authMode, defaultModel: defaultModel)
    }

    /// `apiKeyOverride` is the unsaved key typed into the provider sheet; when
    /// present the probe tests THAT credential instead of the one on disk
    /// (User, 2026-09-06).
    func testProvider(_ id: String, apiKeyOverride: String? = nil) async throws -> NativeAgentShared.ProviderTestResult {
        try await engine.providers.testProvider(id, apiKeyOverride: apiKeyOverride)
    }

    func clearProvider(_ id: String) async throws {
        try await engine.clearProvider(id)
    }

    /// The provider sheet's Remove the key, which provider.disconnect runs
    /// too: the registry row, then the sign-in. `detail` is the sheet's status
    /// line; `ok` false claims no removal.
    func disconnectProvider(_ id: String) async -> (ok: Bool, detail: String, cause: String?) {
        do {
            let result = try await engine.providers.disconnectProvider(id) {
                try await self.clearProvider(id)
            }
            _ = await loadProvidersForChat()
            return (result.ok, result.detail, nil)
        } catch {
            return (false, UserFacingError.message(error, action: "remove the sign-in"), error.localizedDescription)
        }
    }

    // MARK: Integrations / inbox
    func inboxAction(_ id: String, action: String) async throws {
        if let inboxActionOverride {
            return try await inboxActionOverride(id, action)
        }
        try await InboxCardActions.perform(id, action: action, dataRootOverride: dataRootOverride, effects: AppInboxCardActionEffects())
    }
}

extension AppModel {
    nonisolated func nextGenActionReceipt(
        id: String,
        dryRun: Bool,
        surface: String = "nextgen_action"
    ) async throws -> NextGenReceipt {
        try await engine.nextGenActionReceipt(
            id: id, dryRun: dryRun, surface: surface,
            backgroundLoopsManager: backgroundLoopsManager,
            healthCard: { [self] in
                try await AppDoctorPort(
                    dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager
                ).runtime.getHealthCard()
            },
            routePlan: { message in
                try JSONValue.fromEncodable(IntentRoutePlan(await SwiftNativeRouterPlanClient().planRoute(message: message)))
            }
        )
    }
}

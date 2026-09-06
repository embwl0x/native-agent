import Foundation
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
import CommandPalette
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

@MainActor
@Observable
final class AppModel {
    /// Global toast/status surface. Views overlay SystemToastBar(center:) and
    /// any code path can call appModel.systemToasts.push(...).
    let systemToasts = SystemToastCenter()
    /// Central poll scheduler — replaces per-view sleep-loop `.task` blocks
    /// with one coordinated tick that pauses while chat is streaming or the
    /// app is unfocused. Local-state UI uses owner invalidations instead; see
    /// `PollScheduler.swift` for the narrow retained-liveness contract.
    let pollScheduler = PollScheduler()
    var directInstallInFlight = false
    private let activeChatSessionIDWriter: @MainActor (String?) -> Void
    private let backgroundLoopsManager: BackgroundLoopsManager
    private let chatSnapshotPublisher: @MainActor () -> Void
    var approvalResolverOverride: (@MainActor (String, String) async throws -> ApprovalRequest)?
    var inboxReaderOverride: (@MainActor (Bool) async throws -> [InboxItemRecord])?
    var inboxActionOverride: (@MainActor (String, String) async throws -> Void)?
    var inboxSnapshotWriterOverride: (@MainActor () async -> Void)?
    var inboxReloadGeneration = 0
    let chatRenameMutationGate = ChatRenameMutationGate()
    var chatRenameIntentGeneration: [String: Int] = [:]

    // PATCH-2026-05-07: model-default-bump One-time migration: any saved
    // chatModel/telegramModel that's a stale mid/low-tier value gets
    // bumped to the current top-tier default. Users shouldn't end up on
    // haiku-4-5 or gpt-5.4-mini just because the daemon's saved config
    // had them when AppModel first launched.
    static func _bumpStaleModelSelection(_ key: String, fallback: String) {
        let stale: Set<String> = [
            "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3", "gpt-4o", "gpt-4-turbo",
            "claude-sonnet-4-5", "claude-sonnet-4-6", "claude-haiku-4-5",
            "claude-opus-4-5", "claude-opus-4-6",
        ]
        let bumpedKey = "\(key).bumpedToGPT56.v2"
        if UserDefaults.standard.bool(forKey: bumpedKey) { return }
        let current = UserDefaults.standard.string(forKey: key) ?? ""
        if stale.contains(current) || current.isEmpty {
            UserDefaults.standard.set(fallback, forKey: key)
        }
        UserDefaults.standard.set(true, forKey: bumpedKey)
    }

    // PATCH-2026-05-07: observable-bindings All these were UserDefaults-only
    // computed properties — `@Observable` only tracks STORED properties so
    // SwiftUI bindings never propagated and onChange never fired. Converted
    // to stored with `didSet` UserDefaults persistence so settings panels
    // (Telegram, SearXNG, native runtime setting) actually save when toggled.
    private(set) var nativeBaseURL: String = NativeBaseURLDefaults.read() {
        didSet { NativeBaseURLDefaults.write(nativeBaseURL) }
    }

    /// Commit the compatibility URL only after validation. NativeAgent's
    /// in-process Swift runtime remains the runtime owner; this does not
    /// establish a fallback daemon connection.
    @discardableResult
    func configureNativeBaseURL(_ value: String) throws -> String {
        let normalized = try NativeBaseURLDefaults.normalized(value)
        nativeBaseURL = normalized
        return normalized
    }

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
    var chatModel: String = {
        AppModel._bumpStaleModelSelection("chatModel", fallback: nativeAgentPrimaryModel)
        return UserDefaults.standard.string(forKey: "chatModel") ?? nativeAgentPrimaryModel
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

    var telegramModel: String = {
        AppModel._bumpStaleModelSelection("telegramModel", fallback: nativeAgentPrimaryModel)
        return UserDefaults.standard.string(forKey: "telegramModel") ?? nativeAgentPrimaryModel
    }() {
        didSet { UserDefaults.standard.set(telegramModel, forKey: "telegramModel") }
    }

    var telegramReasoningEffort: String = UserDefaults.standard.string(forKey: "telegramReasoningEffort") ?? "high" {
        didSet { UserDefaults.standard.set(telegramReasoningEffort, forKey: "telegramReasoningEffort") }
    }

    /// 2026-06-05 picker-sync: read providers/surfaces.json and sync local
    /// chat/telegram bar picker state to whatever it says. Called on app init
    /// so the chat-bar UserDefaults cache can't drift from disk truth.
    @MainActor
    func refreshSurfacePickerCache() async {
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("surfaces.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        func entryFor(_ surface: String) -> (model: String?, effort: String?, serviceTier: String?) {
            if let inner = obj[surface] as? [String: Any] {
                return (
                    inner["model"] as? String,
                    inner["reasoningEffort"] as? String ?? inner["reasoning_effort"] as? String,
                    inner["serviceTier"] as? String ?? inner["service_tier"] as? String
                )
            }
            if let flat = obj[surface] as? String, !flat.isEmpty {
                return (flat, nil, nil)
            }
            return (nil, nil, nil)
        }
        let chat = entryFor("chat")
        if let m = chat.model, !m.isEmpty, m != chatModel { chatModel = m }
        if let e = chat.effort, !e.isEmpty, e != chatReasoningEffort { chatReasoningEffort = e }
        if let tier = chat.serviceTier {
            chatFastMode = tier == "priority"
        }
        if let model = chat.model, !model.isEmpty {
            chatBrainCanonicalSelection = ChatBrainSelection(
                model: model,
                reasoningEffort: chat.effort ?? chatReasoningEffort,
                fastMode: chat.serviceTier.map { $0 == "priority" } ?? chatFastMode
            )
        }
        let tg = entryFor("telegram")
        if let m = tg.model, !m.isEmpty, m != telegramModel { telegramModel = m }
        if let e = tg.effort, !e.isEmpty, e != telegramReasoningEffort { telegramReasoningEffort = e }
    }

    var telegramTokenConfigured = false
    /// Memories waiting for review, as Today last counted them; the rail's dot
    /// on Today reads this and the pending approvals, the same two the page's
    /// waiting card reads, so the two can never disagree.
    var todayWaitingMemories = 0
    var telegramEnabled = false
    var isSavingTelegram = false
    /// The Telegram settings surface owns this receipt. `statusText` remains
    /// a cross-app activity line and may be replaced by an unrelated refresh.
    var telegramSettingsSaveOutcome: TelegramSettingsSaveOutcome?
    var isTestingTelegram = false
    var isClearingTelegramLogs = false
    var telegramClearLogsOutcome: TelegramClearLogsPresentation.Outcome?
    var telegramStatus: TelegramStatus?
    /// A failed status refresh does not erase the last readable Telegram
    /// receipt snapshot. The settings surface must mark that snapshot stale
    /// instead of presenting it as a current read.
    var telegramStatusRefreshError: String?
    var chatSessions: [ChatSession] = []
    // PATCH-2026-05-11: unified-session-v1 — on first launch after this change, drop any
    // stale Mac-only session ID so the daemon resolves via the configured mobile source key instead.
    var activeChatSessionId: String = {
        if !UserDefaults.standard.bool(forKey: "NativeAgent.unifiedSession.v1") {
            UserDefaults.standard.removeObject(forKey: "activeChatSessionId")
            UserDefaults.standard.set(true, forKey: "NativeAgent.unifiedSession.v1")
        }
        return UserDefaults.standard.string(forKey: "activeChatSessionId") ?? ""
    }()
    // 2026-06-08 detached-chat-windows W0.2: dict-ified storage for both
    // chatMessages and latestContextReceipt. The public properties below are
    // computed reads/writes against the active session's slot, preserving
    // every existing call site (72 chatMessages reads + 9 receipt reads +
    // 25+ writes across NativeClient.swift and ChatView.swift). Per-session
    // accessors `chatMessages(for:)` / `setChatMessages(_:for:)` /
    // `latestContextReceipt(for:)` / `setLatestContextReceipt(_:for:)` let
    // detached chat panels (Phase 1) bind to any session without going
    // through `activeChatSessionId`.
    //
    // Why dict + computed property instead of a per-session ViewModel:
    // PATCH-2026-05-13 (parallel-sessions) already ships `busySessions`,
    // `streamingSessions`, `chatTasks`, `chatTaskGenerations`,
    // `streamingTexts`, `streamingBubbleIds`, `streamingUserTurnIds`,
    // `streamingUserTurnTexts`, `chatDrafts` as
    // per-session dicts. The ONLY two fields still in the singleton are
    // `chatMessages` and `latestContextReceipt` — dict-ifying them
    // completes the per-session migration without inventing a new VM type.
    // 2026-09-06: the transcript's mutation counter. The message-list grouper
    // used to detect "same list" with count + tail row + total content bytes;
    // an interior row replaced with the same byte count, or changed only in
    // its metadata, passed all three and the view kept stale groups. Every
    // write to the transcript now goes through the computed
    // `chatMessagesBySession` below, so the counter cannot be forgotten by a
    // new writer. `chatMessagesStructureVersion` is the cache key: it skips
    // the streaming delta, which rewrites only the final row and which the
    // list patches in place rather than re-walking the whole transcript.
    private var chatMessagesStorage: [String: [ChatMessage]] = [:]
    @ObservationIgnored private var chatMessagesTailOnlyWrite = false
    private(set) var chatMessagesStructureVersion: UInt64 = 0
    var chatMessagesBySession: [String: [ChatMessage]] {
        get { chatMessagesStorage }
        set {
            chatMessagesStorage = newValue
            if !chatMessagesTailOnlyWrite { chatMessagesStructureVersion &+= 1 }
            chatMessagesTailOnlyWrite = false
        }
    }
    /// Write `messages` knowing that only the FINAL row differs from what is
    /// there now. The one caller is the streaming delta (2026-09-06).
    func setChatMessagesTailOnly(_ messages: [ChatMessage], for sessionId: String) {
        chatMessagesTailOnlyWrite = true
        chatMessagesBySession[sessionId] = messages
    }
    var latestContextReceiptBySession: [String: ContextReceipt] = [:]

    var chatMessages: [ChatMessage] {
        get { chatMessagesBySession[activeChatSessionId] ?? [] }
        set { chatMessagesBySession[activeChatSessionId] = newValue }
    }
    var latestContextReceipt: ContextReceipt? {
        get { latestContextReceiptBySession[activeChatSessionId] }
        set { latestContextReceiptBySession[activeChatSessionId] = newValue }
    }

    // M12 (2026-07-09): `refreshForSidebarItem` is a wall of
    // `try? await api.getX() ?? existingValue`. When the backend is dead every
    // one of those falls back to the previous value and the panel renders
    // last-week's data as if it were fetched a moment ago. Record which
    // endpoints came back nil so the UI can say so instead of lying.
    struct PanelRefreshStatus: Equatable, Sendable {
        /// When the panel last attempted a refresh.
        var lastAttemptAt: Date
        /// When the panel last completed a refresh with *every* endpoint OK.
        /// nil means it has never had a fully-successful refresh this run.
        var lastSuccessAt: Date?
        /// Endpoints that returned nil on the last attempt. Non-empty means at
        /// least one value on screen is carried over from an earlier refresh.
        var failedEndpoints: [String]

        var isStale: Bool { !failedEndpoints.isEmpty }
    }

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

    static func detachedContextReceiptWarning(
        history: CompactReadPresentationState,
        receiptStatus: PanelRefreshStatus?
    ) -> String? {
        guard receiptStatus?.isStale == true else { return nil }
        switch history {
        case .empty, .content:
            return "Context receipt unavailable; conversation history is still current."
        case .loading, .unavailable, .stale:
            return "Context details are also unavailable."
        }
    }

    /// Last refresh outcome per sidebar panel. Written only by
    /// `refreshForSidebarItem`; read by views via `panelStaleNotice(for:)`.
    var panelRefreshStatus: [SidebarItem: PanelRefreshStatus] = [:]
    /// Small always-visible readers have lifecycles independent of the full
    /// Chat/Activity panels. Keep their freshness separate so one successful
    /// badge poll cannot erase a stale full-panel warning (or vice versa).
    var whatsRunningRefreshStatus: PanelRefreshStatus?
    var sidebarActivityRefreshStatus: PanelRefreshStatus?
    var detachedChatRefreshStatus: [String: PanelRefreshStatus] = [:]
    var detachedChatContextReceiptRefreshStatus: [String: PanelRefreshStatus] = [:]

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
    var health: RuntimeHealth?
    var activityEvents: [ActivityEvent] = []
    var executions: [WorkshopExecutionRecord] = []
    var runs: [RunRecord] = []
    /// App integration tests use the same native files behind a temporary
    /// root; production leaves this nil and resolves the ordinary data root.
    var dataRootOverride: URL?
    var memories: [MemoryRecord] = []
    var personality: PersonalityProfile?

    /// Memory hygiene learns the name she goes by, so a fact "about Agent" is
    /// kept out of the user's profile whatever the persona is called. Called
    /// wherever the profile is assigned; a `didSet` on an @Observable stored
    /// property took the chat room down (2026-09-02), so it is explicit.
    func teachMemoryHygieneName() {
        let name = personality?.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !name.isEmpty { AdaptiveCandidateHygiene.insertAssistantName(name) }
        // Every sentence about the agent, wherever it is built, speaks in
        // the persona's name and the chosen pronoun.
        AgentVoice.live = AgentVoice.current(name: agentDisplayName)
    }
    var personalityDocs: [PersonalityDoc] = []
    var skills: [SkillRecord] = []
    var tools: [ToolRecord] = []
    var chatToolCatalog: ChatToolCatalogSnapshot?
    /// Last authoritative catalog-read failure. Kept beside the last good
    /// catalog so the Tools surface can say when it is displaying stale data
    /// instead of presenting an old snapshot as a fresh one.
    var chatToolCatalogLoadError: String?
    /// True after a refresh attempt has FAILED (decode error or dispatch
    /// throw). Lets the UI distinguish "still loading" (catalog == nil &&
    /// !loadFailed) from an unavailable catalog (catalog == nil &&
    /// loadFailed), without presenting the latter as an empty result.
    var chatToolCatalogLoadFailed: Bool = false
    /// Toolbar-specific single-flight state. Navigation may still perform its
    /// own scoped load, but repeated user taps cannot launch concurrent Tools
    /// refreshes that race to overwrite the visible receipt.
    var isRefreshingTools = false
    var toolsRefreshState: ToolsRefreshPresentation.State = .idle
    var capabilitySummary: CapabilitySummaryResponse?
    var routePlan: IntentRoutePlan?
    var routePresentation: IntentRoutePresentation = .idle
    var workflows: [WorkflowRecord] = []
    // Render-cost audit F13: `didSet` keeps `pendingActivityCount` derived from
    // EVERY mutation path, not just the badge refresh — see the invariant note
    // on `recomputePendingActivityCount()`.
    var approvals: [ApprovalRequest] = [] {
        didSet { recomputePendingActivityCount() }
    }
    /// Shared by every mounted approval surface. This is UI coordination only;
    /// the ApprovalInbox actor remains the durable terminal-decision authority.
    var approvalResolutionInFlightIDs: Set<String> = []
    /// Retains the one resolver task so direct callers (chat cards included)
    /// join an active decision instead of re-entering NativeClient's executor.
    var approvalResolutionTasks: [String: Task<ApprovalRequest, Error>] = [:]
    /// The decision each in-flight resolution is carrying. 2026-09-06: joining
    /// by id alone handed the FIRST decision's result back to a second caller
    /// who asked for the opposite one, so a Deny pressed over a running Approve
    /// silently reported "approved".
    var approvalResolutionDecisions: [String: String] = [:]
    /// Last compact-Capabilities approval action outcome. This is a UI receipt
    /// only; ApprovalInbox remains the terminal-decision authority.
    var capabilitiesApprovalInboxOutcome: CapabilitiesApprovalInboxResolution?
    var inboxItems: [InboxItemRecord] = [] {
        didSet { recomputePendingActivityCount() }
    }
    var mcpServers: [MCPServerRecord] = []
    var mcpSessions: [MCPSessionStatus] = []
    var mcpConsent: [MCPConsentRecord] = []
    var mcpTools: [MCPToolRecord] = []
    var mcpToolReadState: MCPHubToolReadState = .notLoaded
    var mcpResources: [MCPResourceRecord] = []
    var mcpResourceReadState: MCPHubResourceReadState = .notLoaded
    var latestMCPCall: MCPCallResult?
    var mcpRecentCallState: MCPHubRecentCallState = .notLoaded
    var selectedMCPServerId: String?
    var researchLabRuns: [ResearchLabRun] = []
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
    var capabilityTrust: CapabilityTrustNetwork?
    var latestCapabilityTrustEvaluation: CapabilityTrustEvaluation?
    var latestCapabilityUpdateCheck: CapabilityUpdateCheck?
    var nextGenSummary: NextGenSummary?
    var nextGenPhases: [NextGenPhase] = []
    var nextGenReceipts: [NextGenReceipt] = []
    var latestNextGenReceipt: NextGenReceipt?
    var isRunningNextGenAction = false
    var personalityGrowth: PersonalityGrowthSummary?
    var nativePower: NativePowerSummary?
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
    /// F2: semantic recall results for the Memory tab search box. nil means
    /// "no search active — show appModel.memories". Populated by
    /// `runMemorySemanticSearch(query:)` via the root-resolved MemoryV2 owner.
    var memorySearchResults: [MemoryRecord]? = nil
    var memorySearchError: String? = nil
    /// Normalized query that produced `memorySearchResults`. Views must compare
    /// this before rendering a prior asynchronous response under new keystrokes.
    var memorySearchResultQuery: String? = nil
    /// A semantic request is in flight for `memorySearchResultQuery`. This is
    /// distinct from an empty result so the search field never claims "No
    /// Matches" while the canonical reader is still working.
    var memorySearchIsLoading = false
    var memorySearchGate = LatestAsyncRequestGate()
    var connectorActionRegistry: ConnectorActionRegistry?
    var latestConnectorActionReceipt: ConnectorActionReceipt?
    var improvementGauntletStatus: ImprovementGauntletStatus?
    var latestBrowserRun: BrowserRun?
    var latestGauntletRun: ImprovementGauntletRun?
    var productionHardening: ProductionHardeningSummary?
    var productionExports: [ProductionExport] = []
    var trustPolicy: TrustPolicy? {
        didSet {
            guard let policy = trustPolicy else { return }
            let syncedMode = Self.agentAccessMode(from: policy, fallback: chatFileAccess)
            if chatFileAccess != syncedMode {
                chatFileAccess = syncedMode
            }
        }
    }
    /// The last action initiated on the Trust surface. Unlike `statusText`, it
    /// cannot be overwritten by refreshes or work from another surface.
    var trustCenterActionOutcome: TrustCenterActionOutcome?
    var policySimulation: PolicySimulation?
    /// A transport/read failure is distinct from SecurityCenter's fail-closed
    /// unavailable-policy envelope. Keeping it separate prevents an old
    /// successful verdict from remaining visible after a later failed run.
    var policySimulationFailure: String?
    var backups: [BackupRecord] = []
    var connectors: [ConnectorRecord] = []
    var workspaces: [WorkspaceRecord] = []
    var workspaceSearchResults: [WorkspaceSearchResult] = []
    var evals: [EvalRun] = []
    var releaseChecklist: ReleaseChecklist?
    var watchdogStatus: WatchdogStatus?
    var trainingArtifacts: [TrainingArtifact] = []
    var jobs: [SchedulerJob] = []
    var improvements: [ImprovementRun] = []
    var improvementSummary: ImprovementSummary?
    var researchResults: [ResearchResult] = []
    var setupQuestions: [SetupQuestion] = []
    var doctorReport: DoctorReport?
    // PATCH-2026-05-30: Doctor in-flight flag so the UI can show a spinner
    // while the 7-15s probe runs (rather than appearing frozen until done).
    // Mirrors the doctor button click; flipped true at start of runDoctor,
    // false in the defer block at the end.
    var doctorRunning: Bool = false
    var doctorRunStartedAt: Date?
    // 2026-07-23 B2.6d: when the last full Doctor run completed. Support
    // Snapshot reuses that fresh result instead of re-running the whole pass.
    var doctorReportCompletedAt: Date?
    var codexAuthStatus: CodexAuthStatus?
    var codexDeviceLogin: CodexDeviceLogin?
    var modelCatalog: ModelCatalogResponse?
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
        case failed(message: String, rolledBackTo: ChatBrainSelection?)

        var userMessage: String {
            switch self {
            case .unchanged(let selection), .saved(let selection):
                return "Chat brain saved: \(selection.model) / \(selection.reasoningEffort)\(selection.fastMode ? " / Fast" : "")"
            case .failed(let message, _):
                return "Chat brain save failed: \(message)"
            }
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
    // PATCH-2026-05-07: chat-provider-picker Cache provider list + active
    // chat provider so the chat screen can render a Provider→Model dual
    // picker without re-fetching every render.
    var providersList: [ProviderInfo] = []
    // PATCH-2026-05-07: chat-binding-fix Stored property (not computed)
    // so @Observable actually tracks changes. UserDefaults persistence is
    // a side effect of didSet.
    var chatProvider: String = UserDefaults.standard.string(forKey: "chatProvider") ?? "openai_oauth_direct" {
        didSet { UserDefaults.standard.set(chatProvider, forKey: "chatProvider") }
    }
    var statusText: String = "Not checked"
    /// Bounded, non-transient receipts for mutations initiated from Tools.
    /// Unlike `statusText`, repeated identical failures remain distinct rows.
    var toolOperationStatusReceipts: [ToolOperationStatusReceipt] = []
    // FIX: last decode/network failure seen during refreshAll, so swallowed
    // section failures are observable instead of silently blanking the UI.
    var lastRefreshError: String? = nil
    // PATCH-2026-05-13: parallel-sessions — per-session chat state so the user
    // can work in multiple sessions concurrently. Daemon already supports
    // parallel sessions (per-session chat_file_lock). The single-flight guard
    // here in the Mac UI was the only blocker.
    //
    // `isBusy` / `isChatStreaming` / `currentChatTaskSessionId` are preserved
    // as computed back-compat properties that report the ACTIVE session's
    // state — which is what nearly every ContentView call site actually
    // wants. The new per-session API is `isSessionBusy(_:)` /
    // `isSessionStreaming(_:)` for code that needs to inspect non-active
    // sessions (e.g. running-indicator badges in the sidebar).
    var busySessions: Set<String> = []
    /// Synchronous mutex for the one-time first-run welcome greeting: set before
    /// the provider-refresh await so the .task + two onChange triggers can't
    /// double-greet. See AppModel+FirstRunWelcome.
    @ObservationIgnored var firstRunGreetingInFlight = false
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
    var streamingSessions: Set<String> = []
    var chatTasks: [String: Task<Void, Never>] = [:]
    var chatTaskGenerations: [String: Int] = [:]
    /// The one authoritative Mac presentation lifecycle for the current or
    /// most-recent accepted turn in each session. Operational events, stop
    /// requests, and evidence-backed terminals all reduce into this state.
    var chatTurnLifecycleBySession: [String: MacChatTurnLifecycleState] = [:]
    @ObservationIgnored var activeChatTurnLifecycleIDsBySession: [String: String] = [:]
    @ObservationIgnored var chatTurnLifecycleStore = MacChatTurnLifecycleStore()
    @ObservationIgnored var chatTurnTranscriptProofReader: any MacChatTurnTranscriptProofReading =
        MacChatTurnTranscriptProofReader()
    @ObservationIgnored var chatTurnLifecycleRepairCompleted = false
    /// User, 2026-09-06: a profile repair that landed while a turn was running.
    /// The resident refresh stops and restarts Context Flow and reloads
    /// cognition, so it waits for the last active turn to close rather than
    /// pulling the ground out from under a turn in flight.
    @ObservationIgnored var residentRefreshPendingAfterActiveTurns = false
    /// User-authored turns waiting behind the active turn, keyed by canonical
    /// session id. They stay outside the transcript/provider path until they
    /// become active, so queued text cannot race or duplicate the running turn.
    var queuedChatTurnsBySession: [String: [QueuedChatTurn]] = [:]
    /// A manual Stop pauses automatic queue drain for that session. Natural
    /// completion drains immediately; Steer explicitly unpauses and promotes.
    var pausedChatQueueSessions: Set<String> = []
    /// 2026-09-06: why the queue paused, when it paused because a queued turn
    /// FAILED to start. The drain used to discard the typed rejection's
    /// message, so the strip read "Paused" and the person was never told what
    /// went wrong. Absent for an ordinary Stop-pause, which needs no reason.
    var chatQueuePauseReasons: [String: String] = [:]
    /// Hermetic queue-drain seam. Production leaves this nil and starts the
    /// real chat turn; tests can prove FIFO/promotion without touching a
    /// provider, transcript, or the user's runtime root.
    @ObservationIgnored var queuedChatTurnStartOverride: (@MainActor @Sendable (QueuedChatTurn, String) async -> ChatTurnAcceptance)?
    @ObservationIgnored var drainingChatQueueSessions: Set<String> = []
    // 2026-06-10 audit FIX 4: stopChatStream's cancelled.flag write used to be
    // fire-and-forget — Stop then a quick re-Send raced the new turn's
    // flag-clear, so the stale write could land mid-turn and kill the NEW
    // turn. Track the in-flight write per session; turn starts await it via
    // awaitPendingCancelFlagWrite(for:) so the write is ordered BEFORE the
    // turn-start clear. Entries self-remove when the latest write completes
    // (generation-guarded, all on MainActor).
    var pendingCancelFlagWrites: [String: Task<Void, Never>] = [:]
    var pendingCancelFlagWriteGenerations: [String: Int] = [:]
    // PATCH-2026-05-13: parallel-sessions — when a session is streaming but
    // not active, we still need to know (a) the live delta-buffer and (b)
    // the in-flight bubble id so that switching back to the session can
    // restore the live-text bubble without waiting for the next refresh.
    var streamingTexts: [String: String] = [:]
    var streamingBubbleIds: [String: String] = [:]
    // PATCH-2026-05-13: parallel-sessions — also stash the optimistic user
    // turn (id + content) for each in-flight session. If the user switches
    // away/back before the daemon has persisted the user message, we
    // re-inject it so the visible session shows both the prompt and the
    // streaming reply, not just the reply.
    var streamingUserTurnIds: [String: String] = [:]
    var streamingUserTurnTexts: [String: String] = [:]
    var chatSelectionGeneration = 0

    /// Clear the per-session streaming-bubble state for `sessionId` BEFORE
    /// stashing a pending error on an inactive-session error path. Without
    /// this, selectChatSession's reinjection (gated on streamingSessions +
    /// these dicts) re-adds the empty optimistic assistant bubble during the
    /// post-stash awaits, the drain sees `last.role == "assistant"`, and
    /// silently suppresses the error.
    var chatPersona: String = {
        let saved = UserDefaults.standard.string(forKey: "chatPersona")
        return NativeChatTurnOptions.normalizedPickerPersona(saved)
    }() {
        didSet {
            let normalized = NativeChatTurnOptions.normalizedPickerPersona(chatPersona)
            if normalized != chatPersona {
                chatPersona = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "chatPersona")
            Task {
                await NativeContextFlowRuntime.shared.personaPickerDidChange()
            }
        }
    }
    var agentDisplayName: String {
        let profileName = personality?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profileName.isEmpty { return profileName }
        return canonicalAgentDisplayName(chatPersona)
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
    // PATCH-2026-05-07: living-memory Memory proposals state
    var memoryProposals: [MemoryProposalRecord] = [] {
        didSet { recomputePendingActivityCount() }
    }
    var pendingMemoryProposalsCount: Int {
        memoryProposals.filter { $0.status == "pending" }.count
    }

    // PATCH-2026-05-08: wave3 Feature A/B state
    var healthCard: HealthCard?
    var whatsRunning: WhatsRunning?
    @ObservationIgnored var healthCardRefreshGate = LatestSnapshotRefreshGate()
    @ObservationIgnored var whatsRunningRefreshGate = LatestSnapshotRefreshGate()

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
        approvals.filter { $0.status.lowercased() == "pending" }.count
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
        inboxItems.filter { $0.isActivityPending && $0.isForYouLane }.count
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
    /// collections (`approvals`, `inboxItems`, `memoryProposals`,
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
    /// fires from a tab other than Activity, ActivityView is not yet mounted
    /// and its `.onReceive(.openActivitySectionRequest)` cannot observe the
    /// notification. ContentView stashes the target section here before
    /// switching tabs; ActivityView consumes + clears it on `.task`. The
    /// notification path still works when Activity is already the active tab.
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
            MacSyncEngine.shared.requestChatSnapshotPublication(includeTranscripts: false)
        }
    ) {
        // Earlier builds mirrored the secure-field draft into UserDefaults.
        // The canonical Telegram config is the sole durable credential owner;
        // discard that legacy plaintext draft on the first current launch.
        UserDefaults.standard.removeObject(forKey: "telegramToken")
        self.dataRootOverride = dataRootOverride
        self.backgroundLoopsManager = backgroundLoopsManager
        self.activeChatSessionIDWriter = activeChatSessionIDWriter
        self.chatSnapshotPublisher = chatSnapshotPublisher
        guard startBackgroundTasks else { return }
        Task { @MainActor in await self.refreshSurfacePickerCache() }
        pollScheduler.bind(to: self)
    }

    var client: NativeClient {
        NativeClient(
            baseURL: nativeBaseURL,
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

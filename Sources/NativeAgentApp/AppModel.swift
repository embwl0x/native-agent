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
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import ToolExecution
import PersonaEngine
import ChatTurnRuntime
import ChatToolRuntime
import ChatSessionWork
import TrustCenter
import DreamREMCycle
import DoctorChecks
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
import MacIntegration
import WorkflowOrchestration
import Connectors
import Browser
import DeviceSync
import SchedulerExecution
import TrustPersistence
// Blueprint: | `AppModel.swift` | `AppModel`: app composition, UI/editor state and engine access; provider, persona, configuration and run state derive from engine owners; connector rows derive from `engine.connectors.accounts`; inbox actions receive `engine.inbox`; shared chat draft/session and surface command coordination |

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
@Observable
final class AppModel: Sendable {
    // Unfinished edits belong to their subject, across every presentation.
    // Memory only. Never put credentials here; secure fields stay view-local.
    private var editDrafts: [String: (value: Any, baseline: Any)] = [:]

    func editDraft<Value>(_ subject: String, seed: @autoclosure () -> Value) -> Value {
        (editDrafts[subject]?.value as? Value) ?? seed()
    }

    func editDraftBaseline<Value>(_ subject: String, seed: Value) -> Value {
        (editDrafts[subject]?.baseline as? Value) ?? seed
    }

    func setEditDraft<Value>(_ value: Value, for subject: String, baseline: Value? = nil) {
        editDrafts[subject] = (value, editDrafts[subject]?.baseline ?? baseline ?? value)
    }

    /// An accepted save: the draft goes, or, edited again while it saved, it
    /// now builds on what was saved, so its next merge cannot undo the edit.
    func acceptEditDraft<Value: Equatable>(_ subject: String, submitted: Value, saved: Value) {
        guard let held = editDrafts[subject] else { return }
        if (held.value as? Value) == submitted { editDrafts[subject] = nil }
        else { editDrafts[subject] = (held.value, saved) }
    }

    /// Keep only edits made while this save was in flight, based on the saved
    /// generation. Carrying the whole old draft would resurrect unrelated fields.
    func acceptEditDraft<Value: Codable & Equatable>(_ subject: String, submitted: Value, rebasingOn saved: Value) throws {
        guard let pending = editDrafts[subject]?.value as? Value else { return }
        if pending == submitted { editDrafts[subject] = nil }
        else {
            let rebased = try mergingEditDraft(subject, edited: pending, into: saved, baseline: submitted)
            editDrafts[subject] = (rebased, saved)
        }
    }

    func mergingEditDraft<Value: Codable>(_ subject: String, edited: Value, into current: Value, baseline originalBaseline: Value? = nil) throws -> Value {
        guard let original = originalBaseline ?? (editDrafts[subject]?.baseline as? Value) else { return current }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        func fields(_ value: Value) throws -> [String: JSONValue] {
            try decoder.decode([String: JSONValue].self, from: encoder.encode(value))
        }
        let baseline = try fields(original)
        let changes = try fields(edited)
        var merged = try fields(current)
        for key in Set(baseline.keys).union(changes.keys) where baseline[key] != changes[key] {
            merged[key] = changes[key]
        }
        return try decoder.decode(Value.self, from: encoder.encode(merged))
    }

    func editBinding<Value>(_ subject: String, seed: @autoclosure @escaping () -> Value) -> Binding<Value> {
        Binding(get: { self.editDraft(subject, seed: seed()) },
                set: { self.setEditDraft($0, for: subject) })
    }

    func clearEditDraft(_ subject: String) {
        editDrafts.removeValue(forKey: subject)
    }

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
    // Telegram settings actually save when toggled. Research reads engine configuration.
    var searxngBaseURL: String { engine.configuration.searxngBaseURL }

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

    /// Only an unsaved picker edit is local; saved choices belong to providers.
    var pendingChatBrainSelection: ProvidersFacade.ChatBrainSelection?
    var chatModel: String {
        get { pendingChatBrainSelection?.model ?? engine.providers.selection(for: "chat").model }
        set { var draft = currentChatBrainSelection; draft.model = newValue; pendingChatBrainSelection = draft }
    }
    var chatReasoningEffort: String {
        get { pendingChatBrainSelection?.reasoningEffort ?? engine.providers.selection(for: "chat").reasoningEffort }
        set { var draft = currentChatBrainSelection; draft.reasoningEffort = newValue; pendingChatBrainSelection = draft }
    }
    var chatFastMode: Bool {
        get { pendingChatBrainSelection?.fastMode ?? engine.providers.selection(for: "chat").fastMode }
        set { var draft = currentChatBrainSelection; draft.fastMode = newValue; pendingChatBrainSelection = draft }
    }

    var chatFileAccess: String = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto" {
        didSet { UserDefaults.standard.set(chatFileAccess, forKey: "chatFileAccess") }
    }

    var pendingTelegramModel: String?
    var pendingTelegramReasoningEffort: String?
    var telegramModel: String {
        get { pendingTelegramModel ?? engine.providers.selection(for: "telegram").model }
        set { pendingTelegramModel = newValue }
    }
    var telegramReasoningEffort: String {
        get { pendingTelegramReasoningEffort ?? engine.providers.selection(for: "telegram").reasoningEffort }
        set { pendingTelegramReasoningEffort = newValue }
    }

    @MainActor
    func refreshProviderPresentation() async {
        if case .failed(let detail) = await engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
            setFailureStatus(detail, cause: ProviderRoutingError.underlying(detail))
        }
    }

    /// Last checked form values, used only to preserve unsaved UI edits.
    var telegramSettingsDraftBaseline: TelegramSettingsDraftSnapshot?
    @ObservationIgnored let telegramSettingsRead = LatestRead()
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

    var supportDiagnostics: SupportDiagnostics?
    /// Support Snapshot has its own bounded read pass. Keep its progress
    /// separate from Doctor so its button can be honest about a snapshot that
    /// is loading, unavailable, or failed.
    var supportDiagnosticsLoading = false
    var capabilityCatalogSourceSaveInFlight = false
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
    /// Memory hygiene learns the name she goes by, so a fact "about Agent" is
    /// kept out of the user's profile whatever the persona is called. Called
    /// after Mac profile loads and saves; a `didSet` on an @Observable stored
    /// property took the chat room down (2026-09-02), so it is explicit.
    func teachMemoryHygieneName(previousName: String?) {
        engine.memory.teachAssistantName(engine.persona.profile)
        if previousName != engine.persona.profile?.name { NativeAgentShortcuts.updateAppShortcutParameters() }
        // Every sentence about the agent, wherever it is built, speaks in
        // the persona's name and the chosen pronoun.
        AgentVoice.live = AgentVoice.current(name: agentDisplayName)
    }
    /// Toolbar-specific single-flight state. Navigation may still perform its
    /// own scoped load, but repeated user taps cannot launch concurrent Tools
    /// refreshes that race to overwrite the visible receipt.
    var isRefreshingTools = false
    var toolsRefreshState: ToolsRefreshPresentation.State = .idle
    var routePlan: IntentRoutePlan?
    var routePresentation: IntentRoutePresentation = .idle
    /// Shared by every mounted approval surface. This is UI coordination only;
    /// the ApprovalInbox actor remains the durable terminal-decision authority.
    var approvalResolutionInFlightIDs: Set<String> = []
    var graphSearchResults: [GraphSearchResult] = []
    @ObservationIgnored let graphSearchRead = LatestRead()
    @ObservationIgnored let capabilityUpdatesRead = LatestRead()
    @ObservationIgnored let capabilityEvaluationRead = LatestRead()
    var capabilityCatalogInstallOutcome: CapabilityCatalogInstallOutcome?
    /// The signed demo action performs a multi-store durable install. Keep the
    /// mounted control single-flight so a second click cannot race the
    /// signature gate or make two receipts look like one successful install.
    var isInstallingDemoCapabilityPack = false
    var latestCapabilityTrustEvaluation: CapabilityTrustEvaluation?
    var latestCapabilityUpdateCheck: CapabilityUpdateCheck?
    var isRunningNextGenAction = false
    var latestMemoryHygiene: MemoryHygieneReport?
    /// F2: when a memory feature throws/returns a `not_implemented` /
    /// `panelDisabled` envelope, the UI surfaces this badge instead of a
    /// success toast or red error. Cleared on the next successful run.
    var memoryFeatureDisabledMessage: String?
    /// W3 (eval5): generalised version of `memoryFeatureDisabledMessage` for
    /// non-memory panels (workflow run, eval run, capability pack install,
    /// etc.). When a Swift-native implementation is
    /// deliberately unavailable, the underlying call throws
    /// `NativeActionRouteSupport.notImplemented(...)` with a
    /// `panelDisabled` userInfo flag; AppModel converts that into this
    /// human-readable message so the UI can render a small orange badge
    /// instead of a fake success toast or a red error. Cleared by the next
    /// successful action on the affected panel.
    var disabledFeature: String?
    /// The last action initiated on the Trust surface. Unlike `statusText`, it
    /// cannot be overwritten by refreshes or work from another surface.
    var trustCenterActionOutcome: TrustCenterActionOutcome?
    var isSavingChatBrain: Bool {
        get { engine.providers.isSavingChatBrain }
        set { engine.providers.isSavingChatBrain = newValue }
    }
    var chatProvider: String { engine.providers.selection(for: "chat").provider }
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
        let profileName = (engine.persona.profile?.name ?? engine.memory.cachedAgentDisplayName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        NativeAgentIdentity.displayName(engine.persona.profile?.name ?? engine.memory.cachedAgentDisplayName ?? chatPersona, fallback: "The agent")
    }
    // PATCH-2026-05-06: skill-ui AppModel state — skill lifecycle registry
    var isLoadingSkillManifests = false
    var skillManifestError: String?
    /// Event-identified feedback for the mounted Skill Lifecycle banner/toast.
    var skillLifecycleFeedback: SkillLifecycleFeedback?

    /// The miss ledger, this week and last: the Self-Improvement page's first section.
    var missLessons: [MemoryMissLesson] = []
    @ObservationIgnored let missLessonsRead = LatestRead()
    var dreamError: String?
    var pendingMemoryProposalsCount: Int {
        engine.memory.proposals.filter { $0.status == "pending" }.count
    }

    // PATCH-2026-05-08: wave3 Feature A/B state

    @ObservationIgnored var chatComposerDrafts: [String: ChatComposerDraft] = [:]
    var chatPendingAttachments: [String: [MultimodalAttachment]] = [:]

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
            publishWorkStatus: { [weak self] in await self?.publishWorkStatus() },
            policyChanged: { [weak self] in
                guard let self, let policy = engine.trust.policy else { return }
                let syncedMode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: chatFileAccess)
                if chatFileAccess != syncedMode { chatFileAccess = syncedMode }
            },
            memoryProposalsChanged: { [weak self] in
                guard let self else { return }
                if let reminder = engine.memory.reviewReminder(pending: pendingMemoryProposalsCount, agentName: agentDisplayName) {
                    NativeAgentNotifications.post(title: reminder.title, body: reminder.body)
                }
            }
        )
        guard startBackgroundTasks else { return }
        Task { @MainActor in await self.refreshProviderPresentation() }
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
    func recordRefreshFailure(_ label: String, error: Error) {
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

@MainActor
extension AppModel {
    @MainActor
    @discardableResult
    func refreshSchedulerJobs() async -> SchedulerJobsFeedState? {
        let feed = await engine.desk.refreshJobs()
        if let detail = feed?.failureDetail { statusText = detail }
        return feed
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
    func createWorkshopTask(title: String, objective: String) async -> Bool {
        do {
            _ = try await NativeAgentEngine.submitDeskTask(title: title, objective: objective)
            statusText = NewDeskTaskPresentation.successStatus
            await refreshAll()
            return true
        } catch {
            setFailureStatus(NewDeskTaskPresentation.failureStatus(UserFacingError.cause(error, action: "create the Desk task")), cause: error)
            return false
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
            engine.trust.publishPolicy(nil)
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
    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String? = nil) {
        engine.trust.publishPolicy(policy)
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

    /// The backup, or nil; either way `statusText` carries the receipt.
    @MainActor
    @discardableResult
    func createBackup(reason: String) async -> BackupRecord? {
        let receipt: String
        var cause: String?
        var created: BackupRecord?
        do {
            let backup = try await TrustBackupPersistence.createBackup(
                reason: reason, dataRoot: firstRunDataRoot, host: .app
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
        let outcome: TrustCenterActionOutcome
        var cause: String?
        do {
            let result = try await TrustBackupPersistence.restoreBackup(
                id: backup.id, dataRoot: firstRunDataRoot, host: .app
            )
            if result.requiresRestart {
                statusText = "Restore validated and staged. NativeAgent is restarting to install the backup and carry only readable current requests and consumption evidence. A turn in progress when the backup was taken is restored as stopped; nothing from the backup runs on its own."
                trustCenterActionOutcome = .saved(statusText)
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
            outcome = .saved(receipt)
        } catch {
            receipt = "Restore failed for \"\(backup.reason)\" from \(backup.createdAt). "
                + UserFacingError.cause(error, action: "restore that backup")
            cause = error.localizedDescription
            outcome = .failed(receipt)
        }
        await refreshBackupList(preserving: receipt, cause: cause)
        trustCenterActionOutcome = outcome
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
        guard engine.providers.settings != nil, !engine.providers.hasReadyConnection else { return nil }
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
                case .saved:
                    self.pendingChatBrainSelection = nil
                    self.statusText = result.userMessage
                    self.publishProviderCatalogStatusAfterBrainSave()
                case .unchanged:
                    self.pendingChatBrainSelection = nil
                    self.statusText = result.userMessage
                case .failed:
                    self.pendingChatBrainSelection = nil
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
        if case .failed(_, nil) = result { statusText = result.userMessage }
        return result
    }

    private var currentChatBrainSelection: ProvidersFacade.ChatBrainSelection {
        .init(model: chatModel, reasoningEffort: chatReasoningEffort, fastMode: chatFastMode)
    }

    private func publishProviderCatalogStatusAfterBrainSave() {
        Task {
            _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus()
        }
    }

    /// Refresh the engine's checked provider presentation for every door.
    @MainActor
    @discardableResult
    func loadProvidersForChat() async -> Bool {
        switch await engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
        case .loaded:
            Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
            return true
        case .failed: return false
        }
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
        case .failed(let message, _):
            return "Couldn't save the model choice. \(message)"
        }
    }

    /// What the agent's tool result says: the same line plus the raw cause.
    var agentMessage: String {
        if case .failed(_, let cause) = self { return UserFacingError.forAgent(userMessage, cause: cause) }
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
    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMacIntegrationPreset(preset, currentPolicy: currentPolicy)
    }

    /// Overload of the existing `runConnectorAction(_:)` for the id/dryRun/input
    /// call shape used by the Mac-data probe.
    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue] = [:]) async throws -> ConnectorActionReceipt {
        try await engine.runConnectorAction(id: id, dryRun: dryRun, input: input,
            origin: "mac_ui:connector_action:" + id, platform: AppConnectorActionPlatform(engine: engine))
    }

    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        comparedTo baseline: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot)
            .saveMacControlPolicy(policy, comparedTo: baseline, guardedByLockedPolicy: guardedByLockedPolicy)
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
        try await engine.clearSurfaceOverride(surface: surface)
    }

    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String? = nil, model: String? = nil,
        reasoningEffort: String? = nil, serviceTier: String? = nil, clearOverride: Bool = false
    ) async throws -> ProviderGroupWriteResult {
        try await engine.saveProviderGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride
        )
    }

    func configureSurfaceSelection(
        surface: String, providerID: String, model: String, reasoningEffort: String, serviceTier: String?
    ) async throws -> ModelCatalogResponse {
        try await engine.configureSurfaceSelection(
            surface: surface, providerID: providerID, model: model,
            reasoningEffort: reasoningEffort, serviceTier: serviceTier
        )
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
        try await InboxCardActions.perform(id, action: action, dataRootOverride: dataRootOverride, effects: AppInboxCardActionEffects(inbox: engine.inbox))
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

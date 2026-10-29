import EngineRuntime
import AttentionRouting
import DoctorChecks
import Foundation
import WidgetKit
import AppIntents
import Observation
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ProviderRouting
import BackgroundLoops
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
import TrustCenter
import MultimodalTTS
import SystemOps
import TelegramBot
import DeviceSync
import ApprovalTransactions
import Privacy
import Darwin
import AppKit
@preconcurrency import EventKit
import ToolRegistry
import ApprovalInbox
import ToolExecution
import ChatToolRuntime
import DreamREMCycle
import Research
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import ScreenVision
import Dispatcher
import MacControl
import Onboarding
import MacIntegration
import Connectors
import Browser
import SchedulerExecution
import TrustPersistence
// Blueprint: | `AppModel.swift` | `AppModel`: app composition and UI/editor state; canonical state derives from engine owners; shared draft/session storage and surface presentation |

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
    let backgroundLoopsManager: BackgroundLoopLifetimes = .shared

    // Search configuration belongs to the engine; this property only reads its projection.
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
    var pendingChatBrainSelection: ProviderTurnChoice?
    var chatModel: String {
        get { pendingChatBrainSelection?.model ?? engine.providers.selection(for: "chat").model }
        set { pendingChatBrainSelection = .init(provider: chatProvider, model: newValue, reasoningEffort: chatReasoningEffort, fast: chatFastMode) }
    }
    var chatReasoningEffort: String {
        get { pendingChatBrainSelection?.reasoningEffort ?? engine.providers.selection(for: "chat").reasoningEffort }
        set { pendingChatBrainSelection = .init(provider: chatProvider, model: chatModel, reasoningEffort: newValue, fast: chatFastMode) }
    }
    var chatFastMode: Bool {
        get { pendingChatBrainSelection?.fast ?? engine.providers.selection(for: "chat").fast }
        set { pendingChatBrainSelection = .init(provider: chatProvider, model: chatModel, reasoningEffort: chatReasoningEffort, fast: newValue) }
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
    /// One observer per model; reload write-backs cannot re-enter themselves.
    @ObservationIgnored nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored var reloadingDefaults = false

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
    // The chat opens on the conversation it was left on, so the transcript is
    // built once, with its own identity, from the first frame; startup still
    // resolves it against live direct rows and moves only if it is gone.
    var activeChatSessionId: String = UserDefaults.standard.string(forKey: "activeChatSessionId") ?? "" {
        didSet {
            if activeChatSessionId.isEmpty { UserDefaults.standard.removeObject(forKey: "activeChatSessionId") }
            else { UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId") }
            guard activeChatSessionId != oldValue else { return }
            scrollMoveLog("session.active %@ -> %@", String(oldValue.suffix(12)), String(activeChatSessionId.suffix(12)))
            MacChatUnreadSessions.shared.markRead(activeChatSessionId)
            NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: true)
        }
    }
    /// The active session's loaded transcript (`engine.transcripts`).
    var chatMessages: [ChatMessage] {
        get { engine.transcripts.messages(for: activeChatSessionId) }
        set { engine.transcripts.setMessages(newValue, for: activeChatSessionId) }
    }
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
    @ObservationIgnored var panelRefreshReads: [SidebarItem: LatestRead] = [:]
    /// Pending scoped reads, counted so overlapping readers keep their signal.
    var panelRefreshCounts: [SidebarItem: Int] = [:]
    /// Compact readers keep independent freshness from full-page refreshes.
    var sidebarActivityRefreshStatus: PanelRefreshStatus?
    var detachedChatRefreshStatus: [String: PanelRefreshStatus] = [:]

    /// Set by `performLoadChatState` when the chat message/session fetch threw.
    /// Folded into the `.chat` panel's failed-endpoint list.
    var chatStateLoadFailed = false
    /// The event-driven session-index read failed, so shared Mac projections
    /// are retaining their last proven rows until the next canonical edge.
    var chatSessionIndexRefreshFailed = false

    /// Either failed session read dims retained sidebar rows.
    var chatSidebarSessionListOpacity: Double {
        chatStateLoadFailed || chatSessionIndexRefreshFailed ? 0.55 : 1
    }

    /// Only a successful active-transcript load clears both sidebar failure flags.
    func markChatSidebarLoadSucceeded() {
        chatStateLoadFailed = false
        chatSessionIndexRefreshFailed = false
    }

    var supportDiagnostics: SupportDiagnostics?
    /// Support Snapshot tracks its own bounded read independently of Doctor.
    var supportDiagnosticsLoading = false
    var capabilityCatalogSourceSaveInFlight = false
    /// The live engine owns canonical state; memory pages observe `engine.memory`.
    @ObservationIgnored let engine: NativeAgentEngine
    @ObservationIgnored private let workStatusPublication = WorkStatusPublication()
    /// The immutable Mac chat client shares the engine’s owners and per-turn effect gates.
    @ObservationIgnored lazy var macChatClient = engine.chatClient(profile: .mac)
    /// Explicitly publish the persona name after profile loads/saves so memory separates agent and user facts.
    func teachMemoryHygieneName(previousName: String?) {
        engine.memory.teachAssistantName(engine.persona.profile)
        if previousName != engine.persona.profile?.name { NativeAgentShortcuts.updateAppShortcutParameters() }
        // Every sentence about the agent, wherever it is built, speaks in
        // the persona's name and the chosen pronoun.
        AgentVoice.live = AgentVoice.current(name: agentDisplayName)
    }
    /// Repeated Tools refresh clicks share one toolbar operation and receipt.
    var isRefreshingTools = false
    var toolsRefreshState: ToolsRefreshPresentation.State = .idle
    var graphSearchResults: [GraphSearchResult] = []
    @ObservationIgnored let graphSearchRead = LatestRead()
    @ObservationIgnored let capabilityEvaluationRead = LatestRead()
    var latestCapabilityTrustEvaluation: CapabilityTrustEvaluation?
    /// The last action initiated on the Trust surface. Unlike `statusText`, it
    /// cannot be overwritten by refreshes or work from another surface.
    var trustCenterActionOutcome: TrustCenterActionOutcome?
    var isSavingChatBrain: Bool { engine.providers.isSavingChatBrain }
    var chatProvider: String { pendingChatBrainSelection?.provider ?? engine.providers.selection(for: "chat").provider }
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
    /// Desk consumes the requested handle once its rows have loaded.
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
    // Refresh failure details exposed to the status surface.
    var lastRefreshError: String? = nil
    @ObservationIgnored let firstRunWelcomeTransaction = FirstRunWelcomeTransaction()
    var chatTurnLifecycleRepairCompleted: Bool {
        get { engine.turns.runtime.chatTurnLifecycleRepairCompleted }
        set { engine.turns.runtime.chatTurnLifecycleRepairCompleted = newValue }
    }
    var chatSelectionGeneration = 0

    /// Normalized persona selection persists through PersonaSelection and notifies context flow.
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

    /// Address surfaces show "The agent" for the unnamed seed; agentDisplayName preserves the profile name.
    var agentAddressName: String {
        NativeAgentIdentity.displayName(engine.persona.profile?.name ?? engine.memory.cachedAgentDisplayName ?? chatPersona, fallback: "The agent")
    }
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

    @ObservationIgnored var chatComposerDrafts: [String: ChatComposerDraft] = [:]
    var chatPendingAttachments: [String: [MultimodalAttachment]] = [:]

    /// ContentView holds the requested section across navigation; Today consumes and clears it on appear.
    var pendingActivitySectionRaw: String? = nil

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    init() {
        // Telegram config owns credentials; remove any plaintext UserDefaults draft.
        UserDefaults.standard.removeObject(forKey: "telegramToken")
        self.engine = .live
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
        Task { @MainActor in await self.refreshProviderPresentation() }
        // Every Desk write in this process re-reads the overview, so a new
        // owner wait counts and pushes whether or not phone sync is on.
        Task { [weak self] in
            for await change in StoreChangeBus.shared.changes() where change.store == .desk {
                guard let self else { return }
                await publishWorkStatus()
            }
        }
    }

    func publishChatSnapshot() {
        NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
    }

    var refreshAllInFlight = false
    var refreshAllQueued = false
    // Retain every labeled authority-read failure until the next refresh pass.
    var refreshAllFailureDetails: [String] = []
    var isRecordingRefreshAllFailures = false

    /// Record labeled refresh failures before returning nil.
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
            reloadWidget: {
                if #available(macOS 27, *) {
                    WidgetCenter.shared.reloadTimelines(ofKind: NativeAgentWidgetSnapshot.kind)
                }
            })
    }
}

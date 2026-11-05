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
// Blueprint: | `AppModel.swift` | `AppModel`: Composition, shared drafts and owner-derived UI state |

@MainActor
@Observable
final class AppModel: Sendable {
    // Edits belong to their subject across presentations; keep credentials view-local and out of shared drafts.
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

    /// After save, retain only newer edits rebased on the saved generation so a later merge cannot undo them.
    func acceptEditDraft<Value: Equatable>(_ subject: String, submitted: Value, saved: Value) {
        guard let held = editDrafts[subject] else { return }
        if (held.value as? Value) == submitted { editDrafts[subject] = nil }
        else { editDrafts[subject] = (held.value, saved) }
    }

    /// Carry only edits made during the save; the full old draft would resurrect unrelated fields.
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

    /// Use the shared toast center so feedback appears in the one notice lane.
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

    /// Keep credential drafts in secure fields until explicit save; never mirror typing into UserDefaults.
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

    /// Only unsaved picker edits are local; saved choices belong to providers.
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

    /// Retain checked form values only to preserve unsaved edits.
    var telegramSettingsDraftBaseline: TelegramSettingsDraftSnapshot?
    @ObservationIgnored let telegramSettingsRead = LatestRead()
    /// One observer per model and a re-entry guard prevent reload write-back loops.
    @ObservationIgnored nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored var reloadingDefaults = false

    var telegramEnabled = false
    var isSavingTelegram = false
    /// Keep the Telegram receipt separate because unrelated refreshes can replace statusText.
    var telegramSettingsSaveOutcome: TelegramSettingsSaveOutcome?
    var isTestingTelegram = false
    var isClearingTelegramLogs = false
    var telegramClearLogsOutcome: TelegramClearLogsPresentation.Outcome?
    /// Failed refreshes retain the last readable receipt and mark it stale instead of claiming a current read.
    var telegramStatusRefreshError: String?
    // Build the transcript with its saved identity from the first frame; startup then resolves it against live direct rows.
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
    var chatMessages: [ChatMessage] { engine.transcripts.messages(for: activeChatSessionId) }
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

    /// Only refreshForSidebarItem writes panel outcomes so views share the same freshness receipt.
    var panelRefreshStatus: [SidebarItem: PanelRefreshStatus] = [:]
    @ObservationIgnored var panelRefreshReads: [SidebarItem: LatestRead] = [:]
    /// Count overlapping reads so one completion cannot hide another pending read.
    var panelRefreshCounts: [SidebarItem: Int] = [:]
    /// Compact readers need freshness independent of full-page refreshes.
    var sidebarActivityRefreshStatus: PanelRefreshStatus?
    @ObservationIgnored let sidebarActivityRead = LatestRead()
    /// Offscreen reads must not consume a selected identity awaiting its live page.
    var pendingPaletteDestination: PaletteSavedDestination?
    var pendingMemoryFaceTarget: MemoriesFaceTarget?
    var detachedChatRefreshStatus: [String: PanelRefreshStatus] = [:]

    /// Fold transcript fetch failures into the chat panel's failed-endpoint list.
    var chatStateLoadFailed = false
    /// Retain proven session-index rows after failure until the next canonical edge.
    var chatSessionIndexRefreshFailed = false

    /// Either failed session read must dim retained sidebar rows.
    var chatSidebarSessionListOpacity: Double {
        chatStateLoadFailed || chatSessionIndexRefreshFailed ? 0.55 : 1
    }

    /// Only a successful active-transcript load may clear both sidebar failure flags.
    func markChatSidebarLoadSucceeded() {
        chatStateLoadFailed = false
        chatSessionIndexRefreshFailed = false
    }

    var supportDiagnostics: SupportDiagnostics?
    /// Support Snapshot must not share Doctor's read state.
    var supportDiagnosticsLoading = false
    /// Observe engine.memory because the live engine owns canonical memory state.
    @ObservationIgnored let engine: NativeAgentEngine
    @ObservationIgnored private let workStatusPublication = WorkStatusPublication()
    /// Share engine owners and per-turn effect gates through the immutable Mac client.
    @ObservationIgnored lazy var macChatClient = engine.chatClient(profile: .mac)
    /// Publish the persona name after profile reads and saves so memory distinguishes agent and user facts.
    func teachMemoryHygieneName(previousName: String?) {
        engine.memory.teachAssistantName(engine.persona.profile)
        if previousName != engine.persona.profile?.name { NativeAgentShortcuts.updateAppShortcutParameters() }
        // Build agent-facing identity from the persona's name and chosen pronoun.
        let name = agentDisplayName
        if !name.isEmpty { AgentVoice.live = AgentVoice.current(name: name) }
    }
    /// Repeated Tools refreshes must share one operation and receipt.
    var isRefreshingTools = false
    var toolsRefreshState: ToolsRefreshPresentation.State = .idle
    /// Keep Trust feedback separate so another surface or refresh cannot overwrite it.
    var trustCenterActionOutcome: TrustCenterActionOutcome?
    var isSavingChatBrain: Bool { engine.providers.isSavingChatBrain }
    var chatProvider: String { pendingChatBrainSelection?.provider ?? engine.providers.selection(for: "chat").provider }
    /// A new status retires the previous raw cause.
    var statusText: String = "Not checked" {
        didSet { statusCause = nil }
    }
    /// Keep the raw cause in agent-facing results while the user's screen shows the plain status line.
    var statusCause: String?
    var statusForAgent: String {
        UserFacingError.forAgent(statusText, cause: statusCause)
    }

    /// Preserve the raw cause for the agent while the user sees a plain failure line.
    func setFailureStatus(_ error: Error, action: String) {
        setFailureStatus(UserFacingError.message(error, action: action), cause: error)
    }

    func setFailureStatus(_ line: String, cause error: Error) {
        statusText = line
        statusCause = error.localizedDescription
    }
    /// Navigation shares the Desk owner's selected identity; the face resolves it when its rows arrive.
    var pendingDeskHandle: String? {
        get { engine.desk.faceItem }
        set { engine.desk.faceItem = newValue }
    }
    /// Retain a message locator until ChatView can reveal it.
    var pendingChatMessageID: String?
    /// Retain repeated identical tool failures as distinct bounded receipts rather than transient status.
    var toolOperationStatusReceipts: [ToolOperationStatusReceipt] = []
    var lastRefreshError: String? = nil
    @ObservationIgnored let firstRunWelcomeTransaction = FirstRunWelcomeTransaction()
    var chatTurnLifecycleRepairCompleted: Bool {
        get { engine.turns.runtime.chatTurnLifecycleRepairCompleted }
        set { engine.turns.runtime.chatTurnLifecycleRepairCompleted = newValue }
    }
    var chatSelectionGeneration = 0

    /// Persist persona selection through its owner so context flow is notified.
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
    var agentDisplayName: String { engine.persona.displayName }

    /// Address and display names must share the persona owner's availability.
    var agentAddressName: String { agentDisplayName }
    var isLoadingSkillManifests = false
    var skillManifestError: String?
    var skillLifecycleFeedback: SkillLifecycleFeedback?

    var missLessons: [MemoryMissLesson] = []
    @ObservationIgnored let missLessonsRead = LatestRead()
    var dreamError: String?
    var pendingMemoryProposalsCount: Int {
        engine.memory.proposals.filter { $0.status == "pending" }.count
    }

    @ObservationIgnored var chatComposerDrafts: [String: ChatComposerDraft] = [:]
    var chatPendingAttachments: [String: [MultimodalAttachment]] = [:]

    /// Retain the requested section across navigation until Today consumes it.
    var pendingActivitySectionRaw: String? = nil
    var diagnosticsRunID: String?

    @ObservationIgnored private var settingsFaceUpdates: SettingsFaceUpdates?

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    init() {
        self.engine = .live
        settingsFaceUpdates = SettingsFaceUpdates(self)
        bindDiagnosticsFace()
        engine.bindResidentPresentation(
            publishWorkStatus: { [weak self] in await self?.publishWorkStatus() },
            policyChanged: { [weak self] in
                guard let self, let policy = engine.trust.policy else { return }
                let syncedMode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: chatFileAccess)
                if chatFileAccess != syncedMode { chatFileAccess = syncedMode }
            },
            memoryProposalsChanged: { [weak self] in
                guard let self else { return }
                NativeAgentNotifications.postMemoryReview(pending: pendingMemoryProposalsCount, agentName: agentDisplayName)
            }
        )
        Task { @MainActor in await self.refreshProviderPresentation() }
        // Re-read Desk after every local write so owner waits publish even with phone sync off.
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

    /// Record the labeled failure before returning nil.
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

// MARK: - Diagnostics face

extension AppModel {
    @MainActor func bindDiagnosticsFace() {
        engine.bindDiagnosticsFace { [weak self] action, checkID in
            guard let self else { throw PartCallError(code: "unattached", message: "Reopen NativeAgent to use Diagnostics.") }
            if action == "doctor.support_report" {
                switch await loadSupportDiagnostics() {
                case .unavailable(let reason): throw PartCallError(code: "support_unavailable", message: reason)
                case .loaded(let report, _):
                    return "Support report: \(report.app) \(report.version), health \(report.doctorStatus ?? "unknown"), made \(report.generatedAt)."
                        + " Ask me to export a support bundle for a file to send the developer."
                }
            }
            let repair = action == "doctor.repair"
            switch await runDoctor(repair: repair, repairScope: .button, checkID: checkID) {
            case .unavailable(let reason): throw PartCallError(code: "doctor_unavailable", message: reason)
            case .completed:
                guard let report = engine.doctor.report else {
                    throw PartCallError(code: "report_unavailable", message: "The completed run has no report. Run checks again.")
                }
                return repair ? DoctorFacade.repairCompletionMessage(report: report) : nil
            }
        }
    }
}

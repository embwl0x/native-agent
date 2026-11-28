import BodyRuntime
import Foundation
import WidgetKit
import AppIntents
import Observation
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MindCore
import ProviderRouting
import SenseCore
import DeskCore
import Darwin
import AppKit
@unsafe @preconcurrency import EventKit
import MacNerves
// Blueprint: | `AppModel.swift` | `AppModel`: Composition and owner-derived UI state |

@MainActor
@Observable
final class AppModel: Sendable {

    let systemToasts = SystemToastCenter.shared
    let backgroundLoopsManager: BackgroundLoopLifetimes = .shared


    /// Command reads include unsaved edits, then read the provider owner, never a delayed drawing frame.
    var pendingChatBrainSelection: ProviderTurnChoice?
    var chatModel: String {
        get { currentChatBrainSelection?.model ?? "" }
        set { stageChatBrainSelection(model: newValue) }
    }
    var chatReasoningEffort: String {
        get { currentChatBrainSelection?.reasoningEffort ?? "" }
        set { stageChatBrainSelection(reasoningEffort: newValue) }
    }
    var chatFastMode: Bool {
        get { currentChatBrainSelection?.fast == true }
        set { stageChatBrainSelection(fast: newValue) }
    }

    var chatFileAccess: String = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto" {
        didSet { UserDefaults.standard.set(chatFileAccess, forKey: "chatFileAccess") }
    }

    @MainActor
    func refreshProviderPresentation() async {
        if case .failed(let detail) = await engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
            setFailureStatus(detail, cause: ProviderRoutingError.underlying(detail))
        }
    }

    /// One observer per model and a re-entry guard prevent reload write-back loops.
    @ObservationIgnored nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored var reloadingDefaults = false

    var isClearingTelegramLogs = false
    var telegramClearLogsOutcome: TelegramClearLogsPresentation.Outcome?
    // Build the transcript with its saved identity from the first frame; startup then resolves it against live direct rows.
    var activeChatSessionId: String = UserDefaults.standard.string(forKey: "activeChatSessionId") ?? "" {
        didSet {
            if activeChatSessionId.isEmpty { UserDefaults.standard.removeObject(forKey: "activeChatSessionId") }
            else { UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId") }
            guard activeChatSessionId != oldValue else { return }
            MacChatUnreadSessions.shared.markRead(activeChatSessionId)
            NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: true)
        }
    }
    var chatMessages: [ChatMessage] { engine.transcripts.displayedTranscript(for: activeChatSessionId).messages }

    /// Fold transcript fetch failures into the chat panel's failed-endpoint list.
    var chatStateLoadFailed = false

    /// Transcript loading owns its failure; the session index settles its own read status.
    func markChatSidebarLoadSucceeded() {
        chatStateLoadFailed = false
    }

    /// Support Snapshot must not share Doctor's read state.
    var supportDiagnosticsLoading = false
    /// Observe engine.memory because the live engine owns canonical memory state.
    @ObservationIgnored let engine: NativeAgentEngine
    /// The only agent state the window's views read as stage one moves them over: finished values her owners post, applied per frame.
    @ObservationIgnored let face: FaceFeed
    @ObservationIgnored private let displayFrame = DisplayFrame()
    @ObservationIgnored private let workStatusPublication = WorkStatusPublication()
    /// Share engine owners and per-turn effect gates through the immutable Mac client.
    @ObservationIgnored lazy var macChatClient = engine.chatClient(profile: .mac)
    /// Publish the persona name after profile reads and saves so memory distinguishes agent and user facts.
    func teachMemoryHygieneName(previousName: String?) {
        engine.memory.teachAssistantName(engine.persona.profile)
        if previousName != engine.persona.profile?.name { NativeAgentShortcuts.updateAppShortcutParameters() }
        // Build agent-facing identity from the persona's name and chosen pronoun.
        let name = engine.persona.displayName
        if !name.isEmpty { AgentVoice.live = AgentVoice.current(name: name) }
    }
    var isSavingChatBrain: Bool { engine.providers.isSavingChatBrain }
    var chatProvider: String { currentChatBrainSelection?.provider ?? "" }
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
    var lastRefreshError: String?
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
    var agentDisplayName: String { settingsPersonaDisplayName }


    var dreamError: String?

    @ObservationIgnored private var settingsFaceUpdates: SettingsFaceUpdates?

    deinit {
        if let defaultsObserver = unsafe defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    init() {
        self.engine = .live
        let displayFrame = displayFrame
        face = FaceFeed(source: engine.face, nextFrame: { await displayFrame.next() })
        settingsFaceUpdates = SettingsFaceUpdates(self)
        engine.bindDiagnosticsFace()
        engine.bindResidentPresentation(
            publishWorkStatus: { [weak self] in await self?.publishWorkStatus() },
            policyChanged: { [weak self] in
                guard let self, let policy = engine.trust.policy else { return }
                let syncedMode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: chatFileAccess)
                if chatFileAccess != syncedMode { chatFileAccess = syncedMode }
            },
            memoryProposalsChanged: { [weak self] in
                guard let self else { return }
                NativeAgentNotifications.postMemoryReview(pending: engine.memory.proposals.count, agentName: engine.persona.displayName)
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

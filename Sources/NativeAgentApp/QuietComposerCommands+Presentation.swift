import Foundation
import PersistenceCore
import TrustCenter
import Desk
import MultimodalTTS
import EngineRuntime
import ChatToolRuntime
import AppToolRuntime
import NativeAgentCore
import SwiftUI
import NativeAgentShared
import ProviderRouting
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
import MemoryV2
import ApprovalTransactions
import ToolRegistry
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import SystemOps
import DeviceSync
import BackgroundWork
import StandingBots
import ApprovalInbox
import AppKit
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
// Blueprint: | `QuietComposerCommands+Presentation.swift` | Quiet composer command port, checked routing projection and mounted-page effects |

extension QuietComposerCommands {
    static let cardNames = ChatComposerCard.allCases.map(\.rawValue)

    @MainActor
    struct Routing {
        let appModel: AppModel
        let sessionID: String
        init(appModel: AppModel, sessionID: String? = nil) {
            self.appModel = appModel; self.sessionID = sessionID ?? appModel.activeChatSessionId
        }
    }

    @MainActor
    fileprivate static func draft(_ sessionID: String, appModel: AppModel) -> String {
        appModel.chatDraft(for: sessionID)
    }

    private static func card(named raw: String) -> ChatComposerCard? {
        switch raw {
        case "effort", "thinking": return .effort
        case "receipt": return .context
        default: return ChatComposerCard(rawValue: raw)
        }
    }

    @MainActor
    fileprivate static func openCard(_ raw: String, appModel: AppModel) -> Outcome {
        guard let shell = QuietSelfAdmin.shared.composerCards else {
            return .refuse("composer pane", "composer_unavailable", "No composer is mounted.")
        }
        guard let card = card(named: raw) else {
            return .refuse(
                "composer pane", "unknown_card",
                "The composer panes are: " + cardNames.joined(separator: ", ") + "."
            )
        }
        let changed = shell.activePane != card
        guard shell.open(card) else {
            return .refuse("composer pane", "composer_unavailable", "That composer control is not mounted.")
        }
        return .done(
            "composer \(card.rawValue) pane",
            "The pane is open.",
            changed: changed
        )
    }

    @MainActor
    fileprivate static func closeCard() -> Outcome {
        guard let shell = QuietSelfAdmin.shared.composerCards else {
            return .refuse("composer pane", "composer_unavailable", "No composer is mounted.")
        }
        let was = shell.activePane?.rawValue
        shell.dismiss()
        return .done(
            "composer \(was ?? "shell") pane",
            was == nil ? "No pane was open." : "The pane is closed.",
            changed: was != nil
        )
    }

    @MainActor
    static func showPane(_ raw: String, ref: String) -> Outcome {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tab: WorkPaneTab
        switch key {
        case "steps": tab = .steps
        case "screen": tab = .screen
        case "make":
            let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            tab = .make(ref: ref.isEmpty ? nil : ref)
        default:
            return .refuse("Work pane", "unknown_view", "No Work pane view is called that. The views are: steps, screen, make.")
        }
        let mode = SimpleViewMode.resolved(UserDefaults.standard.string(forKey: SimpleViewMode.key) ?? "")
        guard mode == SimpleViewMode.advanced else {
            return .refuse("Work pane", "no_work_pane",
                           "\(mode.capitalized) view is on screen and has no Work pane, so nothing was opened.")
        }
        WorkPaneState.shared.agentShow(tab)
        // The pane lives on Chat; on another page User sees it when he goes back.
        let onChat = ApplicationLifetime.shared.currentPage?.item == .chat
        return .done("Work pane", "The Work pane is open on \(key)"
            + (onChat ? "." : ", but the person is on another page; they see it when they go back to Chat."))
    }

    static let sheets: [String: ActivitySection] = [
        "approvals": .approvals, "today_inbox": .inbox, "memory_proposals": .memoryProposals,
        "self_improvement": .selfImprovement,
    ]
    static let tabs: [String: (page: SidebarItem, tab: String)] = [
        "knowledge": (.memories, "knowledge"), "minds": (.personality, "minds"),
        "dreams": (.personality, "dreams"), "agents": (.connectors, "agents"),
        "doctor": (.diagnostics, DiagnosticsView.DiagnosticsMode.doctor.rawValue),
        "status": (.diagnostics, DiagnosticsView.DiagnosticsMode.status.rawValue),
        "runs": (.diagnostics, DiagnosticsView.DiagnosticsMode.runs.rawValue),
        "cognition": (.diagnostics, DiagnosticsView.DiagnosticsMode.cognition.rawValue),
        "inspector": (.diagnostics, DiagnosticsView.DiagnosticsMode.inspector.rawValue),
        "skills": (.diagnostics, "skills"), "tools": (.diagnostics, "tools"),
        "trust_access": (.trust, TrustTab.access.rawValue),
        "trust_features": (.trust, TrustTab.features.rawValue),
        "trust_mac_browser": (.trust, "mac"),
        "trust_advanced": (.trust, TrustTab.advanced.rawValue),
    ]

    /// Quiet delivery changes the mounted scene without activating a window.
    @MainActor
    static func setPage(
        _ raw: String, item: String, appModel: AppModel, coordinator: ApplicationLifetime = .shared
    ) async -> Outcome {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let destination: NativeAgentNavigationDestination
        let shown: SidebarItem
        var tab: String?
        var title = key
        if let section = sheets[key] {
            destination = .activity(section)
            shown = section == .memoryProposals ? .memories : .activity
        } else if let home = tabs[key] {
            (destination, shown, tab) = (.sidebar(home.page), home.page, home.tab)
        } else if let page = QuietPages.page(named: raw) {
            destination = .sidebar(page.item)
            shown = SidebarItem.shellHome(for: page.item)?.parent ?? page.item
            (tab, title) = (page.tab, page.id)
        } else {
            return .refuse(
                "rail", "unknown_page",
                "No page is called that. The pages are: " + QuietPages.ids.joined(separator: ", ")
                + ". Inside them: " + (Array(sheets.keys) + Array(tabs.keys)).sorted().joined(separator: ", ")
                + ". Value desk with a Desk item's handle in choice opens that item."
            )
        }
        let handle = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if !handle.isEmpty {
            guard shown == .desk else {
                return .refuse("Desk item", "item_needs_desk", "choice opens a Desk item, so pass value desk with it.")
            }
            do {
                guard try await appModel.engine.desk.store.liveState().items.contains(where: { $0.handle == handle }) else {
                    return .refuse("Desk item", "unknown_desk_item", "No Desk item has the handle \(handle). app desk.read lists the handles.")
                }
            } catch {
                return .refuse("Desk item", "desk_unreadable", "The Desk could not be read (\(error.localizedDescription)), so nothing was opened. Try again.")
            }
        }
        guard coordinator.deliverQuietly(destination) else {
            return .refuse(
                "rail", "no_mounted_window",
                "The main window is not mounted in this process, so the rail cannot be moved "
                + "without opening one — and opening one is not quiet."
            )
        }
        if let tab { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(shown)) }
        if !handle.isEmpty { appModel.pendingDeskHandle = handle }
        let leftSimple = SimpleViewMode.isShowing
        if leftSimple { UserDefaults.standard.set(SimpleViewMode.advanced, forKey: SimpleViewMode.key) }
        guard coordinator.currentPage?.item == shown else {
            return .refuse("rail", "page_not_shown", "The window has not switched to \(title).", effects: .unknown)
        }
        return .done(
            "rail row \"\(title)\"",
            "The window is now showing \(title)" + (handle.isEmpty ? "" : ", opening Desk item \(handle)")
                + (leftSimple ? ", in Advanced view (Simple view has no pages)." : ".")
        )
    }

}

extension AppModel: QuietComposerCommandPort {
    var quietComposerProviderGroups: [(id: String, provider: String, models: [ModelCatalogItem])] {
        QuietComposerCommands.Routing(appModel: self).providerGroups.map { ($0.id, $0.provider, $0.models) }
    }
    var quietComposerEfforts: [ReasoningEffortOption] { QuietComposerCommands.Routing(appModel: self).residentPresentation?.efforts ?? [] }
    var quietComposerSupportsFast: Bool { QuietComposerCommands.Routing(appModel: self).residentPresentation?.supportsFast == true }
    func quietComposerDraft(_ sessionID: String) -> String { QuietComposerCommands.draft(sessionID, appModel: self) }
    func quietComposerDraftRevision(_ sessionID: String) -> (Date, Int) {
        let draft = composerDraft(for: sessionID)
        return (draft.editedAt, Int(clamping: draft.manualEditRevision))
    }
    func setQuietComposerDraft(_ after: String, sessionID: String) {
        composerDraft(for: sessionID).edit(after)
    }
    func clearQuietAcceptedDraft(_ message: String, sessionID: String, editedAt: Date) {
        clearChatDraftAfterSend(message, sessionId: sessionID, editedAt: editedAt)
    }
    func quietComposerPaneClosed(turnID: String?) -> Bool { WorkPaneState.shared.userClosed(turnID: turnID) }
    func quietComposerPresentation(verb: String, value: String, choice: String) async -> QuietComposerOutcome {
        switch verb {
        case "open_card": return QuietComposerCommands.openCard(value, appModel: self)
        case "close_card": return QuietComposerCommands.closeCard()
        case "set_page": return await QuietComposerCommands.setPage(value, item: choice, appModel: self)
        case "show_browser":
            BrowserWindowController.shared.showWindow()
            return .done("Window > Browser", "The browser window is in front.")
        case "show_pane": return QuietComposerCommands.showPane(value, ref: choice)
        case "hide_pane":
            WorkPaneState.shared.agentHide()
            return .done("Work pane", "The Work pane is closed.")
        case "check_updates":
            let check = await UpdateController.shared.probeForUpdate()
            return check.refusal.map { .refuse("Check for Updates", $0.reason, $0.detail) }
                ?? .done("Check for Updates", check.detail, changed: false)
        default: preconditionFailure("Core requested an unknown composer presentation effect")
        }
    }
    func selectQuietComposerModel(_ model: ModelCatalogItem, provider: String) -> Task<String?, Never>? {
        QuietComposerCommands.Routing(appModel: self).select(model: model, provider: provider)
    }
    func saveQuietChatBrain() async -> (succeeded: Bool, agentMessage: String, reasoningEffort: String) {
        let result = await saveChatBrainDefaults()
        switch result {
        case .failed: return (false, result.agentMessage, chatReasoningEffort)
        case .saved(let selection), .unchanged(let selection): return (true, result.agentMessage, selection.reasoningEffort)
        }
    }
    func startQuietSpeech(_ text: String) async -> String? {
        let voice = VoiceOutputController.sharedMessagePlayback
        await voice.speak(text: text, policy: engine.trust.policy,
                          loadPolicy: { try await self.engine.trust.load() }, ownerID: "agent.speak")
        return voice.consumeError(ownerID: "agent.speak")
    }
    func writeQuietScratch(key: String, value: String, sessionId: String) async -> (succeeded: Bool, agentMessage: String) {
        let result = await writeScratch(key: key, value: value, sessionId: sessionId)
        return (result.succeeded, result.agentMessage)
    }
    func quietComposerPresentationState(sessionID: String) async -> [String: JSONValue] {
        let projection = await engine.providers.refreshSession(sessionID)
        let routing = QuietComposerCommands.Routing(appModel: self, sessionID: sessionID)
        var body: [String: JSONValue] = [
            "provider": .string(routing.routeChoice?.provider ?? ""), "model": .string(routing.routeChoice?.model ?? ""), "model_word": .string(routing.modelWord),
            "think": .string(routing.routeChoice?.reasoningEffort ?? ""), "think_word": .string(routing.effortWord),
            "think_choices": .array(routing.efforts.map { .string($0.id) }), "fast": .bool(routing.fastIsOn),
            "trust_word": .string(routing.trustWord), "persona": .string(chatPersona),
            "open_card": .string(QuietSelfAdmin.shared.composerCards?.activePane?.rawValue ?? "none"),
        ]
        if !sessionID.isEmpty, let status = projection.context {
            let usage = ContextFillPresentation.usage(status)
            body["ring_fraction"] = .double(usage.fillFraction)
            if let percent = Int64(exactly: usage.percent.rounded()) {
                body["ring_percent"] = .int(percent)
            } else {
                // Quiet composer readers accept text as well as integers.
                body["ring_percent"] = .string(String(format: "%.0f", usage.percent.rounded()))
            }
            body["context_used_tokens"] = .int(Int64(status.used_tokens))
            body["context_budget_tokens"] = .int(Int64(status.budget))
        }
        return body
    }
}

extension QuietComposerCommands.Routing {
    var presentation: ProvidersFacade.SessionPresentation? {
        guard var value = appModel.engine.providers.sessions[sessionID] else { return nil }
        if value.contract == nil, let pending = appModel.pendingChatBrainSelection { value.choice = pending }
        return value
    }
    var residentPresentation: ProvidersFacade.SessionPresentation? { presentation.flatMap { $0.contract == nil ? $0 : nil } }
    var routeChoice: ProviderTurnChoice? { presentation?.choice }
    var botContract: BotChatContract? { presentation?.contract }
    var isBotConversation: Bool { botContract != nil }
    var providerGroups: [ChatComposerModelGroup] { residentPresentation?.providerGroups ?? [] }
    var efforts: [ReasoningEffortOption] { presentation?.efforts ?? [] }
    var effortIndex: Int { efforts.firstIndex { $0.id == routeChoice?.reasoningEffort } ?? 0 }
    var selectedModelSupportsFast: Bool { residentPresentation?.supportsFast == true }


    var modelWord: String {
        guard let presentation else { return "Reading model…" }
        if let contract = presentation.contract { return contract.model ?? "Bot model" }
        guard let choice = presentation.choice, !choice.model.isEmpty else { return "Choose model" }
        return presentation.selectedModel?.displayName ?? choice.model
    }

    func effortLabel(_ effort: String) -> String {
        efforts.first { $0.id == effort }?.label
            ?? (effort.isEmpty ? "Thinking" : (effort == "xhigh" ? "XHigh" : effort.capitalized))
    }

    var effortWord: String {
        guard presentation != nil else { return "Reading thinking…" }
        if isBotConversation, routeChoice?.reasoningEffort == nil { return "Bot thinking" }
        return effortLabel(routeChoice?.reasoningEffort ?? "")
    }

    var fastIsOn: Bool { presentation?.fastIsOn == true }

    var trustWord: String {
        guard let policy = appModel.engine.trust.policy else { return "Trust unavailable" }
        let access = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: appModel.chatFileAccess)
        return MobileTrustAction.Preset.matching(policy: policy, accessMode: access)?.title
            ?? "Custom Trust"
    }

    var activeTrustPreset: MobileTrustAction.Preset? {
        guard let policy = appModel.engine.trust.policy else { return nil }
        let access = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: appModel.chatFileAccess)
        return MobileTrustAction.Preset.matching(policy: policy, accessMode: access)
    }


    /// The provider save owner serializes the complete choice and returns its receipt.
    @discardableResult
    func select(model: ModelCatalogItem, provider: String) -> Task<String?, Never>? {
        guard residentPresentation != nil else {
            return Task { "This conversation's model controls are unavailable. Open Providers or Helpers." }
        }
        guard !appModel.isSavingChatBrain else { return nil }
        let choice = ProviderTurnChoice(
            provider: provider, model: model.id,
            reasoningEffort: appModel.chatReasoningEffort, fast: appModel.chatFastMode,
            supportedReasoningEfforts: model.supportedReasoningEfforts ?? ProvidersFacade.chatComposerFallbackEfforts,
            defaultReasoningEffort: model.defaultReasoningEffort, supportsFast: model.supportsFast
        )

        let generation = appModel.enqueueChatBrainDefaultsSave(choice)
        return Task { @MainActor in
            guard let generation else { return nil }
            let result = await appModel.engine.providers.awaitChatBrainSave(generation: generation)
            if case .failed = result { return result.agentMessage }
            return nil
        }
    }

    func setEffort(index: Int) {
        guard let presentation = residentPresentation, presentation.efforts.indices.contains(index) else { return }
        let effort = presentation.efforts[index].id
        guard effort != appModel.chatReasoningEffort else { return }
        appModel.chatReasoningEffort = effort
        appModel.enqueueChatBrainDefaultsSave()
    }

}

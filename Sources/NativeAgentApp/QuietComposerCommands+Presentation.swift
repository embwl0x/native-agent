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
    static let tabs: [String: (page: SidebarItem, tab: String)] = [
        "knowledge": (.memories, "knowledge"), "dreams": (.personality, "dreams"),
        "cognition": (.diagnostics, "Cognition"), "inspector": (.diagnostics, "Inspector"),
    ]
    static let cardNames = ChatComposerCard.allCases.map(\.rawValue)

    @MainActor
    struct Routing {
        let appModel: AppModel
        let sessionID: String
        let suppliedPresentation: ProviderComposerPresentation?
        init(appModel: AppModel, sessionID: String? = nil, presentation: ProviderComposerPresentation? = nil) {
            self.appModel = appModel; self.sessionID = sessionID ?? appModel.activeChatSessionId
            suppliedPresentation = presentation
        }
    }

    @MainActor
    fileprivate static func draft(_ sessionID: String, appModel: AppModel) -> String {
        appModel.chatDraft(for: sessionID)
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
    func quietComposerPresentation(verb: String, value: String, choice: String) async -> QuietComposerOutcome {
        do {
            let face = try BodyFacePresentation.current(model: self)
            if let result = await face.composerPresentation(verb: verb, value: value, choice: choice, callerTurn: nil) { return result }
            switch verb {
            case "show_browser":
                BrowserWindowController.shared.showWindow()
                return .done("Window > Browser", "The browser window is in front.")
            case "check_updates":
                let check = await UpdateController.shared.probeForUpdate()
                return check.refusal.map { .refuse("Check for Updates", $0.reason, $0.detail) }
                    ?? .done("Check for Updates", check.detail, changed: false)
            default: return .refuse(verb, "presentation_unavailable", "This presentation has no window owner.")
            }
        } catch { return .refuse(verb, "window_unavailable", error.localizedDescription) }
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
        let routing = QuietComposerCommands.Routing(appModel: self, sessionID: sessionID, presentation: projection.controls)
        var body: [String: JSONValue] = [
            "provider": .string(routing.routeChoice?.provider ?? ""),
            "model": .string(routing.routeChoice?.model ?? ""),
            "model_word": .string(routing.modelWord),
            "think": .string(routing.routeChoice?.reasoningEffort ?? ""), "think_word": .string(routing.effortWord),
            "think_choices": .array(routing.efforts.map { .string($0.id) }), "fast": .bool(routing.fastIsOn),
            "trust_word": .string(routing.trustWord), "persona": .string(chatPersona),
            "open_card": .null,
        ]
        if !sessionID.isEmpty, let status = projection.context {
            let usage = ContextFillPresentation.usage(status)
            body["ring_fraction"] = .double(usage.fillFraction)
            if let percent = Int64(exactly: usage.percent.rounded()) {
                body["ring_percent"] = .int(percent)
            } else {
                body["ring_percent"] = .string(String(format: "%.0f", usage.percent.rounded()))
            }
            body["context_used_tokens"] = .int(Int64(status.used_tokens))
            body["context_budget_tokens"] = .int(Int64(status.budget))
            body["context_measurement_source"] = status.context_mode.map(JSONValue.string) ?? .null
        }
        return body
    }
}

extension QuietComposerCommands.Routing {
    var presentation: ProviderComposerPresentation? {
        let sessionID = sessionID
        let posted = suppliedPresentation ?? appModel.face.slot(.settings).select("providers.composer.\(sessionID)", as: SettingsFace.self) {
            $0?.providers.sessions[sessionID]?.controls
        }
        guard var value = posted else { return nil }
        if value.contract == nil, let pending = appModel.pendingChatBrainSelection { value.choice = pending }
        return value
    }
    var residentPresentation: ProviderComposerPresentation? { presentation.flatMap { $0.contract == nil ? $0 : nil } }
    var routeChoice: ProviderTurnChoice? { presentation?.choice }
    var botContract: ProviderHelperPresentation? { presentation?.contract }
    var isBotConversation: Bool { botContract != nil }
    var providerGroups: [ChatComposerModelGroup] { residentPresentation?.providerGroups ?? [] }
    var efforts: [ReasoningEffortOption] { presentation?.efforts ?? [] }
    var effortIndex: Int? { efforts.firstIndex { $0.id == routeChoice?.reasoningEffort } }
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
        if presentation?.selectedModel?.supportedReasoningEfforts == [] { return "Thinking not configurable" }
        guard !efforts.isEmpty else { return "Thinking unavailable" }
        return effortLabel(routeChoice?.reasoningEffort ?? "")
    }

    var fastIsOn: Bool { presentation?.fastIsOn == true }

    var trustWord: String {
        appModel.face.slot(.settings).select("trust.word", as: SettingsFace.self) { $0?.trust.word } ?? "Trust unavailable"
    }

    var activeTrustPreset: MobileTrustAction.Preset? {
        let raw = appModel.face.slot(.settings).select("trust.activePreset", as: SettingsFace.self) { $0?.trust.activePreset }
        return raw.flatMap(MobileTrustAction.Preset.init(rawValue:))
    }


    /// The provider save owner serializes the complete choice and returns its receipt.
    @discardableResult
    func select(model: ModelCatalogItem, provider: String) -> Task<String?, Never>? {
        guard residentPresentation != nil else {
            return Task { "This conversation's model controls are unavailable. Open Providers or Helpers." }
        }
        guard !appModel.isSavingChatBrain else { return nil }
        guard model.supportedReasoningEfforts != nil else {
            return Task { "This model's thinking choices are unavailable. Reload Providers before choosing it." }
        }
        let choice = ProviderTurnChoice(
            provider: provider, model: model.id,
            reasoningEffort: appModel.chatReasoningEffort, fast: appModel.chatFastMode
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

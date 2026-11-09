import Foundation
import SwiftUI
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import AttentionRouting
import DoctorChecks
import WidgetKit
import AppIntents
import Observation
import MemoryV2
import BackgroundLoops
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
import TrustCenter
import MultimodalTTS
import SystemOps
import TelegramBot
import DeviceSync
// Blueprint: | `AppModel+ProviderCommands.swift` | `AppModel`: checked provider reads, chat-brain saves and disconnect outcomes |

@MainActor
extension AppModel {
    var providerSettingsIssue: String? {
        face.slot(.settings).select("providers.issue", as: SettingsFace.self) { $0?.providers.error }
    }

    var providerAccounts: [ProviderInfo] {
        face.slot(.settings).select("providers.accounts", as: SettingsFace.self) { $0?.providers.snapshot?.providers } ?? []
    }

    var providerReadiness: ProviderSettingsFace.Readiness {
        face.slot(.settings).select("providers.readiness", as: SettingsFace.self) { $0?.providers.readiness } ?? .loading
    }

    /// Drawing readers are separate from the command getters, including while a saved frame is in flight.
    var displayedChatModel: String {
        pendingChatBrainSelection?.model
            ?? face.slot(.settings).select("providers.chatModel", as: SettingsFace.self) { $0?.providers.chatChoice?.model } ?? ""
    }

    var displayedChatProvider: String {
        pendingChatBrainSelection?.provider
            ?? face.slot(.settings).select("providers.chatProvider", as: SettingsFace.self) { $0?.providers.chatChoice?.provider } ?? ""
    }

    var providerSavingChatBrain: Bool {
        face.slot(.settings).select("providers.savingChatBrain", as: SettingsFace.self) { $0?.providers.isSavingChatBrain } == true
    }

    func missingProviderChatGuidance() -> String? {
        guard providerReadiness == .needsConnection else { return nil }
        return """
        No AI provider is connected yet, so I can't reply.

        Use Open Providers below to connect one.
        """
    }

    @discardableResult
    func enqueueChatBrainDefaultsSave(_ choice: ProviderTurnChoice? = nil) -> UInt64? {
        guard let requested = choice ?? currentChatBrainSelection,
              !requested.provider.isEmpty, !requested.model.isEmpty else {
            let detail = "Chat's saved account and model are unavailable. Read Providers before changing its choice."
            setFailureStatus(detail, cause: ProviderRoutingError.underlying(detail))
            return nil
        }
        if let choice { pendingChatBrainSelection = choice }
        return engine.providers.enqueueChatBrainSave(
            requested,
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
        guard let selection = currentChatBrainSelection, !selection.provider.isEmpty, !selection.model.isEmpty else {
            return .failed(message: "Chat's saved account and model are unavailable. Read Providers before changing its choice.")
        }
        guard let generation = enqueueChatBrainDefaultsSave(selection) else { return .unchanged(selection) }
        let result = await engine.providers.awaitChatBrainSave(generation: generation)
        if case .failed(_, nil) = result { statusText = result.userMessage }
        return result
    }

    var currentChatBrainSelection: ProviderTurnChoice? {
        pendingChatBrainSelection ?? engine.providers.chatBrainCanonicalSelection
    }

    func stageChatBrainSelection(model: String? = nil, reasoningEffort: String? = nil, fast: Bool? = nil) {
        guard let selection = currentChatBrainSelection else {
            let detail = "Chat's saved account and model are unavailable. Read Providers before changing its choice."
            setFailureStatus(detail, cause: ProviderRoutingError.underlying(detail))
            return
        }
        pendingChatBrainSelection = .init(provider: selection.provider, model: model ?? selection.model,
            reasoningEffort: reasoningEffort ?? selection.reasoningEffort, fast: fast ?? selection.fast)
    }

    private func publishProviderCatalogStatusAfterBrainSave() {
        Task {
            _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus()
        }
    }

    /// Every door must share the engine's checked provider presentation.
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
        _ = await engine.providers.adoptProviderForBlankSurfaces(
            providerId, dataRoot: engine.dataRoot,
            failure: { error, action in setFailureStatus(error, action: action) }
        )
    }
    // MARK: Providers
    /// Remove the registry row before sign-in; only a durable removal may claim success.
    func disconnectProvider(_ id: String) async -> (ok: Bool, detail: String, cause: String?) {
        do {
            let result = try await engine.providers.disconnectProvider(id)
            _ = await loadProvidersForChat()
            return (result.ok, result.detail, nil)
        } catch {
            return (false, UserFacingError.message(error, action: "remove the sign-in"), error.localizedDescription)
        }
    }

}

extension ProvidersFacade.ChatBrainSaveResult {
    var userMessage: String {
        switch self {
        case .unchanged(let selection), .saved(let selection):
            return "Chat brain saved: \(selection.model) / \(selection.reasoningEffort)\(selection.fast ? " / Fast" : "")"
        case .failed(let message, _):
            return "Couldn't save the model choice. \(message)"
        }
    }

    var agentMessage: String {
        if case .failed(_, let cause) = self { return UserFacingError.forAgent(userMessage, cause: cause) }
        return userMessage
    }
}

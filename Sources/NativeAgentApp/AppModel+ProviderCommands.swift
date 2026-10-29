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
    /// Guidance text to show in chat when no AI provider is usable at all;
    /// `nil` when at least one provider looks connected.
    func missingProviderChatGuidance() -> String? {
        guard engine.providers.settings != nil, !engine.providers.hasReadyConnection else { return nil }
        return """
        No AI provider is connected yet, so I can't reply.

        Use Open Providers below to connect one.
        """
    }

    @discardableResult
    func enqueueChatBrainDefaultsSave(_ choice: ProviderTurnChoice? = nil) -> UInt64? {
        if let choice { pendingChatBrainSelection = choice }
        return engine.providers.enqueueChatBrainSave(
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

    private var currentChatBrainSelection: ProviderTurnChoice {
        .init(provider: chatProvider, model: chatModel, reasoningEffort: chatReasoningEffort, fast: chatFastMode)
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
        _ = await engine.providers.adoptProviderForBlankSurfaces(
            providerId, dataRoot: engine.dataRoot,
            failure: { error, action in setFailureStatus(error, action: action) }
        )
    }
    // MARK: Providers
    /// The provider sheet's Remove the key, which provider.disconnect runs
    /// too: the registry row, then the sign-in. `detail` is the sheet's status
    /// line; `ok` false claims no removal.
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

    /// What the agent's tool result says: the same line plus the raw cause.
    var agentMessage: String {
        if case .failed(_, let cause) = self { return UserFacingError.forAgent(userMessage, cause: cause) }
        return userMessage
    }
}

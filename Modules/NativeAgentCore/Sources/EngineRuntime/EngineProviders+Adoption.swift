import NativeAgentShared
import Foundation
import DeviceSync
import PersistenceCore
import ProviderRouting
// Blueprint: | `EngineProviders+Adoption.swift` | Transactional Chat adoption preserving intentional overrides and pending edits |

extension ProvidersFacade {
    /// Write only Chat’s assignment so other groups inherit naturally; clear disconnected stale assignments while preserving deliberate user overrides.
    @MainActor
    public func adoptProviderForBlankSurfaces(
        _ providerId: String, dataRoot: URL,
        failure: (Error, String) -> Void
    ) async -> Bool {
        defer { Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() } }
        // Adopt only eligible accounts and re-read saved assignments inside the transaction so stale state cannot clear overrides.
        let routing = SwiftNativeProviderRouting(
            dataRoot: dataRoot
        )
        do {
            let providers = try await list().providers
            guard providers.contains(where: { $0.provider_id == providerId && $0.auth_status.eligible }) else { return false }
            let result = try await routing.adoptConnectedProvider(providerId)
            await publishCommittedRouting(result.snapshot)
            await refreshSessionsAfterRoutingWrite()
            if result.surfacesChanged.contains("cognition_reflection") {
                await NativeAgentEngine.liveCognition.refreshConfiguration()
            }
        } catch {
            failure(error, "select the connected account")
            return false
        }
        return true
    }

}

extension ProvidersFacade {
    /// Claim the edit before its first suspension so refreshes cannot replace it.
    @discardableResult
    public func enqueueChatBrainSave(
        _ requested: ProviderTurnChoice,
        failure: @escaping @MainActor (Error) -> String,
        completion: @escaping @MainActor (ChatBrainSaveResult, Error?) -> Void
    ) -> UInt64? {
        if chatBrainSaveTask == nil, requested == chatBrainCanonicalSelection {
            completion(.unchanged(requested), nil)
            return nil
        }
        chatBrainSaveGeneration &+= 1
        let generation = chatBrainSaveGeneration
        chatBrainPendingSave = (generation, requested)
        if chatBrainSaveTask == nil {
            isSavingChatBrain = true
            chatBrainSaveTask = Task { @MainActor [weak self] in
                await self?.drainChatBrainSaves(failure: failure, completion: completion)
            }
        }
        return generation
    }

    public func awaitChatBrainSave(generation: UInt64) async -> ChatBrainSaveResult {
        while true {
            if let completed = chatBrainLastSaveResult, completed.generation >= generation {
                return completed.result
            }
            guard let task = chatBrainSaveTask else {
                return .failed(message: "save coordinator stopped before producing a canonical result")
            }
            await task.value
        }
    }

    private func drainChatBrainSaves(
        failure: @MainActor (Error) -> String,
        completion: @MainActor (ChatBrainSaveResult, Error?) -> Void
    ) async {
        defer {
            isSavingChatBrain = false
            chatBrainSaveTask = nil
        }
        while let pending = chatBrainPendingSave {
            chatBrainPendingSave = nil
            do {
                let selection = try await writeProviderTurnChoice(pending.selection)
                // Newer optimistic fields belong to the pending edit.
                if chatBrainPendingSave != nil { continue }
                let result = ChatBrainSaveResult.saved(selection)
                chatBrainLastSaveResult = (pending.generation, result)
                completion(result, nil)
            } catch {
                if chatBrainPendingSave != nil { continue }
                _ = await refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
                let result = ChatBrainSaveResult.failed(
                    message: failure(error), cause: error.localizedDescription
                )
                chatBrainLastSaveResult = (pending.generation, result)
                completion(result, error)
            }
        }
    }

    private func writeProviderTurnChoice(_ selection: ProviderTurnChoice) async throws -> ProviderTurnChoice {
        let routing = try await saveSurfaceSelection(
            surface: "chat", model: selection.model,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.fast ? "priority" : "default", providerID: selection.provider
        )
        _ = await refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
        guard let canonical = routing.preferences["chat"], let provider = routing.activeProviders["chat"] else {
            throw ProviderRoutingError.underlying("canonical routing snapshot is incomplete")
        }
        return ProviderTurnChoice(
            provider: provider, model: canonical.model, reasoningEffort: canonical.reasoningEffort,
            fast: canonical.serviceTier == "priority"
        )
    }

}

extension ProvidersFacade {
    public func connectOAuthProvider(
        platform: any NativeOAuthPlatformPort.Type, providerID: String,
        present: (OAuthFlowResult) -> Void,
        failure: (Error, String) -> Void
    ) async -> OAuthFlowResult? {
        let result = await NativeOAuthFlow.startOAuthFlow(
            platform: platform, providerId: providerID, dataRoot: dataRoot
        )
        guard !Task.isCancelled else { return nil }
        present(result)
        if result.ok {
            _ = await adoptProviderForBlankSurfaces(
                providerID, dataRoot: dataRoot, failure: failure
            )
        }
        return result
    }

    public func acceptCodexCLISession(
        failure: (Error, String) -> Void
    ) async -> Bool {
        guard await NativeOAuthFlow.recordCodexCLISessionDecision(
            allow: true, source: "providers_offer", dataRoot: dataRoot
        ) else { return false }
        _ = await adoptProviderForBlankSurfaces(
            "openai_oauth_direct", dataRoot: dataRoot, failure: failure
        )
        return true
    }
}

extension ProvidersFacade {
    public func saveConnection(
        _ providerID: String, apiKey: String?, authMode: String, defaultModel: String,
        didSave: () -> Void,
        failure: (Error, String) -> Void
    ) async throws {
        try await configureProvider(id: providerID, apiKey: apiKey, authMode: authMode, defaultModel: defaultModel)
        _ = await adoptProviderForBlankSurfaces(
            providerID, dataRoot: dataRoot, failure: failure
        )
        // A save can be ineligible for adoption; it still owes its open editor a checked current baseline.
        if case .failed(let detail) = await refreshSettings(refreshCatalog: false, cause: { error, _ in error.localizedDescription }) {
            throw ProviderRoutingError.underlying("The account was saved, but its current settings could not be read: \(detail)")
        }
        // LatestRead returns this read even if a newer failure won publication and retained the old account baseline.
        try Task.checkCancellation()
        if let settingsError {
            throw ProviderRoutingError.underlying("The account was saved, but its current settings are unavailable: \(settingsError)")
        }
        didSave()
    }
}

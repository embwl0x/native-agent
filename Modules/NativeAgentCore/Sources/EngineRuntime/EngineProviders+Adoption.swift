import Foundation
import DeviceSync
import PersistenceCore
import ProviderRouting
// Blueprint: | `EngineProviders+Adoption.swift` | Blank-surface adoption delegates to the routing transaction and publishes its committed snapshot through LatestRead.write; serialized chat-brain saves retain pending edits, while canonical selection derives from ProvidersFacade.settings. |

extension ProvidersFacade {
    /// After a provider is connected (especially the FIRST one, at onboarding),
    /// Chat adopts it — and everything else follows Chat.
    ///
    /// So this writes ONE assignment (`chat`) instead of one per surface. Fifteen
    /// identical assignments made Work and Memory and mind read **Explicit
    /// override** on a fresh install when the person had overridden nothing; with
    /// one, the page reads **All activities match Chat** and every lane resolves
    /// through Chat's route. Stale assignments left by an older install (or by a
    /// provider that is no longer connected) are CLEARED rather than repointed,
    /// so they go back to following Chat too — a real override, made by a person
    /// on the Providers page, is left exactly alone.
    @MainActor
    public func adoptProviderForBlankSurfaces(
        _ providerId: String, dataRoot: URL,
        failure: (Error, String) -> Void
    ) async -> Bool {
        defer { Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() } }
        // Only an eligible account can become Chat's inherited route.
        guard let providers = try? await list().providers,
              providers.contains(where: { $0.provider_id == providerId && $0.auth_status.eligible }) else { return false }
        // Saved assignments (without sole-account resolution) are re-read
        // inside the picker's transaction. No stale per-surface clear follows.
        let routing = SwiftNativeProviderRouting(
            dataRoot: dataRoot
        )
        do {
            let result = try await routing.adoptConnectedProvider(providerId)
            try publishCommittedRouting(result.snapshot)
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
        guard NativeOAuthFlow.recordCodexCLISessionDecision(
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
        didSave()
    }
}

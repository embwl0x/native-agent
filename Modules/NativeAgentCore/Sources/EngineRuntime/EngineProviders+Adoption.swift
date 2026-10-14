import Foundation
import PersistenceCore
import ProviderRouting

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
        failure: (Error, String) -> Void,
        clearOverride: (String) async throws -> Void
    ) async -> Bool {
        let available: Set<String> = Set(
            ((try? await list()) ?? [])
                .filter { $0.auth_status.state == "ready" }
                .map { $0.provider_id }
        )
        // Never point surfaces at a provider that isn't actually ready (e.g. a
        // connect that didn't fully land) — that would break routing.
        guard available.contains(providerId) else { return false }
        // Current per-surface assignments from the SOURCE OF TRUTH (active.json
        // on disk), not the possibly-stale trust snapshot — so we never overwrite
        // a surface that active.json already pins to a valid connected provider.
        //
        // 2026-09-13 review: the SAVED assignments, never the resolved snapshot.
        // Resolution fills Chat in from the sole connected account, so right
        // after the first sign-in this read said "a choice is already saved" and
        // adoption wrote nothing. Connecting a second account then removed the
        // sole-account answer, adoption saw a blank Chat and adopted the SECOND
        // account plus its default model — Chat, and every group inheriting it,
        // switched without anyone touching the picker.
        let routing = SwiftNativeProviderRouting(
            dataRoot: dataRoot
        )
        let current: [String: String]
        do {
            current = try await routing.savedActiveProvidersChecked()
        } catch {
            failure(error, "read your providers")
            return false
        }
        let chatAssignment = (current["chat"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if chatAssignment.isEmpty || !available.contains(chatAssignment) {
            // Sign-in connects an account. The picker alone selects its model.
            do { try await self.routing.setActiveProvider(surface: "chat", providerId: providerId) }
            catch { failure(error, "select the connected account") }
        }
        // Anything else that is blank already follows Chat. Anything pointing at
        // a provider that is not connected is a leftover, not a choice: clear it
        // so it follows Chat as well.
        for surface in MODEL_SURFACES where surface != "chat" {
            let cur = (current[surface] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cur.isEmpty, !available.contains(cur) {
                try? await clearOverride(surface)
            }
        }
        return true
    }

}

extension ProvidersFacade {
    /// Claim the edit before its first suspension so refreshes cannot replace it.
    @discardableResult
    public func enqueueChatBrainSave(
        _ requested: ChatBrainSelection,
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
        while let task = chatBrainSaveTask {
            await task.value
            if let completed = chatBrainLastSaveResult, completed.generation >= generation {
                return completed.result
            }
        }
        return .failed(
            message: "save coordinator stopped before producing a canonical result",
            rolledBackTo: chatBrainCanonicalSelection
        )
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
            let rollback = await canonicalChatBrainForRollback()
            do {
                let selection = try await writeChatBrainSelection(pending.selection)
                chatBrainCanonicalSelection = selection
                // Newer optimistic fields belong to the pending edit.
                if chatBrainPendingSave != nil { continue }
                let result = ChatBrainSaveResult.saved(selection)
                chatBrainLastSaveResult = (pending.generation, result)
                completion(result, nil)
            } catch {
                if chatBrainPendingSave != nil { continue }
                let canonical = (try? await readCanonicalChatBrainSelection()) ?? rollback
                if let canonical { chatBrainCanonicalSelection = canonical }
                let result = ChatBrainSaveResult.failed(
                    message: failure(error), rolledBackTo: canonical,
                    cause: error.localizedDescription
                )
                chatBrainLastSaveResult = (pending.generation, result)
                completion(result, error)
            }
        }
    }

    private func canonicalChatBrainForRollback() async -> ChatBrainSelection? {
        if let chatBrainCanonicalSelection { return chatBrainCanonicalSelection }
        let canonical = try? await readCanonicalChatBrainSelection()
        if let canonical { chatBrainCanonicalSelection = canonical }
        return canonical
    }

    private func writeChatBrainSelection(_ selection: ChatBrainSelection) async throws -> ChatBrainSelection {
        let catalog = try await saveSurfaceSelection(
            surface: "chat", model: selection.model,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.fastMode ? "priority" : "default", providerID: nil
        )
        self.catalog = catalog
        let canonical = catalog.current.chat
        return ChatBrainSelection(
            model: canonical.model, reasoningEffort: canonical.reasoningEffort,
            fastMode: canonical.serviceTier == "priority"
        )
    }

    private func readCanonicalChatBrainSelection() async throws -> ChatBrainSelection {
        guard let preference = try await SwiftNativeProviderRouting().computeModelPreferences()["chat"] else {
            throw NSError(domain: "NativeAgent.ChatBrain", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "canonical chat routing is missing"])
        }
        return ChatBrainSelection(
            model: preference.model, reasoningEffort: preference.reasoningEffort,
            fastMode: preference.serviceTier == "priority"
        )
    }
}

extension ProvidersFacade {
    public func connectOAuthProvider(
        platform: any NativeOAuthPlatformPort.Type, providerID: String,
        present: (OAuthFlowResult) -> Void,
        refreshProviders: () async -> Void,
        failure: (Error, String) -> Void,
        clearOverride: (String) async throws -> Void
    ) async -> OAuthFlowResult? {
        let result = await NativeOAuthFlow.startOAuthFlow(
            platform: platform, providerId: providerID, dataRoot: dataRoot
        )
        guard !Task.isCancelled else { return nil }
        present(result)
        if result.ok {
            await refreshProviders()
            if await adoptProviderForBlankSurfaces(
                providerID, dataRoot: dataRoot, failure: failure, clearOverride: clearOverride
            ) { await refreshProviders() }
        }
        return result
    }

    public func acceptCodexCLISession(
        refreshStatus: () async -> Void, refreshProviders: () async -> Void,
        failure: (Error, String) -> Void,
        clearOverride: (String) async throws -> Void
    ) async -> Bool {
        guard NativeOAuthFlow.recordCodexCLISessionDecision(
            allow: true, source: "providers_offer", dataRoot: dataRoot
        ) else { return false }
        await refreshStatus()
        await refreshProviders()
        if await adoptProviderForBlankSurfaces(
            "openai_oauth_direct", dataRoot: dataRoot, failure: failure, clearOverride: clearOverride
        ) { await refreshProviders() }
        return true
    }
}

extension ProvidersFacade {
    public func saveConnection(
        _ providerID: String, apiKey: String?, authMode: String, defaultModel: String,
        didSave: () -> Void, readback: ([ProviderInfo]) -> Void,
        refreshProviders: () async -> Void, failure: (Error, String) -> Void,
        clearOverride: (String) async throws -> Void
    ) async throws {
        try await configureProvider(id: providerID, apiKey: apiKey, authMode: authMode, defaultModel: defaultModel)
        didSave()
        readback(try await list())
        await refreshProviders()
        if await adoptProviderForBlankSurfaces(
            providerID, dataRoot: dataRoot, failure: failure, clearOverride: clearOverride
        ) { await refreshProviders() }
    }
}

import Foundation
import AuthoredCapabilities
import Privacy
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
// Blueprint: | `EngineFaceActs+SettingsProviders.swift` | Provider acts use checked routing transactions, credential owners and committed account readbacks |

extension EngineFaceActs {
    func readChatChoice(session: String) async throws -> FaceActReply {
        let read = await engine.providers.refreshSettings(refreshCatalog: false) { error, _ in
            NativeAppSecretRedactor.redactText(error.localizedDescription)
        }
        let snapshot: ProviderSettingsSnapshot
        switch read {
        case .loaded(let value): snapshot = value
        case .failed(let detail): throw Self.failure("providers_unavailable", detail)
        }
        let presentation = await engine.providers.refreshSession(session)
        // The context meter's failure is the meter's; only an unread choice refuses a change.
        if presentation.choice == nil, let issue = presentation.error { throw Self.failure("chat_choice_unavailable", issue) }
        guard presentation.contract == nil else {
            throw Self.failure("helper_model_owned", "This helper's model is selected in Helpers.")
        }
        var saved = ProviderSettingsFace()
        saved.apply(snapshot: snapshot.disclosedForFace())
        guard saved.chatChoice != nil else {
            throw Self.failure("chat_choice_unavailable", "Choose a connected model in Providers before changing Chat controls.")
        }
        return .provider(saved)
    }

    func saveChatChoice(_ request: ChatChoiceWrite) async throws -> FaceActReply {
        let choice = request.choice
        if request.edit != .selection {
            guard let baseline = request.expectedBaseline, baseline.provider == choice.provider, baseline.model == choice.model,
                  (request.edit == .reasoning ? baseline.fast == choice.fast : baseline.reasoningEffort == choice.reasoningEffort) else {
                throw Self.failure("chat_control_edit_invalid", "Change only the selected Chat control against its checked baseline.")
            }
        }
        let saved = try await engine.providers.routing.saveGroupSelection(group: ProviderSurfaceGroups.chat,
            providerID: request.edit == .selection ? choice.provider : nil, model: request.edit == .selection ? choice.model : nil,
            reasoningEffort: request.edit == .fast ? nil : choice.reasoningEffort,
            serviceTier: request.edit == .reasoning ? nil : (choice.fast ? "priority" : "default"), expectedRevision: request.expectedRevision,
            expectedChatChoice: request.expectedBaseline)
        await engine.providers.publishCommittedRouting(saved.snapshot)
        await engine.providers.refreshSessionsAfterRoutingWrite()
        return .provider(try await providerReadback())
    }

    func saveProviderConnection(_ request: ProviderConnectionWrite) async throws -> FaceActReply {
        try await engine.providers.configureProvider(id: request.id, apiKey: Self.secret(request.secret),
            authMode: request.authMode, defaultModel: request.defaultModel, expectedRevision: request.expectedRevision)
        let committed: [FaceCommittedField] = [.init(id: "authMode", value: .string(request.authMode))]
            + (request.defaultModel.isEmpty ? [] : [.init(id: "model", value: .string(request.defaultModel))])
            + (request.secret?.isEmpty == false ? [.init(id: "key")] : [])
        do {
            var adoptionIssue: String?
            _ = await engine.providers.adoptProviderForBlankSurfaces(request.id, dataRoot: engine.dataRoot) { error, _ in
                adoptionIssue = error.localizedDescription
            }
            let saved = try await providerReadback()
            if let adoptionIssue {
                throw WireFailure(code: "provider_adoption_failed", message: "The account was saved, but Chat could not select it.",
                    cause: NativeAppSecretRedactor.redactText(adoptionIssue), effects: .known)
            }
            return .provider(saved)
        } catch {
            var failure = (error as? WireFailure) ?? WireFailure(code: "provider_readback_failed",
                message: "The account was saved, but its current status could not be read.",
                cause: error.localizedDescription, effects: .known)
            failure.committed = committed
            throw failure
        }
    }

    func testProvider(_ request: ProviderTestRequest) async throws -> FaceActReply {
        let provider = try await engine.providers.provider(id: request.id)
        if let revision = request.displayedRevision, provider.connectionRevision != revision {
            throw Self.failure("provider_conflict", "This account changed. Read Providers before checking it.")
        }
        let probe = try await engine.providers.testConfiguredProvider(provider, authMode: request.authMode,
            apiKey: Self.secret(request.secret) ?? "")
        return .providerTest(.init(result: probe.result, credentialReady: probe.credentialReady, credentialMatches: probe.credentialMatches))
    }

    func disconnectProvider(_ id: String) async throws -> FaceActReply {
        let result = try await engine.providers.disconnectProvider(id)
        guard result.ok else { throw Self.failure("provider_disconnect_failed", result.detail, effects: .unknown) }
        var issue: WireFailure?
        do { _ = try await providerReadback() }
        catch { issue = WireFailure(code: "provider_publication_failed", message: "Sign-in was removed, but Providers could not be read.",
            cause: NativeAppSecretRedactor.redactText(error.localizedDescription), effects: .known) }
        return .committed(.init(identities: [id], value: .object(["detail": .string(result.detail)]), revision: nil,
            effects: .known, publicationFailure: issue))
    }

    func decideCodexCLIConsent(_ allow: Bool) async throws -> FaceActReply {
        guard await NativeOAuthFlow.recordCodexCLISessionDecision(allow: allow, source: "providers_offer", dataRoot: engine.dataRoot) else {
            throw Self.failure("codex_consent_failed", "The consent decision could not be saved. Check the data folder.")
        }
        if allow {
            var issue: String?
            _ = await engine.providers.adoptProviderForBlankSurfaces("openai_oauth_direct", dataRoot: engine.dataRoot) { error, _ in
                issue = error.localizedDescription
            }
            if let issue { throw WireFailure(code: "codex_adoption_failed", message: "Consent was saved, but Chat could not select the account.",
                cause: NativeAppSecretRedactor.redactText(issue), effects: .known) }
        }
        _ = try await providerReadback()
        return try Self.committed(allow, identities: ["openai_oauth_direct"])
    }

    func repairCodexCLIConsent() async throws -> FaceActReply {
        let backup = try await NativeOAuthFlow.repairCodexCLISessionConsent(dataRoot: engine.dataRoot)
        _ = try await providerReadback()
        return try Self.committed(backup.lastPathComponent, identities: ["openai_oauth_direct"])
    }

    func saveAnthropicSetupToken(_ bytes: Data) async throws -> FaceActReply {
        guard let token = try Self.secret(bytes) else { throw Self.failure("token_required", "Enter a setup token.") }
        if let issue = await NativeOAuthFlow.saveAnthropicSetupToken(token, dataRoot: engine.dataRoot) {
            throw Self.failure("setup_token_failed", NativeAppSecretRedactor.redactText(issue))
        }
        _ = try await providerReadback()
        return try Self.committed(true, identities: ["anthropic_oauth_direct"])
    }

    func providerReadback() async throws -> ProviderSettingsFace {
        let read = await engine.providers.refreshSettings(refreshCatalog: false) { error, _ in
            NativeAppSecretRedactor.redactText(error.localizedDescription)
        }
        switch read {
        case .loaded(let snapshot):
            var value = ProviderSettingsFace()
            value.apply(snapshot: snapshot.disclosedForFace())
            do {
                try await engine.providers.deliverFaces()
                try await engine.settingsFeed.deliverFaces()
            } catch {
                throw WireFailure(code: "provider_publication_failed", message: "The provider change was saved, but its display could not update.",
                    cause: NativeAppSecretRedactor.redactText(error.localizedDescription), effects: .known)
            }
            return value
        case .failed(let detail): throw Self.failure("providers_unavailable", detail, effects: .known)
        }
    }

}

import AuthoredCapabilities
import ApprovalTransactions
import ChatToolRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
import Privacy
import Transcripts
// Blueprint: | `ProvidersFace+Actions.swift` | Providers rows use group transactions, provider operations and the credential card |

extension NativeAgentEngine {
    @MainActor
    func actProvidersFace(row: String, action: String, value: String?, by: PartFaces.Actor) async throws -> String? {
        // Model picks, credentials and consent belong to the person; from this page the agent may only check an account or the catalog.
        if case .agent = by, !["provider.test", "provider.refresh"].contains(action) {
            throw PartCallError(code: "person_only",
                message: "Choosing models, signing in, disconnecting and Codex consent belong to the person; ask the person.")
        }
        do { return try await performProvidersFaceAction(row: row, action: action, value: value) }
        catch let error as PartCallError { throw error }
        catch { throw PartCallError(code: "provider_action_failed", message: NativeAppSecretRedactor.redactText(error.localizedDescription)) }
    }

    @MainActor
    private func performProvidersFaceAction(row: String, action: String, value: String?) async throws -> String? {
        if row == "models", action == "provider.refresh" {
            switch await providers.refreshSettings(refreshCatalog: true, cause: { error, _ in error.localizedDescription }) {
            case .failed(let words): throw PartCallError(code: "provider_refresh_failed", message: words)
            case .loaded(let settings):
                let catalog = providers.faceCatalog(settings)
                return [catalog.value, catalog.detail].compactMap { $0 }.joined(separator: " · ")
            }
        }
        guard providers.settingsError == nil, let settings = providers.settings else {
            throw PartCallError(code: "providers_unavailable",
                message: providers.settingsError ?? "Providers have not been read. Refresh Models before changing a choice.")
        }
        if action == "set" {
            for group in ProviderSurfaceGroups.all {
                let prefix = "providers.\(group.id)_"
                if ["model", "thinking", "fast", "use_chat"].contains(where: { row == prefix + $0 }) {
                    try await setProvidersFace(group: group, field: String(row.dropFirst(prefix.count)), value: value, settings: settings)
                    return nil
                }
            }
        }
        if row == "codex-cli-session" { return try await actProvidersCLIOffer(action, settings: settings) }
        guard let account = settings.providers.first(where: { $0.provider_id == row }) else {
            throw PartCallError(code: "provider_row_unavailable", message: "That account is no longer listed. Read Providers again.")
        }
        switch action {
        case "provider.test":
            let result = try await providers.testProvider(account.provider_id)
            if !result.tested {
                return "Nothing was checked. "
                    + NativeAppSecretRedactor.redactText(result.error ?? result.detail ?? "The provider returned no check result.")
            }
            if result.status == "ok" {
                return "\(account.display_name) answered\(result.model_used.map { " on \($0)" } ?? ""). "
                    + "Accounts shows the check of the credential actually sent."
            }
            return "\(account.display_name)'s check failed: "
                + NativeAppSecretRedactor.redactText(result.error ?? result.detail ?? result.status)
        case "provider.disconnect":
            let outcome = try await providers.disconnectProvider(account.provider_id)
            _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            guard outcome.ok else { throw PartCallError(code: "provider_disconnect_failed", message: outcome.detail) }
            return outcome.detail
        case "provider.sign_in":
            guard !account.auth_status.eligible,
                  account.auth_modes.contains("api_key") || account.auth_modes.contains("oauth") else {
                throw PartCallError(code: "provider_sign_in_unavailable", message: "Read Providers again for this account's current actions.")
            }
            return try await raiseProvidersCredentialCard(account)
        default:
            throw PartCallError(code: "provider_action_unavailable", message: "This account has no action called \(action). Read Providers again.")
        }
    }

    @MainActor
    private func setProvidersFace(group: ProviderSurfaceGroup, field: String, value: String?,
                                  settings: ProvidersFacade.SettingsSnapshot) async throws {
        guard let value else { throw PartCallError(code: "provider_value_missing", message: "Choose a value before saving this setting.") }
        switch field {
        case "model":
            guard let option = InlineInteractionRegistry.splitModelOptionID(value),
                  let account = settings.providers.first(where: { $0.provider_id == option.providerID && $0.auth_status.eligible }),
                  let model = ProvidersFacade.modelsForProvider(account.provider_id, providers: [account]).first(where: { $0.id == option.modelID }) else {
                throw PartCallError(code: "provider_model_unavailable", message: "That account and model are no longer offered. Refresh Models.")
            }
            guard model.reasoningCapabilitiesKnown,
                  model.supportedReasoningEfforts.isEmpty || model.supportedReasoningEfforts.contains(model.defaultReasoningEffort) else {
                throw PartCallError(code: "provider_controls_unavailable",
                    message: "\(model.name)'s thinking default is unavailable. Refresh Models before choosing it.")
            }
            let effort = account.provider_id == "openrouter" && model.supportedReasoningEfforts.isEmpty ? "default" : model.defaultReasoningEffort
            _ = try await saveProviderGroupSelection(group: group, providerID: account.provider_id, model: model.id,
                                                     reasoningEffort: effort, serviceTier: "default")
        case "thinking":
            let selections = providers.faceSelections(settings)
            let lead = ProvidersFacade.leadSurface(group, selections: selections)
            guard let pick = selections[lead],
                  let model = ProvidersFacade.modelsForProvider(pick.provider, providers: settings.providers).first(where: { $0.id == pick.model }),
                  model.reasoningCapabilitiesKnown, model.supportedReasoningEfforts.contains(value) else {
                throw PartCallError(code: "provider_thinking_unavailable", message: "That thinking level is no longer offered. Read Providers again.")
            }
            _ = try await saveProviderGroupSelection(group: group, reasoningEffort: value)
        case "fast":
            let on = try providersFaceToggle(value)
            let selections = providers.faceSelections(settings)
            let lead = ProvidersFacade.leadSurface(group, selections: selections)
            guard let pick = selections[lead],
                  ProvidersFacade.modelsForProvider(pick.provider, providers: settings.providers)
                    .first(where: { $0.id == pick.model })?.supportsFast == true else {
                throw PartCallError(code: "provider_fast_unavailable", message: "This account and model do not offer Fast. Read Providers again.")
            }
            _ = try await saveProviderGroupSelection(group: group, serviceTier: on ? "priority" : "default")
        case "use_chat":
            guard group.id != ProviderSurfaceGroups.chat.id else {
                throw PartCallError(code: "provider_chat_root", message: "Chat is the root choice and cannot follow itself.")
            }
            if try providersFaceToggle(value) {
                _ = try await saveProviderGroupSelection(group: group, clearOverride: true)
            } else {
                guard let chat = providers.faceSelections(settings)["chat"], settings.routing.unusablePicks["chat"] == nil else {
                    throw PartCallError(code: "provider_chat_unavailable", message: "Choose a usable Chat model before pinning it to this group.")
                }
                _ = try await saveProviderGroupSelection(group: group, providerID: chat.provider, model: chat.model,
                    reasoningEffort: chat.reasoningEffort, serviceTier: chat.fast ? "priority" : "default")
            }
        default: throw PartCallError(code: "provider_setting_unavailable", message: "This setting is no longer on Providers.")
        }
    }

    private func providersFaceToggle(_ value: String) throws -> Bool {
        switch value {
        case "on": true
        case "off": false
        default: throw PartCallError(code: "provider_toggle_invalid", message: "This switch takes on or off.")
        }
    }

    @MainActor
    private func raiseProvidersCredentialCard(_ account: ProviderInfo) async throws -> String {
        guard let session = try ConversationAnchor.checkedCurrent(dataRoot: dataRoot)?.sessionId else {
            throw PartCallError(code: "provider_conversation_missing", message: "Open a conversation first, then connect this account again.")
        }
        let origin = TurnEnvelope.native("providers:connect")
        let turn = Turn(session: session).with(\.envelope, origin).with(\.verifiedSessionID, session)
        let card = InlineInteractionRegistry.apiKey(provider: account.provider_id,
            why: "You asked to connect \(account.display_name) in Providers. Use the card's protected entry or browser sign-in.")
        guard let raised = await InlineInteractionResolver.raise(card, sessionID: session, resumable: false,
            origin: origin, turn: turn, dataRoot: dataRoot) else {
            throw PartCallError(code: "provider_card_failed", message: "The connection card could not be saved. Check the data folder and try again.")
        }
        return "Connect \(account.display_name) in your conversation: card:\(raised.id) (chat:\(session))."
    }

    @MainActor
    private func actProvidersCLIOffer(_ action: String, settings: ProvidersFacade.SettingsSnapshot) async throws -> String {
        guard let offer = settings.codexCLISessionOffer else {
            throw PartCallError(code: "codex_offer_unavailable", message: "No Codex CLI sign-in offer is available. Read Providers again.")
        }
        switch (offer, action) {
        case (.available, "codex.use_session"):
            var failure: String?
            let saved = await providers.acceptCodexCLISession { error, _ in failure = error.localizedDescription }
            guard saved else { throw PartCallError(code: "codex_consent_failed", message: "The consent decision could not be saved. Check the data folder.") }
            if let failure { throw PartCallError(code: "codex_adoption_failed", message: failure) }
            _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            return "Codex CLI session consent saved. Accounts shows its checked connection state."
        case (.available(_, false), "codex.ignore_session"):
            guard NativeOAuthFlow.recordCodexCLISessionDecision(allow: false, source: "providers_offer", dataRoot: dataRoot) else {
                throw PartCallError(code: "codex_consent_failed", message: "The consent decision could not be saved. Check the data folder.")
            }
            _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            return "Codex CLI sign-in offer ignored."
        case (.unavailable, "codex.repair_consent"):
            let backup = try NativeOAuthFlow.repairCodexCLISessionConsent(dataRoot: dataRoot)
            _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            return "Unreadable consent backed up as \(backup.lastPathComponent). Choose Use it or Ignore again."
        default: throw PartCallError(code: "codex_action_unavailable", message: "Read Providers again for this offer's current actions.")
        }
    }
}

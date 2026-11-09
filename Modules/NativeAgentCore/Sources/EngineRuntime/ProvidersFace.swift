import AuthoredCapabilities
import ApprovalTransactions
import ChatToolRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Privacy
import Transcripts
// Blueprint: | `ProvidersFace.swift` | Checked provider pages and native group, sign-in and CLI-consent acts |

extension ProvidersFacade {
    /// Bind publication to this engine's page port, including roots that are not the resident root.
    func faceRead(on pages: PartFaces) -> PartFaces.Read {
        facePages = pages
        return { [weak self] in
            guard let self else { throw PartCallError(code: "providers_closed", message: "The provider owner has closed.") }
            return await self.readFace()
        }
    }

    func refreshFace() {
        Task { [weak facePages] in await facePages?.refresh(page: "providers") }
    }

    @concurrent nonisolated private func readFace() async -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let state = await MainActor.run {
            (settings: self.settings, error: self.settingsError, started: self.catalogRefreshStarted, probes: self.providerProbeStarts)
        }
        guard state.error == nil, let settings = state.settings else {
            let words = state.error ?? "The accounts and routing have not been read yet. Refresh Models to read them."
            return (PartFace(title: "Providers", line: words, sections: [
                .init(id: "catalog", title: "Catalog", style: .values, rows: [
                    .init(id: "models", title: "Models", detail: words,
                          value: state.started == nil ? "Unavailable" : "Refreshing…",
                          at: state.started.map { $0.formatted(.iso8601) }, tone: state.started == nil ? .attention : .live,
                          actions: [catalogAction(started: state.started)])
                ])
            ]), epoch)
        }
        let selections = faceSelections(settings)
        let options = settings.providers.filter(\.auth_status.eligible).flatMap { account in
            Self.modelsForProvider(account.provider_id, providers: [account]).map { model in
                PartFace.Control.Option(id: InlineInteractionRegistry.modelOptionID(providerID: account.provider_id, modelID: model.id),
                                        label: "\(account.display_name) · \(model.name)")
            }
        }
        var sections = ProviderSurfaceGroups.all.map { faceGroup($0, settings: settings, selections: selections, options: options) }
        if !settings.rowSet.unsupportedStoredKeys.isEmpty {
            sections.append(.init(id: "routing", title: "Saved routing needs repair", style: .values, rows: [
                .init(id: "routing-repair", title: "Unrecognized activities",
                      detail: settings.rowSet.unsupportedStoredKeys.joined(separator: ", ")
                        + ". Tell me in chat to reconstruct the saved routing explicitly.", tone: .attention)
            ]))
        }
        var accounts = settings.providers.sorted {
            ($0.auth_status.eligible ? 0 : 1, $0.display_name) < ($1.auth_status.eligible ? 0 : 1, $1.display_name)
        }.map { faceAccount($0, started: state.probes[$0.provider_id]) }
        if accounts.isEmpty {
            accounts.append(.init(id: "accounts-empty", title: "No accounts listed",
                                  detail: "Refresh Models to read the account catalog.", tone: .attention))
        }
        if let offer = settings.codexCLISessionOffer { accounts.append(faceCLIOffer(offer)) }
        sections.append(.init(id: "accounts", title: "Accounts", style: .list, rows: accounts))
        sections.append(.init(id: "catalog", title: "Catalog", style: .values, rows: [faceCatalog(settings, started: state.started)]))
        return (PartFace(title: "Providers", line: faceLine(settings, selections: selections), sections: sections), epoch)
    }

    nonisolated func faceSelections(_ settings: ProviderSettingsSnapshot) -> [String: ProviderTurnChoice] {
        settings.preferences.reduce(into: [:]) { result, entry in
            guard let account = settings.activeProviders[entry.key] else { return }
            result[entry.key] = .init(provider: account, model: entry.value.model,
                                    reasoningEffort: entry.value.reasoningEffort, fast: entry.value.serviceTier == "priority")
        }
    }

    nonisolated private func faceLine(_ settings: ProviderSettingsSnapshot, selections: [String: ProviderTurnChoice]) -> String {
        guard let chat = selections["chat"], !chat.model.isEmpty else { return "Chat has no readable model and account choice." }
        func words(_ pick: ProviderTurnChoice) -> String {
            let account = settings.providers.first { $0.provider_id == pick.provider }?.display_name ?? pick.provider
            return "\(pick.model) on \(account)"
        }
        let overrides = [ProviderSurfaceGroups.work, ProviderSurfaceGroups.mind].compactMap { group -> String? in
            let lead = Self.leadSurface(group, selections: selections)
            let different = group.surfaces.contains { selections[$0] != chat }
            guard Self.groupHasOverride(group, explicitSurfaces: settings.routing.modelOverrideSurfaces) || different else { return nil }
            guard let pick = selections[lead] else { return "\(faceGroupTitle(group)) is unavailable" }
            let mixed = Self.groupIsMixed(group, selections: selections, explicitSurfaces: settings.routing.modelOverrideSurfaces)
            return "\(faceGroupTitle(group)) uses \(words(pick))\(mixed ? " (mixed choices)" : "")"
        }
        return "Chat thinks with \(words(chat)); " + (overrides.isEmpty ? "work and mind follow it." : overrides.joined(separator: "; ") + ".")
    }

    nonisolated private func faceGroupTitle(_ group: ProviderSurfaceGroup) -> String {
        group.id == ProviderSurfaceGroups.mind.id ? "Mind" : group.title
    }

    nonisolated private func faceGroup(_ group: ProviderSurfaceGroup, settings: ProviderSettingsSnapshot,
                           selections: [String: ProviderTurnChoice], options offered: [PartFace.Control.Option]) -> PartFace.Section {
        let lead = Self.leadSurface(group, selections: selections)
        let pick = selections[lead]
        let prefix = "providers.\(group.id)_"
        var options = offered
        let selected = pick.map { InlineInteractionRegistry.modelOptionID(providerID: $0.provider, modelID: $0.model) }
        if let pick, let selected, !options.contains(where: { $0.id == selected }) {
            let account = settings.providers.first { $0.provider_id == pick.provider }?.display_name ?? pick.provider
            options.insert(.init(id: selected, label: "\(account) · \(pick.model) (saved; unavailable)"), at: 0)
        }
        let unresolvedSelection = selected.map { selected in !offered.contains { $0.id == selected } } ?? true
        // Each control of the group calls provider.choose with its setting; its new value arrives as the call's value.
        func choose(_ setting: String) -> PartFace.Call {
            .init("provider.choose", ["group": .string(group.id), "setting": .string(setting)])
        }
        var rows: [PartFace.Row] = [
            .init(id: prefix + "model", title: "Model", detail: offered.isEmpty ? "No eligible account offers models. Connect an account or refresh Models."
                    : "Choosing a model uses its declared thinking default and turns Fast off.",
                  value: pick?.model, tone: offered.isEmpty || unresolvedSelection ? .attention : nil,
                  control: offered.isEmpty ? nil : .choice(options, selected: selected, call: choose("model")))
        ]
        if let pick {
            let model = Self.modelsForProvider(pick.provider, providers: settings.providers).first { $0.id == pick.model }
            if let model, model.reasoningCapabilitiesKnown {
                if !model.supportedReasoningEfforts.isEmpty {
                    let efforts = Self.reasoningOptions(from: settings.catalog, providers: settings.providers,
                                                       providerID: pick.provider, model: pick.model)
                    var choices = efforts.map { PartFace.Control.Option(id: $0.id, label: $0.label) }
                    let unresolved = !model.supportedReasoningEfforts.contains(pick.reasoningEffort)
                    if unresolved { choices.insert(.init(id: pick.reasoningEffort, label: "Saved: \(pick.reasoningEffort) (unavailable)"), at: 0) }
                    rows.append(.init(id: prefix + "thinking", title: "Thinking", value: pick.reasoningEffort,
                        tone: unresolved ? .attention : nil, control: .choice(choices, selected: pick.reasoningEffort, call: choose("thinking"))))
                }
            } else {
                rows.append(.init(id: prefix + "capabilities", title: "Thinking choices unavailable",
                    detail: "Refresh Models to read \(pick.model)'s capabilities on \(pick.provider).", tone: .attention))
            }
            if model?.supportsFast == true {
                rows.append(.init(id: prefix + "fast", title: "Fast", control: .toggle(pick.fast, call: choose("fast"))))
            }
        }
        if group.id != ProviderSurfaceGroups.chat.id {
            rows.append(.init(id: prefix + "use_chat", title: "Same as Chat",
                detail: "Off pins Chat's current model, account and controls to this group.",
                control: .toggle(!Self.groupHasOverride(group, explicitSurfaces: settings.routing.modelOverrideSurfaces), call: choose("use_chat"))))
        }
        for surface in group.surfaces {
            let problem: String?
            if let saved = settings.routing.unusablePicks[surface] { problem = saved }
            else if settings.unavailableModels[surface] == true {
                problem = "\(selections[surface]?.model ?? "The saved model") is no longer offered. Choose a current model above."
            }
            else if let pick = selections[surface],
                    settings.providers.first(where: { $0.provider_id == pick.provider })?.auth_status.eligible != true {
                problem = "\(pick.provider)'s account is unavailable. Reconnect it in Accounts."
            } else if selections[surface] == nil { problem = "This activity's model and account are unavailable. Choose them above." }
            else { problem = nil }
            if let problem {
                rows.append(.init(id: prefix + "issue:" + surface,
                    title: group.members.first { $0.surface == surface }?.label ?? surface, detail: problem, tone: .attention))
            }
        }
        let mixed = Self.groupIsMixed(group, selections: selections, explicitSurfaces: settings.routing.modelOverrideSurfaces)
        return .init(id: group.id, title: faceGroupTitle(group), style: .values,
            footer: group.caption + (mixed ? ". Mixed choices; choosing here sets every activity in this group." : ""), rows: rows)
    }

    nonisolated private func faceAccount(_ provider: ProviderInfo, started: Date?) -> PartFace.Row {
        let status = provider.auth_status
        let (word, tone): (String, PartFace.Tone) = switch status.state {
        case "ready": ("Ready", .done)
        case "saved": ("Saved, not yet checked", .attention)
        case "failed": ("Could not check", .failed)
        case "rejected": ("Key rejected", .failed)
        default: (status.state.isEmpty ? "Status unavailable" : status.state.replacingOccurrences(of: "_", with: " "), .attention)
        }
        // Only a saved credential can be checked or removed; an account with none offers its sign-in alone.
        let saved = ["ready", "saved", "failed", "rejected", "unavailable"].contains(status.state)
        let account: [String: PartFace.Value] = ["provider": .string(provider.provider_id)]
        let entry: String? = switch (provider.auth_modes.contains("api_key"), provider.auth_modes.contains("oauth")) {
        case (true, false): "Enter a key in the protected entry on the Mac."
        case (false, true): "Sign in in the protected entry on the Mac."
        case (true, true): "Enter a key or sign in in the protected entry on the Mac."
        case (false, false): nil
        }
        var actions: [PartFace.Action] = saved ? [.init(id: "provider.test", label: "Test the connection", call: .init("provider.test", account)),
            .init(id: "provider.disconnect", label: "Disconnect", role: .destructive, call: .init("provider.disconnect", account))] : []
        if !status.eligible, provider.auth_modes.contains("api_key") || provider.auth_modes.contains("oauth") {
            actions.append(.init(id: "provider.sign_in", label: provider.auth_modes.contains("api_key") ? "Add key" : "Sign in",
                                 doors: ["mac"], call: .init("provider.sign_in", account)))
        }
        return .init(id: provider.provider_id, title: provider.display_name,
                     detail: [status.detail, provider.models_note,
                              status.eligible ? nil : entry]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                     value: started == nil ? word : "Checking connection…", at: started.map { $0.formatted(.iso8601) },
                     tone: started == nil ? tone : .live, actions: actions.isEmpty ? nil : actions)
    }

    nonisolated private func faceCLIOffer(_ offer: CodexCLISessionOffer) -> PartFace.Row {
        switch offer {
        case .available(let email, let alreadyDeclined):
            var actions: [PartFace.Action] = [.init(id: "codex.use_session", label: "Use it", call: Self.codexAnswer("use"))]
            if !alreadyDeclined { actions.append(.init(id: "codex.ignore_session", label: "Ignore", call: Self.codexAnswer("ignore"))) }
            return .init(id: "codex-cli-session", title: "Codex CLI sign-in",
                         detail: email.map { "Found an existing sign-in on this Mac (\($0))." } ?? "Found an existing sign-in on this Mac.",
                         value: alreadyDeclined ? "Ignored" : "Available", actions: actions)
        case .unavailable(let reason):
            return .init(id: "codex-cli-session", title: "Codex CLI sign-in adoption unavailable", detail: reason, tone: .attention,
                         actions: [.init(id: "codex.repair_consent", label: "Back up and reset consent", role: .destructive,
                                         call: Self.codexAnswer("repair"))])
        }
    }

    /// The Codex CLI offer's answers are one verb, provider.codex_session, with the answer the row's action gives.
    nonisolated private static func codexAnswer(_ answer: String) -> PartFace.Call { .init("provider.codex_session", ["answer": .string(answer)]) }

    nonisolated func faceCatalog(_ settings: ProviderSettingsSnapshot, started: Date?) -> PartFace.Row {
        let freshness = (settings.catalog?.catalogFreshness).flatMap(ModelCatalogFreshness.init(rawValue:))
        let word: String
        switch freshness {
        case .live: word = "Fresh"
        case .cached: word = "Cached"
        case .liveIncomplete: word = "Refreshed; may be partial"
        case .staleAfterFailedRefresh: word = "Refresh failed; last known list"
        case .unavailable, .none: word = "Unavailable"
        }
        let attention = settings.catalogError != nil || freshness == nil || freshness == .unavailable || freshness == .staleAfterFailedRefresh
        return .init(id: "models", title: "Models", detail: settings.catalogError ?? settings.catalog?.catalogNote,
            value: started == nil ? word : "Refreshing…", at: started.map { $0.formatted(.iso8601) },
            tone: started != nil ? .live : attention ? .attention : .quiet,
            actions: [catalogAction(started: started)])
    }

    nonisolated private func catalogAction(started: Date?) -> PartFace.Action {
        if started != nil {
            return .init(id: "provider.cancel_refresh", label: "Cancel", call: .init("provider.cancel_refresh"))
        }
        return .init(id: "provider.refresh", label: "Refresh", call: .init("provider.refresh"))
    }
}

extension NativeAgentEngine {
    /// `provider.choose`: one group's model (an account and model as the page's option id), thinking, Fast or Same as Chat, through the
    /// group transaction. Choosing a model uses its declared thinking default and turns Fast off.
    @MainActor
    func chooseProviderFace(group id: String, setting field: String, value: JSONValue?) async throws -> String? {
        try await providersVerb { settings in
            guard let group = ProviderSurfaceGroups.all.first(where: { $0.id == id }) else {
                throw PartCallError(code: "provider_setting_unavailable", message: "This setting is no longer on Providers.")
            }
            try await setProvidersFace(group: group, field: field, value: value, settings: settings)
            return nil
        }
    }

    /// The person's own request opens protected entry directly; it needs neither a conversation nor a new ask.
    @MainActor
    public func signInProviderFace(_ provider: String, renderer: UUID? = nil) async throws -> String? {
        try await providersVerb { settings in
            guard let account = settings.providers.first(where: { $0.provider_id == provider }) else {
                throw PartCallError(code: "provider_row_unavailable", message: "That account is no longer listed. Read Providers again.")
            }
            guard account.auth_modes.contains("api_key") || account.auth_modes.contains("oauth") else {
                throw PartCallError(code: "provider_sign_in_unavailable", message: "Read Providers again for this account's current actions.")
            }
            if let renderer {
                let reply = try await faceActs.call(.showProviderSetup(provider: provider, operation: UUID()), renderer: renderer)
                switch reply {
                case .acknowledged: break
                case .failed(let issue), .refused(let issue): throw issue
                case .cancelled: throw CancellationError()
                default: throw FaceWireError.invalidFeedOrder
                }
            } else {
                guard let show = ports.connectorStatus.showProviderSetup else {
                    throw PartCallError(code: "mac_required", message: "Open this account's protected entry on the Mac.")
                }
                try await show(account, dataRoot)
            }
            return "Opened protected entry for \(account.display_name) on the Mac. The connection is ready only after verification."
        }
    }

    /// `provider.codex_session`: the person's answer to the Codex CLI sign-in found on this Mac (use, ignore, or back up and reset an
    /// unreadable consent).
    @MainActor
    func answerCodexSession(_ answer: String) async throws -> String? {
        try await providersVerb { settings in try await actProvidersCLIOffer(answer, settings: settings) }
    }

    /// Every Providers verb reads the checked settings first; its failure is the owner's words, and any other error is redacted.
    @MainActor
    private func providersVerb(_ body: (ProviderSettingsSnapshot) async throws -> String?) async throws -> String? {
        do {
            guard providers.settingsError == nil, let settings = providers.settings else {
                throw PartCallError(code: "providers_unavailable",
                    message: providers.settingsError ?? "Providers have not been read. Refresh Models before changing a choice.")
            }
            return try await body(settings)
        }
        catch let error as PartCallError { throw error }
        catch { throw PartCallError(code: "provider_action_failed", message: NativeAppSecretRedactor.redactText(error.localizedDescription)) }
    }

    @MainActor
    private func setProvidersFace(group: ProviderSurfaceGroup, field: String, value: JSONValue?,
                                  settings: ProviderSettingsSnapshot) async throws {
        guard let value, value != .null else {
            throw PartCallError(code: "provider_value_missing", message: "Choose a value before saving this setting.")
        }
        switch field {
        case "model":
            guard let option = value.stringValue.flatMap(InlineInteractionRegistry.splitModelOptionID),
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
            guard let effort = value.stringValue, let pick = selections[lead],
                  let model = ProvidersFacade.modelsForProvider(pick.provider, providers: settings.providers).first(where: { $0.id == pick.model }),
                  model.reasoningCapabilitiesKnown, model.supportedReasoningEfforts.contains(effort) else {
                throw PartCallError(code: "provider_thinking_unavailable", message: "That thinking level is no longer offered. Read Providers again.")
            }
            _ = try await saveProviderGroupSelection(group: group, reasoningEffort: effort)
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

    private func providersFaceToggle(_ value: JSONValue) throws -> Bool {
        guard let on = value.boolValue else { throw PartCallError(code: "provider_toggle_invalid", message: "This switch takes on or off.") }
        return on
    }

    @MainActor
    private func actProvidersCLIOffer(_ answer: String, settings: ProviderSettingsSnapshot) async throws -> String {
        guard let offer = settings.codexCLISessionOffer else {
            throw PartCallError(code: "codex_offer_unavailable", message: "No Codex CLI sign-in offer is available. Read Providers again.")
        }
        switch (offer, answer) {
        case (.available, "use"):
            var failure: String?
            let saved = await providers.acceptCodexCLISession { error, _ in failure = error.localizedDescription }
            guard saved else { throw PartCallError(code: "codex_consent_failed", message: "The consent decision could not be saved. Check the data folder.") }
            if let failure { throw PartCallError(code: "codex_adoption_failed", message: failure) }
            _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            return "Codex CLI session consent saved. Accounts shows its checked connection state."
        case (.available(_, false), "ignore"):
            guard await NativeOAuthFlow.recordCodexCLISessionDecision(allow: false, source: "providers_offer", dataRoot: dataRoot) else {
                throw PartCallError(code: "codex_consent_failed", message: "The consent decision could not be saved. Check the data folder.")
            }
            _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            return "Codex CLI sign-in offer ignored."
        case (.unavailable, "repair"):
            let backup = try await NativeOAuthFlow.repairCodexCLISessionConsent(dataRoot: dataRoot)
            _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            return "Unreadable consent backed up as \(backup.lastPathComponent). Choose Use it or Ignore again."
        default: throw PartCallError(code: "codex_action_unavailable", message: "Read Providers again for this offer's current actions.")
        }
    }
}

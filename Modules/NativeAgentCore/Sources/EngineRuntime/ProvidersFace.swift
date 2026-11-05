import AuthoredCapabilities
import ChatToolRuntime
import Foundation
import NativeAgentShared
import ProviderRouting
// Blueprint: | `ProvidersFace.swift` | ProvidersFacade reads the Providers face from its checked in-memory settings and publishes at owner writes |

extension ProvidersFacade {
    /// Bind publication to this engine's page port, including roots that are not the resident root.
    func faceRead(on pages: PartFaces) -> PartFaces.Read {
        facePages = pages
        return { [weak self] in
            guard let self else { throw PartCallError(code: "providers_closed", message: "The provider owner has closed.") }
            return self.readFace()
        }
    }

    func refreshFace() {
        Task { [weak facePages] in await facePages?.refresh(page: "providers") }
    }

    private func readFace() -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        guard settingsError == nil, let settings else {
            let words = settingsError ?? "The accounts and routing have not been read yet. Refresh Models to read them."
            return (PartFace(title: "Providers", line: words, sections: [
                .init(id: "catalog", title: "Catalog", style: .values, rows: [
                    .init(id: "models", title: "Models", detail: words,
                          value: catalogRefreshStarted == nil ? "Unavailable" : "Refreshing…",
                          at: catalogRefreshStarted.map { $0.formatted(.iso8601) }, tone: catalogRefreshStarted == nil ? .attention : .live,
                          actions: [.init(id: "provider.refresh", label: "Refresh")])
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
        }.map(faceAccount)
        if accounts.isEmpty {
            accounts.append(.init(id: "accounts-empty", title: "No accounts listed",
                                  detail: "Refresh Models to read the account catalog.", tone: .attention))
        }
        if let offer = settings.codexCLISessionOffer { accounts.append(faceCLIOffer(offer)) }
        sections.append(.init(id: "accounts", title: "Accounts", style: .list, rows: accounts))
        sections.append(.init(id: "catalog", title: "Catalog", style: .values, rows: [faceCatalog(settings)]))
        return (PartFace(title: "Providers", line: faceLine(settings, selections: selections), sections: sections), epoch)
    }

    func faceSelections(_ settings: SettingsSnapshot) -> [String: ProviderTurnChoice] {
        settings.preferences.reduce(into: [:]) { result, entry in
            guard let account = settings.activeProviders[entry.key] else { return }
            result[entry.key] = .init(provider: account, model: entry.value.model,
                                    reasoningEffort: entry.value.reasoningEffort, fast: entry.value.serviceTier == "priority")
        }
    }

    private func faceLine(_ settings: SettingsSnapshot, selections: [String: ProviderTurnChoice]) -> String {
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

    private func faceGroupTitle(_ group: ProviderSurfaceGroup) -> String {
        group.id == ProviderSurfaceGroups.mind.id ? "Mind" : group.title
    }

    private func faceGroup(_ group: ProviderSurfaceGroup, settings: SettingsSnapshot,
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
        var rows: [PartFace.Row] = [
            .init(id: prefix + "model", title: "Model", detail: offered.isEmpty ? "No eligible account offers models. Connect an account or refresh Models."
                    : "Choosing a model uses its declared thinking default and turns Fast off.",
                  value: pick?.model, tone: offered.isEmpty || unresolvedSelection ? .attention : nil,
                  control: offered.isEmpty ? nil : .choice(options, selected: selected))
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
                        tone: unresolved ? .attention : nil, control: .choice(choices, selected: pick.reasoningEffort)))
                }
            } else {
                rows.append(.init(id: prefix + "capabilities", title: "Thinking choices unavailable",
                    detail: "Refresh Models to read \(pick.model)'s capabilities on \(pick.provider).", tone: .attention))
            }
            if model?.supportsFast == true {
                rows.append(.init(id: prefix + "fast", title: "Fast", control: .toggle(pick.fast)))
            }
        }
        if group.id != ProviderSurfaceGroups.chat.id {
            rows.append(.init(id: prefix + "use_chat", title: "Same as Chat",
                detail: "Off pins Chat's current model, account and controls to this group.",
                control: .toggle(!Self.groupHasOverride(group, explicitSurfaces: settings.routing.modelOverrideSurfaces))))
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

    private func faceAccount(_ provider: ProviderInfo) -> PartFace.Row {
        let status = provider.auth_status
        let started = providerProbeStarts[provider.provider_id]
        let (word, tone): (String, PartFace.Tone) = switch status.state {
        case "ready": ("Ready", .done)
        case "saved": ("Saved, not yet checked", .attention)
        case "failed": ("Could not check", .failed)
        case "rejected": ("Key rejected", .failed)
        default: (status.state.isEmpty ? "Status unavailable" : status.state.replacingOccurrences(of: "_", with: " "), .attention)
        }
        // Only a saved credential can be checked or removed; an account with none offers its sign-in alone.
        let saved = ["ready", "saved", "failed", "rejected", "unavailable"].contains(status.state)
        var actions: [PartFace.Action] = saved ? [.init(id: "provider.test", label: "Test the connection"),
                                                  .init(id: "provider.disconnect", label: "Disconnect", role: .destructive)] : []
        if !status.eligible, provider.auth_modes.contains("api_key") || provider.auth_modes.contains("oauth") {
            actions.append(.init(id: "provider.sign_in", label: provider.auth_modes.contains("api_key") ? "Add key" : "Sign in"))
        }
        return .init(id: provider.provider_id, title: provider.display_name,
                     detail: [status.detail, provider.models_note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                     value: started == nil ? word : "Checking connection…", at: started.map { $0.formatted(.iso8601) },
                     tone: started == nil ? tone : .live, actions: actions.isEmpty ? nil : actions)
    }

    private func faceCLIOffer(_ offer: NativeOAuthFlow.CodexCLISessionOffer) -> PartFace.Row {
        switch offer {
        case .available(let email, let alreadyDeclined):
            var actions: [PartFace.Action] = [.init(id: "codex.use_session", label: "Use it")]
            if !alreadyDeclined { actions.append(.init(id: "codex.ignore_session", label: "Ignore")) }
            return .init(id: "codex-cli-session", title: "Codex CLI sign-in",
                         detail: email.map { "Found an existing sign-in on this Mac (\($0))." } ?? "Found an existing sign-in on this Mac.",
                         value: alreadyDeclined ? "Ignored" : "Available", actions: actions)
        case .unavailable(let reason):
            return .init(id: "codex-cli-session", title: "Codex CLI sign-in adoption unavailable", detail: reason, tone: .attention,
                         actions: [.init(id: "codex.repair_consent", label: "Back up and reset consent", role: .destructive)])
        }
    }

    func faceCatalog(_ settings: SettingsSnapshot) -> PartFace.Row {
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
            value: catalogRefreshStarted == nil ? word : "Refreshing…", at: catalogRefreshStarted.map { $0.formatted(.iso8601) },
            tone: catalogRefreshStarted != nil ? .live : attention ? .attention : .quiet,
            actions: [.init(id: "provider.refresh", label: "Refresh")])
    }
}

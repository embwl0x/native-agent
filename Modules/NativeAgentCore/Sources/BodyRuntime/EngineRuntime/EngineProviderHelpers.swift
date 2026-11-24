import PersistenceCore
import NativeAgentCore
import NativeAgentShared
import Foundation
import ProviderRouting
// Blueprint: | `EngineProviderHelpers.swift` | Checked account contracts, inheritance and committed routing publication |
@MainActor
extension ProvidersFacade {

    public enum SettingsRefreshOutcome: Sendable {
        case loaded(ProviderSettingsSnapshot)
        case failed(String)
    }

    public func refreshSettings(refreshCatalog: Bool, cause: @escaping (Error, String) -> String) async -> SettingsRefreshOutcome {
        guard refreshCatalog else {
            defer { refreshAccountModelsInBackground() }
            return await loadSettings(refreshCatalog: false, cause: cause)
        }
        guard catalogRefreshTask == nil else { return .failed("The model catalog is already being refreshed.") }
        catalogRefreshStarted = Date()
        let task = Task<SettingsRefreshOutcome, Never> {
            defer {
                catalogRefreshTask = nil
                catalogRefreshStarted = nil
                refreshFace()
            }
            let result = await loadSettings(refreshCatalog: true, cause: cause)
            return Task.isCancelled ? .failed("Model catalog refresh cancelled.") : result
        }
        catalogRefreshTask = task
        refreshFace()
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    public func cancelCatalogRefresh() async -> String {
        guard let task = catalogRefreshTask else { return "No model catalog refresh is running." }
        task.cancel()
        _ = await task.value
        return "Model catalog refresh cancelled."
    }

    private func loadSettings(refreshCatalog: Bool, cause: (Error, String) -> String) async -> SettingsRefreshOutcome {
        return await settingsReads.read {
            await readSettings(refreshCatalog: refreshCatalog, cause: cause)
        } publish: { outcome in
            guard !Task.isCancelled else { return }
            switch outcome {
            case .loaded(let settings): publishSettings(settings)
            case .failed(let detail): publishSettingsFailure(detail)
            }
        }
    }

    private func readSettings(refreshCatalog: Bool, cause: (Error, String) -> String) async -> SettingsRefreshOutcome {
        do {
            try Task.checkCancellation()
            let facade = self
            var catalog: ModelCatalogResponse?
            var catalogError: String?
            do { catalog = try await facade.modelCatalog(refresh: refreshCatalog) }
            catch { catalogError = cause(error, refreshCatalog ? "refresh the model list" : "load the model list") }
            try Task.checkCancellation()
            let snapshot = try await facade.routing.checkedProviderSnapshot()
            let asking = askingModelRoutes
            let providers = try await Task.detached(priority: .userInitiated) {
                try ProvidersFacade.connections(from: snapshot)
            }.value.map { account in
                // An account whose provider is being asked says so, in place of why it has nothing offered yet.
                var account = account
                if asking.contains(account.provider_id), account.offeredModels.isEmpty {
                    account.models_note = FirstPartyModelDiscovery.askingSentence(route: account.provider_id)
                }
                return account
            }
            return .loaded(await settingsSnapshot(
                routing: snapshot.routing,
                providers: providers,
                catalog: catalog,
                catalogError: catalogError,
                rowSet: snapshot.rowSet
            ))
        } catch {
            return SettingsRefreshOutcome.failed(cause(error, "read the accounts"))
        }
    }

    /// Credential status, CLI consent and cached model availability all read storage; every caller leaves the UI actor here.
    @concurrent private nonisolated func settingsSnapshot(
        routing: ProviderRoutingSnapshot, providers: [ProviderInfo], catalog: ModelCatalogResponse?,
        catalogError: String?, rowSet: ProviderSurfaceRowSet
    ) async -> ProviderSettingsSnapshot {
        var choices: [String: [String: Bool]] = [:]
        var unavailableModels: [String: Bool] = [:]
        for (surface, preference) in routing.preferences {
            let providerID = routing.activeProviders[surface] ?? ""
            if choices[providerID]?[preference.model] == nil {
                choices[providerID, default: [:]][preference.model] = Self.savedModelIsKnownAbsent(
                    providerId: providerID, model: preference.model, providers: providers, dataRoot: dataRoot)
            }
            unavailableModels[surface] = choices[providerID]?[preference.model]
        }
        return ProviderSettingsSnapshot(
            routing: routing, providers: providers, catalog: catalog, catalogError: catalogError,
            rowSet: rowSet,
            unavailableModels: unavailableModels,
            oauthStatuses: Dictionary(uniqueKeysWithValues: ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].map {
                ($0, NativeOAuthFlow.signInStatus(providerID: $0, dataRoot: dataRoot))
            }),
            codexCLISessionOffer: NativeOAuthFlow.codexCLISessionOffer(dataRoot: dataRoot)
        )
    }

    /// Retire pre-commit reads before suspending; the rebuilt snapshot shares refresh ordering so newer publications still win.
    func publishCommittedRouting(_ routing: ProviderRoutingSnapshot) async {
        settingsReads.write {}
        retireSessionReads()
        guard let settings else { return }
        _ = await settingsReads.read {
            await settingsSnapshot(routing: routing, providers: settings.providers, catalog: settings.catalog,
                                   catalogError: settings.catalogError, rowSet: settings.rowSet)
        } publish: { publishSettings($0) }
    }
}

extension ProvidersFacade {
    public var hasReadyConnection: Bool { connections.contains { $0.auth_status.eligible } }

    public func selection(for surface: String) -> ProviderTurnChoice {
        let preference = settings?.preferences[surface]
        return ProviderTurnChoice(provider: settings?.activeProviders[surface] ?? "",
            model: preference?.model ?? "", reasoningEffort: preference?.reasoningEffort ?? "",
            fast: preference?.serviceTier == "priority")
    }

    public nonisolated static func chatModelIsReady(providers: [ProviderInfo], providerID: String, model: String) -> Bool {
        providers.contains { $0.provider_id == providerID && $0.auth_status.eligible
            && $0.models.contains { $0.id == model && !$0.id.isEmpty } }
    }

}

extension ProvidersFacade {
    public struct SurfaceModelChoice: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let defaultReasoningEffort: String
        public let supportedReasoningEfforts: [String]
        public let reasoningCapabilitiesKnown: Bool
        public let supportsFast: Bool

        public init(id: String, name: String, defaultReasoningEffort: String,
                    supportedReasoningEfforts: [String], supportsFast: Bool,
                    reasoningCapabilitiesKnown: Bool) {
            self.id = id
            self.name = name
            self.defaultReasoningEffort = defaultReasoningEffort
            self.supportedReasoningEfforts = supportedReasoningEfforts
            self.reasoningCapabilitiesKnown = reasoningCapabilitiesKnown
            self.supportsFast = supportsFast
        }
    }

    public nonisolated static func modelsForProvider(_ providerId: String, providers: [ProviderInfo]) -> [SurfaceModelChoice] {
        // Read capabilities from this account’s descriptor; absence cannot borrow another transport’s contracts.
        guard let provider = providers.first(where: { $0.provider_id == providerId }) else { return [] }
        return provider.models.map {
            SurfaceModelChoice(
                id: $0.id,
                name: $0.name,
                defaultReasoningEffort: $0.default_reasoning_effort ?? "",
                supportedReasoningEfforts: $0.supported_reasoning_efforts ?? [],
                supportsFast: $0.supports_fast == true,
                reasoningCapabilitiesKnown: $0.supported_reasoning_efforts != nil
            )
        }
    }

    /// Fetched catalogs may be empty or last-known, so missing model entries alone prove nothing.
    private nonisolated static let dynamicCatalogProviders: Set<String> = ["openrouter", "moonshot"]

    /// Only a complete fresh or compiled-in catalog proves absence; Moonshot completeness is unknown, so retain unknown choices.
    private nonisolated static func savedModelIsKnownAbsent(providerId: String, model: String, providers: [ProviderInfo], dataRoot: URL) -> Bool {
        if providerId == "openrouter" {
            // Scope availability to this settings read’s root.
            return OpenRouterModelCatalog.cachedAvailability(
                of: model,
                dataRoot: dataRoot
            ) == .unavailable
        }
        guard !Self.dynamicCatalogProviders.contains(providerId) else { return false }
        guard let provider = providers.first(where: { $0.provider_id == providerId }),
              !provider.models.isEmpty else {
            return false
        }
        // A live route answers through the one carriage check: absent only when no spelling of the pick is in its provider's complete list; its
        // shipped floor proves no model absent.
        if FirstPartyModelDiscovery.isLiveRoute(providerId) {
            return !FirstPartyModelCatalog.routeCarries(model, providerID: providerId, dataRoot: dataRoot)
        }
        return !provider.models.contains(where: { $0.id == model })
    }

}

extension ProvidersFacade {
    private nonisolated static let emptySelection = ProviderTurnChoice(provider: "codex", model: "", reasoningEffort: "", fast: false)

    /// Use the most common group choice with first-surface tie breaking; Chat remains its own root.
    public nonisolated static func leadSurface(_ group: ProviderSurfaceGroup, selections: [String: ProviderTurnChoice]) -> String {
        // Chat is the inheritance root, so its group shows Chat’s choice.
        if group.surfaces.contains("chat") { return "chat" }
        guard var lead = group.surfaces.first else { return "chat" }
        var counts: [ProviderTurnChoice: Int] = [:]
        for surface in group.surfaces { counts[(selections[surface] ?? emptySelection), default: 0] += 1 }
        var best = counts[(selections[lead] ?? emptySelection)] ?? 0
        for surface in group.surfaces.dropFirst() {
            let count = counts[(selections[surface] ?? emptySelection)] ?? 0
            if count > best { best = count; lead = surface }
        }
        return lead
    }

    /// Only model/account overrides make inheriting groups mixed; independent effort does not.
    public nonisolated static func groupIsMixed(_ group: ProviderSurfaceGroup, selections: [String: ProviderTurnChoice],
        explicitSurfaces: Set<String>) -> Bool {
        guard groupHasOverride(group, explicitSurfaces: explicitSurfaces), let first = group.surfaces.first.map({ selections[$0] ?? emptySelection }) else {
            return false
        }
        return group.surfaces.dropFirst().contains { (selections[$0] ?? emptySelection) != first }
    }

    /// Chat is the inheritance root and never clears its own route.
    public nonisolated static func groupHasOverride(_ group: ProviderSurfaceGroup, explicitSurfaces: Set<String>) -> Bool {
        group.surfaces.contains { $0 != "chat" && explicitSurfaces.contains($0) }
    }

}
extension ProvidersFacade {
    public nonisolated static func reasoningOptions(
        from catalog: ModelCatalogResponse?, selectedModel: ModelCatalogItem?
    ) -> [ReasoningEffortOption] {
        guard let supported = selectedModel?.supportedReasoningEfforts else { return [] }
        let catalogOptions = Dictionary(
            (catalog?.reasoningEfforts ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return supported.map { effort in
            catalogOptions[effort] ?? ReasoningEffortOption(
                id: effort,
                label: effort == "xhigh" ? "XHigh" : effort.capitalized,
                description: nil
            )
        }
    }

    public nonisolated static func modelOptions(providers: [ProviderInfo], providerID: String, current: String, limit: Int = 80) -> [ModelCatalogItem] {
        let sourceModels = providerModels(providers: providers, providerID: providerID)
        var seen: Set<String> = []
        var models: [ModelCatalogItem] = []

        if let currentModel = sourceModels.first(where: { $0.id == current }), seen.insert(currentModel.id).inserted {
            models.append(currentModel)
        } else if !current.isEmpty, seen.insert(current).inserted {
            models.append(ModelCatalogItem(id: current, displayName: current,
                description: "Saved model; capabilities unavailable. Reload Providers to read them.", priority: 999))
        }

        for model in sourceModels {
            guard seen.insert(model.id).inserted else { continue }
            models.append(model)
            if models.count >= limit { break }
        }
        return models
    }

    private nonisolated static func providerModels(providers: [ProviderInfo], providerID: String) -> [ModelCatalogItem] {
        providers.first { $0.provider_id == providerID }?.models.map { item in
            ModelCatalogItem(id: item.id, displayName: item.name, description: nil,
                defaultReasoningEffort: item.default_reasoning_effort,
                supportedReasoningEfforts: item.supported_reasoning_efforts,
                supportsFast: item.supports_fast, priority: 0)
        } ?? []
    }

    public nonisolated static func reasoningOptions(from catalog: ModelCatalogResponse?, providers: [ProviderInfo], providerID: String,
        model: String) -> [ReasoningEffortOption] {
        reasoningOptions(from: catalog, selectedModel: providerModels(providers: providers, providerID: providerID).first { $0.id == model })
    }

    public nonisolated static func normalizedReasoningEffort(providers: [ProviderInfo], providerID: String, model: String,
        selected: String) -> String {
        let selectedModel = providerModels(providers: providers, providerID: providerID).first { $0.id == model }
        guard selectedModel?.supportedReasoningEfforts != nil else { return selected }
        return ProviderRouting.normalizedReasoningEffort(
            preferred: selectedModel?.defaultReasoningEffort, selected: selected)
    }
}

extension ChatComposerModelGroup {
    /// Menus list offered rows, plus the selected model's own row (shown with its note) so its controls read from it like any other.
    public static func groups(
        connections: [ProviderInfo], catalog: ModelCatalogResponse?, providerID: String, selectedModel: String? = nil
    ) -> [Self] {
        // Provider-scoped contracts and catalog descriptions form one finished menu.
        var catalogById: [String: ModelCatalogItem] = [:]
        for model in catalog?.models ?? [] where catalogById[model.id] == nil {
            catalogById[model.id] = model
        }
        let groups: [ChatComposerModelGroup] = connections
            .filter {
                $0.provider_id == "codex"
                    || $0.auth_status.eligible
                    || $0.provider_id == providerID
            }
            .sorted { lhs, rhs in
                if (lhs.provider_id == providerID) != (rhs.provider_id == providerID) {
                    return lhs.provider_id == providerID
                }
                return lhs.display_name < rhs.display_name
            }
            .compactMap { provider in
                let shown = provider.models.filter { row in
                    ModelSlot.mayHold(row.id, row: row, savedInSlot: provider.provider_id == providerID ? selectedModel : nil)
                }
                let models = shown.map { item in
                    let catalogModel = catalogById[item.id]
                    // Provider-scoped capability contracts are authoritative because transports can share model ids with different contracts.
                    return ModelCatalogItem(
                        id: item.id,
                        displayName: item.name,
                        description: item.offer_note ?? catalogModel?.description,
                        defaultReasoningEffort: item.default_reasoning_effort,
                        supportedReasoningEfforts: item.supported_reasoning_efforts,
                        supportsFast: item.supports_fast,
                        priority: catalogModel?.priority ?? 0
                    )
                }
                guard !models.isEmpty else { return nil }
                return ChatComposerModelGroup(
                    id: provider.provider_id,
                    provider: provider.display_name,
                    models: models, vendorGroups: vendorGroups(for: models)
                )
            }
        return groups
    }

    private static func vendorGroups(for models: [ModelCatalogItem]) -> [ChatComposerModelGroup]? {
        guard Self.splitsByVendor(models.map(\.id)) else { return nil }
        let byVendor = Dictionary(grouping: models) { String($0.id.prefix { $0 != "/" }) }
        return byVendor.keys.map {
            ChatComposerModelGroup(id: $0, provider: Self.vendorName($0), models: byVendor[$0] ?? [])
        }.sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }
}

// MARK: - provider

/// Provider actions share page operations while preserving the saved sign-in method and keeping keys out of results.
extension ProvidersFacade {
    /// The account a provider verb names by `provider`, or the refusal that lists the ones there are: a lookup of `prepareQuietProvider`.
    public static func quietProviderAccount(_ input: [String: JSONValue], in accounts: [ProviderInfo]) -> Result<ProviderInfo, QuietArgumentRefusal> {
        let id = input["provider"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let account = accounts.first(where: { $0.provider_id == id }) else {
            return .failure(QuietArgumentRefusal(AppToolExecutor.failure(
                "unknown_provider",
                (id.isEmpty ? "Pass provider" : "No account has id \(id)") + ". app {page:\"providers\"} lists them.",
                extra: ["providers": .array(accounts.map { .string($0.provider_id) })])))
        }
        return .success(account)
    }

    /// `provider.set_fallback_model`'s checks of what it names: a connected account, and a model it offers or already holds as its default:
    /// lookups of `prepareQuietProvider`.
    public static func quietFallbackModelRefusal(_ account: ProviderInfo, _ input: [String: JSONValue]) -> QuietArgumentRefusal? {
        let name = account.display_name
        guard account.auth_status.eligible else {
            return QuietArgumentRefusal(AppToolExecutor.failure(
                "not_connected",
                "\(name) is not connected, so it has no fallback model to set. Connecting it is the owner's: ask them to sign in on Providers."))
        }
        // A model choice: offered, or the default already saved here (`ModelSlot.mayHold`).
        let offered = account.offeredModels.map(\.id)
        let model = input["model"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let row = account.models.first { $0.id == model }
        guard ModelSlot.mayHold(model, row: row, savedInSlot: account.default_model) else {
            if offered.isEmpty || row != nil {
                return QuietArgumentRefusal(AppToolExecutor.failure("no_model_list",
                    ModelSlot.refusal(note: account.models_note, accountName: name) + " Run provider.refresh, then try again."))
            }
            return QuietArgumentRefusal(AppToolExecutor.failure(
                "bad_model",
                (model.isEmpty ? "Pass model" : "\(model) is not a model \(name) offers")
                    + ". It takes one of: \(offered.joined(separator: ", ")).",
                extra: ["argument_path": .string("args.model")]))
        }
        return nil
    }

    /// A provider verb's one switch: the accounts read now, the account `provider` names and what it sets there (the lookups) throw the
    /// owner's refusal, or the verb's effect comes back to run. The gate's check before any card and the run make the same lookups.
    @MainActor
    public static func prepareQuietProvider(
        verb: String, input: [String: JSONValue], dataRoot: URL, turn: Turn,
        refresh: @escaping () async -> (accounts: [ProviderInfo], failure: String?),
        cancelRefresh: @escaping () async -> String,
        list: () async throws -> [ProviderInfo],
        test: @escaping (String) async throws -> NativeAgentShared.ProviderTestResult,
        authMode: (ProviderInfo) -> (canSave: Bool, selectedMode: String),
        configure: @escaping (String, String, String) async throws -> Void,
        reload: @escaping () async -> Void,
        disconnect: @escaping (String) async -> (ok: Bool, detail: String)
    ) async throws -> @MainActor () async -> JSONValue {
        let retry = " Try again; read \(AppToolExecutor.doorDoctor) if it keeps failing."
        if verb == "cancel_refresh" {
            return { .object(["status": .string("ok"), "detail": .string(await cancelRefresh())]) }
        }
        if verb == "refresh_models" {
            return {
                let refreshed = await refresh()
                if let detail = refreshed.failure {
                    // Each account's own result stays readable: its row's models_note is the text beside its list (why it is the
                    // floor, or when it was fetched).
                    guard !refreshed.accounts.isEmpty else {
                        return AppToolExecutor.failure("refresh_failed", "The model lists did not refresh: \(detail)." + retry,
                            extra: ["effects": .string("unknown")])
                    }
                    await reload()
                    return AppToolExecutor.failure("refresh_failed", "Not every model list refreshed. \(detail)." + retry,
                        extra: ["effects": .string("partial"), "accounts": .array(refreshed.accounts.map { Self.quietProviderRow($0) })])
                }
                await reload()
                // The answer names each connected account and how many models its provider now lists.
                let asked = refreshed.accounts.filter { $0.auth_status.eligible }.map { "\($0.display_name) \($0.offeredModels.count)" }
                let listed = asked.isEmpty ? "No account is connected, so no provider was asked."
                    : "Refreshed. Connected accounts now list: " + asked.joined(separator: ", ") + "."
                return .object([
                    "status": .string("ok"),
                    "detail": .string(listed),
                    "accounts": .array(refreshed.accounts.map { Self.quietProviderRow($0) }),
                ])
            }
        }
        let accounts: [ProviderInfo]
        do { accounts = try await list() } catch {
            throw QuietArgumentRefusal(AppToolExecutor.failure("providers_unreadable", "The accounts didn't read (\(error.localizedDescription))." + retry))
        }
        if verb == "list" {
            return { .object(["status": .string("ok"), "accounts": .array(accounts.map { Self.quietProviderRow($0) })]) }
        }
        let account = try quietProviderAccount(input, in: accounts).get()
        let id = account.provider_id
        let name = account.display_name
        switch verb {
        case "test":
            return {
                let result: NativeAgentShared.ProviderTestResult
                do { result = try await test(id) } catch {
                    return AppToolExecutor.failure("test_failed", "The test of \(name) could not run: \(error.localizedDescription)." + retry,
                        extra: ["effects": .string("unknown")])
                }
                let works = result.tested && result.status == "ok"
                let problem = NativeAppSecretRedactor.redactText(result.error ?? result.detail ?? result.status)
                let detail = works
                    ? "\(name) works: it answered\(result.model_used.map { " on \($0)" } ?? "")."
                    : result.tested
                        ? "\(name) did not work: \(problem). A rejected key or expired sign-in is the owner's to fix: "
                            + "ask them to reconnect \(name) in Providers."
                        : "\(name) has no connection test, so nothing was checked. \(result.detail ?? "")"
                var body: [String: JSONValue] = [
                    "status": .string("ok"), "provider": .string(id), "tested": .bool(result.tested),
                    // Untested is unknown, not broken.
                    "works": result.tested ? .bool(works) : .null, "detail": .string(detail),
                ]
                if let model = result.model_used { body["model_used"] = .string(model) }
                return .object(body)
            }
        case "set_default_model":
            if let refusal = quietFallbackModelRefusal(account, input) { throw refusal }
            let model = input["model"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Preserve the sheet’s saved sign-in method.
            let mode = authMode(account)
            guard mode.canSave else {
                throw QuietArgumentRefusal(AppToolExecutor.failure(
                    "sign_in_method_unclear",
                    """
                        \(name)'s saved sign-in method isn't one its sheet can keep, so nothing was changed. That's the owner's: ask them to open \(name) in \
                        Providers.
                        """))
            }
            let old = account.default_model ?? ""
            return {
                do {
                    try await configure(id, mode.selectedMode, model)
                } catch {
                    return AppToolExecutor.failure("save_failed", "\(name)'s fallback model was not saved: \(error.localizedDescription)." + retry,
                        extra: ["effects": .string("unknown")])
                }
                await reload()
                return .object([
                    "status": .string("ok"), "provider": .string(id), "changed": .bool(old != model),
                    "old_value": .string(old), "new_value": .string(model),
                    "detail": .string("\(name) now falls back to \(model) wherever no other model is chosen for it."),
                ])
            }
        case "disconnect":
            return {
                // Credential removal requires Full Mac at this door.
                let outcome = await disconnect(id)
                guard outcome.ok else {
                    return AppToolExecutor.failure("disconnect_failed",
                        "\(outcome.detail) app {page:\"providers\"} shows where \(name) stands.",
                        extra: ["provider": .string(id), "effects": .string("unknown")])
                }
                BodyDecidedRow.post(turn: turn, requester: "Full Mac", tool: "provider.disconnect \(id)",
                                       sessionID: input["__session_id"]?.scalarText,
                                       dataRoot: dataRoot)
                return .object(["status": .string("ok"), "provider": .string(id), "changed": .bool(true),
                                "detail": .string("\(name) is disconnected. \(outcome.detail) Signing back in is the owner's.")])
            }
        default:
            throw QuietArgumentRefusal(AppToolExecutor.failure("unknown_verb", "No provider verb is called \(verb)."))
        }
    }

    /// Share the page row’s eligibility and credential-proof wording.
    private static func quietProviderRow(_ account: ProviderInfo) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(account.provider_id),
            "name": .string(account.display_name),
            "connected": .bool(account.auth_status.eligible),
            "state": .string(account.auth_status.state),
            "detail": .string(account.auth_status.detail),
            "fallback_model": .string(account.default_model ?? ""),
            // What the account offers to choose from; the build's rows standing in for a missing list are not offered.
            "models": .array(account.auth_status.eligible ? account.offeredModels.map { .string($0.id) } : []),
        ]
        if let note = account.models_note { row["models_note"] = .string(note) }
        return .object(row)
    }
}

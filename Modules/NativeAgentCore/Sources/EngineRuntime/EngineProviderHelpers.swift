import Privacy
import ChatOrchestration
import AppToolRuntime
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Foundation
import ProviderRouting
extension ProvidersFacade {
    public nonisolated static func readModelRoutingConfig(dataRoot: URL) async throws -> ModelRoutingConfig {
        let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshot()
        return try modelRoutingConfig(from: snapshot)
    }

    public nonisolated static func modelRoutingConfig(from snapshot: ProviderRoutingSnapshot) throws -> ModelRoutingConfig {
        func pref(_ surface: String) throws -> ModelSurfacePreference {
            guard let value = snapshot.preferences[surface] else {
                throw ProviderRoutingError.underlying("canonical routing snapshot is incomplete")
            }
            return ModelSurfacePreference(
                surface: surface, model: value.model, reasoningEffort: value.reasoningEffort,
                serviceTier: value.serviceTier, source: snapshot.activeProviders[surface],
                modelKnown: value.modelKnown
            )
        }
        return try ModelRoutingConfig(
            status: "ok", defaultModel: pref("chat").model, fallbackModels: [],
            reasoningEfforts: defaultReasoningEffortOptions,
            current: ModelRoutingCurrent(
                chat: pref("chat"), telegram: pref("telegram"), ios: pref("ios"),
                executions: pref(WorkshopSurfaceVocabulary.canonical), autonomy: pref("autonomy"),
                swarms: pref("swarms"), dream: pref("dream"), training: pref("training")
            )
        )
    }

    public nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

}

@MainActor
extension ProvidersFacade {
    public struct SettingsSnapshot {
        public let routing: ProviderRoutingSnapshot
        public let providers: [ProviderInfo]
        public let catalog: ModelCatalogResponse?
        public let catalogError: String?
        public let rowSet: ProviderSurfaceRowSet
        public let activeProviders: [String: String]
        public let preferences: [String: SurfacePreference]
    }

    public enum SettingsRefreshOutcome {
        case loaded(SettingsSnapshot)
        case failed(String)
    }

    public func refreshSettings(refreshCatalog: Bool, cause: (Error, String) -> String) async -> SettingsRefreshOutcome {
        do {
            let facade = self
            defer {
                if !refreshCatalog { facade.refreshAccountModelsInBackground() }
            }
            var catalog: ModelCatalogResponse?
            var catalogError: String?
            if refreshCatalog {
                do { catalog = try await facade.modelCatalog(refresh: true) }
                catch { catalogError = cause(error, "refresh the model list") }
            }
            let snapshot = try await facade.routing.checkedProviderSnapshot()
            let providers = try await Task.detached(priority: .userInitiated) {
                try ProvidersFacade.connections(from: snapshot)
            }.value
            if catalog == nil {
                do {
                    catalog = try await facade.modelCatalog(refresh: false, routingSnapshot: snapshot.routing)
                } catch { catalogError = cause(error, "load the model list") }
            }
            let config = try ProvidersFacade.modelRoutingConfig(from: snapshot.routing)
            catalog?.current = config.current
            catalog?.defaultModel = config.current.chat.model
            return .loaded(SettingsSnapshot(
                routing: snapshot.routing,
                providers: providers,
                catalog: catalog,
                catalogError: catalogError,
                rowSet: snapshot.rowSet,
                activeProviders: snapshot.routing.activeProviders,
                preferences: snapshot.routing.preferences
            ))
        } catch {
            return .failed(cause(error, "read the accounts"))
        }
    }
}

extension ProvidersFacade {
    public var hasReadyConnection: Bool { connections.contains { $0.auth_status.eligible } }

    public nonisolated static func chatModelIsReady(providers: [ProviderInfo], providerID: String, model: String) -> Bool {
        providers.contains { $0.provider_id == providerID && $0.auth_status.eligible
            && $0.models.contains { $0.id == model && !$0.id.isEmpty } }
    }

}

extension ProvidersFacade {
    public struct AuthModePickerState: Equatable {
        public let supportedModes: [String]
        public let selectedMode: String
        public let repairedSavedMode: String?

        public var canSave: Bool { supportedModes.contains(selectedMode) }
    }
}

extension ProvidersFacade {
    private nonisolated static let knownModes: Set<String> = ["api_key", "oauth"]

    public nonisolated static func authModePickerState(
        advertisedModes: [String],
        savedMode: String?,
        providerIsReady: Bool
    ) -> AuthModePickerState {
        var seen = Set<String>()
        let supportedModes = advertisedModes.compactMap { raw -> String? in
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard knownModes.contains(mode), seen.insert(mode).inserted else { return nil }
            return mode
        }
        let normalizedSavedMode = savedMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedSavedMode, supportedModes.contains(normalizedSavedMode) {
            return AuthModePickerState(
                supportedModes: supportedModes,
                selectedMode: normalizedSavedMode,
                repairedSavedMode: nil
            )
        }
        let selected = providerIsReady && supportedModes.contains("oauth")
            ? "oauth"
            : (supportedModes.first ?? "")
        return AuthModePickerState(
            supportedModes: supportedModes,
            selectedMode: selected,
            repairedSavedMode: normalizedSavedMode?.isEmpty == false ? normalizedSavedMode : nil
        )
    }
}


extension ProvidersFacade {
    public struct SurfaceModelChoice: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let defaultReasoningEffort: String
        public let supportedReasoningEfforts: [String]
        public let supportsFast: Bool
        public let isUnavailable: Bool

        public init(id: String, name: String, defaultReasoningEffort: String,
                    supportedReasoningEfforts: [String], supportsFast: Bool, isUnavailable: Bool) {
            self.id = id
            self.name = name
            self.defaultReasoningEffort = defaultReasoningEffort
            self.supportedReasoningEfforts = supportedReasoningEfforts
            self.supportsFast = supportsFast
            self.isUnavailable = isUnavailable
        }
    }

    private nonisolated static let fallbackReasoningEfforts = ["low", "medium", "high", "xhigh"]
    public nonisolated static func modelsForProvider(_ providerId: String, providers: [ProviderInfo], catalogModels: [ModelCatalogItem]) -> [SurfaceModelChoice] {
        // S12a: a fetched catalog that could not load is empty and says why
        // (`models_note`); it never borrows the provider-neutral list below.
        if let prov = providers.first(where: { $0.provider_id == providerId }),
           !prov.models.isEmpty || Self.dynamicCatalogProviders.contains(providerId) {
            return prov.models.map {
                SurfaceModelChoice(
                    id: $0.id,
                    name: $0.name,
                    defaultReasoningEffort: $0.default_reasoning_effort ?? "high",
                    supportedReasoningEfforts: $0.supported_reasoning_efforts
                        ?? Self.fallbackReasoningEfforts,
                    supportsFast: $0.supports_fast == true,
                    isUnavailable: false
                )
            }
        }
        return catalogModels.map {
            SurfaceModelChoice(
                id: $0.id,
                name: $0.displayName,
                defaultReasoningEffort: $0.defaultReasoningEffort ?? "high",
                supportedReasoningEfforts: $0.supportedReasoningEfforts
                    ?? Self.fallbackReasoningEfforts,
                supportsFast: $0.supportsFast == true,
                isUnavailable: false
            )
        }
    }

    /// Providers whose catalogue is fetched rather than compiled in. Their
    /// `models` list can be empty or last-known when no live catalogue could
    /// be loaded, so its silence about a model is not evidence of anything.
    private nonisolated static let dynamicCatalogProviders: Set<String> = ["openrouter", "moonshot"]

    /// Whether a LIVE catalogue for this provider says the saved model is gone.
    ///
    /// 2026-09-06: the old test was "the choice list is non-empty", and
    /// `modelsForProvider` substitutes the provider-neutral global catalogue
    /// whenever a provider's own list is empty — so a dynamic provider with no
    /// catalogue yet borrowed someone else's list and the saved model was
    /// labelled Unavailable on it. Evidence now has to come from the provider
    /// itself: OpenRouter's own live-backed cache (`.unknown` until one exists),
    /// or a static provider's compiled-in list, which is the whole truth about
    /// that provider. Moonshot has no live/fallback discriminator, so it never
    /// convicts. Anything unproven shows the saved model plainly.
    public nonisolated static func savedModelIsKnownAbsent(providerId: String, model: String, providers: [ProviderInfo], dataRoot: URL) -> Bool {
        if providerId == "openrouter" {
            // User, 2026-09-06: this read the DEFAULT data root while the rest
            // of the screen works off the model's scoped one, so under an
            // override the verdict came from a catalog belonging to another
            // root — including the "Unavailable" label on a saved model.
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
        return !provider.models.contains(where: { $0.id == model })
    }

}

extension ProvidersFacade {
    public nonisolated static func reconciledBrainForProvider(providerId: String, model: String, reasoningEffort: String?, fastMode: Bool, providers: [ProviderInfo], catalogModels: [ModelCatalogItem]) -> ProviderTurnChoice? {
        let choices = ProvidersFacade.modelsForProvider(providerId, providers: providers, catalogModels: catalogModels)
        guard let first = choices.first else { return nil }
        let current = model
        let choice = choices.first(where: { $0.id == current }) ?? first
        let effort = ProviderRouting.normalizedReasoningEffort(
            options: choice.supportedReasoningEfforts, preferred: choice.defaultReasoningEffort,
            selected: reasoningEffort ?? choice.defaultReasoningEffort
        )
        return ProviderTurnChoice(
            provider: providerId,
            model: choice.id,
            reasoningEffort: effort,
            fast: choice.supportsFast && fastMode
        )
    }


    public nonisolated static func explicitSurfaces(in routing: ProviderRoutingSnapshot) -> Set<String> {
        let chatPreference = routing.preferences["chat"]
        let chatProvider = routing.activeProviders["chat"]
        func resolvedDiffersFromChat(_ surface: String) -> Bool {
            let mine = routing.preferences[surface]
            let myProvider = routing.activeProviders[surface] ?? chatProvider
            return mine?.model != chatPreference?.model
                || mine?.reasoningEffort != chatPreference?.reasoningEffort
                || mine?.serviceTier != chatPreference?.serviceTier
                || myProvider != chatProvider
        }
        return Set(routing.pinnedModels.keys)
            .union(MODEL_SURFACES.filter { $0 != "chat" && resolvedDiffersFromChat($0) })
    }

    public nonisolated static func pickerProviders(_ providers: [ProviderInfo], activeProviders: [String: String]) -> [ProviderInfo] {
        let activeIds = Set(activeProviders.values)
        return providers.filter { $0.provider_id == "codex" || $0.auth_status.eligible
            || activeIds.contains($0.provider_id) }
    }
}

extension ProvidersFacade {
    public struct SurfaceSelection: Hashable, Sendable {
        public let provider: String
        public let model: String
        public let reasoningEffort: String
        public let fastMode: Bool

        public init(provider: String, model: String, reasoningEffort: String, fastMode: Bool) {
            self.provider = provider
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.fastMode = fastMode
        }

        fileprivate static let empty = SurfaceSelection(provider: "codex", model: "", reasoningEffort: "", fastMode: false)
    }

    /// The surface a group's row reads from: the most common choice among its
    /// surfaces, ties going to the group's first surface — so the Chat group
    /// keeps speaking for `chat`.
    public nonisolated static func leadSurface(_ group: ProviderSurfaceGroup, selections: [String: SurfaceSelection]) -> String {
        // Chat is the root the others inherit from, so its group always shows Chat's own choice.
        if group.surfaces.contains("chat") { return "chat" }
        guard var lead = group.surfaces.first else { return "chat" }
        var counts: [SurfaceSelection: Int] = [:]
        for surface in group.surfaces { counts[(selections[surface] ?? .empty), default: 0] += 1 }
        var best = counts[(selections[lead] ?? .empty)] ?? 0
        for surface in group.surfaces.dropFirst() {
            let count = counts[(selections[surface] ?? .empty)] ?? 0
            if count > best { best = count; lead = surface }
        }
        return lead
    }

    /// A group whose surfaces are all inheriting is not mixed even when their
    /// unpinned seeds differ (dream and REM seed cheaper than chat by design).
    /// Mixed means somebody's saved choice put the group's surfaces at odds.
    public nonisolated static func groupIsMixed(_ group: ProviderSurfaceGroup, selections: [String: SurfaceSelection], explicitSurfaces: Set<String>) -> Bool {
        guard groupHasOverride(group, explicitSurfaces: explicitSurfaces), let first = group.surfaces.first.map({ selections[$0] ?? .empty }) else {
            return false
        }
        return group.surfaces.dropFirst().contains { (selections[$0] ?? .empty) != first }
    }

    /// Whether the group holds a saved choice that "Use Chat's choice" would clear.
    /// `chat` is the root everything else inherits from and never clears.
    public nonisolated static func groupHasOverride(_ group: ProviderSurfaceGroup, explicitSurfaces: Set<String>) -> Bool {
        group.surfaces.contains { $0 != "chat" && explicitSurfaces.contains($0) }
    }

}
extension ProvidersFacade {
    public nonisolated static let chatComposerFallbackEfforts = ["low", "medium", "high", "xhigh"]

    public nonisolated static func reasoningOptions(
        from catalog: ModelCatalogResponse?, selectedModel: ModelCatalogItem?
    ) -> [ReasoningEffortOption] {
        let supported = selectedModel?.supportedReasoningEfforts ?? chatComposerFallbackEfforts
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

    public nonisolated static func modelOptions(from catalog: ModelCatalogResponse?, current: String, limit: Int = 80) -> [ModelCatalogItem] {
        let fallbackModels = (
            FirstPartyModelCatalog.publicOpenAIModels
            + FirstPartyModelCatalog.anthropicModels
            + FirstPartyModelCatalog.xAIModels
        ).enumerated().map { index, model in
            ModelCatalogItem(
                id: model.id,
                displayName: model.name,
                description: nil,
                defaultReasoningEffort: model.defaultReasoningEffort,
                supportedReasoningEfforts: model.supportedReasoningEfforts,
                supportsFast: model.supportsFast,
                priority: index
            )
        }
        let sourceModels = catalog?.models ?? CodexSelectableModelCatalog.modelCatalogItems() + fallbackModels
        var seen: Set<String> = []
        var models: [ModelCatalogItem] = []

        if let currentModel = sourceModels.first(where: { $0.id == current }), seen.insert(currentModel.id).inserted {
            models.append(currentModel)
        } else if !current.isEmpty, seen.insert(current).inserted {
            models.append(ModelCatalogItem(id: current, displayName: current, description: "Custom model", defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], supportsFast: nil, priority: 999))
        }

        for model in sourceModels {
            guard seen.insert(model.id).inserted else { continue }
            models.append(model)
            if models.count >= limit { break }
        }
        return models
    }

    public nonisolated static func reasoningOptions(from catalog: ModelCatalogResponse?, model: String) -> [ReasoningEffortOption] {
        ProviderRouting.reasoningOptions(available: catalog?.reasoningEfforts ?? defaultReasoningEffortOptions,
            supported: catalog?.models.first(where: { $0.id == model })?.supportedReasoningEfforts, id: { $0.id })
    }

    public nonisolated static func normalizedReasoningEffort(from catalog: ModelCatalogResponse?, model: String, selected: String) -> String {
        ProviderRouting.normalizedReasoningEffort(options: reasoningOptions(from: catalog, model: model).map(\.id),
            preferred: catalog?.models.first(where: { $0.id == model })?.defaultReasoningEffort, selected: selected)
    }
}

public struct ChatComposerModelGroup: Identifiable {
    @MainActor private static var previousConnections: [ProviderInfo]?
    @MainActor private static var previousCatalog: ModelCatalogResponse?
    @MainActor private static var previousProvider = ""
    @MainActor private static var previousGroups: [Self] = []

    @MainActor public static func groups(
        connections: [ProviderInfo], catalog: ModelCatalogResponse?, providerID: String
    ) -> [Self] {
        if previousConnections == connections, previousCatalog == catalog, previousProvider == providerID {
            return previousGroups
        }
        // One pass over the catalog, not one search per model: this runs on
        // every hover and OpenRouter alone is hundreds of rows (User 09-27).
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
                // The provider in use leads; the rest are alphabetical.
                if (lhs.provider_id == providerID) != (rhs.provider_id == providerID) {
                    return lhs.provider_id == providerID
                }
                return lhs.display_name < rhs.display_name
            }
            .compactMap { provider in
                let models = provider.models.map { item in
                    let catalogModel = catalogById[item.id]
                    // Provider-scoped capabilities stay authoritative: the
                    // global catalog holds duplicate ids for transports with
                    // different contracts.
                    return ModelCatalogItem(
                        id: item.id,
                        displayName: item.name,
                        description: catalogModel?.description,
                        defaultReasoningEffort: item.default_reasoning_effort
                            ?? catalogModel?.defaultReasoningEffort ?? "high",
                        supportedReasoningEfforts: item.supported_reasoning_efforts
                            ?? catalogModel?.supportedReasoningEfforts
                            ?? ProvidersFacade.chatComposerFallbackEfforts,
                        supportsFast: item.supports_fast ?? catalogModel?.supportsFast,
                        priority: catalogModel?.priority ?? 0
                    )
                }
                guard !models.isEmpty else { return nil }
                return ChatComposerModelGroup(
                    id: provider.provider_id,
                    provider: provider.display_name,
                    models: models
                )
            }
        previousConnections = connections
        previousCatalog = catalog
        previousProvider = providerID
        previousGroups = groups
        return groups
    }
    public let id: String
    public let provider: String
    public let models: [ModelCatalogItem]

    public init(id: String, provider: String, models: [ModelCatalogItem]) {
        self.id = id
        self.provider = provider
        self.models = models
    }

    /// A provider whose models are "company/model" and too many for one list
    /// opens to its companies first (OpenRouter: ~460 models, 63 companies).
    @MainActor private static var vendorInput: [ModelCatalogItem] = []
    @MainActor private static var vendorOutput: [Self]?

    @MainActor public var vendorGroups: [ChatComposerModelGroup]? {
        guard models.count > 40, models.allSatisfy({ $0.id.contains("/") }) else { return nil }
        if Self.vendorInput == models { return Self.vendorOutput }
        let byVendor = Dictionary(grouping: models) { String($0.id.prefix { $0 != "/" }) }
        let groups = byVendor.keys
            .map { ChatComposerModelGroup(id: $0, provider: Self.vendorName($0), models: byVendor[$0] ?? []) }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
        Self.vendorInput = models
        Self.vendorOutput = groups
        return groups
    }

    private static let knownVendorNames = [
        "openai": "OpenAI", "anthropic": "Anthropic", "google": "Google", "x-ai": "xAI",
        "meta-llama": "Meta", "mistralai": "Mistral", "qwen": "Qwen", "deepseek": "DeepSeek",
        "z-ai": "Z.ai", "nvidia": "NVIDIA", "moonshotai": "Moonshot", "microsoft": "Microsoft",
        "amazon": "Amazon", "cohere": "Cohere", "perplexity": "Perplexity", "minimax": "MiniMax",
    ]

    public static func vendorName(_ id: String) -> String {
        if let known = knownVendorNames[id] { return known }
        return id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - provider

/// The `provider` tool over the Providers page's own calls: the account list,
/// the account sheet's Test the connection, the page's Refresh, and the
/// sheet's Save with only "Model it falls back to" changed — no key, and the
/// sign-in method the sheet itself would keep.
extension ProvidersFacade {
    @MainActor
    public static func runQuietProvider(
        verb: String, input: [String: JSONValue], dataRoot: URL,
        refresh: () async -> (accounts: [ProviderInfo], failure: String?),
        list: () async throws -> [ProviderInfo],
        test: (String) async throws -> NativeAgentShared.ProviderTestResult,
        authMode: (ProviderInfo) -> (canSave: Bool, selectedMode: String),
        configure: (String, String, String) async throws -> Void,
        reload: () async -> Void,
        disconnect: (String) async -> (ok: Bool, detail: String)
    ) async -> JSONValue {
        let retry = " Try again; read \(AppToolExecutor.doorDoctor) if it keeps failing."
        if verb == "refresh_models" {
            let refreshed = await refresh()
            if let detail = refreshed.failure {
                return AppToolExecutor.failure("refresh_failed", "The model lists did not refresh: \(detail)." + retry, extra: ["effects": .string("unknown")])
            }
            await reload()
            return .object([
                "status": .string("ok"),
                "detail": .string("Fetched every account's model list again, as the page's Refresh does."),
                "accounts": .array(refreshed.accounts.map { quietProviderRow($0) }),
            ])
        }
        let accounts: [ProviderInfo]
        do { accounts = try await list() } catch {
            return AppToolExecutor.failure("providers_unreadable", "The accounts didn't read (\(error.localizedDescription))." + retry)
        }
        if verb == "list" {
            return .object(["status": .string("ok"), "accounts": .array(accounts.map { quietProviderRow($0) })])
        }
        let id = AppToolExecutor.inputString(input["provider"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let account = accounts.first(where: { $0.provider_id == id }) else {
            return AppToolExecutor.failure(
                "unknown_provider",
                (id.isEmpty ? "Pass provider" : "No account has id \(id)") + ". app {page:\"providers\"} lists them.",
                extra: ["providers": .array(accounts.map { .string($0.provider_id) })])
        }
        let name = account.display_name
        switch verb {
        case "test":
            let result: NativeAgentShared.ProviderTestResult
            do { result = try await test(id) } catch {
                return AppToolExecutor.failure("test_failed", "The test of \(name) could not run: \(error.localizedDescription)." + retry, extra: ["effects": .string("unknown")])
            }
            let works = result.tested && result.status == "ok"
            let problem = NativeAppSecretRedactor.redactText(result.error ?? result.detail ?? result.status)
            let detail = works
                ? "\(name) works: it answered\(result.model_used.map { " on \($0)" } ?? "")."
                : result.tested
                    ? "\(name) did not work: \(problem). A rejected key or expired sign-in is the owner's to fix: ask them to reconnect \(name) in Providers."
                    : "\(name) has no connection test, so nothing was checked. \(result.detail ?? "")"
            var body: [String: JSONValue] = [
                "status": .string("ok"), "provider": .string(id), "tested": .bool(result.tested),
                // Untested is unknown, not broken.
                "works": result.tested ? .bool(works) : .null, "detail": .string(detail),
            ]
            if let model = result.model_used { body["model_used"] = .string(model) }
            return .object(body)
        case "set_default_model":
            guard account.auth_status.eligible else {
                return AppToolExecutor.failure(
                    "not_connected",
                    "\(name) is not connected, so it has no fallback model to set. Connecting it is the owner's: ask them to sign in on Providers.")
            }
            let offered = account.models.map(\.id)
            guard !offered.isEmpty else {
                return AppToolExecutor.failure(
                    "no_model_list",
                    "\(name)'s model list isn't loaded, so there is nothing to choose from. Run provider.refresh, then try again.")
            }
            let model = AppToolExecutor.inputString(input["model"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard offered.contains(model) else {
                return AppToolExecutor.failure(
                    "bad_model",
                    (model.isEmpty ? "Pass model" : "\(model) is not a model \(name) offers")
                        + ". It takes one of: \(offered.joined(separator: ", ")).")
            }
            // The sheet's own picker state: the saved sign-in method, kept.
            let mode = authMode(account)
            guard mode.canSave else {
                return AppToolExecutor.failure(
                    "sign_in_method_unclear",
                    "\(name)'s saved sign-in method isn't one its sheet can keep, so nothing was changed. That's the owner's: ask them to open \(name) in Providers.")
            }
            let old = account.default_model ?? ""
            do {
                try await configure(id, mode.selectedMode, model)
            } catch {
                return AppToolExecutor.failure("save_failed", "\(name)'s fallback model was not saved: \(error.localizedDescription)." + retry, extra: ["effects": .string("unknown")])
            }
            await reload()
            return .object([
                "status": .string("ok"), "provider": .string(id), "changed": .bool(old != model),
                "old_value": .string(old), "new_value": .string(model),
                "detail": .string("\(name) now falls back to \(model) wherever no other model is chosen for it."),
            ])
        case "disconnect":
            // The sheet's Remove the key. User's below Full Mac; the door
            // refuses it there.
            let outcome = await disconnect(id)
            guard outcome.ok else {
                return AppToolExecutor.failure("disconnect_failed",
                    "\(outcome.detail) app {page:\"providers\"} shows where \(name) stands.",
                    extra: ["provider": .string(id), "effects": .string("unknown")])
            }
            HarnessDecidedRow.post(requester: "Full Mac", tool: "provider.disconnect \(id)",
                                   sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                   dataRoot: dataRoot)
            return .object(["status": .string("ok"), "provider": .string(id), "changed": .bool(true),
                            "detail": .string("\(name) is disconnected. \(outcome.detail) Signing back in is the owner's.")])
        default:
            return AppToolExecutor.failure("unknown_verb", "No provider verb is called \(verb).")
        }
    }

    /// The account as its line on the page reads: eligible, and the row's own
    /// words for how far its key is proven (saved, checked, rejected, could not check).
    private static func quietProviderRow(_ account: ProviderInfo) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(account.provider_id),
            "name": .string(account.display_name),
            "connected": .bool(account.auth_status.eligible),
            "state": .string(account.auth_status.state),
            "detail": .string(account.auth_status.detail),
            "fallback_model": .string(account.default_model ?? ""),
            "models": .array(account.models.map { .string($0.id) }),
        ]
        if let note = account.models_note { row["models_note"] = .string(note) }
        return .object(row)
    }
}

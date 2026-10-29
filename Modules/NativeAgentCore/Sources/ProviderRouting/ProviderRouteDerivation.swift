import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderRouteDerivation.swift` | Route and catalog derivation from one checked provider snapshot; unknown context windows remain unknown |

extension SwiftNativeProviderRouting {
    func routingSnapshot(
        surfaces: [String: JSONValue],
        activeProviders: [String: String],
        soleConnectedRoute: String?,
        configCache: ProviderConfigCache?,
        revision: Double = 0
    ) -> ProviderRoutingSnapshot {
        let surfacesFile = JSONValue.object(surfaces)
        let (parsedSurfaceModels, parsedSurfaceEfforts, parsedSurfaceServiceTiers) = Self.parseSurfacesFile(surfacesFile)
        // Interpret saved picks against route catalogs without rewriting disk state.
        let accountCatalogs = CodexAccountModelCatalog.chatGPTOAuthCatalogs(dataRoot: dataRoot)
        var cachedModelIDs = accountCatalogs.mapValues { Set($0.map { $0.id.lowercased() }) }
        if let moonshotModels = MoonshotModelCatalog.readCache(dataRoot: dataRoot) {
            cachedModelIDs["moonshot"] = Set(moonshotModels.map { $0.id.lowercased() })
        }
        let retiredPickSurfaces = Self.surfacesWithRetiredPicks(
            parsedSurfaceModels, accountModels: cachedModelIDs
        ) {
            [weak self] surface, model in
            activeProviders[surface]
                ?? activeProviders["chat"]
                ?? self?.inferProviderForModel(model)
        }
        // Retain unusable saved IDs for picker notices and execution refusals.
        var unusablePicks: [String: String] = [:]
        if case .object(let parsed) = parsedSurfaceModels {
            for surface in retiredPickSurfaces {
                guard case .string(let unusable)? = parsed[surface] else { continue }
                let route = activeProviders[surface] ?? activeProviders["chat"]
                if FirstPartyModelCatalog.descriptor(for: unusable) == nil {
                    unusablePicks[surface] = "Your model, \(unusable), is no longer offered, so an available model must be chosen in Providers."
                } else if let route {
                    unusablePicks[surface] = "\(unusable) isn't offered on \(route), so an available model must be chosen in Providers."
                } else {
                    unusablePicks[surface] = "\(unusable) isn't offered, so an available model must be chosen in Providers."
                }
            }
        }
        let surfaceModels = Self.dropping(retiredPickSurfaces, from: parsedSurfaceModels)
        let surfaceEfforts = Self.dropping(retiredPickSurfaces, from: parsedSurfaceEfforts)
        let surfaceServiceTiers = Self.dropping(retiredPickSurfaces, from: parsedSurfaceServiceTiers)
        let routesBeforeRetirement = activeProviders
        let activeProviders = activeProviders.filter {
            // Chat's own route is never dropped: it is the answer everything else inherits, and losing it would strand the whole install.
            $0.key == "chat" || !retiredPickSurfaces.contains($0.key)
        }
        // Chat uses an explicit picker choice, including a saved provider-sheet choice. Connecting an account without a choice leaves its model unset. Retain the exact connected route, never just its family name.
        let chatRoute = activeProviders["chat"] ?? soleConnectedRoute
        // Read defaults from the same cached generation as credential readiness.
        let savedDefaults = savedProviderDefaults(
            for: Set(activeProviders.values).union(chatRoute.map { [$0] } ?? []),
            cache: configCache
        )
        let offeredModels = Dictionary(uniqueKeysWithValues:
            Set(routesBeforeRetirement.values).union(chatRoute.map { [$0] } ?? []).map { route in
                (route, modelsForProvider(route).compactMap { $0["id"]?.stringValue })
            })
        for (surface, route) in activeProviders.merging(chatRoute.map { ["chat": $0] } ?? [:], uniquingKeysWith: { first, _ in first }) {
            guard Self.stringFrom(parsedSurfaceModels, key: surface) == nil,
                  case .model(let saved)? = savedDefaults[route] else { continue }
            let offered = offeredModels[route] ?? []
            if !offered.isEmpty, !offered.contains(saved) {
                unusablePicks[surface] = "\(saved) isn't offered on \(route), so an available model must be chosen in Providers."
            }
        }
        // An unusable Chat pick stays unset; provider-sheet defaults are explicit picks too.
        let chatModelRaw = Self.stringFrom(surfaceModels, key: "chat")
            ?? (unusablePicks["chat"] != nil
                ? nil
                : chatRoute.flatMap { defaultModelForProvider($0, offered: offeredModels[$0] ?? [], savedDefaults: savedDefaults) })
            ?? ""
        let chatModel = Self.normalizeModelIdStatic(chatModelRaw, fallback: "")
        let chatEffortRaw = Self.stringFrom(surfaceEfforts, key: "chat") ?? DEFAULT_REASONING_EFFORT
        let chatEffort = Self.normalizeReasoningEffortStatic(
            chatEffortRaw,
            fallback: DEFAULT_REASONING_EFFORT,
            model: chatModel,
            providerID: activeProviders["chat"],
            supportedReasoningEfforts: accountCatalogs[chatRoute ?? ""]?
                .first { $0.id == chatModel }?.supportedReasoningEfforts
        )
        let chatServiceTier = Self.normalizeServiceTierStatic(
            Self.stringFrom(surfaceServiceTiers, key: "chat") ?? "default"
        )
        // ProviderSurfaceGroups owns membership. Every member resolves to its group's unanimous tuple, otherwise Chat's. Effort is independent: an effort-only group keeps Chat's current model and account. A stray per-surface pin is shown
        // by the page, never splits group routing.
        struct CanonicalTuple: Equatable {
            let model: String
            let effort: String
            let serviceTier: String
            let provider: String?
        }
        let chatTuple = CanonicalTuple(
            model: chatModel,
            effort: chatEffort,
            serviceTier: chatServiceTier,
            provider: chatRoute
        )
        func tuple(
            for surface: String,
            models: JSONValue,
            efforts: JSONValue,
            tiers: JSONValue,
            routes: [String: String]
        ) -> CanonicalTuple? {
            let saved = Self.stringFrom(models, key: surface)
            guard saved != nil || routes[surface] != nil
                || Self.stringFrom(efforts, key: surface) != nil else { return nil }
            let provider = routes[surface] ?? chatRoute
            let model = Self.normalizeModelIdStatic(
                saved ?? (routes[surface] == nil ? chatModel : provider.flatMap { defaultModelForProvider($0, offered: offeredModels[$0] ?? [], savedDefaults: savedDefaults) } ?? ""),
                fallback: ""
            )
            // Keep a provider-only assignment even without a default: it needs a model selection, rather than silently inheriting Chat's account.
            guard !model.isEmpty || routes[surface] != nil else { return nil }
            return CanonicalTuple(
                model: model,
                effort: Self.normalizeReasoningEffortStatic(
                    Self.stringFrom(efforts, key: surface) ?? chatEffort,
                    fallback: chatEffort,
                    model: model,
                    providerID: provider,
                    supportedReasoningEfforts: accountCatalogs[provider ?? ""]?
                        .first { $0.id == model }?.supportedReasoningEfforts
                ),
                serviceTier: Self.normalizeServiceTierStatic(
                    Self.stringFrom(tiers, key: surface) ?? chatServiceTier
                ),
                provider: provider
            )
        }
        func savedTuple(for surface: String) -> CanonicalTuple? {
            tuple(for: surface, models: surfaceModels, efforts: surfaceEfforts,
                  tiers: surfaceServiceTiers, routes: activeProviders)
        }
        // Retired overrides refuse only where the saved group tuple was unanimous. A stray key keeps its picker notice without blocking its inheriting group.
        var retiredOverrideSurfaces: Set<String> = []
        for group in ProviderSurfaceGroups.all where group.id != ProviderSurfaceGroups.chat.id {
            guard group.surfaces.allSatisfy(retiredPickSurfaces.contains) else { continue }
            let saved = group.surfaces.map {
                tuple(for: $0, models: parsedSurfaceModels, efforts: parsedSurfaceEfforts,
                      tiers: parsedSurfaceServiceTiers, routes: routesBeforeRetirement)
            }
            if let first = saved.first ?? nil, saved.allSatisfy({ $0 == first }) {
                retiredOverrideSurfaces.formUnion(group.surfaces)
            }
        }
        var canonicalByGroup: [String: CanonicalTuple] = [:]
        for group in ProviderSurfaceGroups.all {
            if group.id == ProviderSurfaceGroups.chat.id {
                canonicalByGroup[group.id] = chatTuple
                continue
            }
            // A group overrides Chat only when every member has the same complete model/provider/effort/tier tuple; otherwise the group inherits Chat.
            let members = group.surfaces.map(savedTuple)
            let first = members.first ?? nil
            let unanimous = !members.contains(where: { $0 == nil })
                && members.allSatisfy {
                    $0?.model == first?.model
                        && $0?.provider == first?.provider
                        && $0?.effort == first?.effort
                        && $0?.serviceTier == first?.serviceTier
                }
            canonicalByGroup[group.id] = unanimous
                ? (members.first ?? chatTuple) ?? chatTuple
                : chatTuple
        }
        var out: [String: SurfacePreference] = [:]
        var resolvedProviders: [String: String] = [:]
        var mismatchedPicks: [String: String] = [:]
        for surface in MODEL_SURFACES {
            // Resolve each surface through its group; stray saved keys cannot split it.
            let canonical = ProviderSurfaceGroups.group(for: surface)
                .flatMap { canonicalByGroup[$0.id] } ?? chatTuple
            // Model and account travel together; use a surface route only if the canonical tuple has no provider.
            let route = canonical.provider ?? activeProviders[surface]
            // Provider-only choices may use saved sheet picks; unusable Chat picks and retired effective group overrides must stay unset instead.
            let unusableBlocksFallback = retiredOverrideSurfaces.contains(surface)
                || unusablePicks["chat"] != nil
            let model = canonical.model.isEmpty
                ? (unusableBlocksFallback
                    ? ""
                    : Self.normalizeModelIdStatic(
                        route.flatMap { defaultModelForProvider($0, offered: offeredModels[$0] ?? [], savedDefaults: savedDefaults) } ?? "",
                        fallback: ""
                    ))
                : canonical.model
            // Refuse a model/account mismatch explicitly without substituting a model.
            var effectiveModel = retiredOverrideSurfaces.contains(surface) ? "" : model
            if !effectiveModel.isEmpty, let route,
               let family = inferProviderForModel(model),
               !Self.providerCanServeModel(route, inferredProvider: family) {
                mismatchedPicks[surface] = "\(model) isn't available on \(route). Choose one."
                effectiveModel = ""
            }
            let effort = Self.normalizeReasoningEffortStatic(
                canonical.effort,
                fallback: DEFAULT_REASONING_EFFORT,
                model: effectiveModel,
                providerID: route,
                supportedReasoningEfforts: accountCatalogs[route ?? ""]?
                    .first { $0.id == effectiveModel }?.supportedReasoningEfforts
            )
            if let route, !route.isEmpty { resolvedProviders[surface] = route }
            out[surface] = SurfacePreference(
                surface: surface,
                model: effectiveModel,
                reasoningEffort: effort,
                serviceTier: canonical.serviceTier,
                modelKnown: nil
            )
        }
        var pinnedModels: [String: String] = [:]
        if case .object(let models) = surfaceModels {
            for (surface, value) in models {
                guard case .string(let model) = value, !model.isEmpty else { continue }
                pinnedModels[surface] = model
            }
        }
        return ProviderRoutingSnapshot(
            preferences: out,
            activeProviders: resolvedProviders,
            pinnedModels: pinnedModels,
            unusablePicks: unusablePicks.merging(mismatchedPicks) { saved, _ in saved },
            revision: revision
        )
    }
    /// Lookup a single surface. Throws `.invalidRequest` if the surface is not a known MODEL_SURFACE.
    public func modelForSurface(_ surface: String) async throws -> SurfacePreference {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface) else {
            throw ProviderRoutingError.invalidRequest
        }
        let prefs = try await computeModelPreferences()
        // computeModelPreferences seeds every MODEL_SURFACE, so this is total.
        guard let preference = prefs[surface] else {
            throw ProviderRoutingError.configurationFailed("No resolved model preference for \(surface).")
        }
        return preference
    }
    /// Chat's chosen route, for sizing a window on the selected model; nil when routing cannot be read, and the window then stays unknown.
    public func chatRouteProvider() async -> String? {
        (try? await checkedRoutingSnapshot()).flatMap { ProviderRoutingSurfaceLookup.value($0.activeProviders, "chat") }
    }
    /// The provider a model id names, or nil when its spelling names none (the caller then keeps the explicit route). Routing, the picker and dispatch all read this one answer.
    public nonisolated func inferProviderForModel(_ modelId: String) -> String? {
        Self.inferredProviderID(forModel: modelId, dataRoot: dataRoot)
    }
    /// Size background evidence from the selected route's catalog without a second read of the saved selection. OpenRouter reads through its own catalog (cache, TTL refresh, failure backoff); `catalogFailure` is why that list could not be
    /// fetched when the model is missing from it.
    public func catalogContextLength(forModel modelID: String, providerID: String) async
        -> (contextLength: Int?, catalogFailure: String?) {
        let openRouter = providerID == "openrouter"
            ? await OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot) : nil
        let catalog = catalogRows(providerID, openRouterModels: openRouter?.models)
        let length = Self.contextLength(of: modelID, in: catalog.rows)
        return (length, length == nil ? catalog.fault ?? openRouter?.failure : nil)
    }
    /// A route's catalog rows as its picker shows them: the account or provider cache under this root, else the rows this build ships when none is saved. A saved list that cannot be read gives no rows and its fault.
    nonisolated func catalogRows(_ providerID: String, openRouterModels: [ProviderModelInfo]? = nil)
        -> (rows: [[String: JSONValue]], fault: String?) {
        let fault = switch providerID {
        case "codex", "openai_oauth_direct": CodexAccountModelCatalog.cacheFault(dataRoot: dataRoot)
        case "openrouter" where openRouterModels == nil: OpenRouterModelCatalog.cacheFault(dataRoot: dataRoot)
        case "moonshot": MoonshotModelCatalog.cacheFault(dataRoot: dataRoot)
        default: String?.none
        }
        if let fault { return ([], fault) }
        let openRouter = providerID == "openrouter"
            ? openRouterModels ?? OpenRouterModelCatalog.readCache(dataRoot: dataRoot) : nil
        let moonshot = providerID == "moonshot" ? MoonshotModelCatalog.readCache(dataRoot: dataRoot) : nil
        return (modelsForProvider(providerID, openRouterModels: openRouter?.map { $0.providerJSON() },
                                  moonshotModels: moonshot?.map { $0.providerJSON() }), nil)
    }
    /// The window a catalog row states for `modelID`; nil when no row states one.
    nonisolated static func contextLength(of modelID: String, in rows: [[String: JSONValue]]) -> Int? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let row = rows.first(where: {
            guard case .string(let rowID)? = $0["id"] else { return false }
            return rowID.lowercased() == id
        }), case .int(let length)? = row["context_length"], length > 0 else { return nil }
        return Int(exactly: length)
    }
    /// `dataRoot` adds the live Moonshot catalog's ids, which need not carry its prefix; without one only shipped rows answer.
    public nonisolated static func inferredProviderID(forModel modelId: String, dataRoot: URL? = nil) -> String? {
        let lower = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return nil }
        // A vendor/model id is the OpenRouter namespace.
        if lower.contains("/") { return "openrouter" }
        if lower.hasPrefix("claude") { return "anthropic_oauth_direct" }
        if lower.hasPrefix("gpt") { return "openai_oauth_direct" }
        if lower.hasPrefix("grok") { return "xai_oauth_direct" }
        // Kimi Code SUBSCRIPTION ids (kimi-for-coding[-highspeed], k3.1-pro[-highspeed], bare k3).
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower) { return "kimi-code" }
        // Moonshot by declared id: its shipped rows and its live catalog, never a prefix.
        if FirstPartyModelCatalog.descriptor(for: lower, providerID: "moonshot") != nil
            || dataRoot.map({ MoonshotModelCatalog.isKnownCatalogModelID(lower, dataRoot: $0) }) == true {
            return "moonshot"
        }
        return nil
    }
    private nonisolated func defaultModelForProvider(
        _ providerId: String,
        offered: [String],
        savedDefaults: [String: SavedProviderDefault]? = nil
    ) -> String? {
        // A saved provider-sheet choice may be inherited. Catalog ordering never chooses a model for a surface without an explicit pick.
        switch savedDefaults?[providerId] ?? configuredDefaultModel(providerId) {
        case .model(let saved):
            if offered.isEmpty || offered.contains(saved) { return saved }
            FileHandle.standardError.write(Data(
                "[provider-routing] \(providerId) no longer offers saved default '\(saved)'; choose a model in the picker\n".utf8
            ))
            return nil
        case .unreadable(let reason):
            // Corrupt authority cannot authorize a different model selection.
            FileHandle.standardError.write(Data(
                "[provider-routing] keeping the current model: \(reason)\n".utf8
            ))
            return nil
        case .absent:
            break
        }
        return nil
    }
    /// What `providers/<id>.json` says about the provider's `default_model`. Absent and unreadable are distinct; corruption cannot become a catalog default.
    enum SavedProviderDefault {
        case absent
        case model(String)
        case unreadable(String)
        /// The saved pick, or nil for both absent and unreadable. Callers that must distinguish the two switch on the case instead.
        var model: String? {
            if case .model(let id) = self { return id }
            return nil
        }
    }
    /// The `default_model` the person picked in the provider sheet, read from `providers/<id>.json` (where `configureProvider` writes it). Reuse a snapshot's locked config generation, or read through its file owner.
    private nonisolated func configuredDefaultModel(
        _ providerId: String,
        cache: ProviderConfigCache? = nil
    ) -> SavedProviderDefault {
        let trimmedId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedId.contains("/") else { return .absent }
        let read = cache?.reads[trimmedId] ?? readProviderConfig(trimmedId)
        if let reason = read.unreadable { return .unreadable(reason) }
        guard let object = read.object else { return .absent }
        for key in ["default_model", "defaultModel"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return .model(trimmed) }
            }
        }
        return .absent
    }
    /// Read each provider's saved config ONCE per routing snapshot, so every surface in that snapshot resolves against the same bytes.
    private nonisolated func savedProviderDefaults(
        for providerIds: Set<String>,
        cache: ProviderConfigCache? = nil
    ) -> [String: SavedProviderDefault] {
        var out: [String: SavedProviderDefault] = [:]
        for id in providerIds {
            out[id] = configuredDefaultModel(id, cache: cache)
        }
        return out
    }
    /// Bare GPT ids are shared by direct OpenAI transports and the Codex CLI. Compatibility must not normalize Codex into OpenAI because adapter selection still needs to preserve the user's exact auth route.
    nonisolated static func providerCanServeModel(
        _ activeProvider: String,
        inferredProvider: String
    ) -> Bool {
        let active = normalizeProviderId(activeProvider)
        let inferred = normalizeProviderId(inferredProvider)
        return active == inferred || (active == "codex" && inferred == "openai")
    }
}

/// The one context window for an admitted provider/model tuple: the row that route's catalog states (its account or provider cache under `dataRoot`, else the rows this build ships), the same row its picker shows. Nil when no row states
/// one: callers keep unknown as unknown. Without a provider, the smallest window this build ships for the id.
public func verifiedContextLength(
    forModel modelId: String,
    providerID: String?,
    dataRoot: URL? = nil
) -> Int? {
    let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !model.isEmpty else { return nil }
    guard let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !provider.isEmpty else {
        return FirstPartyModelCatalog.descriptor(for: model)?.contextLength
    }
    // A route with neither a shipped nor a fetched catalog carries no evidence.
    guard provider == "openrouter" || !FirstPartyModelCatalog.models(forProviderID: provider).isEmpty else { return nil }
    let rows = dataRoot.map { SwiftNativeProviderRouting(dataRoot: $0).catalogRows(provider).rows }
        ?? FirstPartyModelCatalog.models(forProviderID: provider).map { $0.providerJSON() }
    return SwiftNativeProviderRouting.contextLength(of: model, in: rows)
}

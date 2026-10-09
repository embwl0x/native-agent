import Foundation
import Observation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting

/// `NativeAgentEngine.providers` (S10): provider routing for one data root.
/// The chat picker, Setup, Telegram and the Providers page render
/// `connections` (each provider's auth state and models) and `catalog` (the
/// selectable models plus each surface's saved pick); the Providers page reads
/// the per-surface rows from core `routing`. Reads are nonisolated so the phone
/// lanes use the same owner. Writes still run through the provider executors
/// (`NativeClient.configureProvider`, `setActiveProvider`, `configureModel`…).
@MainActor
@Observable
public final class ProvidersFacade {
    public nonisolated let dataRoot: URL

    /// Every provider connection, as of the last read.
    public var connections: [ProviderInfo] = []
    /// The model catalog and each surface's pick, as of the last read or write.
    public var catalog: ModelCatalogResponse?
    public var codexAuth: CodexAuthStatus?
    public private(set) var accountModelRevision = 0
    private var accountModelRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var accountModelUpdatesTask: Task<Void, Never>?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        let updates = NotificationCenter.default.notifications(named: ChatGPTAccountModelRefresh.didRefresh)
            .compactMap { $0.object as? URL }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.accountModelUpdatesTask = Task { [weak self] in
                for await root in updates {
                    guard let self else { return }
                    guard root == self.dataRoot.standardizedFileURL else { continue }
                    do {
                        self.connections = try await self.list()
                        self.catalog = try await self.modelCatalog(refresh: false)
                        self.accountModelRevision += 1
                    } catch {
                        nativeLog("ChatGPT account model catalog reload failed: %@", error.localizedDescription)
                    }
                }
            }
        }
    }

    deinit {
        accountModelUpdatesTask?.cancel()
    }

    /// Core routing for this root: active provider per surface, saved picks,
    /// the Providers page's row set.
    public nonisolated var routing: SwiftNativeProviderRouting {
        SwiftNativeProviderRouting(dataRoot: dataRoot)
    }

    /// `<dataRoot>/providers/active.json` (surface → provider). Missing is
    /// empty; damaged existing state throws.
    public nonisolated func activeProviders() async throws -> [String: String] {
        try await routing.readActiveProvidersChecked()
    }

    /// UI maintenance returns immediately; no turn waits for account discovery.
    public nonisolated func refreshAccountModelsInBackground() {
        Task { @MainActor [weak self] in
            guard let self, self.accountModelRefreshTask == nil else { return }
            self.accountModelRefreshTask = Task {
                defer { self.accountModelRefreshTask = nil }
                do {
                    _ = try await ChatGPTAccountModelRefresh.shared.refresh(dataRoot: self.dataRoot)
                } catch {
                    nativeLog("ChatGPT account model refresh failed: %@", error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Connections

extension ProvidersFacade {
    public nonisolated func list(
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> [ProviderInfo] {
        let snapshot = try await routing.checkedProviderSnapshot(
            codexCacheURL: codexCacheURL, authEnvironment: authEnvironment
        )
        return try Self.connections(from: snapshot)
    }

    /// Presentation conversion only. ProviderRouting owns discovery, readiness,
    /// saved bookkeeping and the provider-specific model catalog.
    public nonisolated static func connections(from snapshot: ProviderCatalogSnapshot) throws -> [ProviderInfo] {
        snapshot.providers.compactMap { provider in
            let extras: [String: JSONValue]
            if case .object(let object)? = provider.extras { extras = object } else { extras = [:] }
            let modes: [String]
            if case .array(let values)? = extras["auth_modes"] {
                modes = values.compactMap { if case .string(let value) = $0 { return value }; return nil }
            } else { modes = [] }
            func string(_ key: String) -> String? {
                if case .string(let value)? = extras[key] { return value }
                return nil
            }
            guard let authStatus = try? JSONDecoder.nativeAgent.decode(
                    ProviderAuthStatus.self, from: JSONEncoder().encode(provider.oauthStatus)
                ),
                let models = try? JSONDecoder.nativeAgent.decode(
                    [ProviderModelInfo].self, from: JSONEncoder().encode(provider.modelCatalog)
                ) else { return nil }
            return ProviderInfo(
                provider_id: provider.id, display_name: provider.displayName ?? provider.id,
                auth_modes: modes, auth_status: authStatus, models: models,
                auth_mode: string("auth_mode"), default_model: string("default_model"),
                models_note: string("models_note")
            )
        }
    }

    /// One connection by id, exact first, then case-folded.
    public nonisolated func provider(id: String) async throws -> ProviderInfo {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentProvider", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "provider id is required"
            ])
        }
        let providers = try await list()
        if let exact = providers.first(where: { $0.provider_id == trimmed }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        if let folded = providers.first(where: { $0.provider_id.lowercased() == lowered }) {
            return folded
        }
        throw NSError(domain: "NativeAgentProvider", code: 404, userInfo: [
            NSLocalizedDescriptionKey: "provider not found: \(trimmed)"
        ])
    }
}

// MARK: - Catalog

extension ProvidersFacade {
    /// The provider-neutral model catalog with every surface's current pick
    /// (`current`) from one recovered routing snapshot.
    public nonisolated func modelCatalog(
        refresh: Bool,
        codexCacheURL: URL? = nil,
        routingSnapshot suppliedSnapshot: ProviderRoutingSnapshot? = nil
    ) async throws -> ModelCatalogResponse {
        let dataRoot = self.dataRoot
        // Swift-native cutover native impl (2026-06-02): was GET /v1/models. When
        // `<dataRoot>/providers/models.json` is present, decode it. When
        // missing, synthesize a baseline catalog (status=ok) so the
        // Providers UI has a non-empty selectable list. Surface prefs come
        // from `<dataRoot>/providers/surfaces.json` if present.
        var accountRefreshError: Error?
        if refresh {
            do {
                _ = try await ChatGPTAccountModelRefresh.shared.refresh(dataRoot: dataRoot, force: true)
            } catch {
                accountRefreshError = error
            }
        }
        let firstPartyModels = (
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
                priority: 100 + index
            )
        }
        let openRouterRead = await OpenRouterModelCatalog.modelsWithFreshness(
            dataRoot: dataRoot, refresh: refresh
        )
        // S12a: Refresh reaches Moonshot's fetched list too, so the Providers
        // page's "couldn't load models" line has a real retry behind it; the
        // provider rows (`list()`) read the result from its cache.
        if refresh {
            _ = await MoonshotModelCatalog.models(dataRoot: dataRoot, refresh: true)
        }
        // Discovery failure is catalog status, not a failed routing read:
        // callers must still publish the other providers' refreshed lists.
        let catalogFreshness = accountRefreshError == nil
            ? openRouterRead.freshness : .staleAfterFailedRefresh
        let catalogNote = accountRefreshError.map {
            ([$0.localizedDescription] + [openRouterRead.note].compactMap { $0 })
                .joined(separator: " — ")
        } ?? openRouterRead.note
        let openRouterCatalogModels = openRouterRead.models
            .enumerated()
            .map { index, model in
                ModelCatalogItem(
                    id: model.id,
                    displayName: model.name,
                    description: nil,
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                    supportsFast: false,
                    priority: 1_000 + index
                )
            }
        let routingSnapshot: ProviderRoutingSnapshot
        if let suppliedSnapshot { routingSnapshot = suppliedSnapshot }
        else { routingSnapshot = try await routing.checkedRoutingSnapshot() }
        let resolvedCodexCacheURL = codexCacheURL
            ?? CodexSelectableModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: dataRoot)
        let codexSelectableModels = CodexSelectableModelCatalog.modelCatalogItems(
            cacheURL: resolvedCodexCacheURL,
            useDefaultCacheWhenNil: false
        )
        func projectedPreference(_ surface: String) -> ModelSurfacePreference? {
            guard let preference = routingSnapshot.preferences[surface] else { return nil }
            return ModelSurfacePreference(
                surface: preference.surface,
                model: preference.model,
                reasoningEffort: preference.reasoningEffort,
                serviceTier: preference.serviceTier,
                source: nil,
                modelKnown: preference.modelKnown
            )
        }
        guard let chatPreference = projectedPreference("chat"),
              let telegramPreference = projectedPreference("telegram") else {
            throw NSError(
                domain: "NativeAgentProviderRouting",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "canonical routing snapshot is incomplete"]
            )
        }
        let canonicalCurrent = ModelRoutingCurrent(
            chat: chatPreference,
            telegram: telegramPreference,
            ios: projectedPreference("ios"),
            executions: projectedPreference(WorkshopSurfaceVocabulary.canonical),
            autonomy: projectedPreference("autonomy"),
            swarms: projectedPreference("swarms"),
            dream: projectedPreference("dream"),
            training: projectedPreference("training")
        )
        func withDiscoveredModels(_ catalog: ModelCatalogResponse) -> ModelCatalogResponse {
            var merged = catalog
            // models.json is only a compatibility/catalog cache. The picker
            // tuple always comes from Core's one recovered canonical snapshot.
            merged.current = canonicalCurrent
            merged.defaultModel = canonicalCurrent.chat.model
            // The on-disk models.json file is a compatibility cache, not an
            // authority for first-party capabilities. Replace matching rows
            // with the verified/current catalogs so a stale persisted entry
            // cannot hide Sonnet 5/Grok 4.5 or resurrect obsolete Think/Fast
            // flags. Account-backed GPT rows intentionally win duplicate ids
            // in this provider-neutral fallback; provider-scoped pickers use
            // list() and retain their exact transport contract.
            merged.catalogFreshness = catalogFreshness.rawValue
            merged.catalogNote = catalogNote
            let discoveredIDs = Set(
                (codexSelectableModels + firstPartyModels + openRouterCatalogModels).map(\.id)
            )
            merged.models.removeAll { discoveredIDs.contains($0.id) }
            // User, 2026-09-06: a legacy models.json row was only ever removed
            // when the SAME id came back in the new list, so a model OpenRouter
            // had dropped stayed selectable forever and picking it failed at
            // dispatch. A read that actually reached OpenRouter is authoritative
            // for OpenRouter's own rows — the namespaced `vendor/model` form,
            // which is exactly how LLMClient+Real routes an id to OpenRouter —
            // so those rows are replaced wholesale. A cached or failed read
            // prunes nothing: it has no standing to delete anything. User,
            // 2026-09-06: `.live` now also means the envelope claimed no
            // further page — a partial one is served and cached but labelled
            // `liveIncomplete`, so it adds rows and never deletes the ones it
            // did not mention.
            if openRouterRead.freshness.isLive {
                let liveOpenRouterIDs = Set(openRouterCatalogModels.map(\.id))
                merged.models.removeAll {
                    $0.id.contains("/") && !liveOpenRouterIDs.contains($0.id)
                }
            }
            var seen = Set(merged.models.map(\.id))
            for model in codexSelectableModels where seen.insert(model.id).inserted {
                merged.models.append(model)
            }
            for model in firstPartyModels where seen.insert(model.id).inserted {
                merged.models.append(model)
            }
            for model in openRouterCatalogModels where seen.insert(model.id).inserted {
                merged.models.append(model)
            }
            var seenEfforts = Set(merged.reasoningEfforts.map(\.id))
            let labels = ["none": "None", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"]
            for effort in (codexSelectableModels + firstPartyModels)
                .flatMap({ $0.supportedReasoningEfforts ?? [] })
                where seenEfforts.insert(effort).inserted {
                merged.reasoningEfforts.append(ReasoningEffortOption(
                    id: effort,
                    label: labels[effort] ?? effort.capitalized,
                    description: nil
                ))
            }
            merged.models.sort {
                let lhsPriority = $0.priority ?? 10_000
                let rhsPriority = $1.priority ?? 10_000
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return $0.displayName < $1.displayName
            }
            return merged
        }
        let modelsURL = dataRoot.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("models.json")
        if FileManager.default.fileExists(atPath: modelsURL.path),
           let data = try? Data(contentsOf: modelsURL),
           let decoded = try? JSONDecoder.nativeAgent.decode(ModelCatalogResponse.self, from: data) {
            return withDiscoveredModels(decoded)
        }

        // 2026-09-13: the catalog does not name a model of its own. Its default
        // is the person's saved Chat choice — empty when nothing is set up yet,
        // which the picker shows as "Choose".
        let defaultModel = canonicalCurrent.chat.model
        var seenBaseline = Set<String>()
        let baseline = (codexSelectableModels + firstPartyModels + openRouterCatalogModels)
            .filter { seenBaseline.insert($0.id).inserted }
        let efforts = defaultReasoningEffortOptions

        return ModelCatalogResponse(
            status: "ok",
            source: "first_party_capabilities_plus_signed_codex_and_openrouter",
            defaultModel: defaultModel,
            fallbackModels: [],
            models: baseline,
            reasoningEfforts: efforts,
            current: canonicalCurrent,
            updatedAt: nil,
            catalogFreshness: catalogFreshness.rawValue,
            catalogNote: catalogNote
        )
    }

    /// Read Codex auth status directly from disk. Mirrors the old route shape:
    /// `active` reflects whether OAuth tokens are usable, `appOwnedLoggedIn` /
    /// `sharedLoggedIn` distinguish the two storage paths.
    public nonisolated func codexAuthStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowEnvironmentOverride: Bool = true
    ) async throws -> CodexAuthStatus {
        let dataRoot = self.dataRoot
        let codexHome: String = {
            if allowEnvironmentOverride,
               let h = environment["CODEX_HOME"], !h.isEmpty {
                return (h as NSString).expandingTildeInPath
            }
            return dataRoot
                .appendingPathComponent("codex_home", isDirectory: true).path
        }()
        let path = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        var loggedIn = false
        var detail = "no auth.json on disk"
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = obj["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            loggedIn = true
            detail = "OAuth tokens present"
        } else if (try? Data(contentsOf: path)) != nil {
            detail = "auth.json present but tokens missing"
        }
        return CodexAuthStatus(
            active: loggedIn ? "oauth" : "none",
            appOwnedLoggedIn: loggedIn,
            sharedLoggedIn: loggedIn,
            codexHome: codexHome,
            detail: detail
        )
    }
}

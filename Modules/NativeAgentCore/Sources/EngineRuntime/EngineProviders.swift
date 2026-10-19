import Foundation
import Observation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import DeviceSync

/// `NativeAgentEngine.providers` (S10): provider routing for one data root.
/// The chat picker, Setup, Telegram and the Providers page render
/// `connections` (each provider's auth state and models) and `catalog` (the
/// selectable models plus each surface's saved pick); the Providers page reads
/// the per-surface rows from core `routing`. Reads and writes are nonisolated
/// so the phone lanes use the same owner: `configureProvider`,
/// `saveSurfaceSelection`, and `routing` for the active-provider pin.
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

    public struct ChatBrainSelection: Equatable, Sendable {
        public var model: String
        public var reasoningEffort: String
        public var fastMode: Bool

        public init(model: String, reasoningEffort: String, fastMode: Bool) {
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.fastMode = fastMode
        }
    }

    public enum ChatBrainSaveResult: Equatable, Sendable {
        case unchanged(ChatBrainSelection)
        case saved(ChatBrainSelection)
        case failed(message: String, rolledBackTo: ChatBrainSelection?, cause: String? = nil)
    }

    public var isSavingChatBrain = false
    @ObservationIgnored public var chatBrainCanonicalSelection: ChatBrainSelection?
    @ObservationIgnored var chatBrainPendingSave: (generation: UInt64, selection: ChatBrainSelection)?
    @ObservationIgnored public var chatBrainSaveGeneration: UInt64 = 0
    @ObservationIgnored var chatBrainLastSaveResult: (generation: UInt64, result: ChatBrainSaveResult)?
    @ObservationIgnored public internal(set) var chatBrainSaveTask: Task<Void, Never>?

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
    // PATCH-2026-05-07: model-default-bump. One-time migration for a saved
    // chatModel/telegramModel this build no longer carries.
    //
    // 2026-09-13 (User): it CLEARS the stale value instead of bumping it to a
    // model chosen in code. A saved id that is gone is not a pick, and an empty
    // pick is the honest state — the surface then follows its Providers group,
    // and the page says where the choice came from. Substituting a literal here
    // put people on a model they never chose and hid the retirement.
    public nonisolated static func clearRetiredModelSelection(_ key: String) {
        let retired: Set<String> = [
            "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3", "gpt-4o", "gpt-4-turbo",
            "claude-sonnet-4-5", "claude-sonnet-4-6", "claude-haiku-4-5",
            "claude-opus-4-5", "claude-opus-4-6",
        ]
        let clearedKey = "\(key).retiredPickCleared.v3"
        if UserDefaults.standard.bool(forKey: clearedKey) { return }
        let current = UserDefaults.standard.string(forKey: key) ?? ""
        if retired.contains(current) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: clearedKey)
    }

    public nonisolated func disconnectProvider(
        _ id: String, clearProvider: @Sendable () async throws -> Void
    ) async throws -> (ok: Bool, detail: String) {
        try await clearProvider()
        // OAuth credentials have their own store; removing the registry row
        // alone must never claim the account was disconnected.
        let clearedOAuth = NativeOAuthFlow.clearTokens(providerId: id, dataRoot: dataRoot)
        let oauthID = NativeOAuthFlow.normalizedOAuthProviderId(id)
        if ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].contains(oauthID),
           !clearedOAuth {
            return (false, "Clear failed: the OAuth credential could not be removed.")
        }
        // CLI adoption is declined by sign-out, so inspect the shared file
        // itself rather than the credential path chat would now use.
        let detail = NativeOAuthFlow.sharedCodexCLISessionRemains(providerId: id)
            ? "Shared Codex auth is still signed in. Sign out from Codex to remove it."
            : "Credentials removed."
        return (true, detail)
    }

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
            guard var authStatus = try? JSONDecoder.nativeAgent.decode(
                    ProviderAuthStatus.self, from: JSONEncoder().encode(provider.oauthStatus)
                ),
                let models = try? JSONDecoder.nativeAgent.decode(
                    [ProviderModelInfo].self, from: JSONEncoder().encode(provider.modelCatalog)
                ) else { return nil }
            // Eligibility is ProviderRouting's own answer; the state word only says how far it is proven.
            authStatus.eligible = provider.configured == true
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

public extension NativeAgentEngine {
    @MainActor
    func clearSurfaceOverride(
        surface: String, applySelection: @MainActor (SurfacePreference) -> Void
    ) async throws {
        try await providers.routing.clearSurfaceOverride(surface: surface)
        if let preference = try await providers.routing.checkedRoutingSnapshot().preferences[surface] {
            applySelection(preference)
        }
        if surface == "cognition_reflection" {
            await Self.liveCognition.refreshConfiguration()
        }
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
    }

    @MainActor
    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String?, model: String?,
        reasoningEffort: String?, serviceTier: String?, clearOverride: Bool,
        applySnapshot: @MainActor (ProviderRoutingSnapshot) -> Void
    ) async throws -> ProviderGroupWriteResult {
        let result = try await providers.routing.saveGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride
        )
        applySnapshot(result.snapshot)
        if group.surfaces.contains("cognition_reflection") {
            await Self.liveCognition.refreshConfiguration()
        }
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return result
    }

    @MainActor
    func configureSurfaceSelection(
        surface: String, providerID: String, model: String, reasoningEffort: String, serviceTier: String?,
        applySelection: @MainActor (ModelCatalogResponse) -> Void
    ) async throws -> ModelCatalogResponse {
        let response = try await providers.saveSurfaceSelection(
            surface: surface, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, providerID: providerID
        )
        providers.catalog = response
        applySelection(response)
        if surface == "cognition_reflection" {
            await Self.liveCognition.refreshConfiguration()
        }
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return response
    }

    @MainActor
    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String?) async throws {
        try await providers.configureProvider(id: id, apiKey: apiKey, authMode: authMode, defaultModel: defaultModel)
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
    }

    @MainActor
    func clearProvider(_ id: String) async throws {
        try await providers.clearProvider(id)
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
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

// MARK: - Writes

extension ProvidersFacade {
    /// Save one provider's sign-in mode, key and default model. The mode must
    /// be one the provider advertises; an omitted mode takes its first.
    public nonisolated func configureProvider(
        id: String, apiKey: String?, authMode: String, defaultModel: String? = nil
    ) async throws {
        let provider = try await provider(id: id)
        let supportedModes = provider.auth_modes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let requestedMode = authMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The sheet always supplies a selected mode. Keep the existing
        // programmatic/iCloud compatibility behavior for omitted values by
        // selecting the provider's first advertised mode, never an invented
        // generic fallback.
        let normalizedMode = requestedMode.isEmpty ? (supportedModes.first ?? "") : requestedMode
        guard supportedModes.contains(normalizedMode) else {
            throw NSError(domain: "NativeAgentProvider", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "\(provider.display_name) does not support the \(normalizedMode.isEmpty ? "requested" : normalizedMode) authentication method"
            ])
        }
        var config: [String: JSONValue] = ["auth_mode": .string(normalizedMode)]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            config["api_key"] = .string(key)
        }
        if let model = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            config["default_model"] = .string(model)
        }
        _ = try await routing.configureProvider(id: id, config: .object(config))
    }

    /// Save one surface's pick, admitted by the same served catalog the Mac
    /// and phone pickers show (the routing owner checks it inside its
    /// transaction lock), and return the fresh catalog. A nil `providerID`
    /// leaves the surface's active-provider pin alone.
    public nonisolated func saveSurfaceSelection(
        surface: String, model: String, reasoningEffort: String?, serviceTier: String?, providerID: String?
    ) async throws -> ModelCatalogResponse {
        let validateSelection = try await routing.selectionValidator()
        try await routing.saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            providerId: providerID,
            seedMissingControls: true,
            selectionValidator: validateSelection
        )
        return try await modelCatalog(refresh: false)
    }
}

import Foundation
import Observation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import DeviceSync
import ChatToolRuntime
// Blueprint: | `EngineProviders.swift` | ProvidersFacade.settings owns routing, connections, catalog and derived readiness for every Mac picker and phone publication; provider/account invalidations refresh this snapshot. LatestRead orders settings and per-session route/context reads, returning each caller its own result; committed routing publishes through write. ProviderRouting owns persistence, discovery and eligibility; editors hold pending choices only. Catalog rows come only from the live catalog owners; the unwritten providers/models.json compatibility input is retired. |

/// `NativeAgentEngine.providers` (S10): provider routing for one data root.
/// The chat picker, Setup, Telegram and the Providers page render
/// `connections` (each provider's auth state and models) and `catalog` (the
/// selectable models plus each surface's saved pick), derived from `settings`.
/// The same snapshot supplies per-surface routing. Phone lanes use the same
/// published owner: `configureProvider`,
/// `saveSurfaceSelection`, and `routing` for the active-provider pin.
@MainActor
@Observable
public final class ProvidersFacade {
    public nonisolated let dataRoot: URL

    /// Every provider connection, as of the last read.
    public var connections: [ProviderInfo] { settings?.providers ?? [] }
    public enum Readiness: Equatable, Sendable {
        case loading, ready, needsConnection
        case unavailable(String)
    }
    public var readiness: Readiness {
        if let settingsError { return .unavailable(settingsError) }
        guard settings != nil else { return .loading }
        return hasReadyConnection ? .ready : .needsConnection
    }
    /// The model catalog and each surface's pick, as of the last read or write.
    public var catalog: ModelCatalogResponse? { settings?.catalog }
    public private(set) var settings: SettingsSnapshot?
    public private(set) var settingsError: String?
    @ObservationIgnored lazy var settingsReads = LatestRead()
    public var codexAuth: CodexAuthStatus?
    @ObservationIgnored private let codexAuthRead = LatestRead()

    public func refreshCodexAuth() async throws -> CodexAuthStatus {
        try await codexAuthRead.read({ try await codexAuthStatus() }, publish: { codexAuth = $0 })
    }
    /// One effective route and context readout per conversation, shared by every surface.
    public struct SessionPresentation {
        public let contract: BotChatContract?
        public let choice: ProviderTurnChoice?
        public let context: SessionContextStatus?
        public let error: String?
    }
    public private(set) var sessions: [String: SessionPresentation] = [:]
    @ObservationIgnored private var sessionReads: [String: LatestRead] = [:]
    /// The mounted conversation owns the observation lifetime; another window's
    /// session cannot cancel it. All its readers consume `sessions`.
    public func observeSession(_ sessionID: String) async {
        var paths = ["providers/surfaces.json", "providers/active.json", "providers",
                     "chat/messages/\(sessionID).jsonl", "chat/session_state/\(sessionID)/provider_usage.json"]
        if sessionID.hasPrefix("bot-"), let id = UUID(uuidString: String(sessionID.dropFirst(4))) {
            paths.append("bots/definitions/\(id.uuidString).json")
        }
        let changes = FileChangeEvents(paths: paths.map { dataRoot.appendingPathComponent($0) }, emitInitial: false)
        await changes.waitUntilArmed()
        await refreshSession(sessionID)
        await withTaskCancellationHandler {
            for await _ in changes.stream { await refreshSession(sessionID) }
        } onCancel: { changes.cancel() }
    }

    @discardableResult
    public func refreshSession(_ sessionID: String) async -> SessionPresentation {
        guard !sessionID.isEmpty else { return SessionPresentation(contract: nil, choice: nil, context: nil, error: nil) }
        let read = sessionReads[sessionID] ?? LatestRead()
        sessionReads[sessionID] = read
        return await read.read({ await self.readSession(sessionID) }, publish: { sessions[sessionID] = $0 })
    }

    private func readSession(_ sessionID: String) async -> SessionPresentation {
        let contract = await BotChatContract.checked(sessionID, dataRoot: dataRoot)
        var choice = contract?.choice
        do {
            if contract == nil {
                let routing = try await self.routing.checkedRoutingSnapshot()
                choice = routing.preferences["chat"].map {
                    ProviderTurnChoice(provider: routing.activeProviders["chat"] ?? "", model: $0.model,
                                       reasoningEffort: $0.reasoningEffort, fast: $0.serviceTier == "priority")
                }
            }
            let context: SessionContextStatus?
            // A helper never uses the resident's context preparation or compaction.
            if contract == nil, let choice {
                context = try await RuntimeReadProjection.getSessionContext(sessionId: sessionID,
                    model: choice.model, providerID: choice.provider, dataRoot: dataRoot, configuredThresholdTokens: nil)
            } else { context = nil }
            let read = SessionPresentation(contract: contract, choice: choice, context: context, error: contract?.modelChoiceProblem)
            return read
        } catch {
            let read = SessionPresentation(contract: contract, choice: choice, context: nil, error: error.localizedDescription)
            return read
        }
    }
    func retireSessionReads() {
        for (id, read) in sessionReads {
            read.write { _ = sessions.removeValue(forKey: id) }
        }
    }

    func refreshSessionsAfterRoutingWrite() async {
        for id in Array(sessionReads.keys) { _ = await refreshSession(id) }
    }
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
        case failed(message: String, cause: String? = nil)
    }

    public var isSavingChatBrain = false
    public var chatBrainCanonicalSelection: ChatBrainSelection? {
        settings.flatMap { $0.preferences["chat"] }.map {
            ChatBrainSelection(model: $0.model, reasoningEffort: $0.reasoningEffort,
                fastMode: $0.serviceTier == "priority")
        }
    }
    @ObservationIgnored var chatBrainPendingSave: (generation: UInt64, selection: ChatBrainSelection)?
    @ObservationIgnored public var chatBrainSaveGeneration: UInt64 = 0
    @ObservationIgnored var chatBrainLastSaveResult: (generation: UInt64, result: ChatBrainSaveResult)?
    @ObservationIgnored public internal(set) var chatBrainSaveTask: Task<Void, Never>?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        Task { @MainActor [weak self] in
            guard let self else { return }
            let events = EventDeadlinePhysiology.storeAndFileEvents(
                paths: ["providers", "providers/surfaces.json", "providers/active.json",
                        "providers/pending-surface-configuration.json"].map { dataRoot.appendingPathComponent($0) },
                notifications: [ChatGPTAccountModelRefresh.didRefresh])
            self.accountModelUpdatesTask = Task { [weak self] in
                _ = await self?.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
                for await _ in events {
                    guard let self else { return }
                    _ = await self.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
                }
            }
        }
    }

    func publishSettings(_ snapshot: SettingsSnapshot) {
        settings = snapshot
        settingsError = nil
    }

    func publishSettingsFailure(_ detail: String) { settingsError = detail }

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

    public func list() async throws -> [ProviderInfo] {
        switch await refreshSettings(refreshCatalog: false, cause: { error, _ in error.localizedDescription }) {
        case .loaded(let snapshot): return snapshot.providers
        case .failed(let detail): throw ProviderRoutingError.underlying(detail)
        }
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
    func clearSurfaceOverride(surface: String) async throws {
        guard let group = ProviderSurfaceGroups.group(for: surface) else { throw ProviderRoutingError.invalidRequest }
        let result = try await providers.routing.saveGroupSelection(group: group, clearOverride: true)
        try providers.publishCommittedRouting(result.snapshot)
        await providers.refreshSessionsAfterRoutingWrite()
        if surface == "cognition_reflection" {
            await Self.liveCognition.refreshConfiguration()
        }
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
    }

    @MainActor
    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String?, model: String?,
        reasoningEffort: String?, serviceTier: String?, clearOverride: Bool
    ) async throws -> ProviderGroupWriteResult {
        let result = try await providers.routing.saveGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride
        )
        try providers.publishCommittedRouting(result.snapshot)
        _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
        await providers.refreshSessionsAfterRoutingWrite()
        if group.surfaces.contains("cognition_reflection") {
            await Self.liveCognition.refreshConfiguration()
        }
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return result
    }

    @MainActor
    func configureSurfaceSelection(
        surface: String, providerID: String, model: String, reasoningEffort: String, serviceTier: String?
    ) async throws -> ModelCatalogResponse {
        let response = try await providers.saveSurfaceSelection(
            surface: surface, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, providerID: providerID
        )
        _ = await providers.refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
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
        // Catalog owners supply the rows; the checked routing snapshot supplies picks.
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

    /// Project the same selected credential and adapter verdict as provider
    /// readiness; source flags describe that credential, not a second scan.
    public nonisolated func codexAuthStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowEnvironmentOverride: Bool = true
    ) async throws -> CodexAuthStatus {
        let dataRoot = self.dataRoot
        let path = OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: dataRoot, environment: allowEnvironmentOverride ? environment : [:]
        )
        let object = (try? Data(contentsOf: path)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        let status = OpenAIOAuthDirectAdapter.credentialStatus(object, path: path)
        let loggedIn = status.usable
        let appOwned = OpenAIOAuthDirectAdapter.codexChildHome(mirroring: path) != nil
        return CodexAuthStatus(
            active: loggedIn ? "oauth" : "none",
            appOwnedLoggedIn: loggedIn && appOwned,
            sharedLoggedIn: loggedIn && !appOwned,
            codexHome: path.deletingLastPathComponent().path,
            detail: status.detail
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
    public func saveSurfaceSelection(
        surface: String, model: String, reasoningEffort: String?, serviceTier: String?, providerID: String?
    ) async throws -> ModelCatalogResponse {
        guard let group = ProviderSurfaceGroups.group(for: surface) else { throw ProviderRoutingError.invalidRequest }
        let result = try await routing.saveGroupSelection(
            group: group,
            providerID: providerID,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        try publishCommittedRouting(result.snapshot)
        await refreshSessionsAfterRoutingWrite()
        return try await modelCatalog(refresh: false, routingSnapshot: result.snapshot)
    }
}

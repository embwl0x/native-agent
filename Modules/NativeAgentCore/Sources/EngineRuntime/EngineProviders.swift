import StandingBots
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import DeviceSync
import ChatToolRuntime
import AuthoredCapabilities
import ApprovalTransactions
// Blueprint: | `EngineProviders.swift` | One checked root-specific settings/catalog owner across surfaces |

/// Share checked root-specific provider settings, catalog and routing across pickers, setup, Telegram and phone.
@MainActor
public final class ProvidersFacade {
    public nonisolated let dataRoot: URL

    public var connections: [ProviderInfo] { settings?.providers ?? [] }
    public var catalog: ModelCatalogResponse? { settings?.catalog }
    public private(set) var settings: ProviderSettingsSnapshot?
    public private(set) var settingsError: String?
    lazy var settingsReads = LatestRead()
    weak var facePages: PartFaces?
    var providerProbeStarts: [String: Date] = [:] { didSet { publishProviderState() } }
    var catalogRefreshStarted: Date? { didSet { publishProviderState() } }
    var catalogRefreshTask: Task<SettingsRefreshOutcome, Never>?
    public var codexAuth: CodexAuthStatus? { didSet { publishProviderState() } }
    private let codexAuthRead = LatestRead()

    public func refreshCodexAuth() async throws -> CodexAuthStatus {
        try await codexAuthRead.read({ try await codexAuthStatus() }, publish: { codexAuth = $0 })
    }
    private var sessionReads: [String: LatestRead] = [:]
    private var faceDeliveries: [UUID: FaceDeliveryReceipt] = [:]
    /// Mounts own observation independently so another window cannot cancel this session’s reads.
    public func observeSession(_ sessionID: String) async {
        var paths = ["providers/surfaces.json", "providers/active.json", "providers",
                     "chat/messages/\(sessionID).jsonl", "chat/session_state/\(sessionID)/provider_usage.json"]
        if let id = BotDefinition.id(forSession: sessionID) {
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
    public func refreshSession(_ sessionID: String) async -> ProviderSessionPresentation {
        let read = sessionReads[sessionID] ?? LatestRead()
        sessionReads[sessionID] = read
        return await read.read({ await self.readSession(sessionID) }, publish: { faceChanges.yield(.session(sessionID, $0)) })
    }

    public func deliverFaces() async throws {
        let id = UUID()
        let receipt = FaceDeliveryReceipt()
        faceDeliveries[id] = receipt
        defer { faceDeliveries.removeValue(forKey: id) }
        if case .terminated = faceChanges.yield(.delivery(receipt)) { await receipt.close() }
        try await receipt.wait()
    }

    @concurrent private nonisolated func readSession(_ sessionID: String) async -> ProviderSessionPresentation {
        let settings = await self.settings
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
            // A helper uses its own context preparation and the shared verbatim-tail boundary.
            if !sessionID.isEmpty, contract == nil, let choice {
                context = try await RuntimeReadouts.getSessionContext(sessionId: sessionID,
                    model: choice.model, providerID: choice.provider, dataRoot: dataRoot)
            } else { context = nil }
            return ProviderSessionPresentation(controls: .init(contract: contract.map { .init(name: $0.name, model: $0.model) },
                choice: choice, providerGroups: [], models: [:]), context: context,
                error: contract?.modelChoiceProblem).prepared(settings: settings)
        } catch {
            return ProviderSessionPresentation(controls: .init(contract: contract.map { .init(name: $0.name, model: $0.model) },
                choice: choice, providerGroups: [], models: [:]), context: nil,
                error: error.localizedDescription).prepared(settings: settings)
        }
    }
    func retireSessionReads() {
        for read in sessionReads.values { read.write {} }
        faceChanges.yield(.retireSessions)
    }

    func refreshSessionsAfterRoutingWrite() async {
        for id in Array(sessionReads.keys) { _ = await refreshSession(id) }
    }
    private var accountModelRefreshTask: Task<Void, Never>?
    private var accountModelUpdatesTask: Task<Void, Never>?

    public enum ChatBrainSaveResult: Equatable, Sendable {
        case unchanged(ProviderTurnChoice)
        case saved(ProviderTurnChoice)
        case failed(message: String, cause: String? = nil)
    }

    public internal(set) var isSavingChatBrain = false { didSet { publishProviderState() } }
    public var chatBrainCanonicalSelection: ProviderTurnChoice? {
        settings.flatMap { $0.preferences["chat"] }.map {
            ProviderTurnChoice(provider: settings?.activeProviders["chat"] ?? "",
                model: $0.model, reasoningEffort: $0.reasoningEffort, fast: $0.serviceTier == "priority")
        }
    }
    var chatBrainPendingSave: (generation: UInt64, selection: ProviderTurnChoice)?
    var chatBrainSaveGeneration: UInt64 = 0
    var chatBrainLastSaveResult: (generation: UInt64, result: ChatBrainSaveResult)?
    var chatBrainSaveTask: Task<Void, Never>?

    private nonisolated let faceChanges: AsyncStream<ProviderFaceChange>.Continuation
    private nonisolated let faceProjectionTask: Task<Void, Never>

    public nonisolated init(dataRoot: URL, settingsFeed: SettingsFeedProjection) {
        self.dataRoot = dataRoot
        let (changes, input) = AsyncStream.makeStream(of: ProviderFaceChange.self)
        faceChanges = input
        let projection = ProviderFaceProjection(feed: settingsFeed, dataRoot: dataRoot)
        faceProjectionTask = Task { await projection.consume(changes) }
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

    func publishSettings(_ snapshot: ProviderSettingsSnapshot) {
        settings = snapshot
        settingsError = nil
        faceChanges.yield(.snapshot(snapshot))
        refreshFace()
    }

    func publishSettingsFailure(_ detail: String) {
        settingsError = detail
        faceChanges.yield(.failure(detail))
        refreshFace()
    }

    private func publishProviderState() {
        faceChanges.yield(.status(probes: providerProbeStarts, catalogStarted: catalogRefreshStarted,
                                  codexAuth: codexAuth, saving: isSavingChatBrain))
    }

    deinit {
        for receipt in faceDeliveries.values { Task { await receipt.close() } }
        faceChanges.finish()
        faceProjectionTask.cancel()
        accountModelUpdatesTask?.cancel()
        catalogRefreshTask?.cancel()
    }

    public nonisolated var routing: SwiftNativeProviderRouting {
        SwiftNativeProviderRouting(dataRoot: dataRoot)
    }

    /// Account discovery must never hold a turn or UI maintenance.
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
    public nonisolated func disconnectProvider(_ id: String) async throws -> (ok: Bool, detail: String) {
        try await clearProvider(id)
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        // OAuth credentials have their own store; deleting a registry row alone cannot prove disconnect.
        let clearedOAuth = await NativeOAuthFlow.clearTokens(providerId: id, dataRoot: dataRoot)
        let oauthID = NativeOAuthFlow.normalizedOAuthProviderId(id)
        if ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].contains(oauthID),
           !clearedOAuth {
            return (false, "Clear failed: the OAuth credential could not be removed.")
        }
        guard try routing.confirmsDisconnection(id) else {
            return (false, "Sign-out is not confirmed: saved credentials or permission to use them remain.")
        }
        // Inspect the shared CLI file directly because app sign-out disables CLI adoption in chat’s credential path.
        do {
            let sharedRemains = try NativeOAuthFlow.sharedCodexCLISessionRemains(providerId: id)
            return (true, sharedRemains
                ? "Credentials removed. Shared Codex auth is still signed in. Sign out from Codex to remove it."
                : "Credentials removed.")
        } catch {
            // An independent CLI read cannot undo committed app sign-out.
            return (true, "Credentials removed. Shared Codex session could not be checked: \(ProviderFailure.diagnosticDescription(error))")
        }
    }

    public func list() async throws -> (providers: [ProviderInfo], routing: ProviderRoutingSnapshot) {
        switch await refreshSettings(refreshCatalog: false, cause: { error, _ in error.localizedDescription }) {
        case .loaded(let snapshot): return (snapshot.providers, snapshot.routing)
        case .failed(let detail): throw ProviderRoutingError.underlying(detail)
        }
    }

    /// Presentation must derive discovery, readiness, bookkeeping and model contracts from ProviderRouting.
    public nonisolated static func connections(from snapshot: ProviderCatalogSnapshot) throws -> [ProviderInfo] {
        snapshot.providers.map { provider in
            do {
                let extras: [String: JSONValue]
                if let saved = provider.extras {
                    guard case .object(let object) = saved else {
                        throw ProviderRoutingError.underlying("Provider \(provider.id) metadata is not an object; repair its catalog row.")
                    }
                    extras = object
                } else { extras = [:] }
                let modes: [String]
                if let saved = extras["auth_modes"] {
                    guard case .array(let values) = saved else {
                        throw ProviderRoutingError.underlying("Provider \(provider.id) auth_modes is not an array; repair its catalog row.")
                    }
                    modes = try values.map {
                        guard case .string(let value) = $0 else {
                            throw ProviderRoutingError.underlying("Provider \(provider.id) auth_modes contains a non-string; repair its catalog row.")
                        }
                        return value
                    }
                } else { modes = [] }
                func string(_ key: String) throws -> String? {
                    guard let raw = extras[key], raw != .null else { return nil }
                    guard case .string(let value) = raw else {
                        throw ProviderRoutingError.underlying("Provider \(provider.id) \(key) is not a string; repair its catalog row.")
                    }
                    return value
                }
                var authStatus: ProviderAuthStatus
                let models: [ProviderModelInfo]
                do {
                    authStatus = try JSONDecoder.nativeAgent.decode(
                        ProviderAuthStatus.self, from: JSONEncoder().encode(provider.oauthStatus))
                    models = try JSONDecoder.nativeAgent.decode(
                        [ProviderModelInfo].self, from: JSONEncoder().encode(provider.modelCatalog))
                } catch {
                    throw ProviderRoutingError.underlying("""
                        Provider \(provider.id) authentication/model catalog could not be read: \(error.localizedDescription). Repair the reported catalog \
                        row before using its account list.
                        """)
                }
                // Use ProviderRouting eligibility; the state word describes only proof.
                guard let configured = provider.configured else {
                    throw ProviderRoutingError.underlying("Provider \(provider.id) has no checked readiness result; refresh its provider catalog.")
                }
                authStatus.eligible = configured
                return try ProviderInfo(
                    provider_id: provider.id, display_name: provider.displayName ?? provider.id,
                    auth_modes: modes, auth_status: authStatus, models: models,
                    auth_mode: string("auth_mode"), default_model: string("default_model"),
                    models_note: string("models_note"), connectionRevision: string("entry_revision")
                )
            } catch {
                let detail = "\(provider.id)'s catalog is unavailable: \(error.localizedDescription)"
                return ProviderInfo(provider_id: provider.id, display_name: provider.displayName ?? provider.id,
                    auth_modes: [], auth_status: ProviderAuthStatus(provider_id: provider.id, state: "unavailable",
                        detail: detail, user_info: nil, last_checked_at: nil, eligible: false),
                    models: [], models_note: detail)
            }
        }
    }

    public nonisolated func provider(id: String) async throws -> ProviderInfo {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentProvider", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "provider id is required"
            ])
        }
        let providers = try await list().providers
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
    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String? = nil, model: String? = nil,
        reasoningEffort: String? = nil, serviceTier: String? = nil, clearOverride: Bool = false
    ) async throws -> ProviderGroupWriteResult {
        let result = try await providers.routing.saveGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride
        )
        await providers.publishCommittedRouting(result.snapshot)
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
    ) async throws -> ProviderRoutingSnapshot {
        guard let group = ProviderSurfaceGroups.group(for: surface) else { throw ProviderRoutingError.invalidRequest }
        let result = try await saveProviderGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: false
        )
        return result.snapshot
    }

    @MainActor
    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String?) async throws {
        try await providers.configureProvider(id: id, apiKey: apiKey, authMode: authMode, defaultModel: defaultModel)
        Task { _ = await Self.liveDeviceSync.bridge.publishProviderCatalogStatus() }
    }

}

// MARK: - Catalog

extension ProvidersFacade {
    @concurrent public nonisolated func modelCatalog(
        refresh: Bool,
        codexCacheURL: URL? = nil
    ) async throws -> ModelCatalogResponse {
        let dataRoot = self.dataRoot
        async let accountRefresh: Error? = {
            guard refresh else { return nil }
            do {
                _ = try await ChatGPTAccountModelRefresh.shared.refresh(dataRoot: dataRoot, force: true)
                return nil
            } catch {
                return error
            }
        }()
        async let openRouterRefresh = OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot, refresh: refresh)
        async let moonshotRefresh: Void = {
            if refresh { _ = await MoonshotModelCatalog.models(dataRoot: dataRoot, refresh: true) }
        }()
        let accountRefreshError = await accountRefresh
        let firstPartyModels = (
            FirstPartyModelCatalog.publicOpenAIModels
            + FirstPartyModelCatalog.anthropicModels
            + FirstPartyModelCatalog.xAIModels
        ).enumerated().map { index, model in
            ModelCatalogItem(model, priority: 100 + index)
        }
        let (openRouterRead, _) = await (openRouterRefresh, moonshotRefresh)
        // Discovery failure belongs to that catalog; publish refreshed sibling provider lists.
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
                    defaultReasoningEffort: model.default_reasoning_effort,
                    supportedReasoningEfforts: model.supported_reasoning_efforts,
                    supportsFast: model.supports_fast,
                    priority: 1_000 + index
                )
            }
        let resolvedCodexCacheURL = codexCacheURL
            ?? CodexSelectableModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: dataRoot)
        let codexSelectableModels = CodexSelectableModelCatalog.modelCatalogItems(
            cacheURL: resolvedCodexCacheURL,
            useDefaultCacheWhenNil: false
        )
        var seenBaseline = Set<String>()
        let baseline = (codexSelectableModels + firstPartyModels + openRouterCatalogModels)
            .filter { seenBaseline.insert($0.id).inserted }
        let efforts = defaultReasoningEffortOptions

        return ModelCatalogResponse(
            status: "ok",
            source: "first_party_capabilities_plus_signed_codex_and_openrouter",
            models: baseline,
            reasoningEfforts: efforts,
            updatedAt: nil,
            catalogFreshness: catalogFreshness.rawValue,
            catalogNote: catalogNote
        )
    }

    /// Use readiness’s selected credential and adapter verdict; source flags must not come from a second scan.
    @concurrent public nonisolated func codexAuthStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowEnvironmentOverride: Bool = true
    ) async throws -> CodexAuthStatus {
        let dataRoot = self.dataRoot
        let path = ChatGPTTransport.preferredAuthPath(
            dataRoot: dataRoot, environment: allowEnvironmentOverride ? environment : [:]
        )
        let status: (usable: Bool, detail: String, health: OAuthCredentialHealth)
        do {
            status = try ChatGPTTransport.credentialStatus(at: path)
        } catch {
            // Publish optional-refresh failure in its readout so discarded throws cannot leave stale signed-in state.
            return CodexAuthStatus(
                active: "unavailable", appOwnedLoggedIn: false, sharedLoggedIn: false,
                codexHome: path.deletingLastPathComponent().path,
                detail: ProviderFailure.diagnosticDescription(error)
            )
        }
        let loggedIn = status.usable
        let appOwned = ChatGPTTransport.codexChildHome(mirroring: path) != nil
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
    /// Accept only advertised sign-in modes; omission selects the provider’s first advertised mode.
    public nonisolated func configureProvider(
        id: String, apiKey: String?, authMode: String, defaultModel: String? = nil, expectedRevision: String? = nil
    ) async throws {
        let provider = try await provider(id: id)
        let supportedModes = provider.auth_modes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let requestedMode = authMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Omitted mode selects the provider’s first advertised choice, never an invented generic mode.
        let normalizedMode = requestedMode.isEmpty ? (supportedModes.first ?? "") : requestedMode
        guard supportedModes.contains(normalizedMode) else {
            throw NSError(domain: "NativeAgentProvider", code: 400, userInfo: [
                NSLocalizedDescriptionKey: """
                    \(provider.display_name) does not support the \(normalizedMode.isEmpty ? "requested" : normalizedMode) authentication method
                    """
            ])
        }
        var config: [String: JSONValue] = ["auth_mode": .string(normalizedMode)]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            config["api_key"] = .string(key)
        }
        if let model = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            config["default_model"] = .string(model)
        }
        _ = try await routing.configureProvider(id: id, config: .object(config), expectedRevision: expectedRevision)
    }

    /// Admit selections under the routing transaction against the served picker catalog; nil `providerID` preserves the active-provider pin.
    public func saveSurfaceSelection(
        surface: String, model: String, reasoningEffort: String?, serviceTier: String?, providerID: String?
    ) async throws -> ProviderRoutingSnapshot {
        guard let group = ProviderSurfaceGroups.group(for: surface) else { throw ProviderRoutingError.invalidRequest }
        let result = try await routing.saveGroupSelection(
            group: group,
            providerID: providerID,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        await publishCommittedRouting(result.snapshot)
        await refreshSessionsAfterRoutingWrite()
        return result.snapshot
    }
}

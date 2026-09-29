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

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
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
}

// F.evalfix2/R2: real readiness validators for OAuth-direct providers.
// "File non-empty" is not enough — a stale auth.json with no access_token,
// or an expired access_token with no refresh_token, must report needs_oauth
// so the chat brain bar surfaces the exact OAuth repair state.
fileprivate func validateOpenAIOAuthDirect(
    dataRoot: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> (Bool, String) {
    let paths = OpenAIOAuthDirectAdapter.authPathCandidates(
        dataRoot: dataRoot,
        environment: environment,
        allowSharedFallbacks: dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
    )
    var sawAuth = false
    for path in paths {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        sawAuth = true
        let tokens = (obj["tokens"] as? [String: Any]) ?? [:]
        let access = (tokens["access_token"] as? String) ?? ""
        if access.isEmpty { continue }
        let refresh = (tokens["refresh_token"] as? String) ?? ""
        if let expDate = parseExpiresAt(tokens["expires_at"])
                        ?? parseExpiresAt(obj["expires_at"])
                        ?? jwtExpiry(access) {
            if expDate > Date() {
                return (true, "Signed in (valid)")
            }
            if !refresh.isEmpty {
                return (true, "Access expired - refresh on next chat")
            }
            continue
        }
        // No expiry persisted; access_token present. Treat as ready (some
        // ChatGPT tokens are long-lived and don't include expires_at until
        // first refresh).
        return (true, "Signed in")
    }
    if sawAuth {
        return (false, "tokens.access_token empty or expired without refresh_token - sign in required")
    }
    return (false, "auth.json missing or malformed")
}

fileprivate func validateAnthropicOAuthDirect(providersDir: URL) -> (Bool, String) {
    let path = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
    let auth = (try? Data(contentsOf: path))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    // The adapter that serves the calls decides (see credentialStatus).
    let status = AnthropicOAuthDirectAdapter.credentialStatus(auth)
    return (status.usable, status.detail)
}

fileprivate func validateXAIOAuthDirect(providersDir: URL) -> (Bool, String) {
    let path = providersDir.appendingPathComponent("xai_oauth_direct.json")
    guard let data = try? Data(contentsOf: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (false, "xai_oauth_direct.json missing or malformed") }
    let topAccess = (obj["access_token"] as? String) ?? ""
    let nestedAccess = ((obj["tokens"] as? [String: Any])?["access_token"] as? String) ?? ""
    let access = !topAccess.isEmpty ? topAccess : nestedAccess
    guard !access.isEmpty else {
        return (false, "no access_token - sign in required")
    }
    let refresh = (obj["refresh_token"] as? String)
        ?? ((obj["tokens"] as? [String: Any])?["refresh_token"] as? String)
        ?? ""
    if let expDate = parseExpiresAt(obj["expires_at"])
        ?? parseExpiresAt((obj["tokens"] as? [String: Any])?["expires_at"])
        ?? jwtExpiry(access) {
        if expDate > Date() {
            return (true, "Signed in (valid)")
        }
        if !refresh.isEmpty {
            return (true, "Access expired - refresh on next chat")
        }
        return (false, "Access expired and no refresh_token - re-auth required")
    }
    return (true, "Signed in")
}

// FIX 2026-07-04 (false-ready guard): a provider file counts as holding a
// usable credential only when it actually contains one — a non-empty api_key
// (api-key providers) OR oauth token material (oauth providers). A file that
// carries only bookkeeping fields (auth_mode / default_model) — which is what a
// blank-key Save writes via configureProvider — is NOT usable and must not read
// as "ready". Recognizing oauth token fields keeps the oauth-direct providers'
// existing per-provider validators (validate*OAuthDirect) reachable, so this
// only tightens the api-key path it was written to fix.
fileprivate func providerFileHasCredential(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url), !data.isEmpty,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    if obj[ProviderAPIKeyStore.referenceField] != nil {
        return LLMCredentialResolver.resolveAPIKey(providerConfigObject: obj) != nil
    }
    let credentialKeys = ["api_key", "access_token", "setup_token", "refresh_token", "token", "id_token"]
    for key in credentialKeys {
        if let v = obj[key] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
    }
    // Nested oauth token bag (tokens.access_token), as written by some flows.
    if let tokens = obj["tokens"] as? [String: Any],
       let access = tokens["access_token"] as? String,
       !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
    }
    return false
}

/// User, 2026-09-06: the UI bookkeeping `configureProvider` persists next to the
/// credential — the "Model it falls back to" pick and the chosen auth mode. The
/// synthesized provider record omitted both, so reopening the sheet always
/// selected the first catalog model and the saved pick was invisible.
fileprivate func providerFileBookkeeping(_ url: URL) -> (authMode: String?, defaultModel: String?) {
    guard let data = try? Data(contentsOf: url), !data.isEmpty,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (nil, nil) }
    func string(_ keys: [String]) -> String? {
        for key in keys {
            if let v = obj[key] as? String,
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
    return (string(["auth_mode", "authMode"]), string(["default_model", "defaultModel"]))
}

fileprivate func jwtExpiry(_ token: String) -> Date? {
    guard let obj = jwtPayload(token) else { return nil }
    if let exp = obj["exp"] as? Int    { return Date(timeIntervalSince1970: TimeInterval(exp)) }
    if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
    return nil
}

// MARK: - Connections

extension ProvidersFacade {
    /// Every provider connection this root can route to, with its auth state,
    /// its models and the sheet's saved bookkeeping, sorted by display name.
    public nonisolated func list(
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> [ProviderInfo] {
        let dataRoot = self.dataRoot
        // DAEMON KILLED 2026-06-02. Three sources of truth for providers:
        //   1. <dataRoot>/providers/registry.json (legacy daemon-era file)
        //   2. <dataRoot>/providers/<id>.json (OAuth/setup-token files written
        //      by NativeOAuthFlow + AnthropicSetupTokenInput)
        //   3. <dataRoot>/codex_home/auth.json (OpenAI/ChatGPT OAuth lives
        //      here per NativeOAuthFlow's openai_oauth_direct path)
        let providersDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let chatGPTOAuthCacheURL = codexCacheURL ?? CodexSelectableModelCatalog
            .chatGPTOAuthCacheCandidate(
                dataRoot: dataRoot,
                environment: authEnvironment
            )
        // S12a: each fetched catalog says where its rows came from; a list
        // that could not be loaded is empty and carries the reason.
        let openRouterRead = await OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
        let moonshotRead = await MoonshotModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
        let openRouterProviderModels = openRouterRead.models.map { model in
            ProviderModelInfo(
                id: model.id,
                name: model.name,
                context_length: model.contextLength,
                supports_streaming: model.supportsStreaming,
                supports_vision: model.supportsVision,
                supports_tools: model.supportsTools,
                supports_json_mode: model.supportsJSONMode,
                cost_per_1k_in: model.costPer1KIn,
                cost_per_1k_out: model.costPer1KOut
            )
        }
        let moonshotProviderModels = moonshotRead.models.map { model in
            ProviderModelInfo(
                id: model.id,
                name: model.name,
                context_length: model.contextLength,
                supports_streaming: model.supportsStreaming,
                supports_vision: model.supportsVision,
                supports_tools: model.supportsTools,
                supports_json_mode: model.supportsJSONMode,
                default_reasoning_effort: MoonshotModelCatalog.defaultReasoningEffort(for: model.id),
                supported_reasoning_efforts: MoonshotModelCatalog.supportedReasoningEfforts(for: model.id),
                supports_fast: false
            )
        }

        var byId: [String: ProviderInfo] = [:]

        // Model lists per provider family — what each provider actually serves.
        func modelsFor(_ providerId: String) -> [ProviderModelInfo] {
            func info(_ model: FirstPartyModelDescriptor) -> ProviderModelInfo {
                ProviderModelInfo(
                    id: model.id,
                    name: model.name,
                    context_length: model.contextLength,
                    supports_streaming: model.supportsStreaming,
                    supports_vision: model.supportsVision,
                    supports_tools: model.supportsTools,
                    supports_json_mode: model.supportsJSONMode,
                    default_reasoning_effort: model.defaultReasoningEffort,
                    supported_reasoning_efforts: model.supportedReasoningEfforts,
                    supports_fast: model.supportsFast
                )
            }
            let openai = FirstPartyModelCatalog.publicOpenAIModels.map(info)
            let chatGPTOAuthModels = CodexSelectableModelCatalog.providerModels(
                providerID: "openai_oauth_direct",
                cacheURL: chatGPTOAuthCacheURL,
                useDefaultCacheWhenNil: false
            )
            let codexModels = CodexSelectableModelCatalog
                .providerModels(
                    providerID: "codex",
                    cacheURL: codexCacheURL,
                    useDefaultCacheWhenNil: codexCacheURL == nil
                )
            let anthropic = FirstPartyModelCatalog.anthropicModels.map(info)
            let xai = FirstPartyModelCatalog.xAIModels.map(info)
            switch providerId {
            case "openai": return openai
            case "openai_oauth_direct": return chatGPTOAuthModels
            case "codex": return codexModels
            case "anthropic", "anthropic_oauth_direct", "anthropic_mcp": return anthropic
            case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth": return xai
            case "openrouter": return openRouterProviderModels
            case "moonshot": return moonshotProviderModels
            case "kimi-code": return FirstPartyModelCatalog.kimiCodeModels.map(info)
            default: return openai + anthropic + xai
            }
        }

        func synthesize(providerId: String, display: String, hasToken: Bool, modes: [String], readinessDetail: String? = nil) {
            // F.evalfix2/R2: OAuth-direct readiness can't be inferred from
            // "file non-empty" — a stale auth.json with no access_token or
            // an expired access_token + no refresh_token is NOT ready, and
            // the chat surface needs the truth to avoid hiding OAuth repair.
            let (effectiveReady, effectiveDetail): (Bool, String) = {
                if !hasToken {
                    return (false, readinessDetail ?? "No token saved")
                }
                switch providerId {
                case "openai_oauth_direct":
                    return validateOpenAIOAuthDirect(
                        dataRoot: dataRoot,
                        environment: authEnvironment
                    )
                case "anthropic_oauth_direct":
                    return validateAnthropicOAuthDirect(providersDir: providersDir)
                case "xai_oauth_direct":
                    return validateXAIOAuthDirect(providersDir: providersDir)
                default:
                    return (true, readinessDetail ?? "Token persisted")
                }
            }()
            let state = effectiveReady ? "ready" : (modes == ["api_key"] ? "needs_key" : "needs_oauth")
            // User, 2026-09-06: carry the saved bookkeeping so the config sheet
            // round-trips. Without it the sheet re-selected the first catalog
            // model every time it opened and the saved "Model it falls back to"
            // was silently dropped on the next Save.
            let bookkeeping = providerFileBookkeeping(
                providersDir.appendingPathComponent("\(providerId).json")
            )
            byId[providerId] = ProviderInfo(
                provider_id: providerId,
                display_name: display,
                auth_modes: modes,
                auth_status: ProviderAuthStatus(
                    provider_id: providerId,
                    state: state,
                    detail: effectiveDetail,
                    user_info: nil,
                    last_checked_at: nil
                ),
                models: modelsFor(providerId),
                auth_mode: bookkeeping.authMode,
                default_model: bookkeeping.defaultModel
            )
        }

        // Source 1: registry.json (legacy)
        let registryPath = providersDir.appendingPathComponent("registry.json")
        if let rows = try SwiftNativeProviderRouting.loadProviderRegistryChecked(at: registryPath) {
            for value in rows {
                let rowData = try JSONEncoder().encode(value)
                let provider = try JSONDecoder().decode(Provider.self, from: rowData)
                // The older routing shape has only an id and optional metadata.
                // Project it through the same credential/catalog owners as files.
                guard let p = try? JSONDecoder.nativeAgent.decode(ProviderInfo.self, from: rowData) else {
                    let path = providersDir.appendingPathComponent("\(provider.id).json")
                    synthesize(providerId: provider.id, display: provider.displayName ?? provider.id,
                        hasToken: providerFileHasCredential(path),
                        modes: provider.id.contains("oauth") ? ["oauth"] : ["api_key"])
                    if let catalog = provider.modelCatalog,
                       let bytes = try? JSONEncoder().encode(catalog),
                       let models = try? JSONDecoder.nativeAgent.decode([ProviderModelInfo].self, from: bytes) {
                        byId[provider.id]?.models = models
                    }
                    continue
                }
                // User, 2026-09-06: a legacy registry row never goes through
                // `synthesize`, and providers/<id>.json is where
                // `configureProvider` saves the fallback model and the auth
                // mode — so on a migrated install the sheet still lost the
                // saved pick. OpenRouter felt it hardest: its own re-synthesize
                // below is gated on there being no row at all.
                var row = p
                let bookkeeping = providerFileBookkeeping(
                    providersDir.appendingPathComponent("\(p.provider_id).json")
                )
                if let mode = bookkeeping.authMode { row.auth_mode = mode }
                if let model = bookkeeping.defaultModel { row.default_model = model }
                byId[p.provider_id] = row
            }
        }

        // Source 2: providers/<id>.json (Anthropic OAuth direct, OpenRouter, etc.)
        let fm = FileManager.default
        let skipNames: Set<String> = [
            "registry.json",
            "models.json",
            "active.json",
            "surfaces.json",
            // Crash-recovery intent for the surface/provider tuple, not a
            // credential-bearing provider record. If it is visible during an
            // interrupted commit, the provider catalog must not synthesize a
            // fake "Pending Surface Configuration" provider row from it.
            "pending-surface-configuration.json",
            "openrouter-models-cache.json",
            "moonshot-models-cache.json",
        ]
        if let files = try? fm.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "json" && !skipNames.contains(url.lastPathComponent) && !url.lastPathComponent.hasSuffix(".lock") {
                let fields = try SwiftNativeProviderRouting.loadProviderStateObjectChecked(at: url, description: "provider configuration")
                try SwiftNativeProviderRouting.validateProviderConfiguration(fields)
                let providerId = url.deletingPathExtension().lastPathComponent
                if byId[providerId] != nil { continue }
                let display: String = {
                    switch providerId {
                    case "openai", "openai_oauth_direct": return "ChatGPT / OpenAI"
                    case "anthropic": return "Anthropic (API key)"
                    case "anthropic_oauth_direct": return "Anthropic (OAuth / Setup-Token)"
                    case "xai_oauth_direct": return "xAI Grok (OAuth)"
                    case "openrouter": return "OpenRouter"
                    case "moonshot": return "Moonshot AI (Kimi)"
                    case "kimi-code": return "Kimi Code"
                    default: return providerId.replacingOccurrences(of: "_", with: " ").capitalized
                    }
                }()
                let hasToken = providerFileHasCredential(url)
                let modes: [String] = providerId.contains("oauth") ? ["oauth"] : ["api_key", "oauth"]
                synthesize(providerId: providerId, display: display, hasToken: hasToken, modes: modes)
            }
        }

        // First-party provider rows always come from the current canonical
        // catalog. Legacy registry rows may carry stale model arrays and must
        // not win merely because they decoded first.
        synthesize(
            providerId: "openai",
            display: "OpenAI (API key)",
            hasToken: providerFileHasCredential(providersDir.appendingPathComponent("openai.json")),
            modes: ["api_key"]
        )
        synthesize(
            providerId: "anthropic",
            display: "Anthropic (API key)",
            hasToken: providerFileHasCredential(providersDir.appendingPathComponent("anthropic.json")),
            modes: ["api_key"]
        )
        let anthropicOAuthPath = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
        synthesize(
            providerId: "anthropic_oauth_direct",
            display: "Anthropic (OAuth / Setup-Token)",
            hasToken: providerFileHasCredential(anthropicOAuthPath),
            modes: ["oauth"]
        )

        // Source 3: codex_home/auth.json -> OpenAI OAuth direct. Use the
        // same candidate paths as OpenAIOAuthDirectAdapter so the picker does
        // not hide a working App Support token just because the data root is
        // stamped to the repo.
        let codexHasAuth = OpenAIOAuthDirectAdapter
            .authPathCandidates(
                dataRoot: dataRoot,
                environment: authEnvironment,
                allowSharedFallbacks: dataRoot.standardizedFileURL
                    == PersistenceCore.defaultDataRoot().standardizedFileURL
            )
            .contains { path in
                (try? Data(contentsOf: path)).map { !$0.isEmpty } ?? false
            }
        // This account-backed source is authoritative for the ChatGPT OAuth
        // row. A providers/openai_oauth_direct.json file may legitimately
        // contain only UI bookkeeping (auth_mode/default_model); letting that
        // placeholder win would report needs_oauth and hide the signed model
        // catalog even while codex_home/auth.json is healthy.
        synthesize(
            providerId: "openai_oauth_direct",
            display: "ChatGPT (OAuth)",
            hasToken: codexHasAuth,
            modes: ["oauth"],
            readinessDetail: codexHasAuth ? nil : "Sign in with ChatGPT OAuth"
        )
        // Codex CLI provider — always visible as its own explicit provider.
        // Show it as ready iff codex auth.json exists.
        synthesize(providerId: "codex", display: "Codex CLI", hasToken: codexHasAuth, modes: ["oauth"])
        // OpenRouter — always shown so the Providers UI can configure a key.
        // Token presence checked from providers/openrouter.json.
        if byId["openrouter"] == nil {
            let orPath = providersDir.appendingPathComponent("openrouter.json")
            let hasKey = providerFileHasCredential(orPath)
            synthesize(providerId: "openrouter", display: "OpenRouter", hasToken: hasKey, modes: ["api_key"])
        }
        // Unconditional: an empty fetch must not leave a legacy registry row's
        // stale list standing in for OpenRouter's.
        if var provider = byId["openrouter"] {
            provider.models = openRouterProviderModels
            byId["openrouter"] = provider
        }
        synthesize(
            providerId: "moonshot",
            display: "Moonshot AI (Kimi)",
            hasToken: providerFileHasCredential(providersDir.appendingPathComponent("moonshot.json")),
            modes: ["api_key"]
        )
        // Kimi Code SUBSCRIPTION provider (distinct from moonshot's token-billed
        // developer API). Static catalog, api-key auth against kimi-code.json.
        synthesize(
            providerId: "kimi-code",
            display: "Kimi Code",
            hasToken: providerFileHasCredential(providersDir.appendingPathComponent("kimi-code.json")),
            modes: ["api_key"]
        )
        let xaiPath = providersDir.appendingPathComponent("xai_oauth_direct.json")
        let hasXAIToken = providerFileHasCredential(xaiPath)
        synthesize(
            providerId: "xai_oauth_direct",
            display: "xAI Grok (OAuth)",
            hasToken: hasXAIToken,
            modes: ["oauth"],
            readinessDetail: hasXAIToken ? nil : "Sign in with xAI OAuth"
        )

        let codexPreviewModels = CodexSelectableModelCatalog.providerModels(
            providerID: "codex",
            cacheURL: codexCacheURL,
            useDefaultCacheWhenNil: codexCacheURL == nil
        )
        let oauthPreviewModels = CodexSelectableModelCatalog.providerModels(
            providerID: "openai_oauth_direct",
            cacheURL: chatGPTOAuthCacheURL,
            useDefaultCacheWhenNil: false
        )
        let previewIDs = Set((codexPreviewModels + oauthPreviewModels).map(\.id))
        if !previewIDs.isEmpty {
            for (providerID, previewModels) in [
                ("openai_oauth_direct", oauthPreviewModels),
                ("codex", codexPreviewModels),
            ] where !previewModels.isEmpty {
                guard var provider = byId[providerID] else { continue }
                var seen = Set<String>()
                provider.models = (previewModels + provider.models).filter { seen.insert($0.id).inserted }
                byId[providerID] = provider
            }
        }

        byId["openrouter"]?.models_note = openRouterRead.note
        byId["moonshot"]?.models_note = moonshotRead.note

        return Array(byId.values).sorted { $0.display_name < $1.display_name }
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
        codexCacheURL: URL? = nil
    ) async throws -> ModelCatalogResponse {
        let dataRoot = self.dataRoot
        // Swift-native cutover native impl (2026-06-02): was GET /v1/models. When
        // `<dataRoot>/providers/models.json` is present, decode it. When
        // missing, synthesize a baseline catalog (status=ok) so the
        // Providers UI has a non-empty selectable list. Surface prefs come
        // from `<dataRoot>/providers/surfaces.json` if present.
        let resolvedCodexCacheURL = codexCacheURL ?? (
            dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
                ? nil
                : dataRoot.appendingPathComponent("codex_home", isDirectory: true)
                    .appendingPathComponent("models_cache.json")
        )
        let codexSelectableModels = CodexSelectableModelCatalog.modelCatalogItems(
            cacheURL: resolvedCodexCacheURL
        )
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
        let routingSnapshot = try await routing.checkedRoutingSnapshot()
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
            // The on-disk models.json file is a compatibility cache, not an
            // authority for first-party capabilities. Replace matching rows
            // with the verified/current catalogs so a stale persisted entry
            // cannot hide Sonnet 5/Grok 4.5 or resurrect obsolete Think/Fast
            // flags. Account-backed GPT rows intentionally win duplicate ids
            // in this provider-neutral fallback; provider-scoped pickers use
            // list() and retain their exact transport contract.
            merged.catalogFreshness = openRouterRead.freshness.rawValue
            merged.catalogNote = openRouterRead.note
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
        let defaultModel = Self.readModelRoutingConfig(dataRoot: dataRoot).current.chat.model
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
            catalogFreshness: openRouterRead.freshness.rawValue,
            catalogNote: openRouterRead.note
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

import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderReadiness.swift` | Provider inventory and credential readiness |
extension SwiftNativeProviderRouting {
    nonisolated var providersDir: URL {
        dataRoot.appendingPathComponent("providers", isDirectory: true)
    }
    func nativeListProviders(
        openRouterModels: [[String: JSONValue]]? = nil,
        moonshotModels: [[String: JSONValue]]? = nil,
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        additionalProviderIDs: Set<String> = []
    ) throws -> (providers: [Provider], cache: ProviderConfigCache) {
        var byId: [String: Provider] = [:]
        for provider in try Self.loadProviderRegistryChecked(at: providersDir.appendingPathComponent("registry.json")) ?? [] {
            byId[provider.id] = provider
        }
        let skipNames: Set<String> = [
            "registry.json", "models.json", "active.json", "surfaces.json",
            "pending-surface-configuration.json", "cli_session_adoption.json",
            "openrouter-models-cache.json", "moonshot-models-cache.json",
        ]
        var ids = Set(Self.connectableProviderIds).union(byId.keys)
        if let files = try? FileManager.default.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" && !skipNames.contains(file.lastPathComponent) {
                ids.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        let cache = providerConfigCache(for: ids.union(additionalProviderIDs), authEnvironment: authEnvironment)
        for id in ids {
            if let error = cache.reads[id]?.unreadable { throw ProviderRoutingError.underlying(error) }
            var row = byId[id] ?? Provider(id: id)
            row.displayName = Self.connectableProviderIds.contains(id) ? Self.displayName(for: id) : (row.displayName ?? Self.displayName(for: id))
            row.kind = id.contains("oauth") || id == "codex" ? "oauth" : "api_key"
            // Preserve custom registry catalogs; shipped routes always use current catalogs.
            if Self.connectableProviderIds.contains(id) || row.modelCatalog == nil {
                row.modelCatalog = .array(modelsForProvider(
                    id, openRouterModels: openRouterModels, moonshotModels: moonshotModels,
                    codexCacheURL: codexCacheURL, authEnvironment: authEnvironment
                ).map { .object($0) })
            }
            var extras: [String: JSONValue] = [:]
            if case .object(let saved)? = row.extras { extras = saved }
            if Self.connectableProviderIds.contains(id) || extras["auth_modes"] == nil {
                extras["auth_modes"] = .array(authModes(for: id).map { .string($0) })
            }
            // The wire's existing why-the-list-is-missing slot carries an unreadable account list.
            if codexCacheURL == nil, CodexAccountModelCatalog.isAccountBackedProvider(id),
               let fault = CodexAccountModelCatalog.cacheFault(dataRoot: dataRoot, environment: authEnvironment) {
                extras["models_note"] = .string(fault)
            }
            row.extras = .object(extras)
            byId[id] = providerWithReadiness(row, cache: cache, authEnvironment: authEnvironment)
        }
        return (byId.values.sorted { ($0.displayName ?? $0.id) < ($1.displayName ?? $1.id) }, cache)
    }
    private func providerWithReadiness(
        _ provider: Provider, cache: ProviderConfigCache,
        authEnvironment: [String: String]
    ) -> Provider {
        var row = provider
        let readiness = providerReadiness(id: row.id, cache: cache, authEnvironment: authEnvironment)
        row.configured = readiness.ready
        row.active = readiness.ready
        row.oauthStatus = .object([
            "provider_id": .string(row.id),
            "state": .string(readiness.state),
            "detail": .string(readiness.detail),
        ])
        // A failed or unreadable receipt stays the row's error while the key stays eligible.
        row.lastError = readiness.ready && readiness.state != "failed" ? nil : readiness.detail
        var extras: [String: JSONValue] = [:]
        if case .object(let saved)? = row.extras { extras = saved }
        let config = cache.reads[row.id]?.object ?? [:]
        for (key, alias) in [("auth_mode", "authMode"), ("default_model", "defaultModel")] {
            if let value = (config[key] as? String ?? config[alias] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                extras[key] = .string(value)
            }
        }
        row.extras = .object(extras)
        return row
    }
    /// The body reads the same credential admission as provider routing, without catalog discovery.
    public nonisolated func hasUsableCredentials() -> Bool {
        let receipts = ProviderConfigCache(receipts: LLMProviderStatusFeed.receipts(dataRoot: dataRoot))
        return ["anthropic_oauth_direct", "anthropic", "openai_oauth_direct", "openai",
                "openrouter", "moonshot", "kimi-code", "xai_oauth_direct"].contains {
            providerReadiness(id: $0, cache: receipts).ready
        }
    }
    nonisolated func providerReadiness(
        id: String,
        cache: ProviderConfigCache? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (ready: Bool, state: String, detail: String) {
        if let readiness = cache?.readiness[id] { return readiness }
        /// A present credential, a key or a sign-in, is eligible to dispatch
        /// (dispatch is its proof) and read by its own last check for exactly
        /// that credential: rejected is not ready; a failed or unreadable check
        /// stays eligible and says so; otherwise `standing` answers, given the
        /// date a check proved it, if one did.
        func receiptReadiness(_ credential: String, holding: String, rejected: String,
                              standing: (Date?) -> (ready: Bool, state: String, detail: String))
            -> (ready: Bool, state: String, detail: String) {
            let receipts = cache?.receipts ?? LLMProviderStatusFeed.receipts(dataRoot: dataRoot)
            if let unreadable = receipts.unreadable {
                return (true, "failed", "\(holding); its checks are unreadable (\(unreadable)).")
            }
            switch receipts.verdict(providerID: id, key: credential) {
            case .rejected: return (false, "rejected", rejected)
            case .failed(let why): return (true, "failed", "\(holding); its last check failed: \(why)")
            case .proven(let checkedAt): return standing(checkedAt)
            case .unchecked: return standing(nil)
            }
        }
        /// needs_key is absent; rejected is refused at its last check; saved is present and unproven; ready is proven.
        func keyReadiness(_ name: String) -> (ready: Bool, state: String, detail: String) {
            let key: String?
            do {
                key = if let read = cache?.reads[id] {
                    try LLMCredentialResolver.checkedAPIKey(providerConfigObject: read.object)
                } else {
                    try LLMCredentialResolver.checkedAPIKey(providerConfigFile: "\(id).json", dataRoot: dataRoot)
                }
            } catch {
                return (false, "unavailable", ProviderFailure.diagnosticDescription(error))
            }
            guard let key else { return (false, "needs_key", "No \(name) API key configured") }
            return receiptReadiness(key, holding: "\(name) API key saved",
                                    rejected: "\(name) rejected this API key at its last check; paste a new key.") {
                $0.map { (true, "ready", "\(name) API key checked \($0.formatted(.iso8601))") }
                    ?? (true, "saved", "\(name) API key saved, not yet proven by a check")
            }
        }
        /// A sign-in the validator judged usable keeps its own words unless its check says otherwise.
        func signInReadiness(_ judged: (Bool, String, String?)) -> (ready: Bool, state: String, detail: String) {
            guard judged.0, let token = judged.2 else { return (judged.0, "needs_oauth", judged.1) }
            // A sign-in with no check receipt yet is present and unproven, the
            // same word a saved key gets; needs_oauth is for a sign-in that is
            // absent (judged unusable above). 0.6.9 night: Doctor and the
            // Providers page told User to sign in to the account every turn ran on.
            return receiptReadiness(token, holding: "Signed in",
                                    rejected: "This sign-in was rejected at its last check; sign in again in Providers.") { _ in
                (true, "saved", judged.1)
            }
        }
        switch id {
        case "openai_oauth_direct", "codex":
            if id == "codex" {
                guard (try? CodexExecutable.resolveCodexExecutable(environment: authEnvironment)) != nil else {
                    return (false, "needs_install", "Install Codex CLI to use this account through Codex.")
                }
            }
            // Reads codex_home/auth.json and the OAuth candidate paths, not
            // `providers/<id>.json` — nothing in the model lane touches those,
            // so there is no shared read to make.
            return signInReadiness(Self.validateOpenAIOAuthDirect(dataRoot: dataRoot, environment: authEnvironment))
        case "anthropic_oauth_direct":
            return signInReadiness(Self.validateAnthropicOAuthDirect(providersDir: providersDir, preRead: cache?.reads[id]))
        case "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return signInReadiness(Self.validateXAIOAuthDirect(providersDir: providersDir, preRead: cache?.reads[id]))
        case "openai": return keyReadiness("OpenAI")
        case "anthropic": return keyReadiness("Anthropic")
        case "openrouter": return keyReadiness("OpenRouter")
        case "moonshot": return keyReadiness("Moonshot")
        case "kimi-code": return keyReadiness("Kimi Code")
        default:
            // The cached read has already resolved any Keychain reference.
            // Bookkeeping alone (auth mode/default model) is not a credential.
            let config = (cache?.reads[id] ?? readProviderConfig(id)).object ?? [:]
            let credentialKeys = ["api_key", "access_token", "setup_token", "refresh_token", "token", "id_token"]
            let tokens = config["tokens"] as? [String: Any] ?? [:]
            let credentials = credentialKeys.compactMap { config[$0] as? String }
                + [tokens["access_token"] as? String].compactMap { $0 }
            if let credential = credentials.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return receiptReadiness(credential.trimmingCharacters(in: .whitespacesAndNewlines), holding: "Provider credential saved",
                                        rejected: "Provider rejected this credential at its last check; save a new credential.") {
                    $0.map { (true, "ready", "Provider credential checked \($0.formatted(.iso8601))") }
                        ?? (true, "saved", "Provider credential saved, not yet proven by a check")
                }
            }
            return (false, "needs_credentials", "No provider credential configured")
        }
    }
    nonisolated static func displayName(for id: String) -> String {
        switch id {
        case "openai": return "OpenAI (API key)"
        case "openai_oauth_direct": return "ChatGPT (OAuth)"
        case "codex": return "Codex CLI"
        case "anthropic": return "Anthropic (API key)"
        case "anthropic_oauth_direct": return "Anthropic (OAuth / Setup-Token)"
        case "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xAI Grok (OAuth)"
        case "openrouter": return "OpenRouter"
        case "moonshot": return "Moonshot AI (Kimi)"
        case "kimi-code": return "Kimi Code"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    private nonisolated func authModes(for id: String) -> [String] {
        if id.contains("oauth") || id == "codex" { return ["oauth"] }
        if ["openai", "anthropic", "openrouter", "moonshot", "kimi-code"].contains(id) { return ["api_key"] }
        return ["api_key", "oauth"]
    }
    /// Can this route actually run this model at this Think level, on THIS
    /// install? Used wherever a provider/model/effort tuple is CHOSEN rather
    /// than resolved — the Bots editor, the bot tools, the bot runner, and a bot
    /// session continued in Chat.
    ///
    /// Requires a connected provider and a model its authoritative catalog offers.
    ///
    /// It never reaches the network; a fetched-catalog route is judged from the
    /// cache that is already on disk — and a cache that is stale, absent or
    /// known-truncated cannot convict: the pick stands. Moonshot uses the same
    /// cached rows as its picker; other shipped catalogs remain authoritative.
    public func botChoiceRejection(
        provider: String?,
        model: String?,
        reasoningEffort: String?
    ) -> String? {
        let moonshotModels = Self.normalizeProviderId(provider ?? "") == "moonshot"
            ? MoonshotModelCatalog.readCache(dataRoot: dataRoot) : nil
        let accountModels = CodexAccountModelCatalog.isAccountBackedProvider(provider ?? "")
            ? CodexAccountModelCatalog.load(
                providerID: provider ?? "",
                cacheURL: CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: dataRoot),
                useDefaultCacheWhenNil: false
            ) : nil
        if let shape = ProviderModelChoice.rejection(
            provider: provider, model: model, reasoningEffort: reasoningEffort,
            accountModels: accountModels, moonshotModels: moonshotModels
        ) {
            return shape
        }
        guard let provider, let model else { return "Choose an account, model and effort." }
        let route = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerReadiness(id: route).ready else {
            return "\(route) is not connected. Connect it in Providers, or choose an account that is."
        }
        // A fetched-catalog route: convict only on a complete, fresh cache that
        // does not list the model.
        if Self.normalizeProviderId(route) == "openrouter",
           OpenRouterModelCatalog.cachedAvailability(of: picked, dataRoot: dataRoot) == .unavailable {
            return "OpenRouter no longer lists \(picked). Pick a model from its list."
        }
        return nil
    }
    /// `openRouterModels` / `moonshotModels` are the provider's fetched list
    /// when the caller read it (empty = the fetch had nothing), nil when it did
    /// not. Unread, OpenRouter offers nothing and Moonshot its shipped rows;
    /// fetched Moonshot rows also govern saved picks and helper validation.
    nonisolated func modelsForProvider(
        _ id: String,
        openRouterModels: [[String: JSONValue]]? = nil,
        moonshotModels: [[String: JSONValue]]? = nil,
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [[String: JSONValue]] {
        // Project only the selected route; the default still combines all rows
        // in the same order. No unrelated catalog needs rebuilding for a pick.
        var openai: [[String: JSONValue]] { FirstPartyModelCatalog.publicOpenAIModels.map { $0.providerJSON() } }
        var anthropic: [[String: JSONValue]] { FirstPartyModelCatalog.anthropicModels.map { $0.providerJSON() } }
        var xai: [[String: JSONValue]] { FirstPartyModelCatalog.xAIModels.map { $0.providerJSON() } }
        var moonshot: [[String: JSONValue]] { moonshotModels ?? FirstPartyModelCatalog.moonshotModels.map { $0.providerJSON() } }
        switch id {
        case "openai_oauth_direct", "codex":
            if CodexAccountModelCatalog.cacheFault(dataRoot: dataRoot, environment: authEnvironment) != nil { return [] }
            let cacheURL = codexCacheURL ?? CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(
                dataRoot: dataRoot, environment: authEnvironment
            )
            return CodexAccountModelCatalog.providerModels(
                providerID: id, cacheURL: cacheURL,
                useDefaultCacheWhenNil: id == "codex" && cacheURL == nil
                    && !ChatGPTTransport.hasAccessToken(at: NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: dataRoot)), dataRoot: dataRoot
            ).map { $0.providerJSON() }
        case "openrouter": return openRouterModels ?? []
        case "moonshot", "kimi": return moonshot
        default:
            let shipped = FirstPartyModelCatalog.models(forProviderID: id)
            if id == id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !shipped.isEmpty {
                return shipped.map { $0.providerJSON() }
            }
            return openai + anthropic + xai + (openRouterModels ?? []) + moonshot
        }
    }
    func modelPreferencesFromComputed() async throws -> ModelPreferences {
        let prefs = try await computeModelPreferences()
        var current: [String: JSONValue] = [:]
        for surface in MODEL_SURFACES {
            if let p = prefs[surface] {
                current[surface] = .object([
                    "surface": .string(surface),
                    "model": .string(p.model),
                    "reasoningEffort": .string(p.reasoningEffort),
                    "reasoning_effort": .string(p.reasoningEffort),
                    "serviceTier": .string(p.serviceTier),
                    "service_tier": .string(p.serviceTier),
                ])
            }
        }
        return ModelPreferences(
            surfaceModels: .object(current),
            defaultModel: prefs["chat"]?.model,
            extras: .object([
                "current": .object(current),
                "status": .string("ok"),
            ])
        )
    }
}

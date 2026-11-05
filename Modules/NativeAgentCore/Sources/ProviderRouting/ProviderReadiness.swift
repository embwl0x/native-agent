import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderReadiness.swift` | exact credential/catalog readiness |
extension SwiftNativeProviderRouting {
    nonisolated var providersDir: URL {
        dataRoot.appendingPathComponent("providers", isDirectory: true)
    }
    func nativeListProviders(
        openRouterModels: [[String: JSONValue]]? = nil,
        moonshotModels: [[String: JSONValue]]? = nil,
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        additionalProviderIDs: Set<String> = [], preview: Bool = false
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
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { files = [] }
        catch {
            throw ProviderRoutingError.underlying("""
                Provider directory \(providersDir.path) could not be enumerated: \(error.localizedDescription). Repair its access before listing \
                providers.
                """)
        }
        for file in files where file.pathExtension == "json" && !skipNames.contains(file.lastPathComponent) {
            ids.insert(file.deletingPathExtension().lastPathComponent)
        }
        let cache = providerConfigCache(for: ids.union(additionalProviderIDs), authEnvironment: authEnvironment)
        for id in ids {
            var row = byId[id] ?? Provider(id: id)
            row.displayName = Self.connectableProviderIds.contains(id) ? Self.displayName(for: id) : (row.displayName ?? Self.displayName(for: id))
            row.kind = id.contains("oauth") || id == "codex" ? "oauth" : "api_key"
            // Preserve custom registry catalogs; shipped routes always use current catalogs.
            if Self.connectableProviderIds.contains(id) || row.modelCatalog == nil {
                row.modelCatalog = .array(modelsForProvider(
                    id, openRouterModels: openRouterModels, moonshotModels: moonshotModels,
                    codexCacheURL: codexCacheURL, authEnvironment: authEnvironment, preview: preview
                ).map { .object($0) })
            }
            var extras: [String: JSONValue] = [:]
            if case .object(let saved)? = row.extras { extras = saved }
            if Self.connectableProviderIds.contains(id) || extras["auth_modes"] == nil {
                extras["auth_modes"] = .array(authModes(for: id).map { .string($0) })
            }
            // An unreadable account catalog must retain its cause in the missing-list field.
            if codexCacheURL == nil, CodexAccountModelCatalog.isAccountBackedProvider(id) {
                extras["models_note"] = CodexAccountModelCatalog.cacheFault(dataRoot: dataRoot, environment: authEnvironment, preview: preview).map(
                    JSONValue.string)
            }
            if Self.normalizeProviderId(id) == "moonshot" {
                extras["models_note"] = MoonshotModelCatalog.cacheFault(dataRoot: dataRoot).map(JSONValue.string)
            }
            if !Self.connectableProviderIds.contains(id), row.modelCatalog == .array([]) {
                extras["models_note"] = .string("\(id) has no model catalog. Configure its own catalog before choosing or running a model.")
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
            "eligible": .bool(readiness.ready),
        ])
        // A failed or unreadable receipt stays the row's error while the key stays eligible.
        row.lastError = readiness.ready && readiness.state != "failed" ? nil : readiness.detail
        var extras: [String: JSONValue] = [:]
        if case .object(let saved)? = row.extras { extras = saved }
        let config = cache.reads[row.id]?.object ?? [:]
        for key in ["auth_mode", "default_model"] {
            if let value = (config[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                extras[key] = .string(value)
            }
        }
        row.extras = .object(extras)
        return row
    }
    /// Body status shares credential admission without triggering catalog discovery.
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
        if let fault = cache?.reads[id]?.unreadable { return (false, "unavailable", fault) }
        if let readiness = cache?.readiness[id] { return readiness }
        if let error = cache?.reads[id]?.unreadable {
            return (false, "unavailable", error)
        }
        /// Readiness grades the exact credential's own check. Rejection blocks it; absent, failed or unreadable proof stays eligible and unproven until
        /// dispatch.
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
        /// Absent, rejected, saved and proven credentials must remain distinct.
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
        func signInReadiness(_ judged: (Bool, String, String?, unavailable: Bool)) -> (ready: Bool, state: String, detail: String) {
            if judged.unavailable { return (false, "unavailable", judged.1) }
            guard judged.0, let token = judged.2 else { return (judged.0, "needs_oauth", judged.1) }
            // A usable sign-in without a check is present and unproven; needs_oauth is reserved for absent sign-in.
            return receiptReadiness(token, holding: "Signed in",
                                    rejected: "This sign-in was rejected at its last check; sign in again in Providers.") { checkedAt in
                // The check time reads as every face row's time does: the clock today, the day otherwise.
                if let checkedAt {
                    let when = Calendar.current.isDateInToday(checkedAt) ? checkedAt.formatted(date: .omitted, time: .shortened)
                        : checkedAt.formatted(.dateTime.month(.abbreviated).day())
                    return (true, "ready", judged.1 + "; checked " + when)
                }
                return (true, "saved", judged.1)
            }
        }
        switch id {
        case "openai_oauth_direct", "codex":
            if id == "codex" {
                guard (try? CodexExecutable.resolveCodexExecutable(environment: authEnvironment)) != nil else {
                    return (false, "needs_install", "Install Codex CLI to use this account through Codex.")
                }
            }
            // Account credentials have their own paths, so provider-config reads cannot stand in for them.
            return signInReadiness(Self.validateOpenAIOAuthDirect(dataRoot: dataRoot, environment: authEnvironment))
        case "anthropic_oauth_direct":
            return signInReadiness(Self.validateAnthropicOAuthDirect(providersDir: providersDir, preRead: cache?.reads[id]))
        case "xai_oauth_direct":
            return signInReadiness(Self.validateXAIOAuthDirect(providersDir: providersDir, preRead: cache?.reads[id]))
        case "openai": return keyReadiness("OpenAI")
        case "anthropic": return keyReadiness("Anthropic")
        case "openrouter": return keyReadiness("OpenRouter")
        case "moonshot": return keyReadiness("Moonshot")
        case "kimi-code": return keyReadiness("Kimi Code")
        default:
            // The cached read has already resolved any Keychain reference. Bookkeeping alone (auth mode/default model) is not a credential.
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
    /// The account's name as the Providers page lists it: a shipped route by its fixed name, a registered one by its own; throws when the registry is
    /// unreadable.
    public nonisolated func providerDisplayName(_ id: String) throws -> String {
        if Self.connectableProviderIds.contains(id) { return Self.displayName(for: id) }
        let registered = try Self.loadProviderRegistryChecked(at: providersDir.appendingPathComponent("registry.json"))?.first { $0.id == id }
        return registered?.displayName ?? Self.displayName(for: id)
    }
    nonisolated static func displayName(for id: String) -> String {
        switch id {
        case "openai": return "OpenAI (API key)"
        case "openai_oauth_direct": return "ChatGPT (OAuth)"
        case "codex": return "Codex CLI"
        case "anthropic": return "Anthropic (API key)"
        case "anthropic_oauth_direct": return "Anthropic (OAuth / Setup-Token)"
        case "xai_oauth_direct":
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
    /// Validate explicit helper choices without network or reselection. Required catalog faults stop membership checks; incomplete OpenRouter evidence
    /// cannot disprove a saved pin.
    public func botChoiceRejection(
        provider: String?,
        model: String?,
        reasoningEffort: String?, preview: Bool = false
    ) -> String? {
        let routeID = Self.normalizeProviderId(provider ?? "")
        if routeID == "openrouter" {
            let catalog = catalogRows(routeID, preview: preview)
            if let fault = catalog.fault { return fault }
            guard let model, let row = catalog.rows.first(where: { $0["id"] == .string(model) }),
                  case .array(let efforts)? = row["supported_reasoning_efforts"] else {
                return "OpenRouter's model capabilities are unavailable. Reload Providers and choose a model."
            }
            if efforts.isEmpty {
                // A declared absent selector is a valid model. It admits omission of the optional control, never a guessed effort.
                guard reasoningEffort == nil || reasoningEffort == "" || reasoningEffort == "default" else {
                    return "This OpenRouter model has no Think selector. Choose provider default in Providers."
                }
            } else if !efforts.contains(.string(reasoningEffort ?? "")) {
                return "Choose one of this OpenRouter model's declared Think levels: \(efforts.compactMap(\.stringValue).joined(separator: ", "))."
            }
            return providerReadiness(id: routeID).ready ? nil : "OpenRouter is not connected. Connect it in Providers."
        }
        let accountBacked = CodexAccountModelCatalog.isAccountBackedProvider(provider ?? "")
        if accountBacked,
           let fault = CodexAccountModelCatalog.cacheFault(dataRoot: dataRoot, preview: preview) { return fault }
        if routeID == "moonshot", let fault = MoonshotModelCatalog.cacheFault(dataRoot: dataRoot) { return fault }
        if routeID == "openrouter", let fault = OpenRouterModelCatalog.cacheFault(dataRoot: dataRoot) { return fault }
        let moonshotModels = routeID == "moonshot"
            ? MoonshotModelCatalog.readCache(dataRoot: dataRoot) : nil
        let accountModels = accountBacked
            ? CodexAccountModelCatalog.load(
                providerID: provider ?? "",
                cacheURL: CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: dataRoot, preview: preview),
                useDefaultCacheWhenNil: false, dataRoot: dataRoot, preview: preview
            ) : nil
        if let shape = ProviderModelChoice.rejection(
            provider: provider, model: model, reasoningEffort: reasoningEffort,
            accountModels: accountModels, moonshotModels: moonshotModels,
            openRouterModels: routeID == "openrouter" ? OpenRouterModelCatalog.readCache(dataRoot: dataRoot) : nil
        ) {
            return shape
        }
        guard let provider, let model else { return "Choose an account, model and effort." }
        let route = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerReadiness(id: route).ready else {
            return "\(route) is not connected. Connect it in Providers, or choose an account that is."
        }
        // A fetched-catalog route: convict only on a complete, fresh cache that does not list the model.
        if Self.normalizeProviderId(route) == "openrouter",
           OpenRouterModelCatalog.cachedAvailability(of: picked, dataRoot: dataRoot) == .unavailable {
            return "OpenRouter no longer lists \(picked). Pick a model from its list."
        }
        return nil
    }
    /// A missing/unreadable fetched catalog offers no replacement rows; nil means unread and empty means the fetch returned no models.
    nonisolated func modelsForProvider(
        _ id: String,
        openRouterModels: [[String: JSONValue]]? = nil,
        moonshotModels: [[String: JSONValue]]? = nil,
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment, preview: Bool = false
    ) -> [[String: JSONValue]] {
        // A catalog belongs to the selected route. Unknown catalogs offer no rows.
        var moonshot: [[String: JSONValue]] {
            if MoonshotModelCatalog.cacheFault(dataRoot: dataRoot) != nil { return [] }
            return moonshotModels ?? []
        }
        switch id {
        case "openai_oauth_direct", "codex":
            if CodexAccountModelCatalog.cacheFault(dataRoot: dataRoot, environment: authEnvironment, preview: preview) != nil { return [] }
            let cacheURL = codexCacheURL ?? CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(
                dataRoot: dataRoot, environment: authEnvironment, preview: preview
            )
            // This catalog belongs to the selected credential; no second token-presence read may redirect it to the command CLI's cache.
            return CodexAccountModelCatalog.providerModels(
                providerID: id, cacheURL: cacheURL,
                useDefaultCacheWhenNil: false, dataRoot: dataRoot, preview: preview
            ).map { $0.providerJSON() }
        case "openrouter": return openRouterModels ?? []
        case "moonshot": return moonshot
        default:
            let shipped = FirstPartyModelCatalog.models(forProviderID: id)
            if id == id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !shipped.isEmpty {
                return shipped.map { $0.providerJSON() }
            }
            return []
        }
    }
    func modelPreferencesFromComputed() async throws -> ModelPreferences {
        let prefs = try await computeModelPreferences()
        var current: [String: JSONValue] = [:]
        for surface in MODEL_SURFACES {
            if let p = prefs[surface] {
                current[surface] = try JSONValue.parse(JSONEncoder().encode(p))
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

import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

// W-H Band (U5 decomposition, move-only): providers + OAuth-readiness
// validators + embeddings/health routes. Relocated verbatim: the four
// fileprivate OAuth validator free-functions (used only by this cluster)
// move with the block and stay fileprivate here; the extension block was
// already shaped as `extension NativeClient`. One documented lift in the
// root file: writeActiveProvider (fileprivate→internal) — still called by
// configureModel/setSurfaceModel which stay in the root.

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
        if let expDate = parseAuthExpiresAt(tokens["expires_at"])
                        ?? parseAuthExpiresAt(obj["expires_at"])
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
    guard let data = try? Data(contentsOf: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (false, "anthropic_oauth_direct.json missing or malformed") }
    // Accept either OAuth access_token (top-level or nested) or a setup_token.
    let topAccess = (obj["access_token"] as? String) ?? ""
    let nestedAccess = ((obj["tokens"] as? [String: Any])?["access_token"] as? String) ?? ""
    let setupTok   = (obj["setup_token"] as? String) ?? ""
    let access = !topAccess.isEmpty ? topAccess : (!nestedAccess.isEmpty ? nestedAccess : setupTok)
    if access.isEmpty {
        return (false, "no access_token or setup_token — sign in required")
    }
    let refresh = (obj["refresh_token"] as? String) ?? ""
    if let expDate = parseAuthExpiresAt(obj["expires_at"]) {
        if expDate > Date() {
            return (true, "Signed in (valid)")
        }
        if !refresh.isEmpty {
            return (true, "Access expired — refresh on next chat")
        }
        return (false, "Access expired and no refresh_token — re-auth required")
    }
    // setup_token path has no expiry — long-lived.
    return (true, "Signed in")
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
    if let expDate = parseAuthExpiresAt(obj["expires_at"])
        ?? parseAuthExpiresAt((obj["tokens"] as? [String: Any])?["expires_at"])
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

fileprivate func parseAuthExpiresAt(_ raw: Any?) -> Date? {
    guard let raw = raw else { return nil }
    if let i = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
    if let d = raw as? Double { return Date(timeIntervalSince1970: d) }
    guard let s = raw as? String, !s.isEmpty else { return nil }
    if let unix = TimeInterval(s) { return Date(timeIntervalSince1970: unix) }
    let basic = DateFormatter()
    basic.calendar = Calendar(identifier: .iso8601)
    basic.locale = Locale(identifier: "en_US_POSIX")
    basic.timeZone = TimeZone(secondsFromGMT: 0)
    basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    if let d = basic.date(from: s) { return d }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    return nil
}

fileprivate func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var body = String(parts[1])
    while body.count % 4 != 0 { body.append("=") }
    body = body.replacingOccurrences(of: "-", with: "+")
               .replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: body),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let exp = obj["exp"] as? Int    { return Date(timeIntervalSince1970: TimeInterval(exp)) }
    if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
    return nil
}

// PATCH-2026-05-07: model-providers v1 — NativeClient provider API methods
extension NativeClient {
    // DAEMON-DEAD PORT (2026-06-02): registry decode of
    // <dataRoot>/providers/registry.json. Returns [] when the file is missing
    // or malformed — the daemon's empty-registry shape was an empty list.
    func listProviders() async throws -> [ProviderInfo] {
        try await listProviders(
            dataRoot: PersistenceCore.defaultDataRoot(),
            authEnvironment: ProcessInfo.processInfo.environment
        )
    }

    func listProviders(
        dataRoot: URL,
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String]
    ) async throws -> [ProviderInfo] {
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
        let openRouterModels = await OpenRouterModelCatalog.models(dataRoot: dataRoot)
        let moonshotModels = await MoonshotModelCatalog.models(dataRoot: dataRoot)
        let openRouterProviderModels = openRouterModels.map { model in
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
        let openRouterModelDictionaries = openRouterModels.map { model -> [String: Any] in
            var dict: [String: Any] = [
                "id": model.id,
                "name": model.name,
                "context_length": model.contextLength,
                "supports_streaming": model.supportsStreaming,
                "supports_vision": model.supportsVision,
                "supports_tools": model.supportsTools,
                "supports_json_mode": model.supportsJSONMode,
            ]
            if let cost = model.costPer1KIn {
                dict["cost_per_1k_in"] = cost
            }
            if let cost = model.costPer1KOut {
                dict["cost_per_1k_out"] = cost
            }
            return dict
        }
        let moonshotModelDictionaries = moonshotModels.map { model -> [String: Any] in
            [
                "id": model.id,
                "name": model.name,
                "context_length": model.contextLength,
                "supports_streaming": model.supportsStreaming,
                "supports_vision": model.supportsVision,
                "supports_tools": model.supportsTools,
                "supports_json_mode": model.supportsJSONMode,
                "default_reasoning_effort": MoonshotModelCatalog.defaultReasoningEffort(for: model.id),
                "supported_reasoning_efforts": MoonshotModelCatalog.supportedReasoningEfforts(for: model.id),
                "supports_fast": false,
            ]
        }

        var byId: [String: ProviderInfo] = [:]

        // Model lists per provider family — what each provider actually serves.
        func modelsFor(_ providerId: String) -> [[String: Any]] {
            func dictionary(_ model: FirstPartyModelDescriptor) -> [String: Any] {
                [
                    "id": model.id,
                    "name": model.name,
                    "context_length": model.contextLength,
                    "supports_streaming": model.supportsStreaming,
                    "supports_vision": model.supportsVision,
                    "supports_tools": model.supportsTools,
                    "supports_json_mode": model.supportsJSONMode,
                    "default_reasoning_effort": model.defaultReasoningEffort,
                    "supported_reasoning_efforts": model.supportedReasoningEfforts,
                    "supports_fast": model.supportsFast,
                ]
            }
            let openai = FirstPartyModelCatalog.publicOpenAIModels.map(dictionary)
            let chatGPTOAuthModels = CodexSelectableModelCatalog.providerModelDictionaries(
                providerID: "openai_oauth_direct",
                cacheURL: chatGPTOAuthCacheURL,
                useDefaultCacheWhenNil: false
            )
            let codexModels = CodexSelectableModelCatalog
                .providerModelDictionaries(
                    providerID: "codex",
                    cacheURL: codexCacheURL,
                    useDefaultCacheWhenNil: codexCacheURL == nil
                )
            let anthropic = FirstPartyModelCatalog.anthropicModels.map(dictionary)
            let xai = FirstPartyModelCatalog.xAIModels.map(dictionary)
            switch providerId {
            case "openai": return openai
            case "openai_oauth_direct": return chatGPTOAuthModels
            case "codex": return codexModels
            case "anthropic", "anthropic_oauth_direct", "anthropic_mcp": return anthropic
            case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth": return xai
            case "openrouter": return openRouterModelDictionaries
            case "moonshot": return moonshotModelDictionaries
            case "kimi-code": return FirstPartyModelCatalog.kimiCodeModels.map(dictionary)
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
            let statusDict: [String: Any] = [
                "provider_id": providerId,
                "state": state,
                "detail": effectiveDetail,
                "metadata": [:] as [String: String],
            ]
            let providerDict: [String: Any] = [
                "provider_id": providerId,
                "display_name": display,
                "auth_modes": modes,
                "auth_status": statusDict,
                "models": modelsFor(providerId),
            ]
            if let providerJSON = try? JSONSerialization.data(withJSONObject: providerDict),
               let synthesized = try? JSONDecoder.nativeAgent.decode(ProviderInfo.self, from: providerJSON) {
                byId[providerId] = synthesized
            }
        }

        // Source 1: registry.json (legacy)
        let registryPath = providersDir.appendingPathComponent("registry.json")
        if let data = try? Data(contentsOf: registryPath),
           let existing = try? JSONDecoder.nativeAgent.decode([ProviderInfo].self, from: data) {
            for p in existing { byId[p.provider_id] = p }
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
        if !openRouterProviderModels.isEmpty, var provider = byId["openrouter"] {
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

        func decodePreviewModels(_ dictionaries: [[String: Any]]) -> [ProviderModelInfo] {
            dictionaries.compactMap { dictionary in
                guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
                return try? JSONDecoder.nativeAgent.decode(ProviderModelInfo.self, from: data)
            }
        }
        let codexPreviewModels = decodePreviewModels(
            CodexSelectableModelCatalog.providerModelDictionaries(
                providerID: "codex",
                cacheURL: codexCacheURL,
                useDefaultCacheWhenNil: codexCacheURL == nil
            )
        )
        let oauthPreviewModels = decodePreviewModels(
            CodexSelectableModelCatalog.providerModelDictionaries(
                providerID: "openai_oauth_direct",
                cacheURL: chatGPTOAuthCacheURL,
                useDefaultCacheWhenNil: false
            )
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

        return Array(byId.values).sorted { $0.display_name < $1.display_name }
    }

    func getProvider(_ id: String) async throws -> ProviderInfo {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentProvider", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "provider id is required"
            ])
        }
        let providers = try await listProviders()
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

    // DAEMON-DEAD PORT (2026-06-02): persist provider config to
    // <dataRoot>/providers/<id>.json under flock. Merges with the existing
    // dict so unrelated fields aren't clobbered. Empty/whitespace api_key and
    // default_model are skipped (matches the daemon's "only set if provided"
    // semantics).
    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String? = nil) async throws -> EmptyResponse {
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(id).json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
            var entry: [String: JSONValue]
            if case .object(let obj) = current { entry = obj } else { entry = [:] }
            entry["auth_mode"] = .string(authMode)
            if let key = apiKey, !key.isEmpty {
                entry["api_key"] = .string(key)
            }
            if let dm = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !dm.isEmpty {
                entry["default_model"] = .string(dm)
            }
            try await persistence.writeJSON(.object(entry), to: path)
        }
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedId == "moonshot" {
            _ = await MoonshotModelCatalog.models(dataRoot: PersistenceCore.defaultDataRoot(), refresh: true)
        }
        // Wave C review (MED): OpenRouter refresh parity must reach THIS path —
        // it is the Mac Provider Settings save route (the Core routing layer's
        // configureProvider parity alone never fires from the sheet).
        if normalizedId == "openrouter" {
            _ = await OpenRouterModelCatalog.models(dataRoot: PersistenceCore.defaultDataRoot(), refresh: true)
        }
        return EmptyResponse()
    }

    // DAEMON-DEAD PORT (2026-06-02): native reachability probe. Resolves the
    // API key via LLMCredentialResolver (env → providers/<id>.json), then for
    // OpenAI hits GET /v1/models with a Bearer token and reports latency.
    // Anthropic has no free probe endpoint so we report tested:false.
    func testProvider(_ id: String) async throws -> ProviderTestResult {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let (envVar, configFile): (String?, String?) = {
            switch id {
            case "openai": return ("OPENAI_API_KEY", "openai.json")
            case "anthropic": return ("ANTHROPIC_API_KEY", "anthropic.json")
            case "moonshot": return ("MOONSHOT_API_KEY", "moonshot.json")
            case "kimi-code": return ("KIMI_CODE_API_KEY", "kimi-code.json")
            default: return (nil, nil)
            }
        }()

        guard let envVar, let configFile else {
            return ProviderTestResult(
                provider_id: id, status: "unknown", tested: false,
                response: nil, model_used: nil,
                detail: "no native probe for \(id)", error: nil
            )
        }
        guard let apiKey = LLMCredentialResolver.resolveAPIKey(
            envVar: envVar, providerConfigFile: configFile, dataRoot: dataRoot
        ), !apiKey.isEmpty else {
            return ProviderTestResult(
                provider_id: id, status: "error", tested: false,
                response: nil, model_used: nil,
                detail: nil, error: "no api key configured"
            )
        }

        if id == "anthropic" {
            return ProviderTestResult(
                provider_id: id, status: "ok", tested: false,
                response: nil, model_used: nil,
                detail: "anthropic probe skipped", error: nil
            )
        }

        if id == "kimi-code" {
            // Real reachability probe: the subscription API has no free GET
            // /models, so spend one token on a minimal Messages call. Proves
            // key validity + endpoint reachability, and its 200 also confirms
            // the Anthropic-compat body shape end to end.
            var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.timeoutInterval = 20
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": "kimi-for-coding",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ])
            let start = Date()
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    return ProviderTestResult(
                        provider_id: id, status: "ok", tested: true,
                        response: nil, model_used: "kimi-for-coding",
                        detail: "latency=\(ms)ms", error: nil
                    )
                }
                let hint = code == 401 ? "key rejected" : "HTTP \(code)"
                return ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: "kimi-for-coding",
                    detail: "latency=\(ms)ms", error: hint
                )
            } catch {
                return ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: nil,
                    detail: nil, error: error.localizedDescription
                )
            }
        }

        let modelsEndpoint = id == "moonshot"
            ? MoonshotModelCatalog.endpoint
            : URL(string: "https://api.openai.com/v1/models")!
        var req = URLRequest(url: modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                if id == "moonshot" {
                    _ = await MoonshotModelCatalog.models(dataRoot: dataRoot, refresh: true)
                }
                return ProviderTestResult(
                    provider_id: id, status: "ok", tested: true,
                    response: nil, model_used: nil,
                    detail: "latency=\(ms)ms", error: nil
                )
            }
            return ProviderTestResult(
                provider_id: id, status: "error", tested: true,
                response: nil, model_used: nil,
                detail: "latency=\(ms)ms", error: "HTTP \(code)"
            )
        } catch {
            return ProviderTestResult(
                provider_id: id, status: "error", tested: true,
                response: nil, model_used: nil,
                detail: nil, error: error.localizedDescription
            )
        }
    }

    // DAEMON-DEAD PORT (2026-06-02): write surface→provider into
    // <dataRoot>/providers/active.json under flock, merged with existing.
    func setActiveProvider(surface: String, providerId: String) async throws -> EmptyResponse {
        try await Self.writeActiveProvider(surface: surface, providerID: providerId)
        return EmptyResponse()
    }

    // DAEMON-DEAD PORT (2026-06-02): remove the entry with provider_id == id
    // from <dataRoot>/providers/registry.json under flock. Missing file or
    // non-array body → no-op (returns EmptyResponse cleanly, matching Python).
    func clearProvider(_ id: String) async throws -> EmptyResponse {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let path = dataRoot.appendingPathComponent("providers/registry.json")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .array([]))
            guard case .array(let items) = current else { return }
            let filtered = items.filter { item in
                if case .object(let obj) = item,
                   case .string(let rid)? = obj["provider_id"], rid == id {
                    return false
                }
                return true
            }
            try await persistence.writeJSON(.array(filtered), to: path)
        }
        // FIX 2026-07-04: "Remove Key" must delete the on-disk credential, not
        // just the registry row. listProviders() reads readiness from the
        // api_key / oauth token inside providers/<id>.json — leaving that file
        // in place makes the provider still report "ready" after the UI claims
        // the key was removed. Runs regardless of registry.json's shape (an
        // early `return` from the lock block above must not skip this). Removed
        // under a lock on the credential file itself so it can't interleave with
        // a concurrent configureProvider write to the same path.
        let credFile = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(id).json")
        try await persistence.withFileLock(credFile) {
            try? FileManager.default.removeItem(at: credFile)
        }
        return EmptyResponse()
    }

    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test

    // PATCH-2026-05-08: wave3 Feature A/B/D new endpoints
    func getHealthCard() async throws -> HealthCard {
        // F6 (eval E06 fix-2): synthesize health from the real Swift
        // DoctorChecks runner (runDoctor) rather than a hardcoded all-ok
        // row set. Each DoctorCheck maps 1:1 to a HealthCardSubsystem; the
        // overall status is the worst-row rollup (fail > warn > ok) that
        // runDoctor already computes. A doctor failure falls back to a
        // single error row so the panel still renders.
        // W1.2: prefer DoctorAutoRunLoop's cached <dataRoot>/doctor/latest.json
        // when its runAt is <60s old, so the health card doesn't re-run every
        // probe per call. Stale or missing → fall through to a live runDoctor.
        let now = ISO8601DateFormatter().string(from: Date())
        if let cached = readCachedHealthCard(now: now) {
            return await mergingLiveDoctorCoverage(into: cached, now: now)
        }
        do {
            let report = try await runDoctor(repair: false)
            let subs: [HealthCardSubsystem] = report.checks.map { c in
                HealthCardSubsystem(
                    id: c.id,
                    label: c.title,
                    status: c.status,
                    detail: c.detail,
                    fixAction: c.repair
                )
            }
            return HealthCard(overall: report.status, subsystems: subs, createdAt: now)
        } catch {
            let err = HealthCardSubsystem(
                id: "doctor",
                label: "Doctor",
                status: "error",
                detail: "Doctor run failed: \(Self.safeDoctorDetail(error.localizedDescription))",
                fixAction: nil
            )
            return HealthCard(overall: "error", subsystems: [err], createdAt: now)
        }
    }

    private struct CachedDoctorPayload: Decodable {
        let checks: [DoctorCheck]
        let runAt: String?
    }

    private func readCachedHealthCard(now: String) -> HealthCard? {
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("doctor/latest.json")
        guard let data = try? Data(contentsOf: path),
              let payload = try? JSONDecoder().decode(CachedDoctorPayload.self, from: data),
              let runAtString = payload.runAt,
              let runAt = ISO8601DateFormatter().date(from: runAtString),
              Date().timeIntervalSince(runAt) < 60
        else { return nil }
        let subs = payload.checks.map {
            HealthCardSubsystem(
                id: $0.id,
                label: $0.title,
                status: $0.status,
                detail: $0.detail,
                fixAction: $0.repair
            )
        }
        let rollup = Self.doctorRollup(subs.map(\.status))
        return HealthCard(overall: rollup, subsystems: subs, createdAt: now)
    }

    private func mergingLiveDoctorCoverage(into cached: HealthCard, now: String) async -> HealthCard {
        let liveChecks = await liveDoctorCoverageChecks()
        return Self.mergeHealthCard(cached: cached, liveChecks: liveChecks, now: now)
    }

    static func mergeHealthCard(cached: HealthCard, liveChecks: [DoctorCheck], now: String) -> HealthCard {
        let live = liveChecks.map { check in
            HealthCardSubsystem(
                id: check.id,
                label: check.title,
                status: check.status,
                detail: check.detail,
                fixAction: check.repair
            )
        }
        let liveIDs = Set(live.map(\.id))
        let subsystems = cached.subsystems.filter { !liveIDs.contains($0.id) } + live
        let overall = doctorRollup(subsystems.map(\.status))
        return HealthCard(overall: overall, subsystems: subsystems, createdAt: now)
    }

    // Swift-native embedding status. The app no longer installs or probes
    // sentence-transformers/Python extras; the live truth is the MemoryV2
    // process-wide embedder. Three terminal states: CoreML MiniLM when the
    // bundled model loads, explicit mock when the user opted out via config
    // OR set NATIVE_AGENT_EMBEDDING_MOCK=1, and fail-closed (embed() throws)
    // when CoreML was requested but resources are missing / load failed and
    // no env opt-in.
    func getEmbeddingsStatus() async throws -> EmbeddingsStatus {
        guard let runtime = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() else {
            throw MemoryV2Error.storageUnavailable
        }
        let requestedCoreML = runtime.requestedBackend != ManagedEmbeddingProvider.mockBackend
        // effectiveCoreML must be TRUE only when the runtime is ACTUALLY
        // serving CoreML vectors — not when it's mock and not when it's
        // fail-closed (CoreML failed + no NATIVE_AGENT_EMBEDDING_MOCK opt-in).
        // The earlier check `effectiveBackend != mockBackend` returned true
        // for "fail-closed" too, so the UI reported "local"/"Active" while
        // every embed() call was throwing. Match against the canonical CoreML
        // backend instead.
        let effectiveCoreML = runtime.effectiveBackend == ManagedEmbeddingProvider.coreMLBackend
        let isFailClosed = runtime.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend
        let modelName: String = {
            if isFailClosed {
                return "Unavailable / \(runtime.dimensions)d (CoreML failed; install MiniLM or set NATIVE_AGENT_EMBEDDING_MOCK=1)"
            }
            if requestedCoreML {
                let loaded = runtime.coreMLLoaded ? "loaded" : "idle"
                return "\(runtime.modelId) / \(runtime.dimensions)d (\(loaded))"
            }
            return "Deterministic mock / \(runtime.dimensions)d (semantic embeddings off)"
        }()
        let modeDetail = EmbeddingsMemoryModeDetail(
            mode: runtime.mode,
            title: Self.embeddingModeTitle(runtime.mode),
            detail: Self.embeddingModeDetail(runtime, requestedCoreML: requestedCoreML),
            idleUnloadSeconds: runtime.idleUnloadSeconds
        )
        let reindexState = EmbeddingsInstallState(
            state: "complete",
            currentStep: Self.embeddingCurrentStep(runtime, requestedCoreML: requestedCoreML),
            progress: 100,
            error: runtime.lastLoadError,
            detail: Self.embeddingStatusDetail(runtime, requestedCoreML: requestedCoreML),
            startedAt: nil,
            failedAt: nil,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            extrasPath: nil,
            hfCachePath: nil,
            total: nil,
            candidates: nil,
            embedded: nil,
            skipped: nil,
            failed: nil,
            reason: nil,
            lastUpdatedAt: nil
        )
        return EmbeddingsStatus(
            libraryAvailable: runtime.coreMLResourcesAvailable,
            modelLoadable: runtime.modelLoadable,
            configBackend: runtime.requestedBackend,
            envEnabled: true,
            effectiveBackend: isFailClosed ? "unavailable" : (effectiveCoreML ? "local" : "hash"),
            modelName: modelName,
            requestedEnabled: requestedCoreML,
            memoryMode: runtime.mode,
            memoryModeDetail: modeDetail,
            idleUnloadSeconds: runtime.idleUnloadSeconds,
            modelState: EmbeddingsModelState(
                mode: runtime.mode,
                loaded: runtime.coreMLLoaded,
                parentLoaded: runtime.coreMLLoaded,
                workerRunning: false,
                workerPid: nil,
                lastUsedAt: runtime.lastUsedAt,
                lastLoadedAt: runtime.lastLoadedAt,
                lastUnloadedAt: runtime.lastUnloadedAt,
                unloadReason: runtime.unloadReason,
                loadCount: runtime.loadCount,
                unloadCount: runtime.unloadCount,
                cacheSize: nil,
                cacheMaxSize: nil
            ),
            installState: nil,
            reindexState: reindexState,
            extrasPath: nil
        )
    }

    private static func readStringValue(from path: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return obj[key] as? String
    }

    private static func embeddingModeTitle(_ mode: String) -> String {
        switch mode {
        case "performance": return "Fast"
        case "low_memory": return "Low"
        default: return "Balanced"
        }
    }

    // gpt-5.5 review-3 NEEDS_FIX: the three UI-string helpers below now drive
    // off `runtime.effectiveBackend` so the env-mock-opt-in case
    // (NATIVE_AGENT_EMBEDDING_MOCK=1 with requestedCoreML=true) doesn't get
    // mislabeled as fail-closed when embed() is actually returning mock
    // vectors. Snapshot already computes the right `effectiveBackend` value
    // (coreml-minilm / mock / fail-closed); these strings just have to honor
    // it instead of re-deriving from individual fields.

    private static func embeddingModeDetail(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String {
        guard requestedCoreML else {
            return EmbeddingPlainCopy.headline(.turnedOff)
        }
        // Env-mock opt-in path: user wanted CoreML, set the env var, runtime
        // returns mock vectors. Say so honestly.
        if runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend {
            return EmbeddingPlainCopy.headline(.testVectors)
        }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend {
            return EmbeddingPlainCopy.headline(.modelMissing)
        }
        return EmbeddingPlainCopy.modeLine(mode: runtime.mode)
    }

    private static func embeddingCurrentStep(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String {
        if !requestedCoreML { return "Semantic CoreML embedder disabled by user" }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend {
            return "Mock embedder active (NATIVE_AGENT_EMBEDDING_MOCK opt-in)"
        }
        if runtime.coreMLLoaded { return "CoreML semantic embedder loaded" }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.coreMLBackend
            && runtime.lastLoadError == nil {
            return "CoreML semantic embedder ready to lazy-load"
        }
        return "Semantic embedder fail-closed (CoreML resources missing or load failed)"
    }

    // This value lands in the SECONDARY line under a plain headline
    // (SlimSettingsView.modelUnavailableRow), so it is where the identifiers
    // are allowed to live — the headline above it never carries them.
    private static func embeddingStatusDetail(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String? {
        if !requestedCoreML { return EmbeddingPlainCopy.technicalDetail(.turnedOff) }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend {
            return EmbeddingPlainCopy.technicalDetail(.testVectors)
        }
        if let error = runtime.lastLoadError {
            return EmbeddingPlainCopy.technicalDetail(.modelFailed, error: error)
        }
        if runtime.coreMLLoaded { return nil }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend {
            return EmbeddingPlainCopy.technicalDetail(.modelMissing)
        }
        return EmbeddingPlainCopy.notLoadedYetLine
    }

    // DAEMON-DEAD PORT (2026-06-03): configure the Swift embedding runtime.
    // The managed provider persists <dataRoot>/config/embeddings.json::backend
    // and immediately releases CoreML when disabled.
    func setEmbeddingsBackend(enabled: Bool) async throws -> EmbeddingsToggleResult {
        let before = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot()
        do {
            try await SwiftNativeMemoryV2.shared.configureEmbeddingBackend(enabled: enabled)
            let report = try await SwiftNativeMemoryV2.shared
                .reindexAllMemoryEmbeddingsForCurrentProvider()
            let detail = "Atomically activated one embedding epoch across \(report.memories) memories, \(report.proposals) proposals, and \(report.tombstones) tombstones."
            let status = try await getEmbeddingsStatus()
            return EmbeddingsToggleResult(ok: true, error: nil, detail: detail, status: status)
        } catch {
            // A backend is not allowed to change while canonical vectors stay
            // in the prior space. Restore the requested backend so recall
            // immediately returns to the previously active epoch.
            let wasEnabled = before?.requestedBackend != ManagedEmbeddingProvider.mockBackend
            try? await SwiftNativeMemoryV2.shared.configureEmbeddingBackend(enabled: wasEnabled)
            throw error
        }
    }

    // DAEMON-DEAD PORT (2026-06-02): configure the managed Swift embedding
    // runtime's idle-retention mode and return current status.
    func setEmbeddingsMemoryMode(mode: String) async throws -> EmbeddingsToggleResult {
        try await SwiftNativeMemoryV2.shared.configureEmbeddingMemoryMode(mode)
        let status = try await getEmbeddingsStatus()
        return EmbeddingsToggleResult(ok: true, error: nil, detail: nil, status: status)
    }

    // DAEMON-DEAD PORT (2026-06-03): release the process-owned CoreML provider
    // reference. The next semantic recall lazy-loads it again unless the
    // backend is disabled.
    func releaseEmbeddingsMemory() async throws -> EmbeddingsToggleResult {
        _ = await SwiftNativeMemoryV2.shared.releaseEmbeddingMemory(reason: "manual release")
        let status = try await getEmbeddingsStatus()
        return EmbeddingsToggleResult(ok: true, error: nil, detail: "Released Swift CoreML embedding model memory.", status: status)
    }

    // Retired with the zero-Python cutover. Embeddings are bundled as a CoreML
    // resource and status is reported by getEmbeddingsStatus(); there is no
    // in-app Python extras installer anymore.
    func installEmbeddingsExtra() async throws -> EmbeddingsInstallKickoff {
        let status = try await getEmbeddingsStatus()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let detail = status.libraryAvailable
            ? "Swift CoreML embeddings are bundled with NativeAgent; no Python extras install is required."
            // gpt-5.5 review-2 follow-up: stop saying "using deterministic
            // fallback embeddings" — under fail-closed semantics the runtime
            // throws on embed() instead of returning mock vectors. Says
            // recall is fail-closed honestly so the UI matches behavior.
            : "Swift CoreML embedding resources are not loadable; semantic recall is fail-closed until the bundled MiniLM resources are installed. No Python installer is available."
        return EmbeddingsInstallKickoff(
            ok: status.libraryAvailable,
            alreadyRunning: false,
            status: EmbeddingsInstallState(
                state: status.libraryAvailable ? "complete" : "failed",
                currentStep: status.libraryAvailable ? "Bundled Swift CoreML model ready" : "Bundled Swift CoreML model unavailable",
                progress: 100,
                error: status.libraryAvailable ? nil : "CoreML model unavailable",
                detail: detail,
                startedAt: nil,
                failedAt: status.libraryAvailable ? nil : nowISO,
                completedAt: status.libraryAvailable ? nowISO : nil,
                extrasPath: status.extrasPath,
                hfCachePath: nil,
                total: nil,
                candidates: nil,
                embedded: nil,
                skipped: nil,
                failed: nil,
                reason: "zero_python_coreml_bundled",
                lastUpdatedAt: nowISO
            )
        )
    }

    // WAVE 31 (2026-06-01): getEmbeddingsInstallStatus() removed — zero call
    // sites; the dead pollEmbeddingsInstall() appModel wrapper was its only
    // (uninvoked) caller. The daemon GET /v1/embeddings/install/status route is
    // retired this wave; progress comes from getEmbeddingsStatus().installState.
    // The EmbeddingsInstallState type is KEPT — it still decodes the installState/
    // reindexState fields embedded in EmbeddingsStatus. See CUTOVER_PLAN.md §6.55.

    func getWhatsRunning() async throws -> WhatsRunning {
        async let loopStatusesTask = BackgroundLoopsManager.shared.status()
        async let pendingImprovementsTask = SelfImprovementOrchestrator.shared.list_pending()
        let (loopStatuses, pendingImprovements) = await (loopStatusesTask, pendingImprovementsTask)

        var items: [WhatsRunningItem] = []
        for loop in loopStatuses where loop.running {
            items.append(WhatsRunningItem(
                id: loop.loopId,
                kind: "scheduler",
                label: Self.whatsRunningLabel(forLoopId: loop.loopId),
                startedAt: nil,
                startsAt: nil,
                cancellable: false,
                cancelHint: nil
            ))
        }
        for run in pendingImprovements {
            items.append(WhatsRunningItem(
                id: run.id,
                kind: "improvement",
                label: run.objective.isEmpty ? "Self-improvement run" : run.objective,
                startedAt: nil,
                startsAt: nil,
                cancellable: true,
                cancelHint: "Discard pending self-improvement run"
            ))
        }
        items.sort { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.label < rhs.label }
            return lhs.kind < rhs.kind
        }
        return WhatsRunning(items: items, count: items.count)
    }

    private static func whatsRunningLabel(forLoopId loopId: String) -> String {
        switch loopId {
        case "doctor_auto_run": return "Doctor auto-run loop"
        case "full_mac_expiry": return "Full Mac expiry check"
        case "harness_learning": return "Harness learning loop"
        case "memory_consolidation": return "Memory consolidation loop"
        case "self_improvement_sweep": return "Self-improvement sweep loop"
        case "dream_cycle": return "Dream cycle loop"
        case "rem_cycle": return "REM reflection loop"
        case "telegram_poll": return "Telegram long-poll loop"
        default:
            return loopId
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    func postCrashReport(traceback: String, stderrTail: String, exitCode: Int, capturedAt: String) async throws -> [String: Any] {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let impl = makeCrashReportClient()
        let r = try await impl.postCrashReport(
            traceback: traceback,
            stderrTail: stderrTail,
            exitCode: exitCode,
            capturedAt: capturedAt
        )
        // Preserve the established /v1/system/crash_report response dict.
        return [
            "stored": r.stored,
            "path": r.path,
            "improvementSpawned": r.improvementSpawned
        ]
    }

}

// MARK: - Plain-English semantic search copy
//
// UI-6 (2026-08-01, public era): every user-visible sentence about the memory
// search model. Same rule as DoctorPlainCopy / MemoryStatusPlainCopy — the
// headline says what a person lost and what it means for them, and the
// identifiers (Core ML, MiniLM, the env override, the raw load error) survive
// in a secondary technical line instead of being deleted. Pure values in,
// Strings out, so the wording is unit-testable without a UI harness.
enum EmbeddingPlainCopy {

    /// What the embedding runtime is actually doing for search right now.
    enum SearchState: Equatable {
        /// The on-device model is serving real vectors.
        case byMeaning
        /// The user opted out of semantic embeddings in settings.
        case turnedOff
        /// NATIVE_AGENT_EMBEDDING_MOCK opt-in: deterministic test vectors.
        case testVectors
        /// Model resources are not on disk.
        case modelMissing
        /// Model resources exist but failed to load.
        case modelFailed
    }

    /// Leads with the user's loss, never with a backend name.
    static func headline(_ state: SearchState) -> String {
        switch state {
        case .byMeaning:
            return "Memory search finds results by meaning."
        case .turnedOff:
            return "Memory search by meaning is turned off. Searches match words instead."
        case .testVectors:
            return "Memory search is running on test data, so results will not match meaning."
        case .modelMissing:
            return "Memory search by meaning is off because a required model is not installed. Searches match words instead."
        case .modelFailed:
            return "Memory search by meaning is off because the search model could not load. Searches match words instead."
        }
    }

    /// The secondary line. Nil when there is nothing technical worth naming.
    static func technicalDetail(_ state: SearchState, error: String? = nil) -> String? {
        switch state {
        case .byMeaning:
            return nil
        case .turnedOff:
            return "Semantic embeddings are off in settings. Turn them on to use the bundled Core ML MiniLM model."
        case .testVectors:
            return "NATIVE_AGENT_EMBEDDING_MOCK is set, so search uses deterministic test vectors instead of the bundled Core ML MiniLM model."
        case .modelMissing:
            return "Search model: Core ML MiniLM. The bundled resources are not on disk."
        case .modelFailed:
            let trimmed = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return "Search model: Core ML MiniLM. Load failed."
            }
            return "Search model: Core ML MiniLM. Load failed: \(trimmed)"
        }
    }

    /// Idle-retention mode, described by what the user feels rather than by
    /// which model unloads when.
    static func modeLine(mode: String) -> String {
        switch mode {
        case "performance":
            return "The search model stays loaded, so searches return as fast as possible."
        case "low_memory":
            return "The search model unloads after 45 seconds of no use, to keep memory free."
        default:
            return "The search model loads when you search and unloads after 5 minutes of no use."
        }
    }

    /// Transient: the model is fine, just not resident this second.
    static let notLoadedYetLine =
        "The search model is not loaded right now. It loads on your next search."
}

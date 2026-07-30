import Foundation
import PersistenceCore
import ProviderRouting

/// Reads the signed, account-scoped Codex model catalog instead of advertising
/// preview models to users whose ChatGPT/Codex account cannot select them.
enum CodexSelectableModelCatalog {
    struct Model: Equatable {
        let id: String
        let displayName: String
        let description: String?
        let defaultReasoningEffort: String
        let supportedReasoningEfforts: [String]
        let supportsFast: Bool
        let priority: Int
        let contextWindow: Int
    }

    private struct Cache: Decodable {
        var models: [Record]
    }

    private struct Record: Decodable {
        struct Effort: Decodable { var effort: String }
        struct ServiceTier: Decodable { var id: String }

        var slug: String
        var displayName: String
        var description: String?
        var defaultReasoningLevel: String?
        var supportedReasoningLevels: [Effort]?
        var additionalSpeedTiers: [String]?
        var serviceTiers: [ServiceTier]?
        var supportedInAPI: Bool?
        var visibility: String?
        var priority: Int?
        var contextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case description
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case additionalSpeedTiers = "additional_speed_tiers"
            case serviceTiers = "service_tiers"
            case supportedInAPI = "supported_in_api"
            case visibility
            case priority
            case contextWindow = "context_window"
        }
    }

    static func load(
        providerID: String = "codex",
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true
    ) -> [Model] {
        let candidates = cacheURL.map { [$0] }
            ?? (useDefaultCacheWhenNil ? [cacheCandidate()] : [])
        var byID: [String: Model] = [:]
        for (index, descriptor) in FirstPartyModelCatalog.chatGPTAccountFallbackModels.enumerated() {
            byID[descriptor.id] = Model(
                id: descriptor.id,
                displayName: descriptor.name,
                description: nil,
                defaultReasoningEffort: descriptor.defaultReasoningEffort,
                supportedReasoningEfforts: descriptor.supportedReasoningEfforts,
                supportsFast: descriptor.supportsFast,
                priority: 100 + index,
                contextWindow: descriptor.contextLength
            )
        }
        let directOAuth = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "openai_oauth_direct"
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let cache = try? JSONDecoder().decode(Cache.self, from: data) else { continue }
            for record in cache.models {
                let id = record.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard record.visibility == nil || record.visibility == "list",
                      !directOAuth || record.supportedInAPI != false else { continue }
                let efforts = record.supportedReasoningLevels?.map(\.effort).filter { !$0.isEmpty } ?? []
                guard !efforts.isEmpty else { continue }
                let hasFastTier = record.additionalSpeedTiers?.contains("fast") == true
                    && record.serviceTiers?.contains(where: { $0.id == "priority" }) == true
                byID[id] = Model(
                    id: id,
                    displayName: record.displayName,
                    description: record.description,
                    defaultReasoningEffort: record.defaultReasoningLevel ?? efforts[0],
                    supportedReasoningEfforts: efforts,
                    supportsFast: hasFastTier,
                    priority: record.priority ?? 1_000,
                    contextWindow: record.contextWindow ?? 400_000
                )
            }
        }
        return byID.values.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id < $1.id
        }
    }

    static func modelCatalogItems(
        providerID: String = "codex",
        cacheURL: URL? = nil
    ) -> [ModelCatalogItem] {
        load(providerID: providerID, cacheURL: cacheURL).map {
            ModelCatalogItem(
                id: $0.id,
                displayName: $0.displayName,
                description: $0.description,
                defaultReasoningEffort: $0.defaultReasoningEffort,
                supportedReasoningEfforts: $0.supportedReasoningEfforts,
                supportsFast: $0.supportsFast,
                priority: $0.priority
            )
        }
    }

    static func providerModelDictionaries(
        providerID: String,
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true
    ) -> [[String: Any]] {
        guard isAccountBackedProvider(providerID) else {
            return []
        }
        return load(
            providerID: providerID,
            cacheURL: cacheURL,
            useDefaultCacheWhenNil: useDefaultCacheWhenNil
        ).map {
            [
                "id": $0.id,
                "name": $0.displayName,
                "context_length": $0.contextWindow,
                "supports_streaming": true,
                "supports_vision": true,
                "supports_tools": true,
                "supports_json_mode": true,
                "default_reasoning_effort": $0.defaultReasoningEffort,
                "supported_reasoning_efforts": $0.supportedReasoningEfforts,
                "supports_fast": $0.supportsFast,
            ]
        }
    }

    /// Both routes use the same ChatGPT account entitlement catalog. The
    /// transport remains exact: `openai_oauth_direct` calls the ChatGPT Codex
    /// Responses backend, while `codex` invokes the CLI. API-key `openai`
    /// stays deliberately excluded so account-only levels cannot leak onto a
    /// public API request.
    static func isAccountBackedProvider(_ providerID: String) -> Bool {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex", "openai_oauth_direct": return true
        default: return false
        }
    }

    /// Resolve a signed cache that belongs to the OAuth account actually used
    /// by the direct adapter. Prefer a cache beside that auth file. A shared
    /// CLI cache is safe only when both auth files persist the same account id.
    static func chatGPTOAuthCacheCandidate(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let usesCanonicalBody = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let authURL = OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: dataRoot,
            environment: environment,
            allowSharedFallbacks: usesCanonicalBody
        )
        if !usesCanonicalBody {
            let sibling = authURL.deletingLastPathComponent()
                .appendingPathComponent("models_cache.json")
            return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
        }
        return matchingCacheCandidate(
            oauthAuthURL: authURL,
            fallbackCacheURL: cacheCandidate(environment: environment)
        )
    }

    static func matchingCacheCandidate(
        oauthAuthURL: URL,
        fallbackCacheURL: URL
    ) -> URL? {
        let sibling = oauthAuthURL.deletingLastPathComponent()
            .appendingPathComponent("models_cache.json")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        guard FileManager.default.fileExists(atPath: fallbackCacheURL.path),
              let oauthAccount = persistedAccountID(at: oauthAuthURL),
              let cacheAccount = persistedAccountID(
                at: fallbackCacheURL.deletingLastPathComponent()
                    .appendingPathComponent("auth.json")
              ),
              oauthAccount == cacheAccount else {
            return nil
        }
        return fallbackCacheURL
    }

    private static func persistedAccountID(at authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else {
            return nil
        }
        if let accountID = tokens["account_id"] as? String {
            let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let accessToken = tokens["access_token"] as? String else { return nil }
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let payloadData = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String else {
            return nil
        }
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func cacheCandidate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        // CodexAdapter inherits this process environment. An explicit
        // CODEX_HOME is authoritative even when its cache is absent; falling
        // through to another account would advertise models the active CLI
        // cannot use. Without the override, the CLI's exact home is ~/.codex.
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("models_cache.json")
        }
        return homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("models_cache.json")
    }
}

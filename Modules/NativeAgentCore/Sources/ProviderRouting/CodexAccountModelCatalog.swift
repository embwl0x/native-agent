import NativeAgentShared
import Foundation
import PersistenceCore

/// Reads the signed, account-scoped Codex model catalog instead of advertising
/// preview models to users whose ChatGPT/Codex account cannot select them.
public enum CodexAccountModelCatalog {
    public static func providerModels(
        providerID: String,
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true
    ) -> [ProviderModelInfo] {
        guard isAccountBackedProvider(providerID) else {
            return []
        }
        return load(
            providerID: providerID,
            cacheURL: cacheURL,
            useDefaultCacheWhenNil: useDefaultCacheWhenNil
        ).map {
            ProviderModelInfo(
                id: $0.id,
                name: $0.displayName,
                context_length: $0.contextWindow,
                supports_streaming: true,
                supports_vision: true,
                supports_tools: true,
                supports_json_mode: true,
                default_reasoning_effort: $0.defaultReasoningEffort,
                supported_reasoning_efforts: $0.supportedReasoningEfforts,
                supports_fast: $0.supportsFast
            )
        }
    }

    public struct Model: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let description: String?
        public let defaultReasoningEffort: String
        public let supportedReasoningEfforts: [String]
        public let supportsFast: Bool
        public let priority: Int
        public let contextWindow: Int
    }

    private struct Cache: Decodable {
        var models: [Record]
        var accountID: String?

        enum CodingKeys: String, CodingKey {
            case models
            case accountID = "nativeagent_account_id"
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            // Matching accepts any JSON object; malformed model rows still
            // leave the shipped projection, as an unsuccessful load did.
            models = (try? fields.decode([Record].self, forKey: .models)) ?? []
            accountID = try? fields.decode(String.self, forKey: .accountID)
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var decodedByPath: [String: (stamp: [FileAttributeKey: Any], cache: Cache?)] = [:]

    /// Account matching and both route projections share this decode. File
    /// replacement invalidates it; auth identity is checked on every selection.
    private static func readCache(at url: URL) -> Cache? {
        let url = url.resolvingSymlinksInPath()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            decodedByPath.removeValue(forKey: url.path)
            return nil
        }
        if let entry = decodedByPath[url.path], NSDictionary(dictionary: entry.stamp).isEqual(to: attributes) {
            return entry.cache
        }
        let cache = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        guard let after = try? FileManager.default.attributesOfItem(atPath: url.path),
              NSDictionary(dictionary: attributes).isEqual(to: after) else {
            decodedByPath.removeValue(forKey: url.path)
            return nil
        }
        if decodedByPath[url.path] == nil, decodedByPath.count >= 64 {
            decodedByPath.remove(at: decodedByPath.startIndex)
        }
        decodedByPath[url.path] = (attributes, cache)
        return cache
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

    public static func load(
        providerID: String = "codex",
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true
    ) -> [Model] {
        let url = cacheURL ?? (useDefaultCacheWhenNil ? cacheCandidate() : nil)
        return models(providerID: providerID, cache: url.flatMap { readCache(at: $0) })
    }

    private static func models(providerID: String, cache: Cache?) -> [Model] {
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
        if let cache {
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

    /// 2026-09-22: `load` always carries every fallback row, so only the signed
    /// cache itself says this account can run a model. No cache = cannot.
    public static func signedCacheLists(_ modelID: String, providerID: String, cacheURL: URL?) -> Bool {
        guard let cacheURL, let cache = readCache(at: cacheURL) else { return false }
        let directOAuth = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "openai_oauth_direct"
        return cache.models.contains {
            $0.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == modelID.lowercased()
                && ($0.visibility == nil || $0.visibility == "list")
                && (!directOAuth || $0.supportedInAPI != false)
        }
    }

    /// Both routes use the same ChatGPT account entitlement catalog. The
    /// transport remains exact: `openai_oauth_direct` calls the ChatGPT Codex
    /// Responses backend, while `codex` invokes the CLI. API-key `openai`
    /// stays deliberately excluded so account-only levels cannot leak onto a
    /// public API request.
    public static func isAccountBackedProvider(_ providerID: String) -> Bool {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex", "openai_oauth_direct": return true
        default: return false
        }
    }

    /// Resolve a signed cache that belongs to the OAuth account actually used
    /// by the direct adapter. Prefer a cache beside that auth file. A shared
    /// CLI cache is safe only when both auth files persist the same account id.
    public static func chatGPTOAuthCacheCandidate(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        chatGPTOAuthCache(dataRoot: dataRoot, environment: environment)?.url
    }

    static func chatGPTOAuthCatalogs(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: [Model]] {
        let cache = chatGPTOAuthCache(dataRoot: dataRoot, environment: environment)?.cache
        return Dictionary(uniqueKeysWithValues: ["codex", "openai_oauth_direct"].map {
            ($0, models(providerID: $0, cache: cache))
        })
    }

    private static func chatGPTOAuthCache(
        dataRoot: URL,
        environment: [String: String]
    ) -> (url: URL, cache: Cache)? {
        let usesCanonicalBody = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let authURL = usesCanonicalBody
            ? OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: dataRoot, environment: environment)
            : OpenAIOAuthDirectAdapter.boundRootReadAuthPath(dataRoot: dataRoot)
        if !usesCanonicalBody {
            let sibling = authURL.deletingLastPathComponent()
                .appendingPathComponent("models_cache.json")
            guard let cache = readCache(at: sibling), cacheMatchesAccount(cache, authURL: authURL) else { return nil }
            return (sibling, cache)
        }
        return matchingCache(
            oauthAuthURL: authURL,
            fallbackCacheURL: cacheCandidate(environment: environment)
        )
    }

    public static func matchingCacheCandidate(
        oauthAuthURL: URL,
        fallbackCacheURL: URL
    ) -> URL? {
        matchingCache(oauthAuthURL: oauthAuthURL, fallbackCacheURL: fallbackCacheURL)?.url
    }

    static func matchingModels(
        providerID: String,
        oauthAuthURL: URL,
        fallbackCacheURL: URL
    ) -> [Model] {
        models(providerID: providerID, cache: matchingCache(
            oauthAuthURL: oauthAuthURL, fallbackCacheURL: fallbackCacheURL
        )?.cache)
    }

    private static func matchingCache(
        oauthAuthURL: URL,
        fallbackCacheURL: URL
    ) -> (url: URL, cache: Cache)? {
        let sibling = oauthAuthURL.deletingLastPathComponent()
            .appendingPathComponent("models_cache.json")
        if let cache = readCache(at: sibling), cacheMatchesAccount(cache, authURL: oauthAuthURL) {
            return (sibling, cache)
        }
        guard let cache = readCache(at: fallbackCacheURL), cacheMatchesAccount(cache, authURL: oauthAuthURL),
              let oauthAccount = persistedAccountID(at: oauthAuthURL),
              let cacheAccount = persistedAccountID(
                at: fallbackCacheURL.deletingLastPathComponent()
                    .appendingPathComponent("auth.json")
              ),
              oauthAccount == cacheAccount else {
            return nil
        }
        return (fallbackCacheURL, cache)
    }

    private static func cacheMatchesAccount(_ cache: Cache, authURL: URL) -> Bool {
        // Older CLI caches carry no account marker; keep their existing read policy.
        guard let account = cache.accountID else { return true }
        return account == persistedAccountID(at: authURL)
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
        guard let claims = jwtPayload(accessToken, omittingEmptySubsequences: false),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String else {
            return nil
        }
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func cacheCandidate(
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

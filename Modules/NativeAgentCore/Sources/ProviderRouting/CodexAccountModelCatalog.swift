import NativeAgentShared
import NativeAgentCore
import Foundation
import PersistenceCore
import Experiences
// Blueprint: | `CodexAccountModelCatalog.swift` | `CodexAccountModelCatalog` enum; `load`, `matchingModels`; one decoded catalog for account matching and separate Codex/OAuth projections, invalidated by file attributes with auth identity checked on selection; a cache read fault owes repair under `codex.model_catalog:<file path>` with the file as owner; a later successful read settles it; preview preserves the prior decoded cache and owes or settles no repair |

/// Reads the signed, account-scoped Codex model catalog instead of advertising
/// preview models to users whose ChatGPT/Codex account cannot select them.
public enum CodexAccountModelCatalog {
    public static func providerModels(
        providerID: String,
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [ProviderModelInfo] {
        guard isAccountBackedProvider(providerID) else {
            return []
        }
        // The account's models see images; whether this route's transport
        // carries them is the adapter's declaration (the Codex CLI does not).
        let vision = ProviderToolCapability.carriesImages(
            providerID: providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        return load(
            providerID: providerID,
            cacheURL: cacheURL,
            useDefaultCacheWhenNil: useDefaultCacheWhenNil,
            dataRoot: dataRoot
        ).map {
            ProviderModelInfo(
                id: $0.id,
                name: $0.displayName,
                context_length: $0.contextWindow,
                supports_streaming: true,
                supports_vision: vision,
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
            // An unreadable model array is an unreadable list, never an empty one.
            models = try fields.decode([Record].self, forKey: .models)
            for record in models {
                let efforts = record.supportedReasoningLevels.map(\.effort)
                guard !efforts.isEmpty, efforts.allSatisfy({ !$0.isEmpty }),
                      efforts.contains(record.defaultReasoningLevel) else {
                    throw DecodingError.dataCorruptedError(forKey: .models, in: fields,
                        debugDescription: "Account model \(record.slug) has missing or invalid Think controls")
                }
            }
            accountID = try fields.decodeIfPresent(String.self, forKey: .accountID)
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var decodedByPath: [String: (stamp: [FileAttributeKey: Any], cache: Cache?)] = [:]

    /// Account matching and both route projections share this decode. File
    /// replacement invalidates it; auth identity is checked on every selection.
    private static func readCache(at url: URL, dataRoot: URL) -> Cache? {
        let url = url.resolvingSymlinksInPath()
        cacheLock.lock()
        let previewCache = LLMCallContext.preview ? decodedByPath : nil
        defer {
            if let previewCache { decodedByPath = previewCache }
            cacheLock.unlock()
        }
        var attributes: [FileAttributeKey: Any] = [:]
        var cache: Cache?
        var failure: Error?
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let entry = decodedByPath[url.path], NSDictionary(dictionary: entry.stamp).isEqual(to: attributes) {
                return entry.cache
            }
            cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            decodedByPath.removeValue(forKey: url.path)
            return nil
        } catch {
            failure = error
        }
        // An attribute-read fault has no stamp; retain it until attributes become readable.
        if attributes.isEmpty, let entry = decodedByPath[url.path], entry.stamp.isEmpty {
            return entry.cache
        }
        if !attributes.isEmpty {
            guard let after = try? FileManager.default.attributesOfItem(atPath: url.path),
                  NSDictionary(dictionary: attributes).isEqual(to: after) else {
                decodedByPath.removeValue(forKey: url.path)
                return nil
            }
        }
        if decodedByPath[url.path] == nil, decodedByPath.count >= 64 {
            decodedByPath.remove(at: decodedByPath.startIndex)
        }
        decodedByPath[url.path] = (attributes, cache)
        guard !LLMCallContext.preview else { return cache }
        if let failure {
            RepairOwed.owe(dataRoot, id: "codex-model-catalog:" + UUID().uuidString,
                           kind: .act, operation: "codex.model_catalog:" + url.path, owner: url.path,
                           words: "\(url.path) could not be read (\(failure)); its models and windows are unknown until the catalog is repaired")
        } else {
            RepairOwed.settle(dataRoot, operation: "codex.model_catalog:" + url.path,
                              evidence: .init(source: "providers", id: url.path))
        }
        return cache
    }

    private struct Record: Decodable {
        struct Effort: Decodable { var effort: String }
        struct ServiceTier: Decodable { var id: String }

        var slug: String
        var displayName: String
        var description: String?
        var defaultReasoningLevel: String
        var supportedReasoningLevels: [Effort]
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
        useDefaultCacheWhenNil: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [Model] {
        let url = cacheURL ?? (useDefaultCacheWhenNil ? cacheSource(dataRoot: dataRoot, environment: ProcessInfo.processInfo.environment) : nil)
        let cache = url.flatMap { readCache(at: $0, dataRoot: dataRoot) }
        if let url, modelCatalogFault(at: url, read: cache != nil, owner: "this ChatGPT account") != nil { return [] }
        return models(providerID: providerID, cache: cache)
    }

    private static func models(providerID: String, cache: Cache?) -> [Model] {
        var byID: [String: Model] = [:]
        let directOAuth = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "openai_oauth_direct"
        if let cache {
            for record in cache.models {
                let id = record.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard record.visibility == nil || record.visibility == "list",
                      !directOAuth || record.supportedInAPI != false else {
                    byID.removeValue(forKey: id)
                    continue
                }
                let efforts = record.supportedReasoningLevels.map(\.effort)
                let hasFastTier = record.additionalSpeedTiers?.contains("fast") == true
                    && record.serviceTiers?.contains(where: { $0.id == "priority" }) == true
                byID[id] = Model(
                    id: id,
                    displayName: record.displayName,
                    description: record.description,
                    defaultReasoningEffort: record.defaultReasoningLevel,
                    supportedReasoningEfforts: efforts,
                    supportsFast: hasFastTier,
                    priority: record.priority ?? 1_000,
                    // A read catalog owns its windows; an absent value is unknown (0).
                    contextWindow: record.contextWindow ?? 0
                )
            }
        }
        return byID.values.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id < $1.id
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

    /// Resolve the account-matched cache, preserving an unreadable source URL
    /// so load() can report it instead of mistaking it for absent discovery.
    public static func chatGPTOAuthCacheCandidate(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let source = cacheSource(dataRoot: dataRoot, environment: environment)
        if modelCatalogFault(at: source, read: readCache(at: source, dataRoot: dataRoot) != nil, owner: "this ChatGPT account") != nil {
            return source
        }
        return chatGPTOAuthCache(dataRoot: dataRoot, environment: environment)?.url
    }

    static func chatGPTOAuthCatalogs(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: [Model]] {
        if cacheFault(dataRoot: dataRoot, environment: environment) != nil {
            return ["codex": [], "openai_oauth_direct": []]
        }
        let cache = chatGPTOAuthCache(dataRoot: dataRoot, environment: environment)?.cache
        return Dictionary(uniqueKeysWithValues: ["codex", "openai_oauth_direct"].map {
            ($0, models(providerID: $0, cache: cache))
        })
    }

    /// The account's own list is there but unreadable (the CLI's shared one
    /// only when the account has none beside its sign-in): its models and
    /// windows are unknown, never the shipped rows.
    public static func cacheFault(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let url = cacheSource(dataRoot: dataRoot, environment: environment)
        guard let cache = readCache(at: url, dataRoot: dataRoot) else {
            return modelCatalogFault(at: url, read: false, owner: "this ChatGPT account")
                ?? "This ChatGPT account's model catalog is not available at \(url.path). Refresh its models in Providers before choosing or running a model."
        }
        let auth = authPath(dataRoot: dataRoot, environment: environment)
        guard cacheMatchesAccount(cache, authURL: auth) else {
            return "The model catalog does not belong to this ChatGPT account. Refresh its models in Providers."
        }
        return nil
    }

    private static func cacheSource(dataRoot: URL, environment: [String: String]) -> URL {
        let authURL = authPath(dataRoot: dataRoot, environment: environment)
        let sibling = authURL.deletingLastPathComponent().appendingPathComponent("models_cache.json")
        return sibling
    }

    private static func authPath(dataRoot: URL, environment: [String: String]) -> URL {
        ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot, environment: environment)
    }

    private static func chatGPTOAuthCache(
        dataRoot: URL,
        environment: [String: String]
    ) -> (url: URL, cache: Cache)? {
        let authURL = authPath(dataRoot: dataRoot, environment: environment)
        return matchingCache(
            oauthAuthURL: authURL,
            dataRoot: dataRoot
        )
    }

    static func matchingModels(
        providerID: String,
        oauthAuthURL: URL,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [Model] {
        let source = oauthAuthURL.deletingLastPathComponent().appendingPathComponent("models_cache.json")
        if modelCatalogFault(at: source, read: readCache(at: source, dataRoot: dataRoot) != nil, owner: "this ChatGPT account") != nil { return [] }
        return models(providerID: providerID, cache: matchingCache(
            oauthAuthURL: oauthAuthURL, dataRoot: dataRoot
        )?.cache)
    }

    private static func matchingCache(
        oauthAuthURL: URL,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> (url: URL, cache: Cache)? {
        let sibling = oauthAuthURL.deletingLastPathComponent()
            .appendingPathComponent("models_cache.json")
        if let cache = readCache(at: sibling, dataRoot: dataRoot), cacheMatchesAccount(cache, authURL: oauthAuthURL) {
            return (sibling, cache)
        }
        return nil
    }

    private static func cacheMatchesAccount(_ cache: Cache, authURL: URL) -> Bool {
        // A current external CLI cache has no NativeAgent marker. The explicit
        // CLI source is already bound to the selected sign-in's directory.
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
        ChatGPTTransport.preferredAuthPath(environment: environment,
            userCodexHome: homeDirectory.appendingPathComponent(".codex", isDirectory: true), source: .commandCLI)
            .deletingLastPathComponent()
            .appendingPathComponent("models_cache.json")
    }
}

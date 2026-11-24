import Synchronization
import NativeAgentShared
import NativeAgentCore
import Foundation
import PersistenceCore
import SenseCore
// Blueprint: | `CodexAccountModelCatalog.swift` | `CodexAccountModelCatalog`, `load`, `matchingModels`, `codex.model_catalog:<file path>` |

/// Account-scoped discovery prevents advertising models the signed-in account cannot select.
public enum CodexAccountModelCatalog {
    public static func providerModels(
        providerID: String,
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot(), preview: Bool = false
    ) -> [ProviderModelInfo] {
        guard isAccountBackedProvider(providerID) else {
            return []
        }
        let vision = ProviderToolCapability.carriesImages(
            providerID: providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        return load(
            providerID: providerID,
            cacheURL: cacheURL,
            useDefaultCacheWhenNil: useDefaultCacheWhenNil,
            dataRoot: dataRoot, preview: preview
        ).map {
            ProviderModelInfo(
                id: $0.id,
                name: $0.displayName,
                context_length: $0.contextWindow,
                supports_streaming: true,
                supports_vision: vision && $0.inputModalities?.contains("image") != false,
                supports_tools: true,
                supports_json_mode: true,
                default_reasoning_effort: $0.defaultReasoningEffort,
                supported_reasoning_efforts: $0.supportedReasoningEfforts,
                supports_fast: $0.supportsFast,
                controls_note: $0.minimalClientVersion.flatMap { minimum in
                    let checked = ChatGPTTransport.codexClientVersion
                    guard minimum.compare(checked, options: .numeric) == .orderedDescending else { return nil }
                    return "Newer than this app's ChatGPT wire was checked against (\(checked)); its first turn is the check."
                }
            )
        }
    }

    public struct Model: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let description: String?
        public let defaultReasoningEffort: String
        public let supportedReasoningEfforts: [String]
        public let ultraEffort: String
        public let supportsFast: Bool
        public let priority: Int
        public let contextWindow: Int
        let minimalClientVersion: String?
        let inputModalities: [String]?
    }

    struct Cache: Decodable {
        var models: [Record]
        var accountID: String?
        var clientVersion: String?
        var fullListRefusal: String?

        enum CodingKeys: String, CodingKey {
            case models
            case accountID = "nativeagent_account_id"
            case clientVersion = "client_version"
            case fullListRefusal = "nativeagent_full_list_refused"
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            // An unreadable model array is an unreadable list, never an empty one.
            models = try fields.decode([Record].self, forKey: .models)
            for record in models {
                guard !record.slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .models, in: fields, debugDescription: "Account model has an empty slug")
                }
                let efforts = record.supportedReasoningLevels.map(\.effort)
                guard !efforts.isEmpty, efforts.allSatisfy({ !$0.isEmpty }),
                      efforts.contains(record.defaultReasoningLevel) else {
                    throw DecodingError.dataCorruptedError(forKey: .models, in: fields,
                        debugDescription: "Account model \(record.slug) has missing or invalid Think controls")
                }
            }
            accountID = try fields.decodeIfPresent(String.self, forKey: .accountID)
            clientVersion = try fields.decodeIfPresent(String.self, forKey: .clientVersion)
            fullListRefusal = try fields.decodeIfPresent(String.self, forKey: .fullListRefusal)
        }
    }

    private static let decodedByPath = Mutex<[String: (stamp: [FileAttributeKey: Any], cache: Cache?)]>([:])

    /// Account matching and both route projections share this decode. File replacement invalidates it; auth identity is checked on every selection.
    static func readCache(at url: URL, dataRoot: URL, preview: Bool = false) -> Cache? {
        let url = url.resolvingSymlinksInPath()
        return decodedByPath.withLock { decodedByPath in
            let previewCache = preview ? decodedByPath : nil
            defer {
                if let previewCache { decodedByPath = previewCache }
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
            guard !preview else { return cache }
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
    }

    struct Record: Decodable {
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
        var multiAgentReasoningEffort: String?
        var minimalClientVersion: String?
        var inputModalities: [String]?

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
            case multiAgentReasoningEffort = "multi_agent_reasoning_effort"
            case minimalClientVersion = "minimal_client_version"
            case inputModalities = "input_modalities"
        }
    }

    public static func load(
        providerID: String = "codex",
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot(), preview: Bool = false
    ) -> [Model] {
        let url = cacheURL ?? (useDefaultCacheWhenNil ? cacheSource(dataRoot: dataRoot, environment: ProcessInfo.processInfo.environment) : nil)
        let cache = url.flatMap { readCache(at: $0, dataRoot: dataRoot, preview: preview) }
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
                    ultraEffort: record.multiAgentReasoningEffort.flatMap { $0 != "ultra" && efforts.contains($0) ? $0 : nil }
                        ?? (efforts.contains("max") ? "max" : efforts.last { $0 != "ultra" } ?? "medium"),
                    supportsFast: hasFastTier,
                    priority: record.priority ?? 1_000,
                    // A read catalog owns its windows; an absent value is unknown (0).
                    contextWindow: record.contextWindow ?? 0,
                    minimalClientVersion: record.minimalClientVersion,
                    inputModalities: record.inputModalities
                )
            }
        }
        return byID.values.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id < $1.id
        }
    }

    /// Both account transports share entitlement discovery; public API requests must not inherit account-only controls.
    public static func isAccountBackedProvider(_ providerID: String) -> Bool {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex", "openai_oauth_direct": return true
        default: return false
        }
    }

    /// Retain an unreadable source URL so discovery faults cannot look absent.
    public static func chatGPTOAuthCacheCandidate(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment, preview: Bool = false
    ) -> URL? {
        let source = cacheSource(dataRoot: dataRoot, environment: environment)
        if modelCatalogFault(at: source, read: readCache(at: source, dataRoot: dataRoot, preview: preview) != nil, owner: "this ChatGPT account") != nil {
            return source
        }
        return chatGPTOAuthCache(dataRoot: dataRoot, environment: environment, preview: preview)?.url
    }

    static func chatGPTOAuthCatalogs(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment, preview: Bool = false
    ) -> [String: [Model]] {
        if cacheFault(dataRoot: dataRoot, environment: environment, preview: preview) != nil {
            return ["codex": [], "openai_oauth_direct": []]
        }
        let cache = chatGPTOAuthCache(dataRoot: dataRoot, environment: environment, preview: preview)?.cache
        return Dictionary(uniqueKeysWithValues: ["codex", "openai_oauth_direct"].map {
            ($0, models(providerID: $0, cache: cache))
        })
    }

    /// Unreadable account discovery leaves models and windows unknown; shipped rows cannot stand in for it.
    public static func cacheFault(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment, preview: Bool = false
    ) -> String? {
        let url = cacheSource(dataRoot: dataRoot, environment: environment)
        guard let cache = readCache(at: url, dataRoot: dataRoot, preview: preview) else {
            return modelCatalogFault(at: url, read: false, owner: "this ChatGPT account")
                ?? "This ChatGPT account's model catalog is not available at \(url.path). Refresh its models in Providers before choosing or running a model."
        }
        let auth = authPath(dataRoot: dataRoot, environment: environment)
        guard cacheMatchesAccount(cache, authURL: auth) else {
            return "The model catalog does not belong to this ChatGPT account. Refresh its models in Providers."
        }
        return nil
    }

    static func fullListRefusal(dataRoot: URL, environment: [String: String], preview: Bool) -> String? {
        guard let cache = chatGPTOAuthCache(dataRoot: dataRoot, environment: environment, preview: preview)?.cache,
              let refusal = cache.fullListRefusal else { return nil }
        return "The full ChatGPT model list could not be asked (\(refusal)). This list is for checked version \(cache.clientVersion ?? "unstated")."
    }

    private static func cacheSource(dataRoot: URL, environment: [String: String]) -> URL {
        cacheSource(authURL: authPath(dataRoot: dataRoot, environment: environment))
    }

    private static func cacheSource(authURL: URL) -> URL {
        authURL.deletingLastPathComponent().appendingPathComponent("models_cache.json")
    }

    public nonisolated static func observationPaths(dataRoot: URL) -> [URL] {
        let auth = authPath(dataRoot: dataRoot, environment: ProcessInfo.processInfo.environment)
        return [auth, cacheSource(authURL: auth), NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: dataRoot),
                ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot, source: .sharedCLI)]
    }

    private static func authPath(dataRoot: URL, environment: [String: String]) -> URL {
        ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot, environment: environment)
    }

    private static func chatGPTOAuthCache(
        dataRoot: URL,
        environment: [String: String], preview: Bool = false
    ) -> (url: URL, cache: Cache)? {
        let authURL = authPath(dataRoot: dataRoot, environment: environment)
        return matchingCache(
            oauthAuthURL: authURL,
            dataRoot: dataRoot, preview: preview
        )
    }

    static func matchingModels(
        providerID: String,
        oauthAuthURL: URL,
        dataRoot: URL = PersistenceCore.defaultDataRoot(), preview: Bool = false
    ) -> [Model] {
        let source = oauthAuthURL.deletingLastPathComponent().appendingPathComponent("models_cache.json")
        if modelCatalogFault(at: source, read: readCache(at: source, dataRoot: dataRoot, preview: preview) != nil,
            owner: "this ChatGPT account") != nil { return [] }
        return models(providerID: providerID, cache: matchingCache(
            oauthAuthURL: oauthAuthURL, dataRoot: dataRoot, preview: preview
        )?.cache)
    }

    private static func matchingCache(
        oauthAuthURL: URL,
        dataRoot: URL = PersistenceCore.defaultDataRoot(), preview: Bool = false
    ) -> (url: URL, cache: Cache)? {
        let sibling = oauthAuthURL.deletingLastPathComponent()
            .appendingPathComponent("models_cache.json")
        if let cache = readCache(at: sibling, dataRoot: dataRoot, preview: preview), cacheMatchesAccount(cache, authURL: oauthAuthURL) {
            return (sibling, cache)
        }
        return nil
    }

    private static func cacheMatchesAccount(_ cache: Cache, authURL: URL) -> Bool {
        // An external CLI cache has no app marker; its explicit source is already bound to the selected sign-in directory.
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
}

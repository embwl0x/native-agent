import Foundation
import PersistenceCore
import NativeAgentShared

// Blueprint: | `OpenRouterModelCatalog.swift` | `OpenRouterModelCatalog`: live-backed model availability, capability parsing and checked catalog cache through shared TTL machinery |

extension ProviderModelInfo {
    public func providerJSON() -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "context_length": .int(Int64(context_length)),
            "supports_streaming": .bool(supports_streaming),
            "supports_vision": .bool(supports_vision),
            "supports_tools": .bool(supports_tools),
            "supports_json_mode": .bool(supports_json_mode),
        ]
        if let cost_per_1k_in {
            obj["cost_per_1k_in"] = .double(cost_per_1k_in)
        }
        if let cost_per_1k_out {
            obj["cost_per_1k_out"] = .double(cost_per_1k_out)
        }
        obj["default_reasoning_effort"] = default_reasoning_effort.map(JSONValue.string)
        obj["supported_reasoning_efforts"] = supported_reasoning_efforts.map { .array($0.map(JSONValue.string)) }
        obj["supports_fast"] = supports_fast.map(JSONValue.bool)
        return obj
    }
}

public enum OpenRouterModelCatalog {
    public enum CachedModelAvailability: Equatable, Sendable {
        /// A recent live-backed cache contains the exact id.
        case available
        /// A recent live-backed cache does not contain the exact id.
        case unavailable
        /// No recent live-backed catalog exists; stale bytes or no list at all
        /// are insufficient evidence to reject a user pin.
        case unknown
    }
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")!

    /// ModelCatalogTTLCache owns TTL and backoff; OpenRouter supplies parsing, fetching and capabilities.
    static let ttlCache = ModelCatalogTTLCache(
        cachePath: { cachePath(dataRoot: $0) },
        endpoint: endpoint,
        readCache: { readDecodedCache(dataRoot: $0) },
        providerConfigFile: "openrouter.json",
        fetchLive: { try await fetchLiveModels(key: $0, session: $1) }
    )

    public static func models(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> [ProviderModelInfo] {
        await ttlCache.models(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// The read reports whether it reached OpenRouter and why it did not.
    public static func modelsWithFreshness(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> ModelCatalogRead {
        await ttlCache.modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// Only a complete, recent catalog can establish that a model is absent.
    public static func cachedAvailability(
        of modelID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        now: Date = Date()
    ) -> CachedModelAvailability {
        // Membership and completeness come from one decode of the same bytes.
        guard let cached = readDecodedCache(dataRoot: dataRoot),
              !ttlCache.cacheIsStale(fetchedAt: cached.fetchedAt, now: now),
              !cached.models.isEmpty else {
            return .unknown
        }
        let wanted = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .unavailable }
        if cached.models.contains(where: { $0.id == wanted }) { return .available }
        // Only a cache stamped complete can declare a missing model unavailable.
        return cached.isComplete == true ? .unavailable : .unknown
    }

    static func parseModelsResponse(_ root: [String: Any]?) -> [ProviderModelInfo] {
        guard let rows = root?["data"] as? [[String: Any]] else {
            return []
        }

        var byId: [String: ProviderModelInfo] = [:]
        for row in rows {
            guard let model = parseModel(row) else { continue }
            byId[model.id] = model
        }
        return sortModels(Array(byId.values))
    }

    /// Envelope keys whose non-empty value NAMES a further page. A cursor or a
    /// next link that is present but null/empty/false says the opposite: this
    /// is the last page.
    private static let continuationKeys = ["next", "next_page", "next_cursor", "cursor"]

    /// Envelope keys that may nest those continuation markers.
    private static let continuationContainerKeys = ["pagination", "links", "meta"]

    /// Only a complete list may exclude a selected model. Pagination metadata
    /// marks an incomplete list only when it names another page.
    static func responseIsComplete(_ root: [String: Any]?) -> Bool {
        guard let root else { return true }
        if envelopeSaysMore(root) { return false }
        for key in continuationContainerKeys {
            if let nested = root[key] as? [String: Any], envelopeSaysMore(nested) {
                return false
            }
        }
        return true
    }

    private static func envelopeSaysMore(_ object: [String: Any]) -> Bool {
        if truthy(object["has_more"]) { return true }
        for key in continuationKeys where truthy(object[key]) { return true }
        return false
    }

    /// A marker "says more" only when it carries an actual value: null, false,
    /// 0 and the empty string are all a provider saying there is nothing after
    /// this page.
    private static func truthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !trimmed.isEmpty && trimmed != "false" && trimmed != "0" && trimmed != "null"
        }
        if let array = value as? [Any] { return !array.isEmpty }
        if let object = value as? [String: Any] { return !object.isEmpty }
        return true
    }

    private static func fetchLiveModels(
        key: String?,
        session: URLSession
    ) async throws -> ModelCatalogFetch {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NativeAgent", forHTTPHeaderField: "X-Title")
        if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ProviderRoutingError.invalidResponse(status: code)
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ModelCatalogFetch(
            models: parseModelsResponse(root),
            isComplete: responseIsComplete(root)
        )
    }

    private static func parseModel(_ row: [String: Any]) -> ProviderModelInfo? {
        guard let rawID = row["id"] as? String else { return nil }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.hasPrefix("~") else { return nil }
        guard modelCanReturnText(row) else { return nil }

        let name = ((row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? id
        let context = positiveInt(row["context_length"])
            ?? positiveInt((row["top_provider"] as? [String: Any])?["context_length"])
            ?? 0
        let architecture = row["architecture"] as? [String: Any]
        let inputModalities = stringSet(architecture?["input_modalities"])
        let supportedParameters = stringSet(row["supported_parameters"])

        return ProviderModelInfo(
            id: id,
            name: name,
            context_length: context,
            // Capability = upstream declaration AND a NativeAgent wire path.
            // The adapter implements SSE for every text model; the remaining
            // capabilities stay model-specific and come from OpenRouter's
            // own live metadata.
            supports_streaming: true,
            supports_vision: inputModalities.contains("image"),
            supports_tools: supportedParameters.contains("tools"),
            supports_json_mode: supportedParameters.contains("response_format")
                || supportedParameters.contains("structured_outputs"),
            cost_per_1k_in: pricePer1K((row["pricing"] as? [String: Any])?["prompt"]),
            cost_per_1k_out: pricePer1K((row["pricing"] as? [String: Any])?["completion"])
        )
    }

    private static func modelCanReturnText(_ row: [String: Any]) -> Bool {
        guard let architecture = row["architecture"] as? [String: Any] else {
            return true
        }
        let outputModalities = stringSet(architecture["output_modalities"])
        if outputModalities.isEmpty {
            if let modality = architecture["modality"] as? String {
                return modality.lowercased().contains("text")
            }
            return true
        }
        return outputModalities.contains("text")
    }

    private static func sortModels(_ models: [ProviderModelInfo]) -> [ProviderModelInfo] {
        models.sorted { lhs, rhs in
            let lKey = providerModelSortKey(lhs)
            let rKey = providerModelSortKey(rhs)
            if lKey.provider != rKey.provider {
                return lKey.provider.localizedCaseInsensitiveCompare(rKey.provider) == .orderedAscending
            }
            if lKey.model != rKey.model {
                return lKey.model.localizedCaseInsensitiveCompare(rKey.model) == .orderedAscending
            }
            if lhs.name != rhs.name {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    private static func providerModelSortKey(_ model: ProviderModelInfo) -> (provider: String, model: String) {
        let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return (provider: parts[0], model: parts[1])
        }
        return (provider: id, model: model.name)
    }

    private static func cachePath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("openrouter-models-cache.json")
    }

    /// Path/mtime caching preserves fail-closed reads and exposes replacement or removal on the next read.
    static func cacheFault(dataRoot: URL) -> String? {
        modelCatalogFault(at: cachePath(dataRoot: dataRoot), read: readCache(dataRoot: dataRoot) != nil, owner: "OpenRouter")
    }

    static func readCache(dataRoot: URL) -> [ProviderModelInfo]? {
        readDecodedCache(dataRoot: dataRoot)?.models
    }

    /// The whole decoded cache — rows AND the completeness stamp they were
    /// written under — from a single decode of a single set of bytes.
    private static let decodedCache = ModelCatalogDecodeCache()

    private static func readDecodedCache(dataRoot: URL) -> DecodedModelCatalog? {
        decodedCache.read(url: cachePath(dataRoot: dataRoot)) {
            decodeCache(data: $0)
        }
    }

    private static func decodeCache(data: Data) -> DecodedModelCatalog? {
        guard let root = try? JSONValue.parse(data),
              case .object(let obj) = root,
              case .array(let rows)? = obj["models"] else {
            return nil
        }
        let isComplete: Bool?
        if case .bool(let complete)? = obj["complete"] {
            isComplete = complete
        } else {
            isComplete = nil
        }
        let models = rows.compactMap { value -> ProviderModelInfo? in
            guard case .object(let row) = value,
                  let id = string(row["id"]),
                  let name = string(row["name"]) else {
                return nil
            }
            return ProviderModelInfo(
                id: id,
                name: name,
                context_length: row["context_length"]?.integerValue.flatMap { Int(exactly: $0) } ?? 0,
                supports_streaming: row["supports_streaming"]?.boolValue ?? true,
                supports_vision: row["supports_vision"]?.boolValue ?? false,
                supports_tools: row["supports_tools"]?.boolValue ?? false,
                supports_json_mode: row["supports_json_mode"]?.boolValue ?? false,
                cost_per_1k_in: row["cost_per_1k_in"]?.numberValue(coercingStrings: false, finiteOnly: false),
                cost_per_1k_out: row["cost_per_1k_out"]?.numberValue(coercingStrings: false, finiteOnly: false)
            )
        }
        guard !models.isEmpty else { return nil }
        let fetchedAt: Date?
        if case .string(let raw)? = obj["updated_at"] {
            fetchedAt = ISO8601DateFormatter().date(from: raw)
        } else {
            fetchedAt = nil
        }
        return DecodedModelCatalog(models: sortModels(models), isComplete: isComplete, fetchedAt: fetchedAt)
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        guard let array = value as? [Any] else { return [] }
        return Set(array.compactMap { ($0 as? String)?.lowercased() })
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let i = value as? Int, i > 0 { return i }
        if let i = value as? Int64, i > 0 { return Int(i) }
        if let d = value as? Double, d > 0 { return Int(exactly: d.rounded(.towardZero)) }
        if let s = value as? String, let d = Double(s), d > 0 { return Int(exactly: d.rounded(.towardZero)) }
        return nil
    }

    private static func pricePer1K(_ value: Any?) -> Double? {
        let raw: Double?
        if let d = value as? Double {
            raw = d
        } else if let i = value as? Int {
            raw = Double(i)
        } else if let s = value as? String {
            raw = Double(s)
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        return raw * 1000
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

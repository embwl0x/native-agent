import Foundation
import PersistenceCore

public struct ProviderModelDescriptor: Sendable, Equatable {
    public var id: String
    public var name: String
    public var contextLength: Int
    public var supportsStreaming: Bool
    public var supportsVision: Bool
    public var supportsTools: Bool
    public var supportsJSONMode: Bool
    public var costPer1KIn: Double?
    public var costPer1KOut: Double?

    public init(
        id: String,
        name: String,
        contextLength: Int,
        supportsStreaming: Bool = true,
        supportsVision: Bool = false,
        supportsTools: Bool = false,
        supportsJSONMode: Bool = false,
        costPer1KIn: Double? = nil,
        costPer1KOut: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.supportsStreaming = supportsStreaming
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsJSONMode = supportsJSONMode
        self.costPer1KIn = costPer1KIn
        self.costPer1KOut = costPer1KOut
    }

    public func providerJSON() -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "context_length": .int(Int64(contextLength)),
            "supports_streaming": .bool(supportsStreaming),
            "supports_vision": .bool(supportsVision),
            "supports_tools": .bool(supportsTools),
            "supports_json_mode": .bool(supportsJSONMode),
        ]
        if let costPer1KIn {
            obj["cost_per_1k_in"] = .double(costPer1KIn)
        }
        if let costPer1KOut {
            obj["cost_per_1k_out"] = .double(costPer1KOut)
        }
        return obj
    }
}

public enum OpenRouterModelCatalog {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")!

    /// Shared TTL + backoff machinery (R-M3). OpenRouter keeps only its own
    /// parse / fetch / capability specifics; the read/refresh/backoff state
    /// machine lives in `ModelCatalogTTLCache`.
    static let ttlCache = ModelCatalogTTLCache(
        cachePath: { cachePath(dataRoot: $0) },
        endpoint: endpoint,
        readCache: { readCache(dataRoot: $0) },
        cacheUpdatedAt: { cacheUpdatedAt(dataRoot: $0) },
        fetchLive: { try await fetchLiveModels(dataRoot: $0, session: $1) },
        fallback: { fallbackModels() }
    )

    public static func models(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> [ProviderModelDescriptor] {
        await ttlCache.models(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// True when the cache is missing its `updated_at` stamp or that stamp is
    /// older than the TTL. A cache without a parseable stamp is treated as stale
    /// so it refreshes once (writeCache always stamps `updated_at`).
    static func cacheIsStale(dataRoot: URL, now: Date = Date()) -> Bool {
        ttlCache.cacheIsStale(dataRoot: dataRoot, now: now)
    }

    private static func cacheUpdatedAt(dataRoot: URL) -> Date? {
        let path = cachePath(dataRoot: dataRoot)
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONValue.parse(data),
              case .object(let obj) = root,
              case .string(let raw)? = obj["updated_at"] else {
            return nil
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    public static func providerJSONModels(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> [[String: JSONValue]] {
        await models(dataRoot: dataRoot, session: session, refresh: refresh).map { $0.providerJSON() }
    }

    public static func fallbackModels() -> [ProviderModelDescriptor] {
        sortModels([
            ProviderModelDescriptor(
                id: "meta-llama/llama-3.3-70b-instruct",
                name: "Llama 3.3 70B (OpenRouter)",
                contextLength: 128_000,
                supportsStreaming: false,
                supportsVision: false,
                supportsTools: false,
                supportsJSONMode: false
            ),
            ProviderModelDescriptor(
                id: "anthropic/claude-3.5-sonnet",
                name: "Claude 3.5 Sonnet (OpenRouter)",
                contextLength: 200_000,
                supportsStreaming: false,
                supportsVision: false,
                supportsTools: false,
                supportsJSONMode: false
            ),
        ])
    }

    public static func parseModelsResponse(_ data: Data) throws -> [ProviderModelDescriptor] {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = raw as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            return []
        }

        var byId: [String: ProviderModelDescriptor] = [:]
        for row in rows {
            guard let model = parseModel(row) else { continue }
            byId[model.id] = model
        }
        return sortModels(Array(byId.values))
    }

    private static func fetchLiveModels(
        dataRoot: URL,
        session: URLSession
    ) async throws -> [ProviderModelDescriptor] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NativeAgent", forHTTPHeaderField: "X-Title")
        if let key = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENROUTER_API_KEY",
            providerConfigFile: "openrouter.json",
            dataRoot: dataRoot,
            includeEnvironment: dataRoot.standardizedFileURL
                == PersistenceCore.defaultDataRoot().standardizedFileURL
        ) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ProviderRoutingError.invalidResponse(status: code)
        }
        return try parseModelsResponse(data)
    }

    private static func parseModel(_ row: [String: Any]) -> ProviderModelDescriptor? {
        guard let rawID = row["id"] as? String else { return nil }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.hasPrefix("~") else { return nil }
        guard modelCanReturnText(row) else { return nil }

        let name = ((row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? id
        let context = positiveInt(row["context_length"])
            ?? positiveInt((row["top_provider"] as? [String: Any])?["context_length"])
            ?? 128_000

        return ProviderModelDescriptor(
            id: id,
            name: name,
            contextLength: context,
            // These describe the capabilities NativeAgent's adapter can
            // deliver, not merely what OpenRouter says the upstream model can
            // do. The current adapter is buffered prompt completion only.
            supportsStreaming: false,
            supportsVision: false,
            supportsTools: false,
            supportsJSONMode: false,
            costPer1KIn: pricePer1K((row["pricing"] as? [String: Any])?["prompt"]),
            costPer1KOut: pricePer1K((row["pricing"] as? [String: Any])?["completion"])
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

    private static func sortModels(_ models: [ProviderModelDescriptor]) -> [ProviderModelDescriptor] {
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

    private static func providerModelSortKey(_ model: ProviderModelDescriptor) -> (provider: String, model: String) {
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

    private static func readCache(dataRoot: URL) -> [ProviderModelDescriptor]? {
        let path = cachePath(dataRoot: dataRoot)
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONValue.parse(data),
              case .object(let obj) = root,
              case .array(let rows)? = obj["models"] else {
            return nil
        }
        let models = rows.compactMap { value -> ProviderModelDescriptor? in
            guard case .object(let row) = value,
                  let id = string(row["id"]),
                  let name = string(row["name"]) else {
                return nil
            }
            return ProviderModelDescriptor(
                id: id,
                name: name,
                contextLength: int(row["context_length"]) ?? 128_000,
                supportsStreaming: false,
                supportsVision: false,
                supportsTools: false,
                supportsJSONMode: false,
                costPer1KIn: double(row["cost_per_1k_in"]),
                costPer1KOut: double(row["cost_per_1k_out"])
            )
        }
        return models.isEmpty ? nil : sortModels(models)
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        guard let array = value as? [Any] else { return [] }
        return Set(array.compactMap { ($0 as? String)?.lowercased() })
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let i = value as? Int, i > 0 { return i }
        if let i = value as? Int64, i > 0 { return Int(i) }
        if let d = value as? Double, d > 0 { return Int(d) }
        if let s = value as? String, let d = Double(s), d > 0 { return Int(d) }
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

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i)?: return Int(i)
        case .double(let d)?: return Int(d)
        default: return nil
        }
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }
}

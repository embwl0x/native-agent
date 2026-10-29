import Foundation
import PersistenceCore
import NativeAgentShared

// Blueprint: | `MoonshotModelCatalog.swift` | `MoonshotModelCatalog`: authenticated model parsing/capabilities and checked offline cache, using shared TTL state machinery |

/// Authenticated Moonshot/Kimi model discovery with a bounded offline cache.
/// Capability flags come from Moonshot's `/v1/models` response; NativeAgent's
/// own adapter capabilities (streaming, tools, JSON, and supported Think
/// controls) remain explicit here rather than inferred from marketing names.
public enum MoonshotModelCatalog {
    public static let endpoint = URL(string: "https://api.moonshot.ai/v1/models")!

    /// ModelCatalogTTLCache owns TTL and backoff; Moonshot supplies fetching and capabilities.
    static let ttlCache = ModelCatalogTTLCache(
        cachePath: { cachePath(dataRoot: $0) },
        endpoint: endpoint,
        readCache: { readDecodedCache(dataRoot: $0) },
        providerConfigFile: "moonshot.json",
        fetchLive: { ModelCatalogFetch(models: try await fetchLiveModels(key: $0, session: $1), isComplete: true) }
    )

    public static func models(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> [ProviderModelInfo] {
        await ttlCache.models(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// The same read, saying whether it reached Moonshot and, if not, why.
    public static func modelsWithFreshness(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> ModelCatalogRead {
        await ttlCache.modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// The routing guard recognizes account-visible IDs from the same decoded
    /// disk cache `models()` maintains, without touching the network.
    /// Only the provider's own fetched rows count here; the shipped rows are
    /// `FirstPartyModelCatalog.moonshotModels`, which routing checks first.
    public static func isKnownCatalogModelID(
        _ id: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> Bool {
        let needle = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return readCache(dataRoot: dataRoot)?.contains { $0.id.lowercased() == needle } ?? false
    }

    static func parseModelsResponse(_ data: Data) throws -> [ProviderModelInfo] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return [] }
        var byID: [String: ProviderModelInfo] = [:]
        for row in rows {
            guard let rawID = row["id"] as? String else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let context = positiveInt(row["context_length"])
                ?? FirstPartyModelCatalog.moonshotModels.first(where: { $0.id == id })?.contextLength
                ?? 0
            byID[id] = ProviderModelInfo(
                id: id,
                name: displayName(for: id),
                context_length: context,
                supports_streaming: true,
                supports_vision: (row["supports_image_in"] as? Bool) ?? false,
                supports_tools: true,
                supports_json_mode: true
            )
        }
        // Declared rows first in their declared order, then the rest by name.
        let declared = FirstPartyModelCatalog.moonshotModels.map(\.id)
        return byID.values.sorted { lhs, rhs in
            let left = declared.firstIndex(of: lhs.id) ?? declared.count
            let right = declared.firstIndex(of: rhs.id) ?? declared.count
            if left != right { return left < right }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The live catalog states no reasoning contract: a model's controls are
    /// its declared row's, and an id with no row takes none.
    public static func defaultReasoningEffort(for modelID: String) -> String {
        FirstPartyModelCatalog.descriptor(for: modelID, providerID: "moonshot")?.defaultReasoningEffort ?? "none"
    }

    public static func supportedReasoningEfforts(for modelID: String) -> [String] {
        FirstPartyModelCatalog.descriptor(for: modelID, providerID: "moonshot")?.supportedReasoningEfforts ?? ["none"]
    }

    private static func fetchLiveModels(key: String?, session: URLSession) async throws -> [ProviderModelInfo] {
        guard let key, !key.isEmpty else {
            throw LLMError.notConfigured(provider: "moonshot")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderRoutingError.invalidResponse(status: status)
        }
        return try parseModelsResponse(data)
    }

    private static func cachePath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("providers/moonshot-models-cache.json")
    }

    static func cacheFault(dataRoot: URL) -> String? {
        modelCatalogFault(at: cachePath(dataRoot: dataRoot), read: readCache(dataRoot: dataRoot) != nil, owner: "Moonshot")
    }

    static func readCache(dataRoot: URL) -> [ProviderModelInfo]? {
        readDecodedCache(dataRoot: dataRoot)?.models
    }

    private static let decodedCache = ModelCatalogDecodeCache()

    private static func readDecodedCache(dataRoot: URL) -> DecodedModelCatalog? {
        decodedCache.read(url: cachePath(dataRoot: dataRoot), decode: decodeCache)
    }

    private static func decodeCache(_ data: Data) -> DecodedModelCatalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return nil }
        let models = rows.compactMap { row -> ProviderModelInfo? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return ProviderModelInfo(
                id: id,
                name: (row["name"] as? String) ?? displayName(for: id),
                context_length: positiveInt(row["context_length"]) ?? 0,
                supports_streaming: (row["supports_streaming"] as? Bool) ?? true,
                supports_vision: (row["supports_vision"] as? Bool) ?? false,
                supports_tools: (row["supports_tools"] as? Bool) ?? true,
                supports_json_mode: (row["supports_json_mode"] as? Bool) ?? true
            )
        }
        let fetchedAt = (root["updated_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return DecodedModelCatalog(models: models, isComplete: root["complete"] as? Bool, fetchedAt: fetchedAt)
    }

    private static func displayName(for id: String) -> String {
        id.split(separator: "-").map { part in
            let value = String(part)
            if value.lowercased() == "kimi" { return "Kimi" }
            if value.lowercased() == "highspeed" { return "Highspeed" }
            return value.uppercased().hasPrefix("K") && value.dropFirst().allSatisfy(\.isNumber)
                ? value.uppercased()
                : value.capitalized
        }.joined(separator: " ")
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let value = value as? Int, value > 0 { return value }
        if let value = value as? NSNumber, value.intValue > 0 { return value.intValue }
        if let value = value as? String, let parsed = Int(value), parsed > 0 { return parsed }
        return nil
    }
}

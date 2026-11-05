import Foundation
import PersistenceCore
import NativeAgentShared

// Blueprint: | `MoonshotModelCatalog.swift` | `MoonshotModelCatalog`: authenticated model discovery |

/// Only provider metadata supplies model capabilities; native wire support and Think controls remain explicit.
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

    /// Discovery provenance must say whether the network was reached.
    public static func modelsWithFreshness(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> ModelCatalogRead {
        await ttlCache.modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// Routing reads the same credential-bound cache without network access; shipped rows retain their own catalog authority.
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
              let rows = root["data"] as? [[String: Any]] else { throw LLMError.providerError(message: "Moonshot returned an invalid model catalog envelope.") }
        var byID: [String: ProviderModelInfo] = [:]
        for row in rows {
            guard let rawID = row["id"] as? String else { throw LLMError.providerError(message: "Moonshot model row has no ID.") }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw LLMError.providerError(message: "Moonshot model row has an empty ID.") }
            guard let context = positiveInt(row["context_length"]),
                  let vision = boolean(row["supports_image_in"]) else {
                throw LLMError.providerError(
                    message: "Moonshot did not establish the context window or image capability of \(id). Refresh its model catalog before selecting it.")
            }
            byID[id] = ProviderModelInfo(
                id: id,
                name: displayName(for: id),
                context_length: context,
                supports_streaming: true,
                supports_vision: vision,
                supports_tools: true,
                supports_json_mode: true,
                default_reasoning_effort: defaultReasoningEffort(for: id),
                supported_reasoning_efforts: supportedReasoningEfforts(for: id),
                supports_fast: false,
                controls_note: controlsNote(for: id)
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

    /// The live catalog states no reasoning contract: a model's controls are its declared row's. An id with no row has unknown controls.
    public static func defaultReasoningEffort(for modelID: String) -> String? {
        FirstPartyModelCatalog.descriptor(for: modelID, providerID: "moonshot")?.defaultReasoningEffort
    }

    public static func supportedReasoningEfforts(for modelID: String) -> [String]? {
        FirstPartyModelCatalog.descriptor(for: modelID, providerID: "moonshot")?.supportedReasoningEfforts
    }

    private static func controlsNote(for modelID: String) -> String? {
        supportedReasoningEfforts(for: modelID) == nil
            ? "Think controls are unknown for this Moonshot model; NativeAgent needs a declared adapter contract before it can be selected." : nil
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
        do {
            return try ttlCache.currentCache(dataRoot: dataRoot) == nil
                ? "Moonshot model catalog is not available. Refresh its models in Providers." : nil
        } catch { return error.localizedDescription }
    }

    static func readCache(dataRoot: URL) -> [ProviderModelInfo]? {
        do { return try ttlCache.currentCache(dataRoot: dataRoot)?.models }
        catch { return nil } // cacheFault carries the unavailable cause.
    }

    private static let decodedCache = ModelCatalogDecodeCache()

    private static func readDecodedCache(dataRoot: URL) -> DecodedModelCatalog? {
        decodedCache.read(url: cachePath(dataRoot: dataRoot), decode: decodeCache)
    }

    private static func decodeCache(_ data: Data) -> DecodedModelCatalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return nil }
        let models = rows.compactMap { row -> ProviderModelInfo? in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let name = row["name"] as? String,
                  let context = positiveInt(row["context_length"]),
                  let streaming = boolean(row["supports_streaming"]),
                  let vision = boolean(row["supports_vision"]),
                  let tools = boolean(row["supports_tools"]),
                  let json = boolean(row["supports_json_mode"]) else { return nil }
            return ProviderModelInfo(
                id: id,
                name: name,
                context_length: context,
                supports_streaming: streaming,
                supports_vision: vision,
                supports_tools: tools,
                supports_json_mode: json,
                default_reasoning_effort: defaultReasoningEffort(for: id),
                supported_reasoning_efforts: supportedReasoningEfforts(for: id),
                supports_fast: false,
                controls_note: controlsNote(for: id)
            )
        }
        guard models.count == rows.count else { return nil }
        let fetchedAt = (root["updated_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return DecodedModelCatalog(models: models, isComplete: root["complete"] as? Bool, fetchedAt: fetchedAt,
                                   credentialBinding: root["credential_binding"] as? String)
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
        guard let value else { return nil }
        switch JSONValue(fromFoundation: value) {
        case .int(let number) where number > 0: return Int(exactly: number)
        case .double(let number) where number > 0: return Int(exactly: number)
        case .string(let number): return Int(number).flatMap { $0 > 0 ? $0 : nil }
        default: return nil
        }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value, case .bool(let flag) = JSONValue(fromFoundation: value) else { return nil }
        return flag
    }
}

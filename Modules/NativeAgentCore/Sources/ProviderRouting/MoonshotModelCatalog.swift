import Foundation
import PersistenceCore

/// Authenticated Moonshot/Kimi model discovery with a bounded offline cache.
/// Capability flags come from Moonshot's `/v1/models` response; NativeAgent's
/// own adapter capabilities (streaming, tools, JSON, and supported Think
/// controls) remain explicit here rather than inferred from marketing names.
public enum MoonshotModelCatalog {
    public static let endpoint = URL(string: "https://api.moonshot.ai/v1/models")!

    /// Shared TTL + backoff machinery (R-M3). Moonshot keeps only its own
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
        guard let data = try? Data(contentsOf: cachePath(dataRoot: dataRoot)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["updated_at"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    public static func providerJSONModels(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> [[String: JSONValue]] {
        await models(dataRoot: dataRoot, session: session, refresh: refresh).map { model in
            var object = model.providerJSON()
            object["default_reasoning_effort"] = .string(defaultReasoningEffort(for: model.id))
            object["supported_reasoning_efforts"] = .array(
                supportedReasoningEfforts(for: model.id).map(JSONValue.string)
            )
            object["supports_fast"] = .bool(false)
            return object
        }
    }

    /// M-F3 (review round 2): synchronous catalog-membership check for the
    /// routing guard. The live authenticated `/v1/models` response can carry
    /// account-visible ids with NO `kimi-`/`moonshot-` prefix; routing must
    /// recognize those from the same disk cache `models()` maintains — without
    /// going async or touching the network. Memoized on the cache file's
    /// mtime so the per-provider-call cost is a stat(), not a JSON parse.
    private static let knownIDsLock = NSLock()
    nonisolated(unsafe) private static var knownIDsMemo: (path: String, mtime: Date?, ids: Set<String>)?

    public static func isKnownCatalogModelID(
        _ id: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> Bool {
        let needle = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        let path = cachePath(dataRoot: dataRoot)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        knownIDsLock.lock()
        defer { knownIDsLock.unlock() }
        if let memo = knownIDsMemo, memo.path == path.path, memo.mtime == mtime {
            return memo.ids.contains(needle)
        }
        var ids = Set(fallbackModels().map { $0.id.lowercased() })
        for model in readCache(dataRoot: dataRoot) ?? [] {
            ids.insert(model.id.lowercased())
        }
        knownIDsMemo = (path.path, mtime, ids)
        return ids.contains(needle)
    }

    public static func fallbackModels() -> [ProviderModelDescriptor] {
        [
            .init(id: "kimi-k3", name: "Kimi K3", contextLength: 1_048_576, supportsVision: true, supportsTools: true, supportsJSONMode: true),
            .init(id: "kimi-k2.7-code-highspeed", name: "Kimi K2.7 Code Highspeed", contextLength: 262_144, supportsVision: true, supportsTools: true, supportsJSONMode: true),
            .init(id: "kimi-k2.7-code", name: "Kimi K2.7 Code", contextLength: 262_144, supportsVision: true, supportsTools: true, supportsJSONMode: true),
            .init(id: "kimi-k2.6", name: "Kimi K2.6", contextLength: 262_144, supportsVision: true, supportsTools: true, supportsJSONMode: true),
        ]
    }

    public static func parseModelsResponse(_ data: Data) throws -> [ProviderModelDescriptor] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return [] }
        var byID: [String: ProviderModelDescriptor] = [:]
        for row in rows {
            guard let rawID = row["id"] as? String else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let context = positiveInt(row["context_length"])
                ?? fallbackModels().first(where: { $0.id == id })?.contextLength
                ?? 128_000
            byID[id] = ProviderModelDescriptor(
                id: id,
                name: displayName(for: id),
                contextLength: context,
                supportsStreaming: true,
                supportsVision: (row["supports_image_in"] as? Bool) ?? false,
                supportsTools: true,
                supportsJSONMode: true
            )
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.id == "kimi-k3" { return true }
            if rhs.id == "kimi-k3" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func defaultReasoningEffort(for modelID: String) -> String {
        let id = modelID.lowercased()
        if id == "kimi-k3" || id.hasPrefix("kimi-k2.7-code") { return "max" }
        if id == "kimi-k2.6" || id == "kimi-k2.5" { return "high" }
        return "none"
    }

    public static func supportedReasoningEfforts(for modelID: String) -> [String] {
        let id = modelID.lowercased()
        if id == "kimi-k3" || id.hasPrefix("kimi-k2.7-code") { return ["max"] }
        if id == "kimi-k2.6" || id == "kimi-k2.5" { return ["none", "high"] }
        return ["none"]
    }

    private static func fetchLiveModels(dataRoot: URL, session: URLSession) async throws -> [ProviderModelDescriptor] {
        guard let key = LLMCredentialResolver.resolveAPIKey(
            envVar: "MOONSHOT_API_KEY",
            providerConfigFile: "moonshot.json",
            dataRoot: dataRoot,
            includeEnvironment: dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
        ), !key.isEmpty else {
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

    private static func readCache(dataRoot: URL) -> [ProviderModelDescriptor]? {
        guard let data = try? Data(contentsOf: cachePath(dataRoot: dataRoot)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return ProviderModelDescriptor(
                id: id,
                name: (row["name"] as? String) ?? displayName(for: id),
                contextLength: positiveInt(row["context_length"]) ?? 128_000,
                supportsStreaming: (row["supports_streaming"] as? Bool) ?? true,
                supportsVision: (row["supports_vision"] as? Bool) ?? false,
                supportsTools: (row["supports_tools"] as? Bool) ?? true,
                supportsJSONMode: (row["supports_json_mode"] as? Bool) ?? true
            )
        }
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

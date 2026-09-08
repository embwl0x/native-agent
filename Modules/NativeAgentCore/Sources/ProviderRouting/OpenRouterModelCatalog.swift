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
    public enum CachedModelAvailability: Equatable, Sendable {
        /// A recent live-backed cache contains the exact id.
        case available
        /// A recent live-backed cache does not contain the exact id.
        case unavailable
        /// No recent live-backed catalog exists; offline fallback/stale bytes
        /// are insufficient evidence to reject a user pin.
        case unknown
    }
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")!

    /// Shared TTL + backoff machinery (R-M3). OpenRouter keeps only its own
    /// parse / fetch / capability specifics; the read/refresh/backoff state
    /// machine lives in `ModelCatalogTTLCache`.
    static let ttlCache = ModelCatalogTTLCache(
        cachePath: { cachePath(dataRoot: $0) },
        endpoint: endpoint,
        readCache: { readCache(dataRoot: $0) },
        cacheUpdatedAt: { cacheUpdatedAt(dataRoot: $0) },
        // Both doors are the same fetch; `fetchLiveComplete` is the one that
        // carries the completeness verdict (User, 2026-09-06).
        fetchLive: { try await fetchLiveModels(dataRoot: $0, session: $1).models },
        fetchLiveComplete: { try await fetchLiveModels(dataRoot: $0, session: $1) },
        fallback: { fallbackModels() }
    )

    public static func models(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> [ProviderModelDescriptor] {
        await ttlCache.models(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// The same read, saying whether it reached OpenRouter (User, 2026-09-06).
    public static func modelsWithFreshness(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared,
        refresh: Bool = false
    ) async -> ModelCatalogRead {
        await ttlCache.modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// True when the cache is missing its `updated_at` stamp or that stamp is
    /// older than the TTL. A cache without a parseable stamp is treated as stale
    /// so it refreshes once (writeCache always stamps `updated_at`).
    static func cacheIsStale(dataRoot: URL, now: Date = Date()) -> Bool {
        ttlCache.cacheIsStale(dataRoot: dataRoot, now: now)
    }

    public static func cachedAvailability(
        of modelID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        now: Date = Date()
    ) -> CachedModelAvailability {
        // User, 2026-09-06: membership and completeness used to come from two
        // separate reads of this file, so a refresh landing between them could
        // convict a model against a generation that never listed it. Both
        // facts now come from ONE decode of one set of bytes.
        guard !cacheIsStale(dataRoot: dataRoot, now: now),
              let cached = readDecodedCache(dataRoot: dataRoot),
              !cached.models.isEmpty else {
            return .unknown
        }
        let wanted = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .unavailable }
        if cached.models.contains(where: { $0.id == wanted }) { return .available }
        // A cache written from a TRUNCATED page lists only part of the
        // catalogue, so a missing id there is no evidence of absence — it reads
        // as `.unknown` and the pin stands. Only a cache whose source response
        // carried the whole list may say `.unavailable`. User, 2026-09-06: a
        // cache carrying NO completeness stamp is unknown for the same reason —
        // absence of the stamp is not authority to convict.
        return cached.isComplete == true ? .unavailable : .unknown
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

    /// Read-only exact capability projection from the last live-backed cache.
    /// A stale cache remains evidence of the model's published window; TTL
    /// controls picker refresh, not whether prompt budgeting may remember a
    /// previously verified smaller bound.
    public static func cachedDescriptor(
        for modelID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> ProviderModelDescriptor? {
        let wanted = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return readCache(dataRoot: dataRoot)?.first { $0.id == wanted }
    }

    /// Served only when both the on-disk cache and a live fetch are
    /// unavailable. Ids must exist on OpenRouter TODAY — a retired id here
    /// turns the no-network first-run picker into a 404 factory. Verified
    /// against the live /api/v1/models response 2026-08-07 (the previous
    /// entry `anthropic/claude-3.5-sonnet` had been delisted).
    public static func fallbackModels() -> [ProviderModelDescriptor] {
        sortModels([
            ProviderModelDescriptor(
                id: "meta-llama/llama-3.3-70b-instruct",
                name: "Llama 3.3 70B (OpenRouter)",
                contextLength: 131_072,
                supportsStreaming: true,
                supportsVision: false,
                supportsTools: false,
                supportsJSONMode: false
            ),
            ProviderModelDescriptor(
                id: "anthropic/claude-sonnet-5",
                name: "Claude Sonnet 5 (OpenRouter)",
                contextLength: 1_000_000,
                supportsStreaming: true,
                supportsVision: false,
                supportsTools: false,
                supportsJSONMode: false
            ),
        ])
    }

    static func parseModelsResponse(_ data: Data) throws -> [ProviderModelDescriptor] {
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

    /// Envelope keys whose non-empty value NAMES a further page. A cursor or a
    /// next link that is present but null/empty/false says the opposite: this
    /// is the last page.
    private static let continuationKeys = ["next", "next_page", "next_cursor", "cursor"]

    /// Envelope keys that may nest those continuation markers.
    private static let continuationContainerKeys = ["pagination", "links", "meta"]

    /// User, 2026-09-06: only a complete list may prune rows a caller no longer
    /// sees. Complete means the envelope carries no marker that says MORE —
    /// `has_more == true`, or a non-null continuation cursor/link. The mere
    /// PRESENCE of `page`, `links` or `has_more: false` is a paginated API
    /// describing its LAST page, not evidence of truncation. The old
    /// count-against-the-disk-cache comparison is gone entirely: it wedged a
    /// legitimately shrunk catalogue as permanently incomplete (the shrunk list
    /// was never persisted, so every later fetch met the same tall baseline),
    /// and it never caught a marker-free truncation anyway.
    static func responseIsComplete(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
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
        dataRoot: URL,
        session: URLSession
    ) async throws -> ModelCatalogFetch {
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
        return ModelCatalogFetch(
            models: try parseModelsResponse(data),
            isComplete: responseIsComplete(data)
        )
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
        let architecture = row["architecture"] as? [String: Any]
        let inputModalities = stringSet(architecture?["input_modalities"])
        let supportedParameters = stringSet(row["supported_parameters"])

        return ProviderModelDescriptor(
            id: id,
            name: name,
            contextLength: context,
            // Capability = upstream declaration AND a NativeAgent wire path.
            // The adapter implements SSE for every text model; the remaining
            // capabilities stay model-specific and come from OpenRouter's
            // own live metadata.
            supportsStreaming: true,
            supportsVision: inputModalities.contains("image"),
            supportsTools: supportedParameters.contains("tools"),
            supportsJSONMode: supportedParameters.contains("response_format")
                || supportedParameters.contains("structured_outputs"),
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

    /// Sweep item A9: `ContextBudgetPolicy.resolve` reaches this reader through
    /// `ProviderRouting.verifiedContextLength` at FOUR points in a single chat
    /// turn (history window, packet budget, turn budget, cognitive capsule), and
    /// each one used to re-read and re-parse the whole 130KB / 400-row catalog.
    /// Measured on the real cache: 28.4ms per turn of pure decode. The mtime
    /// key keeps every caller's fail-closed semantics — a rewritten or removed
    /// file is visible on the very next read — while the unchanged case costs
    /// one stat.
    private static func readCache(dataRoot: URL) -> [ProviderModelDescriptor]? {
        readDecodedCache(dataRoot: dataRoot)?.models
    }

    /// The whole decoded cache — rows AND the completeness stamp they were
    /// written under — from a single decode of a single set of bytes.
    private static func readDecodedCache(dataRoot: URL) -> DecodedOpenRouterCatalog? {
        OpenRouterCacheDecodeCache.shared.read(url: cachePath(dataRoot: dataRoot)) {
            decodeCache(data: $0)
        }
    }

    /// Deterministic operation-count seam for the per-turn read regression.
    static func _testCacheStats(dataRoot: URL) -> CacheStats {
        OpenRouterCacheDecodeCache.shared.stats(url: cachePath(dataRoot: dataRoot))
    }

    static func _resetCacheForTesting(dataRoot: URL) {
        OpenRouterCacheDecodeCache.shared.reset(url: cachePath(dataRoot: dataRoot))
    }

    struct CacheStats: Sendable, Equatable {
        let decodeAttempts: Int
        let hits: Int
    }

    private static func decodeCache(data: Data) -> DecodedOpenRouterCatalog? {
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
                supportsStreaming: bool(row["supports_streaming"]) ?? true,
                supportsVision: bool(row["supports_vision"]) ?? false,
                supportsTools: bool(row["supports_tools"]) ?? false,
                supportsJSONMode: bool(row["supports_json_mode"]) ?? false,
                costPer1KIn: double(row["cost_per_1k_in"]),
                costPer1KOut: double(row["cost_per_1k_out"])
            )
        }
        guard !models.isEmpty else { return nil }
        return DecodedOpenRouterCatalog(models: sortModels(models), isComplete: isComplete)
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

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i)?: return Int(i)
        case .double(let d)?: return Int(exactly: d.rounded(.towardZero))
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

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }
}

/// One decode of the on-disk catalogue: the rows AND the completeness verdict
/// the bytes were written under. `isComplete` is nil when the file carries no
/// `complete` stamp — unknown, never a claim either way (User, 2026-09-06).
private struct DecodedOpenRouterCatalog: Sendable {
    let models: [ProviderModelDescriptor]
    let isComplete: Bool?
}

/// Process-local decoded cache keyed by canonical path and file mtime.
///
/// Every read still stats the exact file, so removal and atomic replacement are
/// visible on the next read. Missing, unreadable, empty, or undecodable bytes
/// cache only the nil result for that observed mtime; a later mtime always
/// retries the decode. Mirrors `REMPinsDecodedCache` in DreamREMCycle — same
/// invariant, same retry-on-concurrent-write guard.
private final class OpenRouterCacheDecodeCache: @unchecked Sendable {
    static let shared = OpenRouterCacheDecodeCache()

    private struct Entry {
        let modifiedAt: Date
        let catalog: DecodedOpenRouterCatalog?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var decodeAttempts: [String: Int] = [:]
    private var hits: [String: Int] = [:]

    func read(
        url: URL,
        decode: (Data) -> DecodedOpenRouterCatalog?
    ) -> DecodedOpenRouterCatalog? {
        // `attributesOfItem` does NOT follow symlinks, but `Data(contentsOf:)`
        // does. Resolve first so a symlinked cache path stats as the regular
        // file it points at instead of silently reading as "no catalog".
        let url = url.resolvingSymlinksInPath()
        let key = url.path
        lock.lock()
        defer { lock.unlock() }

        // Retry once if a writer replaces the file between the first stat and
        // the read. Never associate bytes with a stale mtime key.
        for _ in 0..<2 {
            guard let modifiedAt = modificationDate(url) else {
                entries.removeValue(forKey: key)
                return nil
            }
            if let entry = entries[key], entry.modifiedAt == modifiedAt {
                hits[key, default: 0] += 1
                return entry.catalog
            }

            decodeAttempts[key, default: 0] += 1
            let decoded = (try? Data(contentsOf: url)).flatMap(decode)
            guard modificationDate(url) == modifiedAt else { continue }

            if entries[key] == nil, entries.count >= 64 {
                entries.remove(at: entries.startIndex)
            }
            entries[key] = Entry(modifiedAt: modifiedAt, catalog: decoded)
            return decoded
        }

        // A continuously changing file is not a safe source to memoize.
        entries.removeValue(forKey: key)
        return nil
    }

    func stats(url: URL) -> OpenRouterModelCatalog.CacheStats {
        let key = url.resolvingSymlinksInPath().path
        lock.lock()
        let value = OpenRouterModelCatalog.CacheStats(
            decodeAttempts: decodeAttempts[key, default: 0],
            hits: hits[key, default: 0]
        )
        lock.unlock()
        return value
    }

    func reset(url: URL) {
        let key = url.resolvingSymlinksInPath().path
        lock.lock()
        entries.removeValue(forKey: key)
        decodeAttempts.removeValue(forKey: key)
        hits.removeValue(forKey: key)
        lock.unlock()
    }

    private func modificationDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { return nil }
        return attributes?[.modificationDate] as? Date
    }
}

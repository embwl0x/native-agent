import Foundation
import PersistenceCore
import NativeAgentShared

// Blueprint: | `OpenRouterModelCatalog.swift` | `OpenRouterModelCatalog`: live-backed membership and controls |

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
        obj["controls_note"] = controls_note.map(JSONValue.string)
        return obj
    }
}

public enum OpenRouterModelCatalog {
    public enum CachedModelAvailability: Equatable, Sendable {
        /// Saved provider rows establish membership for their bound credential.
        case available
        /// Only a complete provider response establishes absence.
        case unavailable
        /// No usable catalog establishes membership or absence.
        case unknown
    }
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")

    /// The cache owns credential binding and publication; OpenRouter owns the wire format.
    static let cache = ModelCatalogCache(
        cachePath: { cachePath(dataRoot: $0) },
        endpoint: endpoint,
        readCache: { try readDecodedCache(dataRoot: $0) },
        credential: .apiKey(providerConfigFile: "openrouter.json"),
        fetchLive: { try await fetchLiveModels(key: $0, session: $1) }
    )

    /// Discovery provenance retains whether the network was reached and why not.
    public static func modelsWithFreshness(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = ProviderHTTP.session,
        refresh: Bool = false
    ) async -> ModelCatalogRead {
        await cache.modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: refresh)
    }

    /// Only a complete credential-bound catalog can establish that a model is absent.
    public static func cachedAvailability(
        of modelID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> CachedModelAvailability {
        // Membership and completeness come from one decode of the same bytes.
        let decoded: DecodedModelCatalog?
        do { decoded = try cache.currentCache(dataRoot: dataRoot) }
        catch { return .unknown }
        guard let cached = decoded,
              !cached.models.isEmpty else {
            return .unknown
        }
        let wanted = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .unavailable }
        if cached.models.contains(where: { $0.id == wanted }) { return .available }
        // Only a cache stamped complete can declare a missing model unavailable.
        return cached.isComplete == true ? .unavailable : .unknown
    }

    static func parseModelsResponse(_ root: [String: Any]?) throws -> [ProviderModelInfo] {
        guard let rows = root?["data"] as? [[String: Any]] else {
            throw LLMError.providerError(message: "OpenRouter returned an invalid model catalog envelope.")
        }

        var byId: [String: ProviderModelInfo] = [:]
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty,
                  let architecture = row["architecture"] as? [String: Any],
                  architecture["input_modalities"] is [String],
                  row["supported_parameters"] is [String],
                  (architecture["output_modalities"] as? [String])?.isEmpty == false
                    || (architecture["modality"] as? String)?.isEmpty == false else {
                throw LLMError.providerError(
                    message: "OpenRouter model row lacks identity or capability evidence. Refresh its model catalog before selecting a model.")
            }
            guard let model = try parseModel(row) else { continue }
            byId[model.id] = model
        }
        return sortModels(Array(byId.values))
    }

    /// Pagination requires a nonempty continuation value; null, empty and false mean no further page.
    private static let continuationKeys = ["next", "next_page", "next_cursor", "cursor"]

    /// Continuation evidence may be nested under these envelope keys.
    private static let continuationContainerKeys = ["pagination", "links", "meta"]

    /// Only a complete list may exclude a selected model. Pagination metadata marks an incomplete list only when it names another page.
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

    /// A marker "says more" only when it carries an actual value: null, false, 0 and the empty string are all a provider saying there is nothing after this
    /// page.
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
        guard let endpoint else { throw URLError(.badURL) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = .infinity
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NativeAgent", forHTTPHeaderField: "X-Title")
        if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let code = http.statusCode
        guard (200..<300).contains(code) else {
            throw ProviderRoutingError.invalidResponse(status: code)
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ModelCatalogFetch(
            models: try parseModelsResponse(root),
            isComplete: responseIsComplete(root)
        )
    }

    private static func parseModel(_ row: [String: Any]) throws -> ProviderModelInfo? {
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
        let reasoning = try reasoningControls(row)

        return ProviderModelInfo(
            id: id,
            name: name,
            context_length: context,
            // Capability = upstream declaration AND a NativeAgent wire path. The adapter implements SSE for every text model; the remaining capabilities
            // stay model-specific and come from OpenRouter's own live metadata.
            supports_streaming: true,
            supports_vision: inputModalities.contains("image"),
            supports_tools: supportedParameters.contains("tools"),
            supports_json_mode: supportedParameters.contains("response_format")
                || supportedParameters.contains("structured_outputs"),
            cost_per_1k_in: pricePer1K((row["pricing"] as? [String: Any])?["prompt"]),
            cost_per_1k_out: pricePer1K((row["pricing"] as? [String: Any])?["completion"]),
            default_reasoning_effort: reasoning.defaultEffort,
            supported_reasoning_efforts: reasoning.efforts,
            supports_fast: false
        )
    }

    /// OpenRouter's current per-model reasoning object owns these controls. Omitted effort selection means provider-default execution, not a guessed list.
    private static func reasoningControls(_ row: [String: Any]) throws -> (defaultEffort: String, efforts: [String]) {
        guard let raw = row["reasoning"], !(raw is NSNull) else { return ("default", ["default"]) }
        func invalid() -> LLMError {
            .providerError(message: "OpenRouter returned invalid reasoning controls for \(row["id"] ?? "a model"). Refresh its model catalog in Providers.")
        }
        guard let reasoning = raw as? [String: Any] else { throw invalid() }
        let gatewayEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        let efforts: [String]
        if reasoning["supported_efforts"] is NSNull {
            // Explicit null is OpenRouter's declaration that all gateway efforts are accepted.
            efforts = gatewayEfforts
        } else if let raw = reasoning["supported_efforts"] {
            guard let declared = raw as? [String], declared.allSatisfy(gatewayEfforts.contains) else { throw invalid() }
            efforts = declared
        } else { efforts = [] }
        if let mandatory = reasoning["mandatory"], !(mandatory is Bool) { throw invalid() }
        let supported = reasoning["mandatory"] as? Bool == true ? efforts.filter { $0 != "none" } : efforts
        let defaultEffort: String
        if let raw = reasoning["default_effort"], !(raw is NSNull) {
            guard let declared = raw as? String, gatewayEfforts.contains(declared),
                  supported.isEmpty || supported.contains(declared) || (declared == "none" && reasoning["mandatory"] as? Bool != true) else { throw invalid() }
            // A model with no effort selector still executes with its provider's default.
            defaultEffort = supported.contains(declared) ? declared : "default"
        } else { defaultEffort = "default" }
        // "default" is the explicit choice to omit this optional request control. It is not an effort guessed from the model's family or name.
        return (defaultEffort, ["default"] + supported)
    }

    private static func modelCanReturnText(_ row: [String: Any]) -> Bool {
        guard let architecture = row["architecture"] as? [String: Any] else { return false }
        let outputModalities = stringSet(architecture["output_modalities"])
        if outputModalities.isEmpty {
            if let modality = architecture["modality"] as? String {
                return modality.lowercased().contains("text")
            }
            return false
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
        let parts = id.split(separator: "/", maxSplits: 1)
        if let provider = parts.first, let model = parts.dropFirst().first {
            return (provider: String(provider), model: String(model))
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
        do {
            return try cache.currentCache(dataRoot: dataRoot) == nil
                ? "OpenRouter model catalog is not available. Refresh its models in Providers." : nil
        } catch { return error.localizedDescription }
    }

    static func readCache(dataRoot: URL) -> [ProviderModelInfo]? {
        do { return try cache.currentCache(dataRoot: dataRoot)?.models }
        catch { return nil } // cacheFault carries the unavailable cause.
    }

    private static let decodedCache = ModelCatalogDecodeCache()

    private static func readDecodedCache(dataRoot: URL) throws -> DecodedModelCatalog? {
        try decodedCache.read(url: cachePath(dataRoot: dataRoot)) {
            guard let decoded = try decodeCache(data: $0) else {
                throw ProviderRoutingError.configurationFailed("The saved OpenRouter model catalog is malformed. Refresh its models in Providers.")
            }
            return decoded
        }
    }

    private static func decodeCache(data: Data) throws -> DecodedModelCatalog? {
        let root = try JSONValue.parse(data)
        guard case .object(let obj) = root,
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
                  let name = string(row["name"]),
                  let context = row["context_length"]?.integerValue.flatMap(Int.init(exactly:)), context >= 0,
                  let streaming = row["supports_streaming"]?.boolValue,
                  let vision = row["supports_vision"]?.boolValue,
                  let tools = row["supports_tools"]?.boolValue,
                  let json = row["supports_json_mode"]?.boolValue else {
                return nil
            }
            let efforts: [String]?
            if let raw = row["supported_reasoning_efforts"] {
                guard case .array(let values) = raw else { return nil }
                let strings = values.compactMap { $0.stringValue }
                guard strings.count == values.count else { return nil }
                efforts = strings
            } else { efforts = nil }
            if let raw = row["default_reasoning_effort"], raw.stringValue == nil { return nil }
            return ProviderModelInfo(
                id: id,
                name: name,
                context_length: context,
                supports_streaming: streaming,
                supports_vision: vision,
                supports_tools: tools,
                supports_json_mode: json,
                cost_per_1k_in: row["cost_per_1k_in"]?.numberValue(coercingStrings: false, finiteOnly: false),
                cost_per_1k_out: row["cost_per_1k_out"]?.numberValue(coercingStrings: false, finiteOnly: false),
                default_reasoning_effort: row["default_reasoning_effort"]?.stringValue,
                supported_reasoning_efforts: efforts,
                supports_fast: row["supports_fast"]?.boolValue
            )
        }
        guard models.count == rows.count else { return nil }
        let fetchedAt: Date?
        if case .string(let raw)? = obj["updated_at"] {
            fetchedAt = ISO8601DateFormatter().date(from: raw)
        } else {
            fetchedAt = nil
        }
        return DecodedModelCatalog(models: sortModels(models), isComplete: isComplete, fetchedAt: fetchedAt,
                                   credentialBinding: obj["credential_binding"]?.stringValue)
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        guard let array = value as? [Any] else { return [] }
        return Set(array.compactMap { ($0 as? String)?.lowercased() })
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let i = value as? Int, i > 0 { return i }
        if let i = value as? Int64, i > 0 { return Int(exactly: i) }
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

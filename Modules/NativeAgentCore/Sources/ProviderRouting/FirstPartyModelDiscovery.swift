import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `FirstPartyModelDiscovery.swift` | `FirstPartyModelDiscovery`: live model lists, offered flag, one identity per model, effective contracts |

/// What an account offers to choose from is what its provider listed, and nothing else. The build's own rows are contracts: they say how to run a
/// model and stand where the provider's list is missing, so every reader still finds a model's row, but they are never offered (`offered: false`).
/// When a provider cannot be reached, the account says so plainly and offers nothing in its place.
///
/// Membership comes from the provider's list endpoint, bound to the credential that fetched it, through `ModelCatalogCache`. A model has one effective
/// contract: its identity is the same whichever spelling names it; its controls come from the shipped row of the same model, else what the
/// provider's list states, else the nearest shipped sibling of the same family on that route, else minimal controls (no think level sent, Fast off);
/// its limits are the tightest the build and the provider state. A model whose window neither states is not offered. The cache keeps what the
/// provider stated, so a later build resolves the contract again from its own rows.
public enum FirstPartyModelDiscovery {
    /// Routes whose providers can be asked for their list. OpenRouter and Moonshot keep their own catalogs; Kimi Code has no list endpoint.
    public static let routeIDs = ["anthropic", "anthropic_oauth_direct", "openai", "xai_oauth_direct", "meta"]

    /// Cache files beside the provider configurations: never read as a configuration, never removed with one.
    public static let cacheFileNames: [String] = routeIDs.map(cacheFileName)

    public static func isLiveRoute(_ providerID: String) -> Bool { caches[providerID] != nil }

    static func cacheFileName(_ route: String) -> String { "\(route)-models-cache.json" }

    /// Whether any connected route holds its provider's complete list now.
    public static func anyLiveList(dataRoot: URL) -> Bool { routeIDs.contains { currentList(route: $0, dataRoot: dataRoot).isLive } }

    private static let caches: [String: ModelCatalogCache] = Dictionary(uniqueKeysWithValues: routeIDs.map { ($0, makeCache($0)) })

    // MARK: - The route's list now

    /// The list a route shows now: the provider's last complete list for the saved credential, else the build's rows (not offered) and why.
    struct RouteList: Sendable {
        let models: [FirstPartyModelDescriptor]
        let note: String?
        let isLive: Bool
        /// Ids the provider listed whose contract this build cannot know (no shipped row, no sibling, no stated window): left out of `models`.
        var unrunnable: Set<String> = []

        /// The one answer to "does this route carry this pick": the listed row that is the same model, whichever spelling names it. Its id is the
        /// spelling to send: the pick itself when the provider listed that exact spelling, else the provider's (latest) spelling of the same model.
        func row(for pick: String) -> FirstPartyModelDescriptor? {
            let id = pick.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { return nil }
            return models.first { $0.id.lowercased() == id }
                ?? models.filter { FirstPartyModelDiscovery.sameModel($0.id, id) }.max { $0.id.lowercased() < $1.id.lowercased() }
        }

        /// The list a person picks from: a model appears once. One listed under its plain id and a dated id is one row under the plain id; the
        /// dated row stays only when it is a saved choice, so the selection is visible and exact. Two dates with no plain id are two rows, as the
        /// provider says. `models` keeps every spelling, so membership, contracts and dispatch are unchanged.
        func choices(keeping saved: Set<String>) -> [FirstPartyModelDescriptor] {
            let listed = Set(models.map { $0.id.lowercased() })
            let kept = Set(saved.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            return models.filter { row in
                let id = row.id.lowercased()
                guard let plain = FirstPartyModelDiscovery.undated(id), listed.contains(plain) else { return true }
                return kept.contains(id)
            }
        }

        /// The account's rows as pickers and pages read them: each carries whether it is offered. Rows from the provider's list are; the build's
        /// rows standing in its place are not, and say so when shown as a slot's current model.
        func rows(keeping saved: Set<String>, route: String) -> [[String: JSONValue]] {
            choices(keeping: saved).map { rowJSON($0, route: route) }
        }

        /// One row as readers see it, carrying the offered flag.
        func rowJSON(_ model: FirstPartyModelDescriptor, route: String) -> [String: JSONValue] {
            var row = model.providerJSON()
            if !isLive {
                row["offered"] = .bool(false)
                row["offer_note"] = .string("Saved. \(FirstPartyModelDiscovery.providerName(route)) has not listed it yet.")
            }
            return row
        }
    }

    /// One model whichever spelling names it: the same id, or the same id with a trailing date. Two different dates are two snapshots.
    static func sameModel(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return left == right || undated(left) == right || undated(right) == left
    }

    /// Synchronous and network-free: routing, pickers and dispatch all read this.
    ///
    /// The last complete list for the current credential is the list until a newer complete list replaces it. A failed refresh changes only its
    /// freshness: the note says the provider could not be asked, when the list shown was fetched, and to refresh. With no complete list for this
    /// credential the build's rows stand in its place for every reader, not offered, and the note says why in one plain sentence.
    static func currentList(route: String, dataRoot: URL) -> RouteList {
        let shipped = FirstPartyModelCatalog.models(forProviderID: route)
        guard let cache = caches[route] else { return RouteList(models: shipped, note: nil, isLive: false) }
        let name = providerName(route)
        func shippedFloor(_ why: String) -> RouteList { RouteList(models: shipped, note: why, isLive: false) }
        let read: (credential: String?, catalog: DecodedModelCatalog?)
        do { read = try cache.boundRead(dataRoot: dataRoot) }
        catch { return shippedFloor("\(name) could not be reached: \(plain(error)). Refresh to try again.") }
        // Nothing saved: the route is not connected and its floor needs no apology.
        guard read.credential != nil else { return RouteList(models: shipped, note: nil, isLive: false) }
        let failure = cache.lastFailureReason(dataRoot: dataRoot)
        guard let catalog = read.catalog, catalog.isComplete == true else {
            if let failure { return shippedFloor("\(name) could not be reached: \(failure). Refresh to try again.") }
            guard read.catalog != nil else { return shippedFloor("\(name) has not been asked for its models yet.") }
            return shippedFloor("\(name) answered with an incomplete list. Refresh to try again.")
        }
        var models: [FirstPartyModelDescriptor] = []
        var unrunnable: Set<String> = []
        for row in catalog.models {
            guard let stated = catalog.rowExtras[row.id]?["provider_stated"]?.objectValue.flatMap(StatedModel.init(json:)) else { continue }
            let model = resolve(stated, route: route)
            // A window this build cannot know would admit requests the provider must refuse: such a model is not offered.
            if model.contextLength > 0 { models.append(model) } else { unrunnable.insert(model.id.lowercased()) }
        }
        var notes: [String] = []
        if let failure {
            let when = catalog.fetchedAt.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            notes.append("\(name) could not be asked: \(failure). This is its list\(when); refresh to try again.")
        }
        if !unrunnable.isEmpty {
            let count = unrunnable.count
            notes.append("\(count) more \(count == 1 ? "model" : "models") from \(name) \(count == 1 ? "is" : "are") not listed because this "
                + "build does not know how to run \(count == 1 ? "it" : "them").")
        }
        return RouteList(models: models, note: notes.isEmpty ? nil : notes.joined(separator: " "), isLive: true, unrunnable: unrunnable)
    }

    /// The row the provider listed for this credential that is this model, whichever spelling names it, with its effective contract.
    static func liveDescriptor(for modelID: String, route: String, dataRoot: URL) -> FirstPartyModelDescriptor? {
        guard isLiveRoute(route) else { return nil }
        let list = currentList(route: route, dataRoot: dataRoot)
        guard list.isLive else { return nil }
        return list.row(for: modelID)
    }

    // MARK: - Asking

    /// Asks one route's provider now. Nil when the list was fetched and saved; otherwise why not, in a plain sentence fragment.
    public static func refresh(route: String, dataRoot: URL, session: URLSession = ProviderHTTP.session) async -> String? {
        guard let cache = caches[route] else { return nil }
        let read = await cache.modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: true)
        guard read.freshness == .unavailable else { return nil }
        return read.failure ?? "the list could not be fetched"
    }

    /// Asks every connected route's provider again. Each failure names its account: "OpenAI: it answered HTTP 500".
    public static func refreshConnected(dataRoot: URL, session: URLSession = ProviderHTTP.session) async -> [String] {
        let connected = routeIDs.filter { hasCredential($0, dataRoot: dataRoot) }
        let failures = await withTaskGroup(of: String?.self) { group in
            for route in connected {
                group.addTask { await refresh(route: route, dataRoot: dataRoot, session: session).map { "\(accountName(route)): \($0)" } }
            }
            var collected: [String] = []
            for await failure in group { if let failure { collected.append(failure) } }
            return collected
        }
        return failures.sorted()
    }

    /// Entering Providers asks a connected route only when no list is saved for its current credential. True when anything was asked.
    @concurrent public nonisolated static func fetchMissing(dataRoot: URL, routes: [String]? = nil,
                                                          session: URLSession = ProviderHTTP.session) async -> Bool {
        let missing = missingRoutes(dataRoot: dataRoot).filter { routes?.contains($0) ?? true }
        await withTaskGroup(of: Void.self) { group in
            for route in missing { group.addTask { _ = await refresh(route: route, dataRoot: dataRoot, session: session) } }
        }
        return !missing.isEmpty
    }

    /// Connected routes with no complete list for their current credential: what `fetchMissing` asks. Synchronous and network-free.
    public static func missingRoutes(dataRoot: URL) -> [String] {
        routeIDs.filter { route in
            guard let cache = caches[route] else { return false }
            do {
                let read = try cache.boundRead(dataRoot: dataRoot)
                return read.credential != nil && read.catalog?.isComplete != true
            } catch { return true }
        }
    }

    /// What an account says while its provider is being asked for its list.
    public static func askingSentence(route: String) -> String { "Asking \(providerName(route)) for its models…" }

    /// A connection check already fetched the list's first page with this key: finish the list and publish it through the same owner. Nil when it
    /// was saved or a newer credential superseded it; otherwise why not.
    static func publishChecked(route: String, firstPage: Data, key: String, dataRoot: URL,
                               session: URLSession = ProviderHTTP.session) async -> String? {
        guard let cache = caches[route] else { return nil }
        do {
            let fetched = try await fetch(route: route, token: key, session: session, firstPage: firstPage)
            switch await cache.publish(fetched, credential: key, dataRoot: dataRoot) {
            case .success: return nil
            case .failure(let failure): return failure.superseded ? nil : failure.reason
            }
        } catch { return plain(error) }
    }

    private static func hasCredential(_ route: String, dataRoot: URL) -> Bool {
        guard let cache = caches[route] else { return false }
        do { return try cache.savedCredential(dataRoot: dataRoot) != nil }
        catch { return true } // An unreadable credential is asked anyway, so its failure is reported.
    }

    // MARK: - Words

    /// The provider, as a person names it.
    static func providerName(_ route: String) -> String {
        switch route {
        case "anthropic", "anthropic_oauth_direct": "Anthropic"
        case "openai": "OpenAI"
        case "xai_oauth_direct": "xAI"
        case "meta": "Meta"
        default: "The provider"
        }
    }

    /// The account, as a person tells two of the same provider apart.
    private static func accountName(_ route: String) -> String {
        switch route {
        case "anthropic": "Anthropic (API key)"
        case "anthropic_oauth_direct": "Your Claude sign-in"
        default: providerName(route)
        }
    }

    static func plain(_ error: Error) -> String {
        if let failure = error as? ModelListFailure { return failure.reason }
        if case .configurationFailed(let message)? = error as? ProviderRoutingError { return message }
        return error.localizedDescription
    }

    struct ModelListFailure: LocalizedError, Sendable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    // MARK: - The cache and its credential

    private static func endpoint(_ route: String) -> URL? {
        switch route {
        case "anthropic", "anthropic_oauth_direct": URL(string: "https://api.anthropic.com/v1/models")
        case "openai": URL(string: "https://api.openai.com/v1/models")
        // Language models only: the general list also carries image and video models.
        case "xai_oauth_direct": URL(string: "https://api.x.ai/v1/language-models")
        case "meta": URL(string: "https://api.meta.ai/v1/models")
        default: nil
        }
    }

    private static func makeCache(_ route: String) -> ModelCatalogCache {
        ModelCatalogCache(
            cachePath: { $0.appendingPathComponent("providers/\(cacheFileName(route))") },
            endpoint: endpoint(route),
            readCache: { try readDecodedCache(route: route, dataRoot: $0) },
            credential: credential(route),
            fetchLive: { token, session in try await fetch(route: route, token: token, session: session) }
        )
    }

    /// API keys bind by the key; a sign-in binds by its account identity, so renewing its access token keeps its list.
    private static func credential(_ route: String) -> ModelCatalogCredential {
        switch route {
        case "anthropic_oauth_direct":
            let file: @Sendable (URL) -> URL = { $0.appendingPathComponent("providers/anthropic_oauth_direct.json") }
            return ModelCatalogCredential(
                file: file, kind: "sign_in",
                current: { try signInIdentity(at: file($0), provider: "anthropic_oauth_direct") },
                prepare: { root in
                    guard try signInIdentity(at: file(root), provider: "anthropic_oauth_direct") != nil else { return nil }
                    return try await AnthropicOAuthTransport(authPathOverride: file(root)).ensureFreshAccessToken()
                })
        case "xai_oauth_direct":
            let file: @Sendable (URL) -> URL = { XAIOAuthTransport.tokenPath(dataRoot: $0) }
            return ModelCatalogCredential(
                file: file, kind: "sign_in",
                current: { try signInIdentity(at: file($0), provider: "xai_oauth_direct") },
                prepare: { root in
                    guard try signInIdentity(at: file(root), provider: "xai_oauth_direct") != nil else { return nil }
                    return try await XAIOAuthTransport(tokenPathOverride: file(root)).ensureFreshAccessToken()
                })
        default:
            return .apiKey(providerConfigFile: "\(route).json")
        }
    }

    /// Reads only the saved metadata, never the Keychain: the sign-in's bound account, else a setup token, else the xAI token reference.
    private static func signInIdentity(at path: URL, provider: String) throws -> String? {
        let object = try ProviderStateValidation.credentialMetadata(at: path)
        let tokens = OAuthRefreshBinding.tokenSet(object, provider: provider)
        return OAuthRefreshBinding.string(tokens["oauth_account_identity"])
            ?? OAuthRefreshBinding.string(tokens["access_token"])
            ?? OAuthRefreshBinding.string(object[XAIOAuthCredentialStore.referenceField])
    }

    private static let decodedCache = ModelCatalogDecodeCache()

    private static func readDecodedCache(route: String, dataRoot: URL) throws -> DecodedModelCatalog? {
        try decodedCache.read(url: dataRoot.appendingPathComponent("providers/\(cacheFileName(route))")) { data in
            guard let decoded = decodeCache(data, route: route) else {
                throw ModelListFailure("the saved \(providerName(route)) model list could not be read")
            }
            return decoded
        }
    }

    /// Controls are resolved again from what the provider stated, never trusted from the saved row.
    private static func decodeCache(_ data: Data, route: String) -> DecodedModelCatalog? {
        guard let root = try? JSONValue.parse(data).objectValue, let rows = root["models"]?.arrayValue else { return nil }
        var models: [ProviderModelInfo] = []
        var extras: [String: [String: JSONValue]] = [:]
        for row in rows {
            guard let stated = row.objectValue?["provider_stated"]?.objectValue.flatMap(StatedModel.init(json:)) else { return nil }
            let descriptor = resolve(stated, route: route)
            models.append(descriptor.providerModelInfo)
            extras[descriptor.id] = ["provider_stated": .object(stated.json)]
        }
        let fetchedAt = root["updated_at"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
        return DecodedModelCatalog(models: models, isComplete: root["complete"]?.boolValue, fetchedAt: fetchedAt,
                                   credentialBinding: root["credential_binding"]?.stringValue, rowExtras: extras)
    }

    // MARK: - Fetching (documented shapes, not yet exercised by this build; an unrecognised shape fails the fetch, never a guess)

    static func fetch(route: String, token: String?, session: URLSession, firstPage: Data? = nil) async throws -> ModelCatalogFetch {
        guard let token, !token.isEmpty else {
            throw ModelListFailure(route.hasSuffix("_oauth_direct") ? "no sign-in is saved" : "no API key is saved")
        }
        let stated: [StatedModel]
        switch route {
        case "anthropic", "anthropic_oauth_direct":
            stated = try await anthropicList(route: route, token: token, session: session, firstPage: firstPage)
        case "openai", "xai_oauth_direct", "meta":
            let data: Data
            if let firstPage { data = firstPage } else {
                guard let url = endpoint(route) else { throw URLError(.badURL) }
                data = try await get(url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"], route: route,
                                     session: session)
            }
            switch route {
            case "openai": stated = try openAIList(data)
            case "meta": stated = try metaList(data)
            default: stated = try xAIList(data)
            }
        default:
            throw ModelListFailure("this account has no model list to ask for")
        }
        guard !stated.isEmpty else { throw ModelListFailure("\(providerName(route)) listed no chat models this build can run") }
        return fetched(stated, route: route)
    }

    /// Shipped rows keep their declared order, so the first row stays a new account's default; new models follow in the provider's order. Every id
    /// keeps the spelling the provider issued: a saved pick is matched to it as the same model (`RouteList.row(for:)`), never renamed here.
    private static func fetched(_ stated: [StatedModel], route: String) -> ModelCatalogFetch {
        let declared = FirstPartyModelCatalog.models(forProviderID: route).map { $0.id.lowercased() }
        func rank(_ id: String) -> Int {
            declared.firstIndex(of: id.lowercased()) ?? declared.firstIndex { sameModel($0, id) } ?? declared.count
        }
        var seen: Set<String> = []
        let ordered = stated.filter { seen.insert($0.id.lowercased()).inserted }.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element.id)
            let right = rank(rhs.element.id)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map { $0.element }
        let descriptors = ordered.map { resolve($0, route: route) }
        var extras: [String: [String: JSONValue]] = [:]
        for (stated, descriptor) in zip(ordered, descriptors) where extras[descriptor.id] == nil {
            extras[descriptor.id] = ["provider_stated": .object(stated.json)]
        }
        return ModelCatalogFetch(models: descriptors.map { $0.providerModelInfo }, isComplete: true, rowExtras: extras)
    }

    /// The id without a trailing date: `-20251001` or `-2026-04-23`. Nil when it carries none.
    private static func undated(_ id: String) -> String? {
        let tokens = id.split(separator: "-").map(String.init)
        func digits(_ token: String, _ count: Int) -> Bool { token.count == count && token.allSatisfy(\.isNumber) }
        if tokens.count > 1, digits(tokens[tokens.count - 1], 8) { return tokens.dropLast().joined(separator: "-") }
        if tokens.count > 3, digits(tokens[tokens.count - 3], 4), digits(tokens[tokens.count - 2], 2), digits(tokens[tokens.count - 1], 2) {
            return tokens.dropLast(3).joined(separator: "-")
        }
        return nil
    }

    private static func get(_ url: URL, headers: [String: String], route: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = .infinity
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if route == "anthropic_oauth_direct", http.statusCode == 401 || http.statusCode == 403 {
                throw ModelListFailure("your Claude sign-in is not allowed to list models (HTTP \(http.statusCode))")
            }
            throw ModelListFailure("it answered HTTP \(http.statusCode)")
        }
        return data
    }

    /// Anthropic pages its list; a partial list is incomplete, so every page is followed until `has_more` is false.
    private static func anthropicList(route: String, token: String, session: URLSession, firstPage: Data?) async throws -> [StatedModel] {
        let headers = route == "anthropic_oauth_direct"
            ? AnthropicOAuthTransport.apiHeaders(accessToken: token)
            : ["x-api-key": token, "anthropic-version": "2023-06-01", "Accept": "application/json"]
        var models: [StatedModel] = []
        var pending = firstPage
        var cursor: String?
        var cursors: Set<String> = []
        while true {
            let data: Data
            if let page = pending {
                data = page
                pending = nil
            } else {
                guard var components = URLComponents(string: "https://api.anthropic.com/v1/models") else { throw URLError(.badURL) }
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (cursor.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
                guard let url = components.url else { throw URLError(.badURL) }
                data = try await get(url, headers: headers, route: route, session: session)
            }
            let page = try anthropicPage(data)
            models += page.rows
            guard let next = page.next else { return models }
            guard cursors.insert(next).inserted else { throw ModelListFailure("Anthropic kept answering with the same page of its list") }
            cursor = next
        }
    }

    private static func anthropicPage(_ data: Data) throws -> (rows: [StatedModel], next: String?) {
        let bad = ModelListFailure("Anthropic's model list was not in the shape this build reads")
        guard let root = try? JSONValue.parse(data).objectValue, let rows = root["data"]?.arrayValue,
              let hasMore = root["has_more"]?.boolValue else { throw bad }
        let models = try rows.map(anthropicModel)
        guard hasMore else { return (models, nil) }
        guard let last = root["last_id"]?.stringValue, !last.isEmpty else {
            throw ModelListFailure("Anthropic said its list goes on but not where")
        }
        return (models, last)
    }

    /// Every Anthropic row is a chat model. Its window, output ceiling, effort levels, adaptive thinking and image input are taken as stated.
    private static func anthropicModel(_ value: JSONValue) throws -> StatedModel {
        let bad = ModelListFailure("Anthropic listed a model in a shape this build does not read")
        guard let row = value.objectValue, let id = row["id"]?.stringValue, !id.isEmpty else { throw bad }
        if let type = row["type"], type.stringValue != "model" { throw bad }
        var model = StatedModel(id: id)
        model.name = try optionalString(row["display_name"], bad)
        model.line = try optionalString(row["line"], bad)
        model.contextLength = try positiveInt(row["max_input_tokens"], bad)
        model.maxOutputTokens = try positiveInt(row["max_tokens"], bad)
        if let capabilities = row["capabilities"], capabilities != .null {
            guard let stated = capabilities.objectValue else { throw bad }
            if let effort = stated["effort"] {
                guard let levels = effort.objectValue, let supported = levels["supported"]?.boolValue else { throw bad }
                let offered = try ["low", "medium", "high", "xhigh", "max"].filter { try isSupported(levels[$0], bad) }
                model.efforts = supported ? offered : []
            }
            if let thinking = stated["thinking"] {
                guard let object = thinking.objectValue else { throw bad }
                if let types = object["types"] {
                    guard let kinds = types.objectValue else { throw bad }
                    model.adaptiveThinking = try isSupported(kinds["adaptive"], bad)
                }
            }
            if let image = stated["image_input"] { model.vision = try isSupported(image, bad) }
        }
        return model
    }

    // OpenAI's list holds every model the key can call, not only chat ones. A chat model's id starts with `gpt-` or is `chat-latest`, and any id
    // naming image, audio, realtime, tts, transcribe, embedding, moderation or search is not a chat model. This is the one place that rule lives.
    private static let openAINonChatWords = ["image", "audio", "realtime", "tts", "transcribe", "embedding", "moderation", "search"]

    private static func openAIList(_ data: Data) throws -> [StatedModel] {
        try listedIDs(data, provider: "OpenAI").filter { id in
            let lower = id.lowercased()
            return (lower.hasPrefix("gpt-") || lower == "chat-latest") && !openAINonChatWords.contains { lower.contains($0) }
        }.map { StatedModel(id: $0) }
    }

    /// Muse models only; a `-contributor` id needs a separate data-use choice this build does not make.
    private static func metaList(_ data: Data) throws -> [StatedModel] {
        try listedIDs(data, provider: "Meta").filter { id in
            let lower = id.lowercased()
            return lower.hasPrefix("muse-") && !lower.hasSuffix("-contributor")
        }.map { StatedModel(id: $0) }
    }

    private static func listedIDs(_ data: Data, provider: String) throws -> [String] {
        let bad = ModelListFailure("\(provider)'s model list was not in the shape this build reads")
        guard let root = try? JSONValue.parse(data).objectValue, let rows = root["data"]?.arrayValue else { throw bad }
        return try rows.map { row in
            guard let id = row.objectValue?["id"]?.stringValue, !id.isEmpty else { throw bad }
            return id
        }
    }

    /// xAI states effort levels and a default per model; its window when it states one; image input from its modalities.
    private static func xAIList(_ data: Data) throws -> [StatedModel] {
        let bad = ModelListFailure("xAI's model list was not in the shape this build reads")
        guard let root = try? JSONValue.parse(data).objectValue, let rows = root["models"]?.arrayValue else { throw bad }
        return try rows.map { value in
            guard let row = value.objectValue, let id = row["id"]?.stringValue, !id.isEmpty else { throw bad }
            var model = StatedModel(id: id)
            model.contextLength = try positiveInt(row["context_length"], bad)
            if let modalities = row["input_modalities"], modalities != .null {
                guard let list = modalities.arrayValue else { throw bad }
                model.vision = try list.map { guard let word = $0.stringValue else { throw bad }; return word }.contains("image")
            }
            if let capabilities = row["capabilities"], capabilities != .null {
                guard let stated = capabilities.objectValue, let efforts = stated["reasoning_effort"]?.arrayValue else { throw bad }
                model.efforts = try efforts.map { guard let level = $0.stringValue else { throw bad }; return level.lowercased() }
                model.defaultEffort = try optionalString(stated["default_reasoning_effort"], bad)?.lowercased()
            }
            return model
        }
    }

    private static func optionalString(_ value: JSONValue?, _ bad: ModelListFailure) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue else { throw bad }
        return text.isEmpty ? nil : text
    }

    /// A stated zero or negative is no statement.
    private static func positiveInt(_ value: JSONValue?, _ bad: ModelListFailure) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let number = value.exactIntegerValue else { throw bad }
        return number > 0 ? number : nil
    }

    private static func isSupported(_ value: JSONValue?, _ bad: ModelListFailure) throws -> Bool {
        guard let value, value != .null else { return false }
        guard let supported = value.objectValue?["supported"]?.boolValue else { throw bad }
        return supported
    }

    // MARK: - Contract

    /// What the provider's list itself said about one model; nil fields were not stated.
    struct StatedModel: Sendable, Equatable {
        var id: String
        var name: String?
        var line: String?
        var contextLength: Int?
        var maxOutputTokens: Int?
        var efforts: [String]?
        var defaultEffort: String?
        var adaptiveThinking: Bool?
        var vision: Bool?

        init(id: String) { self.id = id }

        init?(json: [String: JSONValue]) {
            guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
            self.id = id
            name = json["name"]?.stringValue
            line = json["line"]?.stringValue
            contextLength = json["context_length"]?.exactIntegerValue
            maxOutputTokens = json["max_output_tokens"]?.exactIntegerValue
            efforts = json["reasoning_efforts"]?.arrayValue?.compactMap(\.stringValue)
            defaultEffort = json["default_reasoning_effort"]?.stringValue
            adaptiveThinking = json["adaptive_thinking"]?.boolValue
            vision = json["supports_vision"]?.boolValue
        }

        var json: [String: JSONValue] {
            var object: [String: JSONValue] = ["id": .string(id)]
            object["name"] = name.map(JSONValue.string)
            object["line"] = line.map(JSONValue.string)
            object["context_length"] = contextLength.map { JSONValue.int(Int64($0)) }
            object["max_output_tokens"] = maxOutputTokens.map { JSONValue.int(Int64($0)) }
            object["reasoning_efforts"] = efforts.map { JSONValue.array($0.map(JSONValue.string)) }
            object["default_reasoning_effort"] = defaultEffort.map(JSONValue.string)
            object["adaptive_thinking"] = adaptiveThinking.map(JSONValue.bool)
            object["supports_vision"] = vision.map(JSONValue.bool)
            return object
        }
    }

    /// One effective contract. A shipped row of the same model (whichever spelling the provider listed) gives every control; each limit comes from
    /// whichever of the row and the provider states it, the tighter when both do. Otherwise each field from what the provider stated, then the
    /// nearest shipped sibling, then minimal controls. A window neither states stays 0: unknown, and such a model is not offered.
    static func resolve(_ stated: StatedModel, route: String) -> FirstPartyModelDescriptor {
        let shipped = FirstPartyModelCatalog.models(forProviderID: route)
        let id = stated.id.lowercased()
        if let row = shipped.first(where: { $0.id.lowercased() == id }) ?? shipped.first(where: { sameModel($0.id, id) }) {
            return row.withLimits(id: stated.id, contextLength: stated.contextLength, maxOutputTokens: stated.maxOutputTokens)
        }
        let sibling = nearestSibling(of: stated, in: shipped, route: route)
        let vocabulary: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        var efforts = stated.efforts.map { $0.filter(vocabulary.contains) } ?? sibling?.supportedReasoningEfforts ?? []
        var defaultEffort = stated.defaultEffort ?? sibling?.defaultReasoningEffort ?? "default"
        // "default" sends no think level at all: the provider's own default.
        if !efforts.contains(defaultEffort) {
            defaultEffort = "default"
            if !efforts.contains("default") { efforts.append("default") }
        }
        let provider = providerName(route)
        let note: String
        if let sibling {
            note = "New from \(provider). Its controls follow \(sibling.name) until this build knows it."
        } else if stated.efforts?.isEmpty == false {
            note = "New from \(provider). It offers the Think levels \(provider) lists, without Fast, until this build knows it."
        } else {
            note = "New from \(provider). It runs with the provider's defaults until this build knows it."
        }
        return FirstPartyModelDescriptor(
            id: stated.id,
            name: stated.name ?? displayName(stated.id),
            contextLength: stated.contextLength ?? sibling?.contextLength ?? 0,
            supportsVision: stated.vision ?? sibling?.supportsVision ?? false,
            supportsJSONMode: sibling?.supportsJSONMode ?? false,
            defaultReasoningEffort: defaultEffort,
            supportedReasoningEfforts: efforts,
            supportsFast: sibling?.supportsFast ?? false,
            supportsMidConversationSystem: sibling?.supportsMidConversationSystem ?? false,
            adaptiveThinking: stated.adaptiveThinking ?? sibling?.adaptiveThinking ?? false,
            usesResponses: route == "openai" && servesThroughResponses(stated.id),
            reasoningWire: sibling?.reasoningWire ?? .effort,
            maxOutputTokens: stated.maxOutputTokens,
            controlsNote: note)
    }

    /// A GPT-5-or-later model this build does not ship goes through Responses; older ones and `chat-latest` through Chat Completions.
    private static func servesThroughResponses(_ id: String) -> Bool {
        let tokens = id.lowercased().split(separator: "-").map(String.init)
        guard tokens.count >= 2, tokens[0] == "gpt", let major = dotted(tokens[1])?.first else { return false }
        return major >= 5
    }

    private struct Family: Equatable {
        let key: String
        let version: [Int]
    }

    /// The newest shipped row of the same line and variant whose version is at or below this one, by numeric comparison.
    private static func nearestSibling(of stated: StatedModel, in shipped: [FirstPartyModelDescriptor],
                                       route: String) -> FirstPartyModelDescriptor? {
        guard let wanted = family(of: stated.id, line: stated.line, route: route) else { return nil }
        var best: (row: FirstPartyModelDescriptor, version: [Int])?
        for row in shipped {
            guard let candidate = family(of: row.id, line: nil, route: route), candidate.key == wanted.key,
                  compare(candidate.version, wanted.version) <= 0 else { continue }
            if best.map({ compare(candidate.version, $0.version) > 0 }) ?? true { best = (row, candidate.version) }
        }
        return best?.row
    }

    private static func family(of id: String, line statedLine: String?, route: String) -> Family? {
        let tokens = id.lowercased().split(separator: "-").map(String.init)
        guard tokens.count >= 2 else { return nil }
        switch route {
        case "anthropic", "anthropic_oauth_direct":
            // claude-<line>-<major>[-<minor>][-<date>]; Mythos follows Fable. Anthropic's stated line wins over the id's.
            let lines: Set<String> = ["opus", "sonnet", "haiku", "fable", "mythos"]
            guard tokens[0] == "claude", lines.contains(tokens[1]) else { return nil }
            var line = statedLine?.lowercased() ?? tokens[1]
            if line == "mythos" { line = "fable" }
            guard lines.contains(line) else { return nil }
            let version = tokens.dropFirst(2).prefix { $0.count <= 3 && $0.allSatisfy(\.isNumber) }.compactMap { Int($0) }
            return version.isEmpty ? nil : Family(key: "claude-" + line, version: version)
        case "openai":
            // gpt-<version>[-<variant>][-<yyyy>-<mm>-<dd>], keeping the variant.
            guard tokens[0] == "gpt", let version = dotted(tokens[1]) else { return nil }
            var rest = Array(tokens.dropFirst(2))
            if rest.count >= 3, rest.suffix(3).map(\.count) == [4, 2, 2], rest.suffix(3).allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                rest.removeLast(3)
            }
            let variant = rest.joined(separator: "-")
            guard ["", "sol", "terra", "luna", "astra", "pro", "mini"].contains(variant) else { return nil }
            return Family(key: "gpt-" + variant, version: version)
        case "xai_oauth_direct":
            // grok-<version>… or grok-<line>-<version>…, keeping reasoning, non-reasoning and multi-agent apart.
            guard tokens[0] == "grok" else { return nil }
            let line: String
            let version: [Int]
            if let numbered = dotted(tokens[1]) {
                line = "grok"
                version = numbered
            } else {
                guard tokens.count >= 3, let numbered = dotted(tokens[2]) else { return nil }
                line = tokens[1]
                version = numbered
            }
            let lower = id.lowercased()
            let variant = lower.contains("multi-agent") ? "multi-agent"
                : lower.contains("non-reasoning") ? "non-reasoning"
                : lower.contains("reasoning") ? "reasoning" : ""
            return Family(key: line + "|" + variant, version: version)
        case "meta":
            // muse-<line>-<version>[-<variant>]
            guard tokens[0] == "muse", tokens.count >= 3, let version = dotted(tokens[2]) else { return nil }
            return Family(key: "muse-" + tokens[1] + "|" + tokens.dropFirst(3).joined(separator: "-"), version: version)
        default:
            return nil
        }
    }

    private static func dotted(_ token: String) -> [Int]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    private static func displayName(_ id: String) -> String {
        let words = id.split(separator: "-").map { part -> String in
            switch part.lowercased() {
            case "gpt": "GPT"
            case "grok": "Grok"
            case "muse": "Muse"
            default: part.prefix(1).uppercased() + String(part.dropFirst())
            }
        }
        if words.first == "GPT", words.count > 1 { return (["GPT-" + words[1]] + words.dropFirst(2)).joined(separator: " ") }
        return words.joined(separator: " ")
    }
}

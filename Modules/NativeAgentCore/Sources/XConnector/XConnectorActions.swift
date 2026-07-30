import Foundation
import NativeAgentCore
import PersistenceCore
import CryptoKit

public enum XConnectorActions {
    private static let apiBase = "https://api.twitter.com"
    private static let requestTimeout: TimeInterval = 20
    private static let tweetFields = "id,text,author_id,created_at,public_metrics,conversation_id,referenced_tweets,lang"
    private static let meFields = "id,username,name,verified,public_metrics"
    private static let userIDCache = UserIDCache()

    public static func status(input: [String: JSONValue]) async throws -> JSONValue {
        do {
            _ = try await currentBearer()
            let token = try loadOAuth2Token()
            let secrets = try? loadOAuth1Credentials()
            let expiresAt = Double((token["expires_at"] as? String) ?? "") ?? 0
            var obj = baseEnvelope(actionId: "x.status", status: "completed")
            obj["account"] = secrets.map { .string(mask($0.apiKey)) } ?? .null
            obj["bearer_valid"] = .bool(true)
            obj["scope"] = (token["scope"] as? String).map(JSONValue.string) ?? .null
            obj["expires_at_iso"] = expiresAt > 0 ? .string(iso(Date(timeIntervalSince1970: expiresAt))) : .null
            obj["oauth1_available"] = .bool(secrets != nil)
            return .object(obj)
        } catch {
            return failureEnvelope(actionId: "x.status", error: error)
        }
    }

    public static func me(input: [String: JSONValue]) async throws -> JSONValue {
        await run(actionId: "x.me") {
            let bearer = try await currentBearer()
            let url = apiURL("/2/users/me")
            let (status, data) = try await httpGET(url, bearer: bearer, query: [
                ("user.fields", meFields)
            ])
            guard (200..<300).contains(status) else {
                return httpFailureEnvelope(actionId: "x.me", statusCode: status, data: data)
            }
            let payload = try parseJSONObject(data)
            return completedEnvelope(actionId: "x.me", fields: [
                "data": JSONValue(fromFoundation: payload["data"] ?? NSNull())
            ])
        }
    }

    public static func searchRecent(input: [String: JSONValue]) async throws -> JSONValue {
        await run(actionId: "x.search_recent") {
            let query = inputString(input["query"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else {
                throw XActionError("missing_input", detail: "x.search_recent requires a non-empty query.")
            }
            let maxResults = clampedInt(input["max"], defaultValue: 10, min: 1, max: 100)
            let bearer = try await currentBearer()
            let url = apiURL("/2/tweets/search/recent")
            let (status, data) = try await httpGET(url, bearer: bearer, query: [
                ("query", query),
                ("max_results", String(maxResults)),
                ("tweet.fields", "id,text,author_id,created_at,public_metrics")
            ])
            guard (200..<300).contains(status) else {
                return httpFailureEnvelope(actionId: "x.search_recent", statusCode: status, data: data)
            }
            let payload = try parseJSONObject(data)
            return completedEnvelope(actionId: "x.search_recent", fields: tweetsAndMetaFields(payload))
        }
    }

    public static func postTweet(input: [String: JSONValue]) async throws -> JSONValue {
        await run(actionId: "x.post_tweet") {
            let text = inputString(input["text"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw XActionError("missing_input", detail: "x.post_tweet requires non-empty text.")
            }
            let bearer = try await currentBearer()
            var body: [String: Any] = ["text": text]
            if let replyToTweetId = inputString(input["replyToTweetId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !replyToTweetId.isEmpty {
                body["reply"] = ["in_reply_to_tweet_id": replyToTweetId]
            }
            let url = apiURL("/2/tweets")
            let (status, data) = try await httpJSONPOST(url, bearer: bearer, body: body)
            guard (200..<300).contains(status) else {
                return httpFailureEnvelope(actionId: "x.post_tweet", statusCode: status, data: data)
            }
            let payload = try parseJSONObject(data)
            return completedEnvelope(actionId: "x.post_tweet", fields: [
                "data": JSONValue(fromFoundation: payload["data"] ?? NSNull())
            ])
        }
    }

    public static func timelineHome(input: [String: JSONValue]) async throws -> JSONValue {
        await run(actionId: "x.timeline_home") {
            let bearer = try await currentBearer()
            let userID = try await authenticatedUserIDBearer(bearer: bearer)
            let query = timelineQuery(input: input)
            let url = apiURL("/2/users/\(percentEncode(userID))/timelines/reverse_chronological")
            let (status, data) = try await httpGET(url, bearer: bearer, query: query)
            guard (200..<300).contains(status) else {
                return httpFailureEnvelope(actionId: "x.timeline_home", statusCode: status, data: data)
            }
            let payload = try parseJSONObject(data)
            var fields = tweetsAndMetaFields(payload)
            fields["user_id"] = .string(userID)
            return completedEnvelope(actionId: "x.timeline_home", fields: fields)
        }
    }

    public static func userTweets(input: [String: JSONValue]) async throws -> JSONValue {
        await run(actionId: "x.user_tweets") {
            let bearer = try await currentBearer()
            let resolved = try await resolveUserIDBearer(input: input, bearer: bearer)
            let query = userTweetsQuery(input: input)
            let url = apiURL("/2/users/\(percentEncode(resolved.id))/tweets")
            let (status, data) = try await httpGET(url, bearer: bearer, query: query)
            guard (200..<300).contains(status) else {
                return httpFailureEnvelope(actionId: "x.user_tweets", statusCode: status, data: data)
            }
            let payload = try parseJSONObject(data)
            var fields = tweetsAndMetaFields(payload)
            fields["user_id"] = .string(resolved.id)
            if let username = resolved.username { fields["username"] = .string(username) }
            return completedEnvelope(actionId: "x.user_tweets", fields: fields)
        }
    }

    public static func timelineHomeV1(input: [String: JSONValue]) async throws -> JSONValue {
        await run(actionId: "x.timeline_home_v1") {
            let userID = try await authenticatedUserIDOAuth1()
            let query = timelineQuery(input: input)
            let url = apiURL("/2/users/\(percentEncode(userID))/timelines/reverse_chronological")
            let auth = try await oauth1AuthHeader(method: "GET", url: url, query: query)
            let (status, data) = try await httpGET(url, headers: ["Authorization": auth], query: query)
            guard (200..<300).contains(status) else {
                return httpFailureEnvelope(actionId: "x.timeline_home_v1", statusCode: status, data: data)
            }
            let payload = try parseJSONObject(data)
            var fields = tweetsAndMetaFields(payload)
            fields["user_id"] = .string(userID)
            return completedEnvelope(actionId: "x.timeline_home_v1", fields: fields)
        }
    }

    public static func userTweetsV1(input: [String: JSONValue]) async throws -> JSONValue {
        await run(actionId: "x.user_tweets_v1") {
            let resolved = try await resolveUserIDOAuth1(input: input)
            let query = userTweetsQuery(input: input)
            let url = apiURL("/2/users/\(percentEncode(resolved.id))/tweets")
            let auth = try await oauth1AuthHeader(method: "GET", url: url, query: query)
            let (status, data) = try await httpGET(url, headers: ["Authorization": auth], query: query)
            guard (200..<300).contains(status) else {
                return httpFailureEnvelope(actionId: "x.user_tweets_v1", statusCode: status, data: data)
            }
            let payload = try parseJSONObject(data)
            var fields = tweetsAndMetaFields(payload)
            fields["user_id"] = .string(resolved.id)
            if let username = resolved.username { fields["username"] = .string(username) }
            return completedEnvelope(actionId: "x.user_tweets_v1", fields: fields)
        }
    }

    private static func loadOAuth2Token() throws -> [String: Any] {
        let path = oauth2TokenPath()
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XActionError(
                "missing_oauth2_token",
                detail: "X is not connected. Connect X under NativeAgent Connectors before running this action."
            )
        }
        let data = try Data(contentsOf: path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XActionError(
                "invalid_oauth2_token",
                detail: "NativeAgent's saved X authorization is invalid. Reconnect X under Connectors."
            )
        }
        return obj
    }

    private static func saveOAuth2Token(_ tokens: [String: Any]) throws {
        let path = oauth2TokenPath()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: tokens, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: path.path)
    }

    /// 2026-06-06 fix: gate `currentBearer` through an actor so two
    /// concurrent expired-token actions can't both POST a refresh against
    /// the SAME refresh_token. X rotates refresh tokens on success — one
    /// refresh would invalidate the other's `refresh_token` and turn a
    /// good call into `refresh_failed`.
    ///
    /// Swift actors are RE-ENTRANT across `await` suspensions, so a naive
    /// `await currentBearerLocked()` inside the actor still lets a second
    /// caller enter the actor while the first is awaiting the refresh
    /// network call. The in-flight-Task pattern coalesces all concurrent
    /// callers onto ONE refresh: the first caller starts the Task, every
    /// other caller awaits the same Task's value, and once the Task
    /// completes (success or failure) `inFlight` is cleared so the next
    /// expired call can start fresh.
    private actor RefreshGate {
        static let shared = RefreshGate()
        private var inFlight: Task<String, Error>?

        func resolveBearer() async throws -> String {
            if let existing = inFlight {
                return try await existing.value
            }
            let task = Task { try await XConnectorActions.currentBearerLocked() }
            inFlight = task
            defer { inFlight = nil }
            return try await task.value
        }
    }

    private static func currentBearer() async throws -> String {
        try await RefreshGate.shared.resolveBearer()
    }

    fileprivate static func currentBearerLocked() async throws -> String {
        var tokens = try loadOAuth2Token()
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            throw XActionError("missing_access_token", detail: "X OAuth2 token file is missing access_token.")
        }
        let expiresAt = Double((tokens["expires_at"] as? String) ?? "") ?? 0
        let now = Date().timeIntervalSince1970
        if expiresAt > now + 60 {
            return accessToken
        }

        guard let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw XActionError("missing_refresh_token", detail: "X OAuth2 token is expired and refresh_token is missing.")
        }
        guard let clientID = resolveClientID(), !clientID.isEmpty else {
            throw XActionError("refresh_disabled", detail: "X OAuth2 token refresh requires NATIVE_AGENT_X_CLIENT_ID env var OR a Swift-native app file at <dataRoot>/connectors/x/oauth_app.json with {client_id, client_secret?}.")
        }

        let url = URL(string: "https://api.twitter.com/2/oauth2/token")!
        let (status, data) = try await httpFormPOST(url, headers: [
            "Content-Type": "application/x-www-form-urlencoded"
        ], formBody: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID)
        ])
        guard status == 200 else {
            throw XActionError("refresh_failed", detail: "X OAuth2 refresh HTTP \(status): \(bodyExcerpt(data))")
        }
        let obj = try parseJSONObject(data)
        guard let refreshedAccess = obj["access_token"] as? String, !refreshedAccess.isEmpty else {
            throw XActionError("refresh_invalid", detail: "X OAuth2 refresh response did not include access_token.")
        }

        let expiresIn = numericDouble(obj["expires_in"]) ?? 0
        let refreshedAt = Date()
        tokens["access_token"] = refreshedAccess
        if let refreshedRefresh = obj["refresh_token"] as? String, !refreshedRefresh.isEmpty {
            tokens["refresh_token"] = refreshedRefresh
        }
        tokens["token_type"] = (obj["token_type"] as? String) ?? (tokens["token_type"] as? String) ?? "bearer"
        tokens["scope"] = (obj["scope"] as? String) ?? (tokens["scope"] as? String) ?? ""
        tokens["expires_at"] = String(refreshedAt.timeIntervalSince1970 + expiresIn)
        tokens["saved_at"] = iso(refreshedAt)
        tokens["provider"] = (tokens["provider"] as? String) ?? "x"
        try saveOAuth2Token(tokens)
        return refreshedAccess
    }

    private static func httpGET(_ url: URL, bearer: String, query: [(String, String)] = []) async throws -> (Int, Data) {
        try await httpGET(url, headers: ["Authorization": "Bearer \(bearer)"], query: query)
    }

    private static func httpGET(_ url: URL, headers: [String: String], query: [(String, String)] = []) async throws -> (Int, Data) {
        var request = URLRequest(url: appendQuery(query, to: url))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XActionError("invalid_response", detail: "X API returned a non-HTTP response.")
        }
        return (http.statusCode, data)
    }

    private static func httpJSONPOST(_ url: URL, bearer: String, body: [String: Any]) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XActionError("invalid_response", detail: "X API returned a non-HTTP response.")
        }
        return (http.statusCode, data)
    }

    private static func httpFormPOST(_ url: URL, headers: [String: String], formBody: [(String, String)]) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = formEncode(formBody).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XActionError("invalid_response", detail: "X API returned a non-HTTP response.")
        }
        return (http.statusCode, data)
    }

    private static func oauth1AuthHeader(method: String, url: URL, query: [(String, String)], formBody: [(String, String)] = []) async throws -> String {
        let credentials = try loadOAuth1Credentials()
        var oauthParams: [(String, String)] = [
            ("oauth_consumer_key", credentials.apiKey),
            ("oauth_nonce", UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
            ("oauth_signature_method", "HMAC-SHA1"),
            ("oauth_timestamp", String(Int(Date().timeIntervalSince1970))),
            ("oauth_token", credentials.accessToken),
            ("oauth_version", "1.0")
        ]

        let encodedParams = (query + formBody + oauthParams).map { pair in
            (percentEncode(pair.0), percentEncode(pair.1))
        }
        let sortedParams = encodedParams.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let normalizedPairs = sortedParams.map { pair in
            pair.0 + "=" + pair.1
        }
        let normalizedParams = normalizedPairs.joined(separator: "&")
        let baseString = [
            method.uppercased(),
            baseURLString(url),
            normalizedParams
        ].map(percentEncode).joined(separator: "&")
        let signingKey = "\(percentEncode(credentials.apiSecret))&\(percentEncode(credentials.accessTokenSecret))"
        let signatureBytes = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(baseString.utf8),
            using: SymmetricKey(data: Data(signingKey.utf8))
        )
        let signature = Data(signatureBytes).base64EncodedString()
        oauthParams.append(("oauth_signature", signature))
        let headerParams = oauthParams
            .sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            .map { "\(percentEncode($0.0))=\"\(percentEncode($0.1))\"" }
            .joined(separator: ", ")
        return "OAuth \(headerParams)"
    }

    private static func loadOAuth1Secrets() throws -> [String: Any] {
        let path = oauth1SecretsPath()
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XActionError("missing_oauth1_credentials", detail: "Missing X OAuth1 credentials at \(path.path).")
        }
        let data = try Data(contentsOf: path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XActionError("invalid_oauth1_credentials", detail: "X OAuth1 credentials file is not a JSON object: \(path.path)")
        }
        return obj
    }

    private static func loadOAuth1Credentials() throws -> OAuth1Credentials {
        let obj = try loadOAuth1Secrets()
        func require(_ key: String) throws -> String {
            guard let value = obj[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw XActionError("missing_oauth1_credential", detail: "X OAuth1 credentials file is missing \(key).")
            }
            return value
        }
        return OAuth1Credentials(
            apiKey: try require("api_key"),
            apiSecret: try require("api_secret"),
            accessToken: try require("access_token"),
            accessTokenSecret: try require("access_token_secret")
        )
    }

    private static func authenticatedUserIDBearer(bearer: String) async throws -> String {
        if let cached = await userIDCache.get() { return cached }
        let url = apiURL("/2/users/me")
        let (status, data) = try await httpGET(url, bearer: bearer, query: [("user.fields", "id")])
        guard (200..<300).contains(status) else {
            throw XActionError("me_lookup_failed", detail: "X /2/users/me HTTP \(status): \(bodyExcerpt(data))")
        }
        let id = try userID(from: data)
        await userIDCache.set(id)
        return id
    }

    private static func authenticatedUserIDOAuth1() async throws -> String {
        if let cached = await userIDCache.get() { return cached }
        let url = apiURL("/2/users/me")
        let query = [("user.fields", "id")]
        let auth = try await oauth1AuthHeader(method: "GET", url: url, query: query)
        let (status, data) = try await httpGET(url, headers: ["Authorization": auth], query: query)
        guard (200..<300).contains(status) else {
            throw XActionError("me_lookup_failed", detail: "X /2/users/me OAuth1 HTTP \(status): \(bodyExcerpt(data))")
        }
        let id = try userID(from: data)
        await userIDCache.set(id)
        return id
    }

    private static func resolveUserIDBearer(input: [String: JSONValue], bearer: String) async throws -> ResolvedUser {
        if let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return ResolvedUser(id: id, username: normalizedUsername(inputString(input["username"])))
        }
        guard let username = normalizedUsername(inputString(input["username"])) else {
            throw XActionError("missing_input", detail: "x.user_tweets requires either id or username.")
        }
        let url = apiURL("/2/users/by/username/\(percentEncode(username))")
        let (status, data) = try await httpGET(url, bearer: bearer, query: [("user.fields", "id,username,name")])
        guard (200..<300).contains(status) else {
            throw XActionError("user_lookup_failed", detail: "X username lookup HTTP \(status): \(bodyExcerpt(data))")
        }
        return try resolvedUser(from: data, fallbackUsername: username)
    }

    private static func resolveUserIDOAuth1(input: [String: JSONValue]) async throws -> ResolvedUser {
        if let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return ResolvedUser(id: id, username: normalizedUsername(inputString(input["username"])))
        }
        guard let username = normalizedUsername(inputString(input["username"])) else {
            throw XActionError("missing_input", detail: "x.user_tweets_v1 requires either id or username.")
        }
        let url = apiURL("/2/users/by/username/\(percentEncode(username))")
        let query = [("user.fields", "id,username,name")]
        let auth = try await oauth1AuthHeader(method: "GET", url: url, query: query)
        let (status, data) = try await httpGET(url, headers: ["Authorization": auth], query: query)
        guard (200..<300).contains(status) else {
            throw XActionError("user_lookup_failed", detail: "X username lookup OAuth1 HTTP \(status): \(bodyExcerpt(data))")
        }
        return try resolvedUser(from: data, fallbackUsername: username)
    }

    private static func userID(from data: Data) throws -> String {
        let payload = try parseJSONObject(data)
        guard let dataObj = payload["data"] as? [String: Any],
              let id = dataObj["id"] as? String,
              !id.isEmpty else {
            throw XActionError("invalid_user_response", detail: "X /2/users/me response did not include data.id.")
        }
        return id
    }

    private static func resolvedUser(from data: Data, fallbackUsername: String) throws -> ResolvedUser {
        let payload = try parseJSONObject(data)
        guard let dataObj = payload["data"] as? [String: Any],
              let id = dataObj["id"] as? String,
              !id.isEmpty else {
            throw XActionError("invalid_user_response", detail: "X username lookup response did not include data.id.")
        }
        return ResolvedUser(id: id, username: (dataObj["username"] as? String) ?? fallbackUsername)
    }

    private static func timelineQuery(input: [String: JSONValue]) -> [(String, String)] {
        var query: [(String, String)] = [
            ("max_results", String(clampedInt(input["max"], defaultValue: 25, min: 1, max: 100))),
            ("tweet.fields", tweetFields)
        ]
        if let exclude = inputString(input["exclude"])?.trimmingCharacters(in: .whitespacesAndNewlines), !exclude.isEmpty {
            query.append(("exclude", exclude))
        }
        if let next = inputString(input["next_token"])?.trimmingCharacters(in: .whitespacesAndNewlines), !next.isEmpty {
            query.append(("pagination_token", next))
        }
        return query
    }

    private static func userTweetsQuery(input: [String: JSONValue]) -> [(String, String)] {
        var query: [(String, String)] = [
            ("max_results", String(clampedInt(input["max"], defaultValue: 25, min: 1, max: 100))),
            ("tweet.fields", tweetFields)
        ]
        if let exclude = inputString(input["exclude"])?.trimmingCharacters(in: .whitespacesAndNewlines), !exclude.isEmpty {
            query.append(("exclude", exclude))
        }
        if let next = inputString(input["next_token"])?.trimmingCharacters(in: .whitespacesAndNewlines), !next.isEmpty {
            query.append(("pagination_token", next))
        }
        return query
    }

    private static func tweetsAndMetaFields(_ payload: [String: Any]) -> [String: JSONValue] {
        [
            "tweets": JSONValue(fromFoundation: payload["data"] ?? []),
            "meta": JSONValue(fromFoundation: payload["meta"] ?? [:])
        ]
    }

    private static func parseJSONObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XActionError("invalid_json", detail: "X API returned a non-object JSON payload.")
        }
        return obj
    }

    private static func run(actionId: String, _ body: () async throws -> JSONValue) async -> JSONValue {
        do {
            return try await body()
        } catch {
            return failureEnvelope(actionId: actionId, error: error)
        }
    }

    private static func baseEnvelope(actionId: String, status: String) -> [String: JSONValue] {
        [
            "status": .string(status),
            "actionId": .string(actionId),
            "source": .string("x")
        ]
    }

    private static func completedEnvelope(actionId: String, fields: [String: JSONValue]) -> JSONValue {
        var obj = baseEnvelope(actionId: actionId, status: "completed")
        for (key, value) in fields {
            obj[key] = value
        }
        return .object(obj)
    }

    private static func failureEnvelope(actionId: String, error: Error) -> JSONValue {
        if let actionError = error as? XActionError {
            return failureEnvelope(actionId: actionId, short: actionError.message, detail: actionError.detail)
        }
        return failureEnvelope(actionId: actionId, short: "failed", detail: error.localizedDescription)
    }

    private static func failureEnvelope(actionId: String, short: String, detail: String) -> JSONValue {
        var obj = baseEnvelope(actionId: actionId, status: "failed")
        obj["error"] = .string(short)
        obj["detail"] = .string(detail)
        return .object(obj)
    }

    private static func httpFailureEnvelope(actionId: String, statusCode: Int, data: Data) -> JSONValue {
        let envelope = failureEnvelope(
            actionId: actionId,
            short: "http_\(statusCode)",
            detail: "X API HTTP \(statusCode): \(bodyExcerpt(data))"
        )
        // Carry the code as a typed field too — consumers (the chat-side
        // OAuth1 fallback) were matching obj["statusCode"], which this
        // envelope never had, making the fallback dead code (audit 2026-06-09).
        guard case .object(var obj) = envelope else { return envelope }
        obj["statusCode"] = .int(Int64(statusCode))
        return .object(obj)
    }

    private static func appendQuery(_ query: [(String, String)], to url: URL) -> URL {
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.append(contentsOf: query.map { URLQueryItem(name: $0.0, value: $0.1) })
        components.queryItems = items
        return components.url ?? url
    }

    private static func formEncode(_ items: [(String, String)]) -> String {
        items.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func baseURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.components(separatedBy: "?").first ?? url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString.components(separatedBy: "?").first ?? url.absoluteString
    }

    private static func apiURL(_ path: String) -> URL {
        URL(string: "\(apiBase)\(path)")!
    }

    private static func oauth2TokenPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("oauth_tokens", isDirectory: true)
            .appendingPathComponent("x.json")
    }

    /// Resolve the X OAuth 2.0 client_id from Swift-native state only.
    /// `NATIVE_AGENT_X_CLIENT_ID` env wins; otherwise read the Swift-owned
    /// app credentials file at `<dataRoot>/connectors/x/oauth_app.json`
    /// (parallel to the Swift-owned `auth.json` written by NativeOAuthFlow).
    /// Retired runtime `config/config.json` is intentionally NOT consulted —
    /// Swift owns its own config locations.
    private static func resolveClientID() -> String? {
        let env = ProcessInfo.processInfo.environment["NATIVE_AGENT_X_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        let appPath = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("x", isDirectory: true)
            .appendingPathComponent("oauth_app.json")
        guard let data = try? Data(contentsOf: appPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = root["client_id"] as? String
        else { return nil }
        let trimmed = cid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func oauth1SecretsPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent("x.json")
    }

    private static func bodyExcerpt(_ data: Data) -> String {
        String(data: data.prefix(400), encoding: .utf8) ?? "<\(min(data.count, 400)) binary bytes>"
    }

    private static func inputString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    private static func inputInt(_ raw: JSONValue?) -> Int? {
        switch raw {
        case .int(let value): return Int(value)
        case .double(let value): return Int(value)
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    private static func clampedInt(_ raw: JSONValue?, defaultValue: Int, min minValue: Int, max maxValue: Int) -> Int {
        max(minValue, min(inputInt(raw) ?? defaultValue, maxValue))
    }

    private static func normalizedUsername(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let stripped = value.hasPrefix("@") ? String(value.dropFirst()) : value
        return stripped.isEmpty ? nil : stripped
    }

    private static func numericDouble(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as String: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func mask(_ value: String) -> String {
        "\(value.prefix(4))...\(value.suffix(4))"
    }

    private struct OAuth1Credentials {
        let apiKey: String
        let apiSecret: String
        let accessToken: String
        let accessTokenSecret: String
    }

    private struct ResolvedUser {
        let id: String
        let username: String?
    }

    private struct XActionError: LocalizedError {
        let message: String
        let detail: String

        init(_ message: String, detail: String) {
            self.message = message
            self.detail = detail
        }

        var errorDescription: String? { detail }
    }

    private actor UserIDCache {
        private var value: String?

        func get() -> String? {
            value
        }

        func set(_ value: String) {
            self.value = value
        }
    }
}

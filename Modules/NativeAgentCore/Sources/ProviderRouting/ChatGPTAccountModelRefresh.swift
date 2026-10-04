import Foundation
import NativeAgentShared
import PersistenceCore

/// Account discovery is UI/sign-in maintenance, never part of provider dispatch.
public actor ChatGPTAccountModelRefresh {
    public static let shared = ChatGPTAccountModelRefresh()
    public static let didRefresh = Notification.Name("ChatGPTAccountModelRefresh.didRefresh")
    // Codex's ModelsClient sends its protocol version as client_version.
    private static let clientVersion = "0.159.0"
    private struct CredentialKey: Hashable {
        let root: URL
        let accessToken: String
    }
    private var flights: [CredentialKey: Task<Bool, Error>] = [:]
    private var failedAt: [CredentialKey: Date] = [:]

    public static func cacheURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("models_cache.json")
    }

    /// Missing/unreadable/unbound caches are stale; successful reads last 24 hours.
    /// Automatic failures cool down for five minutes; explicit refresh bypasses it.
    @discardableResult
    public func refresh(dataRoot: URL, force: Bool = false) async throws -> Bool {
        let root = dataRoot.standardizedFileURL
        let authPath = NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: root)
        guard let token = OpenAIOAuthDirectAdapter.storedAccessToken(at: authPath) else { return false }
        var key = CredentialKey(root: root, accessToken: token)
        if !force {
            if let failure = failedAt[key], Date().timeIntervalSince(failure) < 300 { return false }
            if Self.isFresh(dataRoot: root, authPath: authPath) { return false }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let adapter = OpenAIOAuthDirectAdapter(session: session, authPathOverride: authPath)
        let context: CodexOAuthAccessContext
        do {
            try Self.validateCachePath(dataRoot: root, authPath: authPath)
            context = try await adapter.codexAccessContext()
        } catch {
            failedAt[key] = Date()
            throw error
        }
        // Token renewal is serialized by the adapter; discovery joins using
        // the token it will actually send, including its failure cooldown.
        key = CredentialKey(root: root, accessToken: context.accessToken)
        if let flight = flights[key] { return try await flight.value }
        if !force {
            if let failure = failedAt[key], Date().timeIntervalSince(failure) < 300 { return false }
            if Self.isFresh(dataRoot: root, authPath: authPath) { return false }
        }
        let flight = Task {
            try await Self.fetch(dataRoot: root, authPath: authPath, context: context, session: session)
        }
        flights[key] = flight
        defer { flights[key] = nil }
        do {
            let changed = try await flight.value
            failedAt = failedAt.filter { $0.key.root != root }
            return changed
        } catch {
            failedAt = failedAt.filter { $0.key.root != root }
            failedAt[key] = Date()
            throw error
        }
    }

    private static func isFresh(dataRoot: URL, authPath: URL) -> Bool {
        guard let bytes = try? Data(contentsOf: cacheURL(dataRoot: dataRoot)),
              let cache = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let stamp = cache["fetched_at"] as? String,
              let account = cache["nativeagent_account_id"] as? String,
              let token = OpenAIOAuthDirectAdapter.storedAccessToken(at: authPath),
              account == (try? OpenAIOAuthDirectAdapter(authPathOverride: authPath)
                .currentAccountID(accessToken: token)),
              let models = cache["models"] as? [[String: Any]], !models.isEmpty else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: stamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let fetched = fractional ?? formatter.date(from: stamp) else { return false }
        let age = Date().timeIntervalSince(fetched)
        return age >= 0 && age < 86_400
    }

    private static func validateCachePath(dataRoot: URL, authPath: URL) throws {
        // Never follow a codex_home/auth/cache symlink into the shared CLI home.
        let parent = cacheURL(dataRoot: dataRoot).deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath()
            .appendingPathComponent("codex_home", isDirectory: true),
              authPath.resolvingSymlinksInPath() == parent.appendingPathComponent("auth.json"),
              cacheURL(dataRoot: dataRoot).resolvingSymlinksInPath()
                == parent.appendingPathComponent("models_cache.json"),
              !parent.resolvingSymlinksInPath().path.hasPrefix(
                OpenAIOAuthDirectAdapter.defaultUserCodexHome().path + "/"
              ), parent != OpenAIOAuthDirectAdapter.defaultUserCodexHome() else {
            throw failure("The app-owned model cache path is unavailable.")
        }
    }

    private static func fetch(
        dataRoot: URL, authPath: URL, context: CodexOAuthAccessContext, session: URLSession
    ) async throws -> Bool {
        let parent = cacheURL(dataRoot: dataRoot).deletingLastPathComponent()
        var request = URLRequest(url: URL(string:
            "https://chatgpt.com/backend-api/codex/models?client_version=\(clientVersion)")!)
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(context.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue(OpenAIOAuthDirectAdapter.codexBackendOriginator, forHTTPHeaderField: "originator")
        request.setValue(OpenAIOAuthDirectAdapter.codexBackendUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure("ChatGPT account model refresh failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        guard var cache = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let models = cache["models"] as? [[String: Any]], !models.isEmpty,
              models.allSatisfy({ ($0["slug"] as? String)?.isEmpty == false
                && $0["display_name"] is String
                && $0["supported_reasoning_levels"] is [[String: Any]] }) else {
            throw failure("ChatGPT returned an invalid account model catalog.")
        }
        cache["fetched_at"] = ISO8601DateFormatter().string(from: Date())
        cache["client_version"] = clientVersion
        cache["etag"] = http.value(forHTTPHeaderField: "ETag")
        cache["nativeagent_account_id"] = context.accountID
        let saved = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
        try CredentialFileLock.withLock(authPath) {
            guard OpenAIOAuthDirectAdapter.storedAccessToken(at: authPath) == context.accessToken else {
                throw OAuthRequestAccount.changed("openai_oauth_direct")
            }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try saved.write(to: cacheURL(dataRoot: dataRoot), options: [.atomic])
        }
        NotificationCenter.default.post(name: didRefresh, object: dataRoot)
        return true
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ChatGPTAccountModelRefresh", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

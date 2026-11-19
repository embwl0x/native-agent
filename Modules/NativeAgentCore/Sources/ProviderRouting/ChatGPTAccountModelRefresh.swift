import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `ChatGPTAccountModelRefresh.swift` | `ChatGPTAccountModelRefresh`: account discovery outside dispatch; says when it cannot ask |

/// Account discovery is UI/sign-in maintenance, never part of provider dispatch.
public actor ChatGPTAccountModelRefresh {
    public static let shared = ChatGPTAccountModelRefresh()
    public static let didRefresh = Notification.Name("ChatGPTAccountModelRefresh.didRefresh")
    private struct CredentialKey: Hashable {
        let root: URL
        let accessToken: String
    }
    private var flights: [CredentialKey: Task<Bool, Error>] = [:]
    private var failures: [CredentialKey: any Error] = [:]

    public static func cacheURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("models_cache.json")
    }

    /// What an explicit refresh says when the selected sign-in was adopted from the Codex command-line tool: the app never writes that tool's files,
    /// so its list is the tool's own and cannot be asked for here.
    public static let adoptedSignInCannotRefresh = """
        this sign-in comes from the Codex command-line tool, so its model list is the tool's own and the app cannot refresh it. Sign in with \
        ChatGPT in the app to get a list the app can refresh.
        """

    @discardableResult
    public func refresh(dataRoot: URL, force: Bool = false) async throws -> Bool {
        let root = dataRoot.standardizedFileURL
        let authPath = ChatGPTTransport.preferredAuthPath(dataRoot: root)
        // This maintenance operation writes only the app-owned account cache; do not discover an inactive sign-in when runtime selected another one.
        // The only other selected path is an adopted command-line one. An explicit refresh says it could not ask only when that path holds a
        // ChatGPT session; with none (the tool signed in with an API key, or nothing usable) there is nothing to refresh and nothing to report,
        // as before. Its unreadable bytes stay readiness's to report.
        guard authPath.standardizedFileURL == NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: root).standardizedFileURL else {
            guard force, (try? ChatGPTTransport.storedAccessToken(at: authPath)) != nil else { return false }
            throw Self.failure(Self.adoptedSignInCannotRefresh)
        }
        guard let token = try ChatGPTTransport.storedAccessToken(at: authPath) else { return false }
        var key = CredentialKey(root: root, accessToken: token)
        if !force, let failure = failures[key] { throw failure }
        do {
            try Self.validateCachePath(dataRoot: root, authPath: authPath)
            if !force, try Self.isCurrent(dataRoot: root, authPath: authPath, token: token) { return false }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = .infinity
            config.timeoutIntervalForResource = .infinity
            config.waitsForConnectivity = true
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let adapter = ChatGPTTransport(session: session, authPathOverride: authPath)
            let context = try await adapter.codexAccessContext()
            // Token renewal is serialized by the adapter; join discovery for the credential actually sent.
            key = CredentialKey(root: root, accessToken: context.accessToken)
            if let flight = flights[key] {
                return try await withTaskCancellationHandler { try await flight.value } onCancel: { flight.cancel() }
            }
            if !force, let failure = failures[key] { throw failure }
            if !force, try Self.isCurrent(dataRoot: root, authPath: authPath, token: context.accessToken) { return false }
            let flight = Task {
                try await Self.fetch(dataRoot: root, authPath: authPath, context: context, session: session)
            }
            flights[key] = flight
            defer { flights[key] = nil }
            let changed = try await withTaskCancellationHandler { try await flight.value } onCancel: { flight.cancel() }
            failures.removeValue(forKey: key)
            return changed
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled, !Task.isCancelled { failures[key] = error }
            throw error
        }
    }

    private static func isCurrent(dataRoot: URL, authPath: URL, token: String) throws -> Bool {
        let url = cacheURL(dataRoot: dataRoot)
        let bytes: Data
        do { bytes = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return false }
        let cache = try JSONDecoder().decode(CodexAccountModelCatalog.Cache.self, from: bytes)
        guard let account = cache.accountID,
              cache.clientVersion == ChatGPTTransport.codexModelListVersion
                || (cache.clientVersion == ChatGPTTransport.codexClientVersion && cache.fullListRefusal != nil),
              let saved = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
              -saved.timeIntervalSinceNow < 86_400 else { return false }
        return account == (try ChatGPTTransport(authPathOverride: authPath).currentAccountID(accessToken: token))
    }

    private static func validateCachePath(dataRoot: URL, authPath: URL) throws {
        // Never follow a codex_home/auth/cache symlink into the shared CLI home.
        let parent = cacheURL(dataRoot: dataRoot).deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath()
            .appendingPathComponent("codex_home", isDirectory: true),
              authPath.resolvingSymlinksInPath() == parent.appendingPathComponent("auth.json"),
              cacheURL(dataRoot: dataRoot).resolvingSymlinksInPath()
                == parent.appendingPathComponent("models_cache.json"),
              NativeAgentWorkspaceRoot.relativePath(parent.resolvingSymlinksInPath().path,
                under: ChatGPTTransport.defaultUserCodexHome().path)?.isEmpty != false,
              parent != ChatGPTTransport.defaultUserCodexHome() else {
            throw failure("The app-owned model cache path is unavailable.")
        }
    }

    private static func fetch(
        dataRoot: URL, authPath: URL, context: CodexOAuthAccessContext, session: URLSession
    ) async throws -> Bool {
        var version = ChatGPTTransport.codexModelListVersion
        var refusal: String?
        while true {
            try Task.checkCancellation()
            guard let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=\(version)") else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = .infinity
            request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(context.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(ChatGPTTransport.codexBackendOriginator, forHTTPHeaderField: "originator")
            request.setValue(ChatGPTTransport.codexBackendUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let http: HTTPURLResponse
            let models: [CodexAccountModelCatalog.Record]
            var cache: [String: Any]
            do {
                let (bytes, response) = try await session.data(for: request)
                guard let reply = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard reply.statusCode == 200 else { throw failure("ChatGPT account model refresh failed (HTTP \(reply.statusCode)).") }
                http = reply
                do {
                    models = try JSONDecoder().decode(CodexAccountModelCatalog.Cache.self, from: bytes).models
                    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                        throw failure("ChatGPT returned an invalid account model catalog.")
                    }
                    cache = object
                } catch is DecodingError {
                    throw failure("ChatGPT returned an invalid account model catalog.")
                }
            } catch {
                try Task.checkCancellation()
                guard version == ChatGPTTransport.codexModelListVersion,
                      !(error is CancellationError), (error as? URLError)?.code != .cancelled else { throw error }
                if let saved = CodexAccountModelCatalog.readCache(at: cacheURL(dataRoot: dataRoot), dataRoot: dataRoot),
                   saved.accountID == context.accountID, saved.clientVersion == ChatGPTTransport.codexModelListVersion { throw error }
                try CredentialFileLock.withLock(authPath) {
                    guard try ChatGPTTransport.storedAccessToken(at: authPath) == context.accessToken else {
                        throw OAuthRequestAccount.changed("openai_oauth_direct")
                    }
                }
                refusal = ContextSecretContentPolicy.redactedFragment(error.localizedDescription)
                version = ChatGPTTransport.codexClientVersion
                continue
            }
            typealias Keys = CodexAccountModelCatalog.Cache.CodingKeys
            cache["fetched_at"] = NativeTimestampFormat.plainZulu(Date())
            cache[Keys.clientVersion.rawValue] = version
            cache["etag"] = http.value(forHTTPHeaderField: "ETag")
            cache[Keys.accountID.rawValue] = context.accountID
            cache[Keys.fullListRefusal.rawValue] = refusal
            let saved = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
            let url = cacheURL(dataRoot: dataRoot)
            let previous = try CredentialFileLock.withLock(authPath) {
                try Task.checkCancellation()
                guard try ChatGPTTransport.storedAccessToken(at: authPath) == context.accessToken else {
                    throw OAuthRequestAccount.changed("openai_oauth_direct")
                }
                let previous = CodexAccountModelCatalog.readCache(at: url, dataRoot: dataRoot)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(saved, to: url)
                return previous
            }
            if refusal == nil, let previous, previous.accountID == context.accountID,
               previous.clientVersion == ChatGPTTransport.codexModelListVersion {
                var known = Set(previous.models.filter { $0.visibility == nil || $0.visibility == "list" }
                    .map { $0.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                let route = "openai_oauth_direct"
                for model in models where (model.visibility == nil || model.visibility == "list") && model.supportedInAPI != false {
                    let id = model.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard known.insert(id).inserted else { continue }
                    Attention.post(Happening(.world, subject: "providers:\(route)", door: "providers",
                        words: "OpenAI lists a new model on your ChatGPT account: \(model.displayName)", once: "model:\(route):\(id)"), dataRoot: dataRoot)
                }
            }
            NotificationCenter.default.post(name: didRefresh, object: dataRoot)
            return true
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ChatGPTAccountModelRefresh", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

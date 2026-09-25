import Foundation
import Security
import PersistenceCore

/// One bounded exchange. This layer never retries a potentially accepted send.
public enum AgentPeerHTTP {
    public static let maximumResponseBytes = 2 * 1_024 * 1_024
    /// Test-scoped transport injection; production callers cannot configure it.
    @TaskLocal static var fixtureConfiguration: (@Sendable () -> URLSessionConfiguration)?
    public struct Response: Sendable, Equatable {
        public let statusCode: Int
        /// Nil for an empty or non-JSON response; raw bodies are never errors.
        public let json: JSONValue?
        public var events: [JSONValue] = []
        public var interrupted = false
    }
    public enum TransportError: Error, LocalizedError, Equatable {
        case invalidURL, invalidRequest, tooLarge, redirected, unavailable, cancelled
        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Peer URL must use HTTPS or exact loopback HTTP without embedded credentials or a fragment."
            case .invalidRequest: return "Peer request is invalid."
            case .tooLarge: return "Peer response exceeded the bounded capture limit; delivery outcome may be unknown."
            case .redirected: return "Peer redirect was refused; verify the configured endpoint before sending again."
            case .unavailable: return "Peer exchange did not finish; delivery outcome may be unknown."
            case .cancelled: return "Peer exchange was cancelled; this does not cancel remote work."
            }
        }
    }

    public static func send(_ request: AgentA2AWire.Request, bearerToken: String? = nil,
                            timeout: TimeInterval = 45) async throws -> Response {
        if request.grpcMethod != nil {
            return try await AgentA2AGRPC.send(request, bearerToken: bearerToken, timeout: timeout)
        }
        let configuration = fixtureConfiguration?() ?? .ephemeral
        return try await exchange(url: request.url, method: request.httpMethod, headers: request.headers,
                                  body: request.body, bearerToken: bearerToken, timeout: timeout,
                                  configuration: configuration)
    }

    public static func get(_ url: URL, bearerToken: String? = nil, headers: [String: String] = [:],
                           timeout: TimeInterval = 30) async throws -> Response {
        let configuration = fixtureConfiguration?() ?? .ephemeral
        return try await exchange(url: url, method: "GET", headers: headers, body: nil,
                                  bearerToken: bearerToken, timeout: timeout, configuration: configuration)
    }

    /// Automatic discovery has no credentials, DNS lookup, redirects or system proxy.
    static func getLoopbackCard(_ url: URL) async throws -> Response {
        try validateLoopbackCandidate(url)
        let configuration = fixtureConfiguration?() ?? .ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        return try await exchange(url: url, method: "GET", headers: [:], body: nil,
                                  bearerToken: nil, timeout: 0.6, configuration: configuration)
    }

    static func validateLoopbackCandidate(_ url: URL) throws {
        guard url.scheme == "http", ["127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              (1...65535).contains(url.port ?? 80) else { throw TransportError.invalidURL }
    }

    static func exchange(url: URL, method: String, headers: [String: String], body: JSONValue?,
                         bearerToken: String?, timeout: TimeInterval,
                         configuration: URLSessionConfiguration = .ephemeral) async throws -> Response {
        try validateURL(url)
        guard ["GET", "POST", "DELETE"].contains(method), timeout.isFinite, timeout > 0, timeout <= 600 else { throw TransportError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers {
            guard !key.contains(where: { $0.isNewline }), !value.contains(where: { $0.isNewline }),
                  !["authorization", "proxy-authorization", "cookie", "host"].contains(key.lowercased()) else { throw TransportError.invalidRequest }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let bearerToken {
            guard validToken(bearerToken) else { throw TransportError.invalidRequest }
            request.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try body.serializedData(pretty: false)
            guard request.httpBody!.count <= maximumResponseBytes else { throw TransportError.invalidRequest }
        }
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let exchange = Exchange(streaming: headers["Accept"] == "text/event-stream")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: { exchange.cancel() }
    }

    public static func validateURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)) else {
            throw TransportError.invalidURL
        }
    }
    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384 && token.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    private final class Exchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Response, Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var cancelled = false
        private var finished = false
        private var data = Data()
        private var status: Int?
        private let streaming: Bool
        private var eventStream = false

        init(streaming: Bool) { self.streaming = streaming }

        func start(request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<Response, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock(); continuation.resume(throwing: TransportError.cancelled); return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            finish(.failure(TransportError.cancelled))
        }
        private func finish(_ result: Swift.Result<Response, Error>) {
            lock.lock()
            guard !finished, let continuation else { lock.unlock(); return }
            finished = true
            self.continuation = nil
            let session = self.session
            self.session = nil
            self.task = nil
            lock.unlock()
            session?.invalidateAndCancel()
            continuation.resume(with: result)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
            finish(.failure(TransportError.redirected))
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.rejectProtectionSpace, nil) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse else {
                completionHandler(.cancel); finish(.failure(TransportError.unavailable)); return
            }
            guard !(300...399).contains(response.statusCode) else {
                completionHandler(.cancel); finish(.failure(TransportError.redirected)); return
            }
            guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
                completionHandler(.cancel); finish(.failure(TransportError.tooLarge)); return
            }
            status = response.statusCode
            eventStream = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
            guard bytes.count <= maximumResponseBytes - data.count else {
                finish(.failure(TransportError.tooLarge)); return
            }
            data.append(bytes)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if streaming, eventStream, let status {
                // Only blank-line-delimited events are evidence. A truncated tail
                // and even a clean EOF do not establish task completion.
                do {
                    let events = try AgentA2AStream.events(in: data)
                    finish(.success(Response(statusCode: status, json: nil, events: events, interrupted: error != nil)))
                } catch { finish(.failure(TransportError.unavailable)) }
                return
            }
            guard error == nil, let status else { finish(.failure(TransportError.unavailable)); return }
            finish(.success(Response(statusCode: status, json: try? JSONValue.parse(data))))
        }
    }
}

/// Dedicated per-peer secrets. Never consults generic provider or bridge keys.
public enum AgentPeerCredentials {
    public static let unavailableDetail = "unavailable now - its key is missing; reconnect"

    /// The bearer-only door and current contact projections share this check.
    public static func resolve(_ token: String, peers: [AgentPeerContact],
                               readCredential: (String) throws -> String? = { try read(peerID: $0) }) -> AgentPeerContact? {
        guard AgentPeerHTTP.validToken(token) else { return nil }
        let matches = peers.filter { peer in
            guard peer.credentialKey == AgentPeerContact.credentialKey(for: peer.id),
                  let stored = try? readCredential(peer.id) else { return false }
            let a = Array(stored.utf8), b = Array(token.utf8)
            guard a.count == b.count else { return false }
            return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
        return matches.count == 1 ? matches.first : nil
    }

    public static func isAvailable(_ peer: AgentPeerContact, peers: [AgentPeerContact],
                                   readCredential: (String) throws -> String? = { try read(peerID: $0) }) -> Bool {
        // Local ACP sessions and desktop routes do not use a contact bearer.
        if peer.credentialKey == nil && (peer.transport == .acp || peer.transport == .desktop || peer.transport == .desktopChat) { return true }
        guard let token = try? readCredential(peer.id) else { return false }
        return resolve(token, peers: peers, readCredential: readCredential)?.id == peer.id
    }

    /// Pre-upgrade credentials remain valid for the same stable contact ID.
    static let legacyService = "com.nativeagent.agent-peer-bearer"

    /// This install's own peer bearers.
    static var service: String {
        guard let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.isEmpty else { return legacyService }
        return "\(legacyService).\(bundleID)"
    }
    public enum CredentialError: Error, LocalizedError, Equatable {
        case invalidPeer, invalidToken, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalidPeer: return "Peer credential identity is invalid."
            case .invalidToken: return "Peer bearer credential is invalid."
            case .unavailable: return "Peer credential could not be accessed in the dedicated Keychain store."
            }
        }
    }
    static func query(peerID: String) throws -> [String: Any] {
        try query(peerID: peerID, service: service)
    }
    static func query(peerID: String, service: String) throws -> [String: Any] {
        guard UUID(uuidString: peerID)?.uuidString.lowercased() == peerID else { throw CredentialError.invalidPeer }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: AgentPeerContact.credentialKey(for: peerID),
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    private static func readToken(peerID: String, service: String) throws -> String? {
        var query = try query(peerID: peerID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), AgentPeerHTTP.validToken(token) else { throw CredentialError.unavailable }
        return token
    }
    /// Prefer the install-scoped key; retain the legacy form indefinitely.
    /// Revocation removes both forms, so fallback cannot resurrect a key.
    public static func read(peerID: String) throws -> String? {
        guard automaticTestDataRoot() == nil else { throw CredentialError.unavailable }
        let (cached, generation) = cache.withLock { ($0.tokens[peerID], $0.generations[peerID, default: 0]) }
        if let cached { return cached }
        let token = try compatibleToken(service: service) { try readToken(peerID: peerID, service: $0) }
        // A write or delete that landed during the read wins; hold nothing.
        cache.withLock { if $0.generations[peerID, default: 0] == generation { $0.tokens[peerID] = .some(token) } }
        return token
    }
    /// 2026-09-25: every contact projection checks every peer's key, so one
    /// people list read the Keychain ~120 times (5.5k SecItemCopyMatching in
    /// 6h). Reads (a missing key too) are held in memory; this process is the
    /// only writer, and write/delete drop the entry and bump its generation
    /// so a read already in flight cannot put the old key back. Failures are
    /// not held.
    private static let cache = LockedPeerTokens()
    private final class LockedPeerTokens: @unchecked Sendable {
        private let lock = NSLock()
        struct State {
            var tokens: [String: String?] = [:]
            var generations: [String: Int] = [:]
        }
        private var state = State()
        func withLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&state)
        }
        func forget(_ peerID: String) {
            withLock { $0.tokens[peerID] = nil; $0.generations[peerID, default: 0] += 1 }
        }
    }
    static func compatibleToken(service: String, read: (String) throws -> String?) throws -> String? {
        if let current = try read(service) { return current }
        return service == legacyService ? nil : try read(legacyService)
    }
    public static func write(_ token: String, peerID: String) throws {
        let query = try query(peerID: peerID)
        defer { cache.forget(peerID) }
        guard AgentPeerHTTP.validToken(token) else { throw CredentialError.invalidToken }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecUseAuthenticationUI as String] = nil
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.unavailable }
    }
    public static func delete(peerID: String) throws {
        defer { cache.forget(peerID) }
        try revoke(service: service) { service in
            let status = SecItemDelete(try query(peerID: peerID, service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
        }
    }
    static func revoke(service: String, delete: (String) throws -> Void) throws {
        // Legacy first: a partial failure must never reveal an older secret.
        if service != legacyService { try delete(legacyService) }
        try delete(service)
    }
}

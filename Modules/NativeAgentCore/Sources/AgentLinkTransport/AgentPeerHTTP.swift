import Foundation
import PersistenceCore

/// One bounded exchange. This layer never retries a potentially accepted send.
public enum AgentPeerHTTP {
    public typealias LiveUpdateHandler = @Sendable (AgentA2AStream.LiveUpdate) async -> Void
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
                            timeout: TimeInterval = 45, liveUpdate: LiveUpdateHandler?) async throws -> Response {
        if request.grpcMethod != nil {
            return try await AgentA2AGRPC.send(request, bearerToken: bearerToken, timeout: timeout,
                liveUpdate: liveUpdate)
        }
        let configuration = fixtureConfiguration?() ?? .ephemeral
        return try await exchange(url: request.url, method: request.httpMethod, headers: request.headers,
                                  body: request.body, bearerToken: bearerToken, timeout: timeout,
                                  configuration: configuration, liveUpdate: liveUpdate,
                                  streamInterface: request.streamInterface, requestID: request.requestID,
                                  expectedTaskID: request.expectedTaskID)
    }

    public static func get(_ url: URL, bearerToken: String? = nil, headers: [String: String] = [:],
                           timeout: TimeInterval = 30, liveUpdate: LiveUpdateHandler?) async throws -> Response {
        let configuration = fixtureConfiguration?() ?? .ephemeral
        return try await exchange(url: url, method: "GET", headers: headers, body: nil,
                                  bearerToken: bearerToken, timeout: timeout, configuration: configuration, liveUpdate: liveUpdate)
    }

    /// Automatic discovery has no credentials, DNS lookup, redirects or system proxy.
    package static func getLoopbackCard(_ url: URL) async throws -> Response {
        try validateLoopbackCandidate(url)
        let configuration = fixtureConfiguration?() ?? .ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        return try await exchange(url: url, method: "GET", headers: [:], body: nil,
                                  bearerToken: nil, timeout: 0.6, configuration: configuration, liveUpdate: nil)
    }

    package static func validateLoopbackCandidate(_ url: URL) throws {
        guard url.scheme == "http", ["127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              (1...65535).contains(url.port ?? 80) else { throw TransportError.invalidURL }
    }

    static func exchange(url: URL, method: String, headers: [String: String], body: JSONValue?,
                         bearerToken: String?, timeout: TimeInterval,
                         configuration: URLSessionConfiguration = .ephemeral,
                         liveUpdate: LiveUpdateHandler?, streamInterface: AgentA2AWire.Interface? = nil,
                         requestID: String? = nil, expectedTaskID: String? = nil) async throws -> Response {
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
        let exchange = Exchange(streaming: headers["Accept"] == "text/event-stream",
            liveUpdate: liveUpdate, accumulator: streamInterface.map {
                AgentA2AStream.Accumulator(interface: $0, requestID: requestID,
                    expectedTaskID: expectedTaskID, bearerToken: bearerToken)
            })
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
    package static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384 && token.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    /// Redact the assembled snapshot and hold its trailing credential prefix.
    /// Prefix matching is linear, including for the maximum allowed token size.
    package static func redactLiveText(_ text: String, token: String?) -> String {
        guard let token, !token.isEmpty else { return text }
        let redacted = text.replacingOccurrences(of: token, with: "[redacted]")
        let needle = Array(token.utf8)
        guard needle.count > 1 else { return redacted }
        var prefixes = Array(repeating: 0, count: needle.count)
        var matched = 0
        for index in 1..<needle.count {
            while matched > 0, needle[index] != needle[matched] { matched = prefixes[matched - 1] }
            if needle[index] == needle[matched] { matched += 1 }
            prefixes[index] = matched
        }
        matched = 0
        for byte in redacted.utf8.suffix(needle.count - 1) {
            while matched > 0, byte != needle[matched] { matched = prefixes[matched - 1] }
            if byte == needle[matched] { matched += 1 }
        }
        return String(decoding: redacted.utf8.dropLast(matched), as: UTF8.self)
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
        /// The live stream retains the latest display snapshot; the result
        /// below is still built from the whole capture, exactly as before.
        private let liveFeed: AsyncStream<AgentA2AStream.LiveUpdate>.Continuation?
        private var liveOffset = 0
        private var accumulator: AgentA2AStream.Accumulator?

        init(streaming: Bool, liveUpdate: LiveUpdateHandler?, accumulator: AgentA2AStream.Accumulator?) {
            self.streaming = streaming
            self.accumulator = accumulator
            guard streaming, accumulator != nil, let liveUpdate else { liveFeed = nil; return }
            let (updates, feed) = AsyncStream.makeStream(of: AgentA2AStream.LiveUpdate.self, bufferingPolicy: .bufferingNewest(1))
            liveFeed = feed
            Task {
                for await update in updates { await liveUpdate(update) }
            }
        }

        private func forwardLive() {
            guard let liveFeed, eventStream, let status, (200..<300).contains(status) else { return }
            // Frames end in a blank line (\n\n or \r\n\r\n); both end in LF.
            var end = data.endIndex - 1
            while end > data.startIndex + liveOffset {
                if data[end] == 0x0A, data[end - 1] == 0x0A || (data[end - 1] == 0x0D && end - 2 >= data.startIndex && data[end - 2] == 0x0A) { break }
                end -= 1
            }
            guard end > data.startIndex + liveOffset else { return }
            let complete = data[(data.startIndex + liveOffset)...end]
            liveOffset = end + 1 - data.startIndex
            do {
                for event in try AgentA2AStream.events(in: Data(complete)) {
                    if let update = try accumulator?.receive(event) { liveFeed.yield(update) }
                }
            } catch {
                accumulator = nil
                liveFeed.finish()
                finish(.failure(error))
            }
        }

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
            liveFeed?.finish()
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
            forwardLive()
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

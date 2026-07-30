import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore

// Wave-30 unit tests for the AnthropicOAuthDirectAdapter refresh path. We
// Uses an Anthropic-suite-private URLProtocol stub. Swift Testing runs suites
// in parallel and the OpenAI OAuth tests also keep static stub state, so
// sharing that class lets provider tests replace each other's responders.

final class AnthropicOAuthStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var failure: Error?
    nonisolated(unsafe) static var allRequests: [URLRequest] = []
    nonisolated(unsafe) static var allRequestBodies: [Data?] = []

    static func reset() {
        responder = nil
        failure = nil
        allRequests.removeAll()
        allRequestBodies.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.allRequests.append(request)
        if let body = request.httpBody {
            Self.allRequestBodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            Self.allRequestBodies.append(data)
        } else {
            Self.allRequestBodies.append(nil)
        }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let resp = responder(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: resp.status,
            httpVersion: "HTTP/1.1",
            headerFields: resp.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resp.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct AnthropicOAuthDirectRefreshTests {

    private func stubSession(requestTimeout: TimeInterval = 60) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AnthropicOAuthStubURLProtocol.self]
        cfg.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: cfg)
    }

    @Test func production_session_uses_bounded_timeouts() throws {
        let session = AnthropicOAuthDirectAdapter.makeProductionSession(environment: [
            "NATIVE_AGENT_ANTHROPIC_OAUTH_REQUEST_TIMEOUT_SEC": "12",
            "NATIVE_AGENT_ANTHROPIC_OAUTH_RESOURCE_TIMEOUT_SEC": "34",
        ])
        #expect(session.configuration.timeoutIntervalForRequest == 12)
        #expect(session.configuration.timeoutIntervalForResource == 34)
        #expect(session.configuration.waitsForConnectivity == true)
        #expect(session.configuration.urlCache == nil)
    }

    @discardableResult
    private func writeAuthFile(_ obj: [String: Any]) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("anth-oauth-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("anthropic_oauth_direct.json")
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try! data.write(to: path)
        return path
    }

    /// ISO basic UTC for a date `offset` seconds from now.
    private func isoBasic(offsetSec: TimeInterval) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date().addingTimeInterval(offset(offsetSec)))
    }
    private func offset(_ s: TimeInterval) -> TimeInterval { s }

    // ---------- expires_at parsing ----------

    @Test func parseExpiresAt_iso_basic() throws {
        let raw = "2099-01-02T03:04:05Z"
        let d = try #require(AnthropicOAuthDirectAdapter.parseExpiresAt(raw))
        // 2099 should be > 2026, sanity check.
        #expect(d.timeIntervalSince1970 > Date().timeIntervalSince1970)
    }

    @Test func parseExpiresAt_unix_int() throws {
        let raw: Any = 4102444800   // 2100-01-01
        let d = try #require(AnthropicOAuthDirectAdapter.parseExpiresAt(raw))
        #expect(Int(d.timeIntervalSince1970) == 4102444800)
    }

    // ---------- loadAccessTokenAndExpiry ----------

    @Test func load_returns_token_and_expiry_from_top_level() throws {
        let path = writeAuthFile([
            "access_token": "tok_abc",
            "refresh_token": "rt_abc",
            "expires_at": isoBasic(offsetSec: 3600),
        ])
        let (tok, exp) = try #require(AnthropicOAuthDirectAdapter.loadAccessTokenAndExpiry(from: path))
        #expect(tok == "tok_abc")
        let e = try #require(exp)
        #expect(e.timeIntervalSinceNow > 600, "should be ~1h in the future")
    }

    @Test func load_returns_nil_expiry_for_pkce_setup_shape() throws {
        let path = writeAuthFile([
            "tokens": ["access_token": "tok_pkce"],
        ])
        let (tok, exp) = try #require(AnthropicOAuthDirectAdapter.loadAccessTokenAndExpiry(from: path))
        #expect(tok == "tok_pkce")
        #expect(exp == nil)
    }

    // ---------- Refresh trigger when expires_at is in the past ----------

    @Test func refreshes_when_expires_at_in_past() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_old",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: -60),  // already expired
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])
        // Responder dispatches by URL.
        AnthropicOAuthStubURLProtocol.responder = { req in
            if req.url?.path == "/v1/oauth/token" {
                // Refresh succeeds and rotates the refresh_token.
                let body: [String: Any] = [
                    "access_token":  "tok_new",
                    "refresh_token": "rt_v2",
                    "expires_in":    3600,
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return .init(status: 200, body: data,
                             headers: ["Content-Type": "application/json"])
            }
            // /v1/messages — return a valid Anthropic response shape.
            let body: [String: Any] = [
                "content": [["type": "text", "text": "hello back"]],
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return .init(status: 200, body: data,
                         headers: ["Content-Type": "application/json"])
        }

        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(),
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            refreshEndpoint: URL(string: "https://platform.claude.com/v1/oauth/token")!,
            authPathOverride: path
        )
        let out = try await adapter.complete(
            prompt: "hi", system: nil, model: "claude-opus-4-8"
        )
        #expect(out == "hello back")

        // The refresh endpoint must have been called and the token file
        // must now hold the rotated credentials.
        let refreshReqs = AnthropicOAuthStubURLProtocol.allRequests
            .filter { $0.url?.path == "/v1/oauth/token" }
        #expect(refreshReqs.count == 1, "refresh should run exactly once")
        let data = try Data(contentsOf: path)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["access_token"] as? String == "tok_new")
        #expect(obj["refresh_token"] as? String == "rt_v2")
        // Final /v1/messages request must use the NEW token.
        let msgReq = try #require(AnthropicOAuthStubURLProtocol.allRequests.first(where: { $0.url?.path == "/v1/messages" }))
        #expect(msgReq.value(forHTTPHeaderField: "Authorization") == "Bearer tok_new")
    }

    @Test func no_refresh_when_expires_at_far_future() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_fresh",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: 7200),  // 2h future, well past buffer
        ])
        AnthropicOAuthStubURLProtocol.responder = { req in
            let body: [String: Any] = ["content": [["type": "text", "text": "ok"]]]
            return .init(status: 200,
                         body: try! JSONSerialization.data(withJSONObject: body),
                         headers: ["Content-Type": "application/json"])
        }
        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        _ = try await LLMCallContext.$reasoningEffort.withValue("xhigh") {
            try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
        }
        let refreshReqs = AnthropicOAuthStubURLProtocol.allRequests
            .filter { $0.url?.path == "/v1/oauth/token" }
        #expect(refreshReqs.isEmpty, "fresh token should NOT trigger refresh")
        let msgIndex = try #require(AnthropicOAuthStubURLProtocol.allRequests.firstIndex {
            $0.url?.path == "/v1/messages"
        })
        let body = try #require(AnthropicOAuthStubURLProtocol.allRequestBodies[msgIndex])
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((object["output_config"] as? [String: String])?["effort"] == "xhigh")
    }

    @Test func messages_400_surfaces_provider_body() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_fresh",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: 7200),
        ])
        AnthropicOAuthStubURLProtocol.responder = { req in
            if req.url?.path == "/v1/messages" {
                return .init(
                    status: 400,
                    body: Data(#"{"error":{"message":"model not available"}}"#.utf8),
                    headers: ["Content-Type": "application/json"]
                )
            }
            return .init(status: 200, body: Data())
        }
        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .underlying(let msg) = err else {
                Issue.record("expected .underlying with provider body, got \(err)")
                return
            }
            #expect(msg.contains("anthropic oauth status 400"))
            #expect(msg.contains("model not available"))
        }
    }

    // F3-M3: a streaming/HTTP 5xx from the PRIMARY provider is retryable. Both
    // the `complete` and `completeMessages` sites previously threw `.underlying`
    // (terminal), so a transient Anthropic 500 terminally failed a turn that
    // GPT/Moonshot/xAI would have replayed. Pin both sites → `.transient` with
    // the provider body preserved.
    @Test func complete_5xx_surfaces_transient_with_body() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_fresh",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: 7200),
        ])
        AnthropicOAuthStubURLProtocol.responder = { req in
            if req.url?.path == "/v1/messages" {
                return .init(
                    status: 503,
                    body: Data(#"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8),
                    headers: ["Content-Type": "application/json"]
                )
            }
            return .init(status: 200, body: Data())
        }
        let adapter = AnthropicOAuthDirectAdapter(session: stubSession(), authPathOverride: path)
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .transient(let msg) = err else {
                Issue.record("expected .transient for 5xx, got \(err)")
                return
            }
            #expect(msg.contains("Overloaded"), "body must be preserved for diagnosis")
        }
    }

    @Test func completeMessages_5xx_surfaces_transient_with_body() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_fresh",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: 7200),
        ])
        AnthropicOAuthStubURLProtocol.responder = { req in
            if req.url?.path == "/v1/messages" {
                return .init(
                    status: 500,
                    body: Data(#"{"error":{"message":"internal boom"}}"#.utf8),
                    headers: ["Content-Type": "application/json"]
                )
            }
            return .init(status: 200, body: Data())
        }
        let adapter = AnthropicOAuthDirectAdapter(session: stubSession(), authPathOverride: path)
        do {
            _ = try await adapter.completeMessages(
                messages: [.user("p")], system: nil, model: "claude-opus-4-8", tools: nil
            )
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .transient(let msg) = err else {
                Issue.record("expected .transient for 5xx, got \(err)")
                return
            }
            #expect(msg.contains("internal boom"), "body must be preserved for diagnosis")
        }
    }

    @Test func messages_400_extra_usage_surfaces_clean_provider_error() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_fresh",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: 7200),
        ])
        AnthropicOAuthStubURLProtocol.responder = { req in
            if req.url?.path == "/v1/messages" {
                return .init(
                    status: 400,
                    body: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"You're out of extra usage. Add more at claude.ai/settings/usage and keep going."},"request_id":"req_123"}"#.utf8),
                    headers: ["Content-Type": "application/json"]
                )
            }
            return .init(status: 200, body: Data())
        }
        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .providerError(let msg) = err else {
                Issue.record("expected .providerError usage notice, got \(err)")
                return
            }
            #expect(msg == "Anthropic OAuth usage is exhausted. Add more at claude.ai/settings/usage or switch providers.")
        }
    }

    @Test func complete_timeout_surfaces_transient_timeout_not_connection_refused() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        AnthropicOAuthStubURLProtocol.failure = URLError(.timedOut)
        let path = writeAuthFile([
            "access_token": "tok_fresh",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: 7200),
        ])
        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(requestTimeout: 7),
            authPathOverride: path
        )

        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .transient(let msg) = err else {
                Issue.record("expected .transient timeout, got \(err)")
                return
            }
            #expect(msg.contains("anthropic_oauth_direct complete timed out"))
            #expect(msg.contains("7s"))
            #expect(!msg.contains("connection refused"))
        }
    }

    // A3.5/A3.1: a refresh-endpoint 401 means the refresh token was rejected →
    // the credential is genuinely revoked. authRejected carries the reconnect
    // guidance + provider body, replacing the misleading .notConfigured (a
    // revoked token used to read as "you never signed in").
    @Test func refresh_401_surfaces_as_authRejected() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_old",
            "refresh_token": "rt_revoked",
            "expires_at": isoBasic(offsetSec: -60),
        ])
        AnthropicOAuthStubURLProtocol.responder = { req in
            // Refresh endpoint returns 401 → token revoked.
            if req.url?.path == "/v1/oauth/token" {
                return .init(status: 401, body: Data("revoked".utf8))
            }
            return .init(status: 200, body: Data())
        }
        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .authRejected(let provider, _) = err else {
                Issue.record("expected .authRejected, got \(err)")
                return
            }
            #expect(provider == "anthropic_oauth_direct")
        }
    }

    // A3.5: a refresh-endpoint 5xx is a provider-side hiccup, NOT a dead token
    // — it must surface .transient so the session survives without a needless
    // reconnect prompt (the misreported-as-revoked bug this fix closes).
    @Test func refresh_5xx_surfaces_as_transient_keeps_session() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        let path = writeAuthFile([
            "access_token": "tok_old",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: -60),
        ])
        AnthropicOAuthStubURLProtocol.responder = { req in
            if req.url?.path == "/v1/oauth/token" {
                return .init(status: 503, body: Data("upstream busy".utf8))
            }
            return .init(status: 200, body: Data())
        }
        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .transient = err else {
                Issue.record("expected .transient for refresh 5xx, got \(err)")
                return
            }
        }
    }

    @Test func retries_on_401_with_force_refresh() async throws {
        AnthropicOAuthStubURLProtocol.reset()
        // Token NOT expired by clock, so the first attempt uses it as-is.
        // Server still rejects with 401 — adapter must refresh and retry.
        let path = writeAuthFile([
            "access_token": "tok_stale",
            "refresh_token": "rt_v1",
            "expires_at": isoBasic(offsetSec: 3600),
        ])
        nonisolated(unsafe) var messagesCalls = 0
        AnthropicOAuthStubURLProtocol.responder = { req in
            if req.url?.path == "/v1/oauth/token" {
                let body: [String: Any] = [
                    "access_token":  "tok_new",
                    "refresh_token": "rt_v2",
                    "expires_in":    3600,
                ]
                return .init(status: 200,
                             body: try! JSONSerialization.data(withJSONObject: body),
                             headers: ["Content-Type": "application/json"])
            }
            // /v1/messages — first call: 401 (token stale despite clock).
            messagesCalls += 1
            if messagesCalls == 1 {
                return .init(status: 401, body: Data("expired".utf8))
            }
            let body: [String: Any] = ["content": [["type": "text", "text": "retry-ok"]]]
            return .init(status: 200,
                         body: try! JSONSerialization.data(withJSONObject: body),
                         headers: ["Content-Type": "application/json"])
        }
        let adapter = AnthropicOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        let out = try await adapter.complete(prompt: "p", system: nil, model: "claude-opus-4-8")
        #expect(out == "retry-ok")
        let refreshes = AnthropicOAuthStubURLProtocol.allRequests
            .filter { $0.url?.path == "/v1/oauth/token" }
        #expect(refreshes.count == 1, "exactly one refresh should rotate the token")
    }
}

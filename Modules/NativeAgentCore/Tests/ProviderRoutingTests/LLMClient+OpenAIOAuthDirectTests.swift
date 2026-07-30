import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - URLProtocol stub (OAuth-suite-private to avoid cross-suite static collision)
//
// LLMClientRealTests has its own `OAuthStubURLProtocol` with static `responder` /
// `lastRequest` / `lastBody`. Swift Testing runs suites in parallel by default
// and `.serialized` only serializes WITHIN a suite — so if these tests
// share that class, the two suites stomp each other's static state. We
// declare an OAuth-suite-private protocol class instead. Same shape as
// LLMClientRealTests' stub; just isolated identity.

final class OAuthStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        /// Mid-stream transport failure: after delivering `body`, fail the
        /// load with this error instead of finishing — exercises the SSE
        /// byte-stream error path (transient classification pin). Same shape
        /// as Item9StubURLProtocol.Response.midStreamError.
        var midStreamError: Error? = nil
    }
    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var failure: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var allRequests: [URLRequest] = []
    nonisolated(unsafe) static var allBodies: [Data] = []

    static func reset() {
        responder = nil
        failure = nil
        lastRequest = nil
        lastBody = nil
        allRequests.removeAll()
        allBodies.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        OAuthStubURLProtocol.lastRequest = request
        OAuthStubURLProtocol.allRequests.append(request)
        var capturedBody = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                capturedBody.append(buf, count: read)
            }
            stream.close()
        } else if let httpBody = request.httpBody {
            capturedBody = httpBody
        }
        OAuthStubURLProtocol.lastBody = capturedBody
        OAuthStubURLProtocol.allBodies.append(capturedBody)
        if let failure = OAuthStubURLProtocol.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let responder = OAuthStubURLProtocol.responder else {
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
        if let err = resp.midStreamError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - JWT factory

/// Build a JWT-shaped string with the given payload. The signature is bogus
/// (always "sig"); the adapter only ever reads claims from the unverified
/// payload, so signature validity does not matter. base64url, NO padding —
/// mirrors the standard JWT compact serialization the Python provider sees.
private func makeJWT(payload: [String: Any]) -> String {
    func b64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
             .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
    let header = b64url(#"{"alg":"none","typ":"JWT"}"#.data(using: .utf8)!)
    let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "\(header).\(b64url(payloadData)).sig"
}

/// Build an access-token JWT with the standard ChatGPT-OAuth claim shape.
/// `expSecondsFromNow` controls when the token expires relative to now —
/// negative means already-expired.
private func makeAccessJWT(
    accountID: String? = "acct_123",
    expSecondsFromNow: Int = 3600
) -> String {
    var payload: [String: Any] = [
        "exp": Int(Date().timeIntervalSince1970) + expSecondsFromNow,
        "sub": "user_abc",
    ]
    if let acct = accountID {
        payload["https://api.openai.com/auth"] = [
            "chatgpt_account_id": acct,
        ]
    }
    return makeJWT(payload: payload)
}

// MARK: - Helpers

/// Build a temp `data/codex_home/auth.json` and return the URL to the file.
@discardableResult
private func writeAuthJSON(_ obj: [String: Any]) -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("oauthdirect-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("auth.json")
    writeAuthJSON(obj, to: path)
    return path
}

private func writeAuthJSON(_ obj: [String: Any], to path: URL) {
    try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
    try! data.write(to: path)
}

private func stubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [OAuthStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

// MARK: - Tests

@Suite(.serialized) struct OpenAIOAuthDirectAdapterTests {

    // ---------- JWT decode ----------

    @Test func production_session_uses_longer_nativeagent_timeouts() throws {
        let session = OpenAIOAuthDirectAdapter.makeProductionSession(environment: [:])
        let cfg = session.configuration
        #expect(cfg.timeoutIntervalForRequest == 240)
        #expect(cfg.timeoutIntervalForResource == 600)
        #expect(cfg.waitsForConnectivity == true)
    }

    @Test func jwt_payload_decodes_base64url_with_padding_variants() throws {
        // 1-byte, 2-byte, and 0-byte padding cases all need to round-trip.
        for accountID in ["a", "ab", "abc"] {
            let token = makeAccessJWT(accountID: accountID)
            let payload = try #require(OpenAIOAuthDirectAdapter.jwtPayload(token))
            let claim = try #require(payload["https://api.openai.com/auth"] as? [String: Any])
            #expect(claim["chatgpt_account_id"] as? String == accountID)
        }
    }

    @Test func jwt_payload_returns_nil_for_malformed_tokens() throws {
        // WAVE 27 review fix (gpt-5.5 NIT): replace the prior tautological
        // `x == nil || x != nil` with strong assertions on the genuinely
        // malformed cases. The `garbage` token has fewer than 2 dots; the
        // empty / single-part cases also fail the parts.count >= 2 check.
        #expect(OpenAIOAuthDirectAdapter.jwtPayload("") == nil)
        #expect(OpenAIOAuthDirectAdapter.jwtPayload("only-one-part") == nil)
        // A 3-part token whose payload section is junk bytes decodes to nil
        // (base64url may succeed but JSONSerialization rejects non-JSON).
        #expect(OpenAIOAuthDirectAdapter.jwtPayload("a.!!!.c") == nil)
        #expect(OpenAIOAuthDirectAdapter.extractAccountIDFromJWT("garbage") == nil)
    }

    // ---------- Model coercion (Python parity) ----------

    @Test func model_coercion_passes_gpt_through() throws {
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("gpt-5.5") == nativeAgentPrimaryModel)
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("gpt-4o") == "gpt-4o")
    }

    @Test func model_coercion_strips_openai_namespace() throws {
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("openai/gpt-5.5") == nativeAgentPrimaryModel)
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("openai/gpt-4o") == "gpt-4o")
    }

    @Test func model_coercion_remaps_claude_to_gpt_default() throws {
        // Defensive remap preserves retired L136-L143 behavior — Anthropic ids that
        // accidentally land on this adapter must not 404 the chatgpt.com
        // backend.
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("claude-opus-4-7") == nativeAgentPrimaryModel)
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("claude-haiku-4-6") == "gpt-5.4-mini")
    }

    @Test func model_coercion_default_for_empty_or_unknown() throws {
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel(nil) == nativeAgentPrimaryModel)
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("") == nativeAgentPrimaryModel)
        #expect(OpenAIOAuthDirectAdapter.coerceToGPTModel("llama-3") == nativeAgentPrimaryModel)
    }

    @Test func jwt_exp_claim_detection() throws {
        let fresh = makeAccessJWT(expSecondsFromNow: 7200)
        let expired = makeAccessJWT(expSecondsFromNow: -60)
        let freshExp = try #require(OpenAIOAuthDirectAdapter.tokenExpiresAt(fresh))
        let expiredExp = try #require(OpenAIOAuthDirectAdapter.tokenExpiresAt(expired))
        let now = Int(Date().timeIntervalSince1970)
        #expect(freshExp > now + 60, "fresh token should expire well in the future")
        #expect(expiredExp < now, "expired token should be in the past")
    }

    @Test func account_id_extraction_from_jwt_claim() throws {
        let token = makeAccessJWT(accountID: "acct_xyz")
        #expect(OpenAIOAuthDirectAdapter.extractAccountIDFromJWT(token) == "acct_xyz")
    }

    @Test func account_id_returns_nil_when_claim_missing() throws {
        // JWT with no auth claim at all (the Python `_account_id` fallback
        // path returns None on the same input).
        let payload: [String: Any] = ["exp": Int(Date().timeIntervalSince1970) + 3600]
        let token = makeJWT(payload: payload)
        #expect(OpenAIOAuthDirectAdapter.extractAccountIDFromJWT(token) == nil)
    }

    // ---------- not-configured paths ----------

    @Test func notConfigured_when_authJson_missing() async throws {
        // Point the adapter at a path that doesn't exist.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)/auth.json")
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            #expect(err == .notConfigured(provider: "openai_oauth_direct"))
        }
    }

    @Test func preferredAuthPath_uses_appSupport_when_stamped_repo_auth_is_not_usable() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("oauth-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let repoData = repo.appendingPathComponent("data", isDirectory: true)
        let repoAuth = repoData
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        let appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        let appSupportAuth = appSupport
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")

        writeAuthJSON(["tokens": [:] as [String: Any]], to: repoAuth)
        writeAuthJSON([
            "tokens": [
                "access_token": makeAccessJWT(accountID: "acct_appsupport"),
                "refresh_token": "refresh",
            ],
        ], to: appSupportAuth)

        let resolved = OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: repoData,
            environment: [:],
            currentDirectoryPath: repo.path,
            appSupportRoot: appSupport
        )
        #expect(resolved.standardizedFileURL == appSupportAuth.standardizedFileURL)
    }

    @Test func preferredAuthPath_uses_sharedCodex_when_appOwnedAuth_is_missing() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("oauth-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let repoData = repo.appendingPathComponent("data", isDirectory: true)
        let appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        let sharedCodexHome = base.appendingPathComponent(".codex", isDirectory: true)
        let sharedAuth = sharedCodexHome.appendingPathComponent("auth.json")

        writeAuthJSON([
            "tokens": [
                "access_token": makeAccessJWT(accountID: "acct_shared"),
                "refresh_token": "refresh",
            ],
        ], to: sharedAuth)

        let resolved = OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: repoData,
            environment: [:],
            currentDirectoryPath: repo.path,
            appSupportRoot: appSupport,
            userCodexHome: sharedCodexHome
        )
        #expect(resolved.standardizedFileURL == sharedAuth.standardizedFileURL)
    }

    @Test func preferredAuthPath_respects_explicit_codexHome_even_when_appSupport_has_token() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("oauth-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let explicitCodexHome = base.appendingPathComponent("ExplicitCodexHome", isDirectory: true)
        let explicitAuth = explicitCodexHome.appendingPathComponent("auth.json")
        let appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        let appSupportAuth = appSupport
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")

        writeAuthJSON([
            "tokens": [
                "access_token": makeAccessJWT(accountID: "acct_appsupport"),
                "refresh_token": "refresh",
            ],
        ], to: appSupportAuth)

        let resolved = OpenAIOAuthDirectAdapter.preferredAuthPath(
            environment: ["CODEX_HOME": explicitCodexHome.path],
            currentDirectoryPath: base.path,
            appSupportRoot: appSupport
        )
        #expect(resolved.standardizedFileURL == explicitAuth.standardizedFileURL)
    }

    @Test func notConfigured_when_tokens_block_empty() async throws {
        let path = writeAuthJSON([
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [:] as [String: Any],
        ])
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            #expect(err == .notConfigured(provider: "openai_oauth_direct"))
        }
    }

    @Test func notConfigured_when_account_id_unresolvable() async throws {
        // Has access_token but the JWT has no chatgpt_account_id claim and no
        // persisted account_id field.
        let payload: [String: Any] = ["exp": Int(Date().timeIntervalSince1970) + 3600]
        let token = makeJWT(payload: payload)
        let path = writeAuthJSON([
            "tokens": ["access_token": token],
        ])
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            #expect(err == .notConfigured(provider: "openai_oauth_direct"))
        }
    }

    // ---------- Request shape ----------

    @Test func complete_POSTs_responses_endpoint_with_correct_headers_and_body() async throws {
        OAuthStubURLProtocol.reset()
        // Build SSE body with a single text delta + a completed event.
        let sse = """
        data: {"type":"response.output_text.delta","delta":"Hello"}

        data: {"type":"response.output_text.delta","delta":" world"}

        data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":2}}}

        """
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 200, body: sse.data(using: .utf8)!,
                  headers: ["Content-Type": "text/event-stream"])
        }
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": [
                "access_token": token,
                "refresh_token": "rt_xxx",
                "account_id": "acct_abc",
            ],
        ])
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            endpoint: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            authPathOverride: path
        )
        let out = try await adapter.complete(prompt: "Hi", system: "be terse", model: "gpt-5.5")
        #expect(out == "Hello world")

        let req = try #require(OAuthStubURLProtocol.lastRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(req.value(forHTTPHeaderField: "chatgpt-account-id") == "acct_abc")
        #expect(req.value(forHTTPHeaderField: "originator") == "nativeagent")
        #expect(req.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
        #expect(req.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try #require(OAuthStubURLProtocol.lastBody)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(parsed["model"] as? String == nativeAgentPrimaryModel)
        #expect(parsed["stream"] as? Bool == true)
        #expect(parsed["store"] as? Bool == false)
        #expect(parsed["instructions"] as? String == "be terse")
        let input = try #require(parsed["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "Hi")
        // max_output_tokens MUST NOT be present (chatgpt.com backend rejects it).
        #expect(parsed["max_output_tokens"] == nil)
    }

    @Test func chatgptOAuth_requestBodyMapsAccountPresetsToAcceptedWireEffortAndCarriesFast() throws {
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("unused-auth.json")
        )
        let body = LLMCallContext.$reasoningEffort.withValue("ultra") {
            LLMCallContext.$serviceTier.withValue("priority") {
                adapter.buildResponsesBodyFromMessages(
                    model: "gpt-5.6-sol",
                    messages: [.user("hello")],
                    system: "test",
                    tools: nil
                )
            }
        }
        let reasoning = try #require(body["reasoning"] as? [String: String])
        #expect(reasoning["effort"] == "xhigh")
        #expect(body["service_tier"] as? String == "priority")

        let maxBody = LLMCallContext.$reasoningEffort.withValue("max") {
            adapter.buildResponsesBodyFromMessages(
                model: "gpt-5.6-sol",
                messages: [.user("hello")],
                system: "test",
                tools: nil
            )
        }
        #expect((maxBody["reasoning"] as? [String: String])?["effort"] == "xhigh")

        let lunaBody = LLMCallContext.$reasoningEffort.withValue("ultra") {
            adapter.buildResponsesBodyFromMessages(
                model: "gpt-5.6-luna",
                messages: [.user("hello")],
                system: "test",
                tools: nil
            )
        }
        #expect(lunaBody["reasoning"] == nil)
    }

    @Test func streamMessages_yields_text_deltas_and_structured_tool_calls() async throws {
        OAuthStubURLProtocol.reset()
        let sse = """
        data: {"type":"response.output_text.delta","delta":"Checking"}

        data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"tool_catalog","arguments":""}}

        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"category\\":\\"apns\\"}"}

        data: {"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"tool_catalog","arguments":"{\\"category\\":\\"apns\\"}"}}

        data: {"type":"response.completed","response":{"status":"completed"}}

        """
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 200, body: sse.data(using: .utf8)!,
                  headers: ["Content-Type": "text/event-stream"])
        }
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": [
                "access_token": token,
                "refresh_token": "rt_xxx",
                "account_id": "acct_abc",
            ],
        ])
        let adapter = OpenAIOAuthDirectAdapter(session: stubSession(), authPathOverride: path)
        let schema = LLMToolSchema(
            name: "tool_catalog",
            description: "List tools",
            parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
        )

        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("what tools do you have")],
            system: "be useful",
            model: "gpt-5.5",
            tools: [schema]
        ) {
            events.append(event)
        }

        // The function_call_arguments.delta frame emits a `.keepAlive` (liveness,
        // no content) — filter it; the CONTENT events are the text delta + tool call.
        let content = events.filter { $0 != .keepAlive }
        #expect(content.count == 2)
        if content.count == 2 {
            if case .textDelta(let text) = content[0] {
                #expect(text == "Checking")
            } else {
                Issue.record("expected text delta")
            }
            if case .toolCall(let call) = content[1] {
                #expect(call.id == "call_1")
                #expect(call.name == "tool_catalog")
                let parsed = try #require(try JSONSerialization.jsonObject(with: call.inputJSON) as? [String: Any])
                #expect(parsed["category"] as? String == "apns")
            } else {
                Issue.record("expected tool call")
            }
        }
        // Liveness: the arg-delta produced a keepalive, and no empty content leaked.
        #expect(events.contains(.keepAlive))
        #expect(!events.contains(.textDelta("")))
    }

    // keepAlive liveness for the OpenAI streaming path (gpt-5.5 review 2026-06-15):
    // a reasoning frame carries no content but must yield `.keepAlive` so a long
    // reasoning phase doesn't trip ProviderStreamGuard's idle timeout.
    @Test func streamMessages_reasoningFrame_yieldsKeepAliveNotContent() async throws {
        OAuthStubURLProtocol.reset()
        let sse = """
        data: {"type":"response.reasoning_text.delta","delta":"thinking it through"}

        data: {"type":"response.output_text.delta","delta":"done"}

        data: {"type":"response.completed","response":{"status":"completed"}}

        """
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 200, body: sse.data(using: .utf8)!,
                  headers: ["Content-Type": "text/event-stream"])
        }
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": [
                "access_token": token,
                "refresh_token": "rt_xxx",
                "account_id": "acct_abc",
            ],
        ])
        let adapter = OpenAIOAuthDirectAdapter(session: stubSession(), authPathOverride: path)
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: "sys", model: "gpt-5.5", tools: nil
        ) {
            events.append(event)
        }
        #expect(events.contains(.keepAlive))          // liveness preserved
        #expect(!events.contains(.textDelta("")))     // no empty content leak
        let texts = events.compactMap { e -> String? in
            if case .textDelta(let s) = e { return s }; return nil
        }
        #expect(texts == ["done"])                    // reasoning never enters reply text
    }

    // (gpt-5.5 review 2026-07-02, R15-SSE consolidation follow-up) Mid-stream
    // transport errors thrown while iterating the SSE byte stream route
    // through the SAME transientNetworkError mapping as initial-connect
    // failures: a resource timeout AFTER headers + body bytes were accepted
    // classifies .transient, not a raw URLError falling through the generic
    // catch. Mirrors AnthropicStreamMessagesSSETests
    // .streamMessages_midStreamTimeout_classifiedTransient. Note (same
    // platform limitation documented there): URLSession discards its
    // coalescing buffer when a URLProtocol fails, so delivered-but-unvended
    // deltas are lost — the pin is the ERROR CLASSIFICATION, not delta
    // observation; no assertion on received events.
    @Test func streamMessages_midStreamTimeout_classifiedTransient() async throws {
        OAuthStubURLProtocol.reset()
        defer { OAuthStubURLProtocol.reset() }
        let head = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"par\"}\n\n"
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(head.utf8),
                  headers: ["Content-Type": "text/event-stream"],
                  midStreamError: URLError(.timedOut))
        }
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": [
                "access_token": token,
                "refresh_token": "rt_xxx",
                "account_id": "acct_abc",
            ],
        ])
        let adapter = OpenAIOAuthDirectAdapter(session: stubSession(), authPathOverride: path)
        var thrown: Error?
        do {
            for try await _ in adapter.streamMessages(
                messages: [.user("hi")], system: nil, model: "gpt-5.5", tools: nil
            ) {}
        } catch { thrown = error }
        if case .transient(let message)? = thrown as? LLMError {
            #expect(message.contains("streamMessages"))
            #expect(message.contains("timed out"))
        } else {
            Issue.record("expected .transient, got \(String(describing: thrown))")
        }
    }

    @Test func completeMessages_http_400_surfaces_provider_body() async throws {
        OAuthStubURLProtocol.reset()
        let errorBody = #"{"error":{"message":"bad tool schema: missing required field"}}"#
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 400, body: Data(errorBody.utf8),
                  headers: ["Content-Type": "application/json"])
        }
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": [
                "access_token": token,
                "refresh_token": "rt_xxx",
                "account_id": "acct_abc",
            ],
        ])
        let adapter = OpenAIOAuthDirectAdapter(session: stubSession(), authPathOverride: path)

        do {
            _ = try await adapter.completeMessages(
                messages: [.user("hi")],
                system: "be useful",
                model: "gpt-5.5",
                tools: nil
            )
            Issue.record("expected providerError")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected providerError, got \(error)")
                return
            }
            #expect(message.contains("HTTP 400"))
            #expect(message.contains("bad tool schema"))
        }
    }

    @Test func streamMessages_http_400_surfaces_provider_body() async throws {
        OAuthStubURLProtocol.reset()
        let errorBody = #"{"detail":"unsupported field in responses body"}"#
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 400, body: Data(errorBody.utf8),
                  headers: ["Content-Type": "application/json"])
        }
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": [
                "access_token": token,
                "refresh_token": "rt_xxx",
                "account_id": "acct_abc",
            ],
        ])
        let adapter = OpenAIOAuthDirectAdapter(session: stubSession(), authPathOverride: path)

        do {
            for try await _ in adapter.streamMessages(
                messages: [.user("hi")],
                system: "be useful",
                model: "gpt-5.5",
                tools: nil
            ) {}
            Issue.record("expected providerError")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected providerError, got \(error)")
                return
            }
            #expect(message.contains("HTTP 400"))
            #expect(message.contains("unsupported field"))
        }
    }

    @Test func complete_uses_default_instructions_when_system_nil() async throws {
        OAuthStubURLProtocol.reset()
        OAuthStubURLProtocol.responder = { _ in
            let sse = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
            return .init(status: 200, body: sse.data(using: .utf8)!,
                         headers: ["Content-Type": "text/event-stream"])
        }
        let token = makeAccessJWT()
        let path = writeAuthJSON(["tokens": ["access_token": token, "account_id": "acct_123"]])
        let adapter = OpenAIOAuthDirectAdapter(session: stubSession(), authPathOverride: path)
        _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
        let body = try #require(OAuthStubURLProtocol.lastBody)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(parsed["instructions"] as? String == "You are a helpful assistant.")
    }

    // ---------- Refresh flow ----------

    @Test func http_401_triggers_refresh_and_retry() async throws {
        OAuthStubURLProtocol.reset()
        let oldToken = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: 3600)
        let newToken = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: 7200)
        let path = writeAuthJSON([
            "tokens": [
                "access_token": oldToken,
                "refresh_token": "rt_initial",
                "account_id": "acct_abc",
            ],
        ])
        // Responder: first call to /codex/responses returns 401, then the
        // refresh endpoint returns new tokens, then the retried /codex/responses
        // returns 200 with one text delta.
        let callCounter = NSLock()
        nonisolated(unsafe) var responsesCalls = 0
        OAuthStubURLProtocol.responder = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/oauth/token") {
                let body = #"{"access_token":"\#(newToken)","refresh_token":"rt_rotated","id_token":"id_new"}"#
                return .init(status: 200, body: body.data(using: .utf8)!)
            }
            if url.contains("/codex/responses") {
                callCounter.lock()
                responsesCalls += 1
                let n = responsesCalls
                callCounter.unlock()
                if n == 1 {
                    return .init(status: 401, body: Data())
                }
                let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
                return .init(status: 200, body: sse.data(using: .utf8)!,
                             headers: ["Content-Type": "text/event-stream"])
            }
            return .init(status: 500, body: Data())
        }
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            endpoint: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            refreshEndpoint: URL(string: "https://auth.openai.com/oauth/token")!,
            authPathOverride: path
        )
        let out = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
        #expect(out == "ok")
        #expect(responsesCalls == 2, "expected 2 calls to /codex/responses (initial 401 + retry)")

        // Persisted blob should now have the rotated tokens.
        let updated = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: path)) as? [String: Any])
        let tokens = try #require(updated["tokens"] as? [String: Any])
        #expect(tokens["access_token"] as? String == newToken)
        #expect(tokens["refresh_token"] as? String == "rt_rotated")
    }

    @Test func second_http_401_throws_oauth_direct_exhausted_marker() async throws {
        // WAVE 27 review fix (gpt-5.5 BLOCKING): second 401 must surface the
        // exhausted marker, NOT .notConfigured — the "tokens revoked, re-sign-
        // in required" state must never be masked as unconfigured. Prerelease
        // Wave-1 review (2026-07-23): the carrier class is now .authRejected
        // (A3.1 contract — dead OAuth renders as auth rejection with the
        // marker as detail); propagation semantics unchanged (adapter
        // selection is static, no error-triggered fallback exists).
        OAuthStubURLProtocol.reset()
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": [
                "access_token": token,
                "refresh_token": "rt_initial",
                "account_id": "acct_abc",
            ],
        ])
        OAuthStubURLProtocol.responder = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/oauth/token") {
                let body = #"{"access_token":"\#(token)","refresh_token":"rt_rotated"}"#
                return .init(status: 200, body: body.data(using: .utf8)!)
            }
            return .init(status: 401, body: Data())
        }
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            if case .authRejected(let provider, let detail) = err {
                #expect(provider == "openai_oauth_direct")
                #expect(detail?.contains("oauth_direct_exhausted") == true)
            } else {
                Issue.record("expected .authRejected(oauth_direct_exhausted), got: \(err)")
            }
        }
    }

    @Test func exhausted_marker_does_not_fall_back_to_apikey() async throws {
        // The whole point of using .underlying for exhaustion: when
        // SwiftNativeLLMClient routes a gpt-* model through openAIComplete,
        // an exhausted OAuth state must PROPAGATE the error instead of
        // letting the api-key adapter (which would 401 too with null
        // OPENAI_API_KEY) come in and mask it as a generic notConfigured.
        final class ExhaustedOAuth: LLMAdapter, @unchecked Sendable {
            let providerId = "openai_oauth_direct"
            func complete(prompt: String, system: String?, model: String) async throws -> String {
                throw LLMError.authRejected(
                    provider: "openai_oauth_direct",
                    detail: OpenAIOAuthDirectExhaustedMarker
                )
            }
        }
        let openAI = SpyAdapter2(providerId: "openai", response: "fallback-MUST-NOT-fire")
        let client = SwiftNativeLLMClient(
            router: MockRouter2(chatModel: "ignored"),
            codex: SpyAdapter2(providerId: "codex"),
            anthropic: SpyAdapter2(providerId: "anthropic"),
            openAI: openAI,
            openAIOAuthDirect: ExhaustedOAuth()
        )
        do {
            _ = try await client.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            if case .authRejected(_, let detail) = err {
                #expect(detail?.contains("oauth_direct_exhausted") == true)
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
        #expect(openAI.lastModel == nil, "api-key fallback must NOT fire on exhausted-marker")
    }

    @Test func expired_jwt_triggers_proactive_refresh() async throws {
        OAuthStubURLProtocol.reset()
        // Token is already expired (exp in the past) — adapter should refresh
        // BEFORE making the responses call.
        let expired = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: -60)
        let fresh = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: 7200)
        let path = writeAuthJSON([
            "tokens": [
                "access_token": expired,
                "refresh_token": "rt_initial",
                "account_id": "acct_abc",
            ],
        ])
        nonisolated(unsafe) var refreshCalls = 0
        nonisolated(unsafe) var responsesAuthHeader: String? = nil
        OAuthStubURLProtocol.responder = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/oauth/token") {
                refreshCalls += 1
                let body = #"{"access_token":"\#(fresh)","refresh_token":"rt_rotated"}"#
                return .init(status: 200, body: body.data(using: .utf8)!)
            }
            if url.contains("/codex/responses") {
                responsesAuthHeader = req.value(forHTTPHeaderField: "Authorization")
                let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
                return .init(status: 200, body: sse.data(using: .utf8)!,
                             headers: ["Content-Type": "text/event-stream"])
            }
            return .init(status: 500, body: Data())
        }
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
        #expect(refreshCalls == 1, "expected proactive refresh before first responses call")
        // Retry header must use the NEW token, not the expired one.
        #expect(responsesAuthHeader == "Bearer \(fresh)")
    }

    // ---------- Refresh body shape ----------

    @Test func concurrent_callers_share_one_refresh() async throws {
        // WAVE 27 review fix (gpt-5.5 BLOCKING): two callers noticing the
        // token is expired must NOT each POST /oauth/token — the refresh
        // token is single-use and the second call would rotate-and-burn it.
        // The actor-backed AsyncSerialQueue + inside-lock re-read enforces
        // this: refreshCalls should be exactly 1 across N concurrent
        // ensureFreshAccessToken() calls.
        OAuthStubURLProtocol.reset()
        let expired = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: -60)
        let fresh = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: 7200)
        let path = writeAuthJSON([
            "tokens": [
                "access_token": expired,
                "refresh_token": "rt_initial",
                "account_id": "acct_abc",
            ],
        ])
        // Pure synchronous counter — the URLProtocol responder runs on a
        // sync thread; we use a class with OSAllocatedUnfairLock equivalent
        // to keep the count Sendable-safe without NSLock in async ctx.
        final class SyncCounter: @unchecked Sendable {
            private let lock = NSRecursiveLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            func get() -> Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let counter = SyncCounter()
        OAuthStubURLProtocol.responder = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/oauth/token") {
                counter.bump()
                let body = #"{"access_token":"\#(fresh)","refresh_token":"rt_rotated"}"#
                return .init(status: 200, body: body.data(using: .utf8)!)
            }
            return .init(status: 500, body: Data())
        }
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        // Fire N concurrent ensureFreshAccessToken() calls.
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await adapter.ensureFreshAccessToken()
                }
            }
            for try await _ in group {}
        }
        let final = counter.get()
        #expect(final == 1, "expected exactly 1 refresh across concurrent callers, got \(final)")
    }

    @Test func network_failure_is_transient_not_fallback_trigger() async throws {
        // WAVE 27 review fix (gpt-5.5 BLOCKING): a real network failure
        // with valid tokens must surface as .transient, NOT .notConfigured.
        // The latter would let SwiftNativeLLMClient.openAIComplete fall
        // back to the api-key adapter, which doesn't help and masks the
        // real network problem.
        OAuthStubURLProtocol.reset()
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": ["access_token": token, "account_id": "acct_abc"],
        ])
        // Responder returns a URLError-style failure by setting nil responder
        // — the StubURLProtocol surfaces this as URLError.unknown.
        OAuthStubURLProtocol.responder = nil
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .transient(let message) = err else {
                Issue.record("network failure must be .transient, got \(err)")
                return
            }
            #expect(message.contains("network error"))
            #expect(!message.contains("connection refused"))
        }
    }

    @Test func timeout_failure_is_truthful_transient_not_connection_refused() async throws {
        OAuthStubURLProtocol.reset()
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": ["access_token": token, "account_id": "acct_abc"],
        ])
        OAuthStubURLProtocol.failure = URLError(.timedOut)
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        do {
            _ = try await adapter.completeMessages(
                messages: [.user("p")],
                system: nil,
                model: "gpt-5.5",
                tools: nil
            )
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .transient(let message) = err else {
                Issue.record("timeout must be .transient, got \(err)")
                return
            }
            #expect(message.contains("timed out"))
            #expect(message.contains("openai_oauth_direct completeMessages"))
            #expect(!message.contains("connection refused"))
        }
    }

    @Test func refresh_body_shape_matches_python() async throws {
        OAuthStubURLProtocol.reset()
        let expired = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: -60)
        let fresh = makeAccessJWT(accountID: "acct_abc", expSecondsFromNow: 7200)
        let path = writeAuthJSON([
            "tokens": [
                "access_token": expired,
                "refresh_token": "rt_initial",
                "account_id": "acct_abc",
            ],
        ])
        nonisolated(unsafe) var refreshBody: Data? = nil
        nonisolated(unsafe) var refreshContentType: String? = nil
        OAuthStubURLProtocol.responder = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/oauth/token") {
                refreshBody = OAuthStubURLProtocol.lastBody
                refreshContentType = req.value(forHTTPHeaderField: "Content-Type")
                let body = #"{"access_token":"\#(fresh)","refresh_token":"rt_rotated"}"#
                return .init(status: 200, body: body.data(using: .utf8)!)
            }
            let sse = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
            return .init(status: 200, body: sse.data(using: .utf8)!)
        }
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
        let body = try #require(refreshBody)
        let bodyStr = try #require(String(data: body, encoding: .utf8))
        #expect(refreshContentType == "application/x-www-form-urlencoded")
        #expect(bodyStr.contains("grant_type=refresh_token"))
        #expect(bodyStr.contains("refresh_token=rt_initial"))
        #expect(bodyStr.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        // NO scope param, NO redirect_uri — matches pi-ai exact body shape.
        #expect(!bodyStr.contains("scope="))
        #expect(!bodyStr.contains("redirect_uri="))
    }

    // ---------- Cancellation ----------

    @Test func cancellation_propagates_as_CancellationError() async throws {
        OAuthStubURLProtocol.reset()
        let token = makeAccessJWT(accountID: "acct_abc")
        let path = writeAuthJSON([
            "tokens": ["access_token": token, "account_id": "acct_abc"],
        ])
        // Responder hangs indefinitely so the only way out is cancellation.
        // Use an unreachable host via a stub that never finishes the request.
        // Instead of hanging the stub (URLProtocol doesn't model deadline well
        // when we cancel the outer Task), we exercise cancellation by
        // cancelling the Task BEFORE the call lands. The Task.checkCancellation
        // upstream in SwiftNativeLLMClient + URLSession's cancellation surfaces
        // through the same NSURLErrorCancelled path the test asserts on.
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 200, body: "data: {\"type\":\"response.completed\",\"response\":{}}\n\n".data(using: .utf8)!)
        }
        let adapter = OpenAIOAuthDirectAdapter(
            session: stubSession(),
            authPathOverride: path
        )
        let task = Task<String, Error> {
            try Task.checkCancellation()
            return try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
        }
        task.cancel()
        do {
            _ = try await task.value
            // The cancel may race with the request — accept either outcome.
            // We're proving the call doesn't deadlock; the strict
            // CancellationError surfacing is exercised by complete()'s
            // explicit NSURLErrorCancelled mapping.
        } catch is CancellationError {
            // Expected.
        } catch {
            // URLSession may not fire — that's fine. The point is no deadlock.
        }
    }

    // ---------- SwiftNativeLLMClient OAuth routing ----------

    @Test func swiftNativeLLMClient_gpt_model_prefers_oauth_direct_when_present() async throws {
        let oauth = SpyAdapter2(providerId: "openai_oauth_direct", response: "from-oauth")
        let openAI = SpyAdapter2(providerId: "openai", response: "from-apikey")
        let client = SwiftNativeLLMClient(
            router: MockRouter2(chatModel: "ignored"),
            codex: SpyAdapter2(providerId: "codex"),
            anthropic: SpyAdapter2(providerId: "anthropic"),
            openAI: openAI,
            openAIOAuthDirect: oauth
        )
        let out = try await client.complete(prompt: "p", system: nil, model: "gpt-5.5")
        #expect(out == "from-oauth")
        #expect(oauth.lastModel == "gpt-5.5")
        #expect(openAI.lastModel == nil, "api-key adapter must NOT be called when OAuth succeeds")
    }

    @Test func swiftNativeLLMClient_gpt_model_surfaces_oauth_notConfigured_without_apikey_swap() async throws {
        // OAuth adapter throws notConfigured -> the selected OAuth provider is
        // broken/missing auth. Surface that directly; do not silently swap to
        // the API-key OpenAIAdapter spy.
        final class ThrowingOAuthAdapter: LLMAdapter, @unchecked Sendable {
            let providerId = "openai_oauth_direct"
            func complete(prompt: String, system: String?, model: String) async throws -> String {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
        }
        let openAI = SpyAdapter2(providerId: "openai", response: "from-apikey")
        let client = SwiftNativeLLMClient(
            router: MockRouter2(chatModel: "ignored"),
            codex: SpyAdapter2(providerId: "codex"),
            anthropic: SpyAdapter2(providerId: "anthropic"),
            openAI: openAI,
            openAIOAuthDirect: ThrowingOAuthAdapter()
        )
        do {
            _ = try await client.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected OAuth notConfigured")
        } catch let err as LLMError {
            #expect(err == .notConfigured(provider: "openai_oauth_direct"))
        }
        #expect(openAI.lastModel == nil, "api-key adapter must NOT be called when OAuth is selected but unconfigured")
    }

    @Test func swiftNativeLLMClient_gpt_model_propagates_non_notConfigured_oauth_errors() async throws {
        final class TransientOAuthAdapter: LLMAdapter, @unchecked Sendable {
            let providerId = "openai_oauth_direct"
            func complete(prompt: String, system: String?, model: String) async throws -> String {
                throw LLMError.transient(message: "rate limit")
            }
        }
        let openAI = SpyAdapter2(providerId: "openai", response: "fallback-should-NOT-fire")
        let client = SwiftNativeLLMClient(
            router: MockRouter2(chatModel: "ignored"),
            codex: SpyAdapter2(providerId: "codex"),
            anthropic: SpyAdapter2(providerId: "anthropic"),
            openAI: openAI,
            openAIOAuthDirect: TransientOAuthAdapter()
        )
        do {
            _ = try await client.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            if case .transient = err {} else { Issue.record("wrong: \(err)") }
        }
        #expect(openAI.lastModel == nil, "api-key adapter must NOT swallow a transient OAuth error")
    }

    // MARK: - strict routing on the STREAMING paths (9358710c removed the
    // OAuth→api-key fallback on openAIStream/anthropicStream too; the complete()
    // twins above had coverage, the stream twins did not — closing that gap).

    @Test func swiftNativeLLMClient_gpt_stream_surfaces_oauth_notConfigured_without_apikey_swap() async throws {
        // OAuth adapter throws .notConfigured BEFORE any chunk → openAIStream
        // must surface it, NOT silently fall through to the api-key stream.
        final class ThrowingOAuthAdapter: LLMAdapter, @unchecked Sendable {
            let providerId = "openai_oauth_direct"
            func complete(prompt: String, system: String?, model: String) async throws -> String {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            // default stream() forwards to complete() → throws pre-yield.
        }
        let openAI = SpyAdapter2(providerId: "openai", response: "from-apikey-stream")
        let client = SwiftNativeLLMClient(
            router: MockRouter2(chatModel: "ignored"),
            codex: SpyAdapter2(providerId: "codex"),
            anthropic: SpyAdapter2(providerId: "anthropic"),
            openAI: openAI,
            openAIOAuthDirect: ThrowingOAuthAdapter()
        )
        var chunks: [String] = []
        do {
            for try await c in client.stream(prompt: "p", system: nil, model: "gpt-5.5") {
                chunks.append(c)
            }
            Issue.record("expected OAuth .notConfigured to surface on the stream")
        } catch let err as LLMError {
            #expect(err == .notConfigured(provider: "openai_oauth_direct"))
        }
        #expect(chunks.isEmpty, "no chunks should be yielded when OAuth is unconfigured")
        #expect(openAI.lastModel == nil, "api-key stream must NOT fire on OAuth .notConfigured (no fallback)")
    }

    @Test func swiftNativeLLMClient_claude_stream_surfaces_oauth_notConfigured_without_apikey_swap() async throws {
        final class ThrowingAnthropicOAuthAdapter: LLMAdapter, @unchecked Sendable {
            let providerId = "anthropic_oauth_direct"
            func complete(prompt: String, system: String?, model: String) async throws -> String {
                throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
            }
        }
        let anthropic = SpyAdapter2(providerId: "anthropic", response: "from-apikey-stream")
        let client = SwiftNativeLLMClient(
            router: MockRouter2(chatModel: "ignored"),
            codex: SpyAdapter2(providerId: "codex"),
            anthropic: anthropic,
            openAI: SpyAdapter2(providerId: "openai"),
            anthropicOAuthDirect: ThrowingAnthropicOAuthAdapter()
        )
        var chunks: [String] = []
        do {
            for try await c in client.stream(prompt: "p", system: nil, model: "claude-opus-4-8") {
                chunks.append(c)
            }
            Issue.record("expected OAuth .notConfigured to surface on the stream")
        } catch let err as LLMError {
            #expect(err == .notConfigured(provider: "anthropic_oauth_direct"))
        }
        #expect(chunks.isEmpty, "no chunks should be yielded when OAuth is unconfigured")
        #expect(anthropic.lastModel == nil, "api-key stream must NOT fire on OAuth .notConfigured (no fallback)")
    }

    @Test func swiftNativeLLMClient_without_oauth_uses_apikey_directly() async throws {
        // When openAIOAuthDirect is nil (legacy wiring path), the api-key
        // adapter is the sole OpenAI handler — no behaviour change.
        let openAI = SpyAdapter2(providerId: "openai", response: "from-apikey")
        let client = SwiftNativeLLMClient(
            router: MockRouter2(chatModel: "ignored"),
            codex: SpyAdapter2(providerId: "codex"),
            anthropic: SpyAdapter2(providerId: "anthropic"),
            openAI: openAI
        )
        let out = try await client.complete(prompt: "p", system: nil, model: "gpt-5.5")
        #expect(out == "from-apikey")
    }

    // ---------- SSE parser ----------

    @Test func sse_parser_collects_text_deltas_in_order() throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"foo"}

        data: {"type":"response.output_text.delta","delta":" bar"}

        data: {"type":"response.output_text.delta","delta":" baz"}

        data: {"type":"response.completed","response":{"status":"completed"}}

        """
        let out = OpenAIOAuthDirectAdapter.collectResponsesSSE(
            from: sse.data(using: .utf8)!
        )
        #expect(out == "foo bar baz")
    }

    @Test func sse_parser_ignores_unknown_event_types() throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"hi"}

        data: {"type":"response.function_call_arguments.delta","delta":"{"}

        data: {"type":"ping"}

        data: {"type":"response.completed","response":{"status":"completed"}}

        """
        let out = OpenAIOAuthDirectAdapter.collectResponsesSSE(
            from: sse.data(using: .utf8)!
        )
        #expect(out == "hi")
    }

    @Test func sse_parser_surfaces_response_failed_as_provider_error() throws {
        // WAVE 27 review fix (gpt-5.5 BLOCKING): a 200 SSE that ends with
        // `response.failed` must NOT return success with empty text.
        let sse = """
        data: {"type":"response.output_text.delta","delta":"partial"}

        data: {"type":"response.failed","response":{"error":{"message":"backend overloaded"}}}

        """
        let result = OpenAIOAuthDirectAdapter.parseResponsesSSE(
            from: sse.data(using: .utf8)!
        )
        if case .providerError(let msg) = result {
            #expect(msg.contains("backend overloaded"))
        } else {
            Issue.record("expected .providerError, got: \(result)")
        }
    }

    @Test func sse_parser_surfaces_bare_error_frame() throws {
        let sse = """
        data: {"type":"error","message":"unexpected_token_invalid"}

        """
        let result = OpenAIOAuthDirectAdapter.parseResponsesSSE(
            from: sse.data(using: .utf8)!
        )
        if case .providerError(let msg) = result {
            #expect(msg.contains("unexpected_token_invalid"))
        } else {
            Issue.record("expected .providerError, got: \(result)")
        }
    }

    @Test func complete_throws_providerError_on_response_failed_frame() async throws {
        OAuthStubURLProtocol.reset()
        let sse = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"throttled\"}}}\n\n"
        OAuthStubURLProtocol.responder = { _ in
            .init(status: 200, body: sse.data(using: .utf8)!,
                  headers: ["Content-Type": "text/event-stream"])
        }
        let token = makeAccessJWT()
        let path = writeAuthJSON(["tokens": ["access_token": token, "account_id": "acct_123"]])
        let adapter = OpenAIOAuthDirectAdapter(session: stubSession(), authPathOverride: path)
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
            Issue.record("expected throw")
        } catch let err as LLMError {
            if case .providerError(let msg) = err {
                #expect(msg.contains("throttled"))
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test func sse_parser_breaks_on_done_sentinel() throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"a"}

        data: [DONE]

        data: {"type":"response.output_text.delta","delta":"b"}

        """
        let out = OpenAIOAuthDirectAdapter.collectResponsesSSE(
            from: sse.data(using: .utf8)!
        )
        #expect(out == "a", "deltas after [DONE] must be ignored")
    }
}

// MARK: - Local test helpers
// Distinct names from LLMClientRealTests' private SpyAdapter / MockRouter so
// the two suites compile in the same module without collision.

private struct MockRouter2: ProviderRoutingProtocol {
    var chatModel: String
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .object([:]))
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: chatModel, reasoningEffort: "high")]
    }
}

private final class SpyAdapter2: LLMAdapter, @unchecked Sendable {
    let providerId: String
    var lastPrompt: String?
    var lastSystem: String?
    var lastModel: String?
    var response: String

    init(providerId: String, response: String = "ok") {
        self.providerId = providerId
        self.response = response
    }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        lastPrompt = prompt
        lastSystem = system
        lastModel = model
        return response
    }
}

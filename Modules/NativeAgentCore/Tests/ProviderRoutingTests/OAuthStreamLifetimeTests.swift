import Foundation
import Testing
@testable import ProviderRouting

private enum OAuthStreamShape: String, CaseIterable, Sendable {
    case openAIMessages, xAIText, xAIMessages, anthropicText, anthropicMessages

    var isOpenAI: Bool { self == .openAIMessages }
    var isAnthropic: Bool { self == .anthropicText || self == .anthropicMessages }
    var isStructured: Bool { self == .openAIMessages || self == .xAIMessages || self == .anthropicMessages }
    var model: String { isOpenAI ? "gpt-5.5" : isAnthropic ? "claude-sonnet-4-6" : "grok-4" }

    var delta: String {
        if isOpenAI { return "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n" }
        if isAnthropic {
            return "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n"
        }
        return "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"
    }

    var terminal: String {
        if isOpenAI { return "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n" }
        if isAnthropic { return "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n" }
        return "data: [DONE]\n\n"
    }

    func writeAuth(root: URL, access: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("auth.json")
        let tokens: [String: Any] = ["access_token": access, "refresh_token": "fixture-initial-refresh", "account_id": "fixture-account"]
        var object = isOpenAI ? ["tokens": tokens] : tokens
        object["token_endpoint"] = "https://x.ai/oauth/token"
        object["fixture_metadata"] = "preserve-me"
        try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
        return path
    }

    func adapter(session: URLSession, root: URL, auth: URL) -> any LLMAdapter {
        let endpoint = URL(string: "https://provider.invalid/reply")!
        let refresh = URL(string: "https://x.ai/oauth/token")!
        if isOpenAI {
            return OpenAIOAuthDirectAdapter(session: session, endpoint: endpoint, refreshEndpoint: refresh, authPathOverride: auth, telemetryDataRootOverride: root)
        }
        if isAnthropic {
            return AnthropicOAuthDirectAdapter(session: session, endpoint: endpoint, refreshEndpoint: refresh, authPathOverride: auth, telemetryDataRootOverride: root)
        }
        return XAIOAuthDirectAdapter(session: session, endpoint: endpoint, refreshEndpoint: refresh, tokenPathOverride: auth, telemetryDataRootOverride: root)
    }
}

private final class OAuthLifetimeProbe: @unchecked Sendable {
    let body: Data
    let rejectFirst: Bool
    let replyStatus: Int
    let refreshBody: Data
    private let lock = NSLock()
    private var log: [String] = []
    private var replyCount = 0
    private weak var heldReply: OAuthLifetimeProtocol?

    init(body: String, rejectFirst: Bool, freshAccess: String, replyStatus: Int = 200) throws {
        self.body = Data(body.utf8)
        self.rejectFirst = rejectFirst
        self.replyStatus = replyStatus
        refreshBody = try JSONSerialization.data(withJSONObject: [
            "access_token": freshAccess, "refresh_token": "fixture-rotated-refresh", "expires_in": 7200
        ])
    }

    func hold(_ reply: OAuthLifetimeProtocol) {
        lock.lock()
        defer { lock.unlock() }
        heldReply = reply
    }

    func failHeldReply() {
        lock.lock()
        let reply = heldReply
        lock.unlock()
        reply?.failRead()
    }

    func start(path: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let label: String
        if path == "/reply" {
            replyCount += 1
            label = "reply\(replyCount)"
        } else { label = path == "/oauth/token" ? "refresh" : "bystander" }
        log.append(label)
        return label
    }

    func stopped(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        log.append("stop-\(label)")
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }
}

// Isolated from other parallel suites. Intercepts *all* URLs, including the
// trusted x.ai refresh URL required by that adapter's token-state contract.
private final class OAuthLifetimeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var probe: OAuthLifetimeProbe!
    private var activeProbe: OAuthLifetimeProbe?
    private var label = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let probe = Self.probe!
        activeProbe = probe
        label = probe.start(path: request.url!.path)
        let refresh = label == "refresh"
        let rejected = label == "reply1" && probe.rejectFirst
        if label.hasPrefix("reply") { probe.hold(self) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: rejected ? 401 : label.hasPrefix("reply") ? probe.replyStatus : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": refresh ? "application/json" : "text/event-stream", "Retry-After": "7"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = refresh ? probe.refreshBody : rejected ? Data("rejected held-open body".utf8) : probe.body
        client?.urlProtocol(self, didLoad: body)
        // Only refresh reaches EOF. Both rejected and accepted provider
        // requests remain open until the adapter retires their exact task.
        if refresh { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() { activeProbe?.stopped(label) }

    func failRead() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
}

private enum AnthropicErrorBodyScenario: String, CaseIterable, Sendable {
    case exactByteCap, deadline, readFailure, rejectedAfterRefresh, quota, rateLimited, stop

    var status: Int {
        switch self {
        case .rejectedAfterRefresh: 401
        case .quota: 403
        case .rateLimited: 429
        default: 500
        }
    }

    var body: String {
        switch self {
        case .exactByteCap: String(repeating: "e", count: 4096)
        case .quota: "quota exceeded"
        case .rejectedAfterRefresh: "revoked fixture token"
        default: #"{"error":"upstream unavailable","access_token":"fixture-private-token"}"#
        }
    }
}

@Suite("OAuth streaming requests retire at attempt boundaries", .serialized)
struct OAuthStreamLifetimeTests {
    private func token(_ name: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "exp": Int(Date().timeIntervalSince1970) + 7200, "fixture": name
        ])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).fixture-signature"
    }

    private func session(probe: OAuthLifetimeProbe) -> URLSession {
        OAuthLifetimeProtocol.probe = probe
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthLifetimeProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func consume(_ adapter: any LLMAdapter, shape: OAuthStreamShape) -> Task<Result<String, Error>, Never> {
        Task {
            do {
                var text = ""
                if shape.isStructured {
                    for try await event in adapter.streamMessages(messages: [.user("hi")], system: nil, model: shape.model, tools: nil) {
                        if case .textDelta(let delta) = event { text += delta }
                    }
                } else {
                    for try await delta in adapter.stream(prompt: "hi", system: nil, model: shape.model) { text += delta }
                }
                return .success(text)
            } catch { return .failure(error) }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }

    @Test(arguments: OAuthStreamShape.allCases)
    fileprivate func terminalClosesOnlyReplyWithoutRefreshOrRemoteEOF(shape: OAuthStreamShape) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OAuthLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldAccess = try token("old")
        let auth = try shape.writeAuth(root: root, access: oldAccess)
        let authBefore = try Data(contentsOf: auth)
        let probe = try OAuthLifetimeProbe(body: shape.delta + shape.terminal, rejectFirst: false, freshAccess: token("new"))
        let session = session(probe: probe)
        defer { session.invalidateAndCancel() }
        let bystander = session.dataTask(with: URL(string: "https://provider.invalid/bystander")!)
        bystander.resume()
        defer { bystander.cancel() }
        #expect(await waitUntil { probe.events.contains("bystander") })
        let result = await consume(shape.adapter(session: session, root: root, auth: auth), shape: shape).value
        #expect(try result.get() == "hello")
        #expect(await waitUntil { probe.events.contains("stop-reply1") })
        #expect(!probe.events.contains("refresh"))
        #expect(!probe.events.contains("reply2"))
        #expect(!probe.events.contains("stop-bystander"))
        #expect(bystander.state == .running)
        #expect(try Data(contentsOf: auth) == authBefore)
    }

    @Test(arguments: OAuthStreamShape.allCases)
    fileprivate func stopClosesHeldStreamWithoutRefreshOrRetry(shape: OAuthStreamShape) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OAuthLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = try shape.writeAuth(root: root, access: token("old"))
        let authBefore = try Data(contentsOf: auth)
        let probe = try OAuthLifetimeProbe(body: shape.delta, rejectFirst: false, freshAccess: token("new"))
        let session = session(probe: probe)
        defer { session.invalidateAndCancel() }
        let consumer = consume(shape.adapter(session: session, root: root, auth: auth), shape: shape)
        #expect(await waitUntil { probe.events.contains("reply1") })
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.value
        #expect(await waitUntil { probe.events.contains("stop-reply1") })
        #expect(!probe.events.contains("refresh"))
        #expect(!probe.events.contains("reply2"))
        #expect(try Data(contentsOf: auth) == authBefore)
    }

    @Test(arguments: OAuthStreamShape.allCases)
    fileprivate func first401ClosesBeforeRefreshAndPreservesSingleRotation(shape: OAuthStreamShape) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OAuthLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = try shape.writeAuth(root: root, access: token("old"))
        let newAccess = try token("new")
        let probe = try OAuthLifetimeProbe(body: shape.delta + shape.terminal, rejectFirst: true, freshAccess: newAccess)
        let session = session(probe: probe)
        defer { session.invalidateAndCancel() }
        let result = await consume(shape.adapter(session: session, root: root, auth: auth), shape: shape).value
        #expect(try result.get() == "hello")
        #expect(await waitUntil { probe.events.contains("stop-reply2") })
        let events = probe.events
        let rejectedStop = try #require(events.firstIndex(of: "stop-reply1"))
        let refreshStart = try #require(events.firstIndex(of: "refresh"))
        let retryStart = try #require(events.firstIndex(of: "reply2"))
        #expect(rejectedStop < refreshStart)
        #expect(refreshStart < retryStart)
        #expect(events.filter { $0 == "refresh" }.count == 1)
        #expect(!events.contains("reply3"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
        let tokens = shape.isOpenAI ? try #require(object["tokens"] as? [String: Any]) : object
        #expect(tokens["access_token"] as? String == newAccess)
        #expect(tokens["refresh_token"] as? String == "fixture-rotated-refresh")
        #expect(object["fixture_metadata"] as? String == "preserve-me")
    }

    @Test(arguments: [OAuthStreamShape.anthropicText, .anthropicMessages], AnthropicErrorBodyScenario.allCases)
    fileprivate func anthropicErrorBodyHasBoundedLifetimeAndUnchangedStatusVerdict(
        shape: OAuthStreamShape, scenario: AnthropicErrorBodyScenario
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnthropicBodyLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = try shape.writeAuth(root: root, access: token("old"))
        let authBefore = try Data(contentsOf: auth)
        let probe = try OAuthLifetimeProbe(
            body: scenario.body, rejectFirst: scenario == .rejectedAfterRefresh,
            freshAccess: token("new"), replyStatus: scenario.status
        )
        let session = session(probe: probe)
        defer { session.invalidateAndCancel() }
        let started = Date()
        let consumer = consume(shape.adapter(session: session, root: root, auth: auth), shape: shape)
        #expect(await waitUntil { probe.events.contains("reply1") })
        if scenario == .stop || scenario == .readFailure {
            // Ensure the partial diagnostic bytes entered the held read first.
            try await Task.sleep(for: .milliseconds(50))
            if scenario == .stop { consumer.cancel() } else { probe.failHeldReply() }
        }
        if scenario == .exactByteCap || scenario == .rateLimited || scenario == .stop {
            #expect(await waitUntil { probe.events.contains("stop-reply1") })
        }
        let result = await consumer.value
        #expect(Date().timeIntervalSince(started) < 4)
        if scenario == .stop {
            // AsyncThrowingStream cancellation can finish its consumer without
            // throwing; the request shutdown and unchanged auth are the proof.
            #expect(!probe.events.contains("refresh"))
            #expect(!probe.events.contains("reply2"))
            #expect(try Data(contentsOf: auth) == authBefore)
            return
        }
        guard case .failure(let error) = result, let llmError = error as? LLMError else {
            Issue.record("Expected the original provider HTTP verdict"); return
        }
        switch scenario {
        case .exactByteCap:
            guard case .underlying(let message) = llmError else { Issue.record("Expected existing HTTP500 underlying mapping"); return }
            #expect(message == "anthropic oauth status 500: " + String(repeating: "e", count: 1200) + "... [truncated]")
        case .deadline, .readFailure:
            guard case .underlying(let message) = llmError else { Issue.record("Read lifetime replaced the HTTP500 verdict"); return }
            #expect(message.contains("upstream unavailable"))
            #expect(message.contains("***"))
            #expect(!message.contains("fixture-private-token"))
        case .rejectedAfterRefresh:
            guard case .authRejected(let provider, let detail) = llmError else { Issue.record("Expected second401 authRejected"); return }
            #expect(provider == "anthropic_oauth_direct")
            #expect(detail?.contains("revoked fixture token") == true)
            #expect(probe.events.filter { $0 == "refresh" }.count == 1)
            #expect(!probe.events.contains("reply3"))
        case .quota:
            guard case .providerError(let message) = llmError else { Issue.record("Expected usage-exhausted provider error"); return }
            #expect(message.contains("Anthropic OAuth usage is exhausted"))
        case .rateLimited:
            guard case .transient(let message) = llmError else { Issue.record("Expected rate limited transient"); return }
            #expect(message == "rate limited [retry-after=7s]")
        case .stop: break
        }
        if scenario != .rejectedAfterRefresh {
            #expect(!probe.events.contains("refresh"))
            #expect(!probe.events.contains("reply2"))
            #expect(try Data(contentsOf: auth) == authBefore)
        }
    }
}

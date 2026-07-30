import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }
    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        responder = nil
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            stream.close()
            StubURLProtocol.lastBody = data
        } else {
            StubURLProtocol.lastBody = request.httpBody
        }
        guard let responder = StubURLProtocol.responder else {
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

private func stubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

// MARK: - Mock router

private struct MockRouter: ProviderRoutingProtocol {
    enum CheckedFailure: Error, Equatable { case unavailable }
    var chatModel: String
    var active: [String: String] = [:]
    var providers: [String: Provider] = [:]
    var checkedSnapshotFails = false
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider {
        if let provider = providers[id] { return provider }
        throw ProviderRoutingError.providerNotFound
    }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .object([:]))
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        [
            "chat": SurfacePreference(surface: "chat", model: chatModel, reasoningEffort: "high"),
            "telegram": SurfacePreference(surface: "telegram", model: chatModel, reasoningEffort: "high"),
        ]
    }
    func activeProvidersForSurfaces() async -> [String: String] { active }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        if checkedSnapshotFails { throw CheckedFailure.unavailable }
        return ProviderRoutingSnapshot(
            preferences: try await computeModelPreferences(),
            activeProviders: active,
            pinnedModels: [:]
        )
    }
}

// MARK: - Spy adapter

private final class SpyAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    var lastPrompt: String?
    var lastSystem: String?
    var lastModel: String?
    var lastReasoningEffort: String?
    var response: String

    init(providerId: String, response: String = "ok") {
        self.providerId = providerId
        self.response = response
    }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        lastPrompt = prompt
        lastSystem = system
        lastModel = model
        lastReasoningEffort = LLMCallContext.reasoningEffort
        return response
    }
}

private actor LifecycleCapture: LLMCallLifecycleObserving {
    private var events: [LLMCallLifecycleEvent] = []

    func observeProviderCall(_ event: LLMCallLifecycleEvent) {
        events.append(event)
    }

    func snapshot() -> [LLMCallLifecycleEvent] { events }
}

private final class FailingAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    init(providerId: String) { self.providerId = providerId }
    func complete(prompt: String, system: String?, model: String) async throws -> String {
        throw LLMError.underlying(message: "synthetic provider failure")
    }
}

private final class SuspendedAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    init(providerId: String) { self.providerId = providerId }
    func complete(prompt: String, system: String?, model: String) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "late"
    }
}

// MARK: - Codex tests

@Suite(.serialized) struct LLMClientRealTests {

@Test func codex_adapter_invokes_subprocess_with_correct_args_and_stdin() async throws {
    final class Box: @unchecked Sendable { var value: CodexProcessInvocation? }
    let box = Box()
    let runner: CodexProcessRunner = { inv in
        box.value = inv
        return CodexProcessResult(exitCode: 0, stdout: "hi\n", stderr: "")
    }
    let adapter = CodexAdapter(codexBin: "/usr/bin/codex", timeout: 10, runner: runner)
    let out = try await adapter.complete(prompt: "hello", system: "be terse", model: "gpt-5.5")
    #expect(out == "hi\n")
    let captured = box.value
    #expect(captured?.executable == "/usr/bin/codex")
    #expect(captured?.arguments.contains("-m") == true)
    #expect(captured?.arguments.contains("gpt-5.5") == true)
    #expect(captured?.stdin == "hello")
}

@Test func codex_adapter_forwardsInjectedProcessEnvironment() async throws {
    final class Box: @unchecked Sendable { var value: CodexProcessInvocation? }
    let box = Box()
    let environment = [
        "PATH": "/usr/bin:/bin",
        "CODEX_HOME": "/tmp/nativeagent-fixture/codex_home",
        "NATIVE_AGENT_DATA_ROOT": "/tmp/nativeagent-fixture",
    ]
    let adapter = CodexAdapter(
        runner: { invocation in
            box.value = invocation
            return CodexProcessResult(exitCode: 0, stdout: "ok", stderr: "")
        },
        processEnvironmentOverride: environment
    )

    _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.6-sol")

    #expect(box.value?.environment == environment)
}

@Test func codex_adapter_forwardsGPT56ReasoningAndFastControls() async throws {
    final class Box: @unchecked Sendable { var value: CodexProcessInvocation? }
    let box = Box()
    let runner: CodexProcessRunner = { invocation in
        box.value = invocation
        return CodexProcessResult(exitCode: 0, stdout: "ok", stderr: "")
    }
    let adapter = CodexAdapter(codexBin: "/usr/bin/codex", timeout: 10, runner: runner)
    _ = try await LLMCallContext.$reasoningEffort.withValue("ultra") {
        try await LLMCallContext.$serviceTier.withValue("priority") {
            try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.6-sol")
        }
    }
    #expect(box.value?.arguments == [
        "-c", "model_reasoning_effort=\"ultra\"",
        "-c", "service_tier=\"priority\"",
        "-m", "gpt-5.6-sol",
    ])
}

@Test func codex_adapter_timeout_throws_underlying() async throws {
    let runner: CodexProcessRunner = { _ in
        CodexProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: true)
    }
    let adapter = CodexAdapter(timeout: 1, runner: runner)
    await #expect(throws: LLMError.self) {
        _ = try await adapter.complete(prompt: "x", system: nil, model: "gpt-5.5")
    }
}

@Test func codex_adapter_nonzero_exit_throws_underlying_with_stderr() async throws {
    let runner: CodexProcessRunner = { _ in
        CodexProcessResult(exitCode: 2, stdout: "", stderr: "boom")
    }
    let adapter = CodexAdapter(runner: runner)
    do {
        _ = try await adapter.complete(prompt: "x", system: nil, model: "m")
        Issue.record("expected throw")
    } catch let err as LLMError {
        if case .underlying(let msg) = err {
            #expect(msg.contains("boom"))
        } else {
            Issue.record("wrong error: \(err)")
        }
    }
}

// MARK: - Anthropic tests

@Test func anthropic_adapter_POSTs_correct_url_headers_body() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in
        let body = #"{"content":[{"type":"text","text":"hi"}]}"#.data(using: .utf8)!
        return .init(status: 200, body: body)
    }
    let adapter = AnthropicAdapter(
        session: stubSession(),
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        apiKeyOverride: "sk-test"
    )
    // 2026-07-21 audit: the combined-block cache breakpoint is gated on the
    // chat-turn signal (LLMCallContext.sessionId) — bind it so this body
    // assertion exercises the chat-turn shape it always represented.
    _ = try await LLMCallContext.$sessionId.withValue("sess-body") {
        try await adapter.complete(prompt: "p", system: "s", model: "claude-3-opus")
    }

    let req = try #require(StubURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let body = try #require(StubURLProtocol.lastBody)
    let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(parsed["model"] as? String == "claude-3-opus")
    // U1 step 3 (2026-06-10): system is now a BLOCK ARRAY carrying an
    // ephemeral cache_control breakpoint (was a plain string).
    let systemBlocks = parsed["system"] as? [[String: Any]]
    #expect(systemBlocks?.count == 1)
    #expect(systemBlocks?.first?["text"] as? String == "s")
    #expect((systemBlocks?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    let msgs = parsed["messages"] as! [[String: String]]
    #expect(msgs.first?["content"] == "p")
}

@Test func anthropic_adapter_parses_content_array_first_text() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in
        let body = #"{"content":[{"type":"text","text":"hello world"}]}"#.data(using: .utf8)!
        return .init(status: 200, body: body)
    }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    let out = try await adapter.complete(prompt: "p", system: nil, model: "claude-x")
    #expect(out == "hello world")
}

/// 2026-07-21 audit (fix 4): the api-key adapter's COMBINED system block only
/// carries an ephemeral cache breakpoint for cache-eligible callers — a chat
/// turn (LLMCallContext.sessionId bound). One-shot callers (background loops,
/// dream/REM) skip it: stamping would pay the 1.25x cache-write premium with
/// ~zero read probability. The segmented stable/dynamic split is unaffected.
@Test func anthropic_makeSystemBlocks_breakpointGatedOnChatTurnSignal() throws {
    // Explicit gate: eligible → breakpoint; one-shot → plain block, text intact.
    let eligible = try #require(AnthropicAdapter.makeSystemBlocks("sys", segments: nil, cacheEligible: true))
    #expect((eligible.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    let oneShot = try #require(AnthropicAdapter.makeSystemBlocks("sys", segments: nil, cacheEligible: false))
    #expect(oneShot.first?["cache_control"] == nil)
    #expect(oneShot.first?["text"] as? String == "sys")

    // Default gate reads the TaskLocal: unbound (background caller) → no
    // breakpoint; bound chat session → breakpoint.
    let unbound = try #require(AnthropicAdapter.makeSystemBlocks("sys"))
    #expect(unbound.first?["cache_control"] == nil)
    let bound = LLMCallContext.$sessionId.withValue("sess-unit") {
        AnthropicAdapter.makeSystemBlocks("sys")
    }
    let boundBlocks = try #require(bound)
    #expect((boundBlocks.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

    // Segmented split (chat-turn shape) keeps the stable-block breakpoint and
    // leaves the churning dynamic tail uncached regardless of the gate.
    let segments = SystemPromptSegments(stable: "S", dynamic: "D")
    let split = try #require(AnthropicAdapter.makeSystemBlocks("S\n\nD", segments: segments, cacheEligible: false))
    #expect(split.count == 2)
    #expect((split[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    #expect(split[0]["text"] as? String == "S\n\n")
    #expect(split[1]["cache_control"] == nil)
    #expect(split[1]["text"] as? String == "D")
}

/// 2026-07-21 audit (fix 2): a thinking_delta carries no user-visible reply
/// text but IS real model output — the api-key String stream must yield an
/// EMPTY liveness chunk for it (and for input_json_delta) so
/// ProviderStreamGuard's idle clock can't kill a healthy long-thinking
/// kimi-code turn. The reply text itself is byte-untouched.
@Test func anthropic_adapter_stream_thinking_delta_yields_empty_liveness_chunk() async throws {
    StubURLProtocol.reset()
    let sse = """
    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"ponder"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    StubURLProtocol.responder = { _ in
        .init(status: 200, body: Data(sse.utf8), headers: ["Content-Type": "text/event-stream"])
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("anthropic-thinking-liveness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = AnthropicAdapter(
        session: stubSession(),
        apiKeyOverride: "k",
        telemetryDataRootOverride: root
    )
    var collected: [String] = []
    for try await chunk in adapter.stream(prompt: "p", system: nil, model: "m") {
        collected.append(chunk)
    }
    // One empty liveness chunk per non-text delta; the reply text is intact.
    #expect(collected == ["", "", "answer"])
    #expect(collected.joined() == "answer")
}

/// 2026-07-21 audit (fix 2): the api-key OpenAI String stream dropped
/// reasoning_content frames with zero liveness — the ProviderStreamGuard idle
/// clock could kill a healthy long-reasoning stream. Reasoning frames now
/// yield an EMPTY liveness chunk; reply text is byte-untouched.
@Test func openai_adapter_stream_reasoning_content_yields_empty_liveness_chunk() async throws {
    StubURLProtocol.reset()
    let sse = """
    data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}

    data: {"choices":[{"delta":{"content":"foo"}}]}

    data: [DONE]

    """
    StubURLProtocol.responder = { _ in
        .init(status: 200, body: Data(sse.utf8), headers: ["Content-Type": "text/event-stream"])
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-reasoning-liveness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = OpenAIAdapter(
        session: stubSession(),
        apiKeyOverride: "k",
        telemetryDataRootOverride: root
    )
    var collected: [String] = []
    for try await chunk in adapter.stream(prompt: "p", system: nil, model: "gpt-5.5") {
        collected.append(chunk)
    }
    #expect(collected == ["", "foo"])
    #expect(collected.joined() == "foo")
}

// A3.1: a key IS present (apiKeyOverride: "k"), so a 401 is a positive
// credential rejection → .authRejected, NOT the misleading .notConfigured.
@Test func anthropic_adapter_401_throws_authRejected_anthropic() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in
        .init(status: 401, body: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8))
    }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    do {
        _ = try await adapter.complete(prompt: "p", system: nil, model: "m")
        Issue.record("expected throw")
    } catch let err as LLMError {
        guard case .authRejected(let provider, let detail) = err else {
            Issue.record("expected .authRejected, got \(err)")
            return
        }
        #expect(provider == "anthropic")
        #expect(detail?.contains("invalid x-api-key") == true, "provider body must be carried")
    }
}

@Test func anthropic_adapter_429_throws_transient() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in .init(status: 429, body: "slow down".data(using: .utf8)!) }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    do {
        _ = try await adapter.complete(prompt: "p", system: nil, model: "m")
        Issue.record("expected throw")
    } catch let err as LLMError {
        if case .transient = err {} else { Issue.record("wrong: \(err)") }
    }
}

@Test func anthropic_adapter_5xx_throws_underlying_with_parsed_body() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in .init(status: 503, body: "overloaded".data(using: .utf8)!) }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    do {
        _ = try await adapter.complete(prompt: "p", system: nil, model: "m")
        Issue.record("expected throw")
    } catch let err as LLMError {
        if case .underlying(let msg) = err {
            #expect(msg.contains("overloaded"))
        } else { Issue.record("wrong: \(err)") }
    }
}

// MARK: - OpenAI tests

@Test func openai_adapter_POSTs_correct_url_headers_body() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in
        let body = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
        return .init(status: 200, body: body)
    }
    let adapter = OpenAIAdapter(
        session: stubSession(),
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        apiKeyOverride: "sk-x"
    )
    _ = try await adapter.complete(prompt: "p", system: "s", model: "gpt-5.5")

    let req = try #require(StubURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
    let body = try #require(StubURLProtocol.lastBody)
    let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(parsed["model"] as? String == "gpt-5.5")
    let msgs = parsed["messages"] as! [[String: String]]
    #expect(msgs.count == 2)
    #expect(msgs[0]["role"] == "system")
    #expect(msgs[0]["content"] == "s")
    #expect(msgs[1]["role"] == "user")
    #expect(msgs[1]["content"] == "p")
}

@Test func openai_adapter_parses_choices0_message_content() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in
        let body = #"{"choices":[{"message":{"content":"the answer"}}]}"#.data(using: .utf8)!
        return .init(status: 200, body: body)
    }
    let adapter = OpenAIAdapter(session: stubSession(), apiKeyOverride: "k")
    let out = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
    #expect(out == "the answer")
}

// A3.1: key present → 401 is a positive credential rejection → .authRejected.
@Test func openai_adapter_401_throws_authRejected_openai() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in
        .init(status: 401, body: Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8))
    }
    let adapter = OpenAIAdapter(session: stubSession(), apiKeyOverride: "k")
    do {
        _ = try await adapter.complete(prompt: "p", system: nil, model: "m")
        Issue.record("expected throw")
    } catch let err as LLMError {
        guard case .authRejected(let provider, let detail) = err else {
            Issue.record("expected .authRejected, got \(err)")
            return
        }
        #expect(provider == "openai")
        #expect(detail?.contains("Incorrect API key") == true)
    }
}

@Test func openai_adapter_429_throws_transient() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in .init(status: 429, body: "rl".data(using: .utf8)!) }
    let adapter = OpenAIAdapter(session: stubSession(), apiKeyOverride: "k")
    do {
        _ = try await adapter.complete(prompt: "p", system: nil, model: "m")
        Issue.record("expected throw")
    } catch let err as LLMError {
        if case .transient = err {} else { Issue.record("wrong: \(err)") }
    }
}

@Test func openai_adapter_5xx_throws_transient() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in .init(status: 502, body: "bad gw".data(using: .utf8)!) }
    let adapter = OpenAIAdapter(session: stubSession(), apiKeyOverride: "k")
    do {
        _ = try await adapter.complete(prompt: "p", system: nil, model: "m")
        Issue.record("expected throw")
    } catch let err as LLMError {
        // R-M1: 5xx is now .transient (retryable) for every Chat-Completions
        // adapter; was .underlying (terminal) here before the unification.
        if case .transient = err {} else { Issue.record("wrong: \(err)") }
    }
}

// MARK: - SwiftNativeLLMClient dispatch tests

@Test func swiftNativeLLMClient_emitsCorrelatedProviderLifecycleAroundComplete() async throws {
    let capture = LifecycleCapture()
    let adapter = SpyAdapter(providerId: "openai", response: "ok")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: SpyAdapter(providerId: "codex"),
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: adapter,
        lifecycleObserver: capture
    )

    let output = try await TurnTraceContext.$turnId.withValue("turn-1") {
        try await LLMCallContext.$sessionId.withValue("session-1") {
            try await client.complete(
                prompt: "p", system: nil, model: "gpt-5.6-sol",
                surface: "telegram", tools: nil
            )
        }
    }
    let events = await capture.snapshot()

    #expect(output == "ok")
    #expect(events.map(\.phase) == [.started, .succeeded])
    #expect(events.first?.id == events.last?.id)
    #expect(events.first?.providerId == "openai")
    #expect(events.first?.model == "gpt-5.6-sol")
    #expect(events.first?.surface == "telegram")
    #expect(events.first?.sessionId == "session-1")
    #expect(events.first?.turnId == "turn-1")
    #expect(events.first?.reasoningEffort == "high")
    #expect(events.first?.reasoningEffort == adapter.lastReasoningEffort)
    #expect(events.allSatisfy { !$0.streaming })
}

@Test func swiftNativeLLMClient_emitsFailedTerminalForThrownProviderCall() async throws {
    let capture = LifecycleCapture()
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: SpyAdapter(providerId: "codex"),
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: FailingAdapter(providerId: "openai"),
        lifecycleObserver: capture
    )

    await #expect(throws: LLMError.self) {
        _ = try await client.complete(prompt: "p", system: nil, model: "gpt-5.6-sol")
    }
    let events = await capture.snapshot()
    #expect(events.map(\.phase) == [.started, .failed])
    #expect(events.first?.id == events.last?.id)
}

@Test func swiftNativeLLMClient_cancellationClosesPredictionWithoutCallingItFailure() async throws {
    let capture = LifecycleCapture()
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: SpyAdapter(providerId: "codex"),
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: SuspendedAdapter(providerId: "openai"),
        lifecycleObserver: capture
    )

    let task = Task {
        try await client.complete(prompt: "p", system: nil, model: "gpt-5.6-sol")
    }
    while await capture.snapshot().isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }

    let events = await capture.snapshot()
    #expect(events.map(\.phase) == [.started, .cancelled])
    #expect(events.first?.id == events.last?.id)
}

@Test func swiftNativeLLMClient_streamMessagesEmitsOneStartedAndSucceededPair() async throws {
    let capture = LifecycleCapture()
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: SpyAdapter(providerId: "codex"),
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: SpyAdapter(providerId: "openai", response: "streamed"),
        lifecycleObserver: capture
    )

    var text = ""
    for try await event in client.streamMessages(
        messages: [.user("p")], system: nil, model: "gpt-5.6-sol",
        surface: "chat", tools: nil
    ) {
        if case .textDelta(let delta) = event { text += delta }
    }
    let events = await capture.snapshot()
    #expect(text == "streamed")
    #expect(events.map(\.phase) == [.started, .succeeded])
    #expect(events.allSatisfy { $0.streaming })
    #expect(events.first?.id == events.last?.id)
}

@Test func swiftNativeLLMClient_claude_model_dispatches_anthropic() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic", response: "A")
    let openAI = SpyAdapter(providerId: "openai")
    let codex = SpyAdapter(providerId: "codex")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codex, anthropic: anthropic, openAI: openAI
    )
    let out = try await client.complete(prompt: "p", system: nil, model: "claude-3-sonnet")
    #expect(out == "A")
    #expect(anthropic.lastModel == "claude-3-sonnet")
    #expect(openAI.lastModel == nil)
    #expect(codex.lastModel == nil)
}

@Test func swiftNativeLLMClient_gpt_model_dispatches_openai() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic")
    let openAI = SpyAdapter(providerId: "openai", response: "O")
    let codex = SpyAdapter(providerId: "codex")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codex, anthropic: anthropic, openAI: openAI
    )
    let out = try await client.complete(prompt: "p", system: nil, model: "gpt-5.5")
    #expect(out == "O")
    #expect(openAI.lastModel == "gpt-5.5")
    #expect(anthropic.lastModel == nil)
}

@Test func swiftNativeLLMClient_grok_model_dispatches_xai() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic")
    let openAI = SpyAdapter(providerId: "openai")
    let xai = SpyAdapter(providerId: "xai_oauth_direct", response: "X")
    let codex = SpyAdapter(providerId: "codex")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codex,
        anthropic: anthropic,
        openAI: openAI,
        xaiOAuthDirect: xai
    )
    let out = try await client.complete(prompt: "p", system: nil, model: "grok-4.3")
    #expect(out == "X")
    #expect(xai.lastModel == "grok-4.3")
    #expect(openAI.lastModel == nil)
    #expect(anthropic.lastModel == nil)
    #expect(codex.lastModel == nil)
}

@Test func swiftNativeLLMClient_unknown_prefix_dispatches_codex() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic")
    let openAI = SpyAdapter(providerId: "openai")
    let codex = SpyAdapter(providerId: "codex", response: "C")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codex, anthropic: anthropic, openAI: openAI
    )
    let out = try await client.complete(prompt: "p", system: nil, model: "llama-3")
    #expect(out == "C")
    #expect(codex.lastModel == "llama-3")
}

/// M-F3: a pinned Moonshot catalog id with NO active provider must route to
/// the moonshot adapter, never fall through to codex. Parametrized over the
/// LIVE first-party catalog so that the day an account-visible catalog id
/// drops the `kimi-`/`moonshot-` prefix, this test exercises the new
/// catalog-membership guard automatically. (All current ids carry the
/// prefix, so today these hit the prefix branch — the membership guard is the
/// belt-and-suspenders for a non-conforming future id; see M-F3 oracle test.)
@Test(arguments: FirstPartyModelCatalog.moonshotModels.map(\.id))
func swiftNativeLLMClient_moonshotCatalogId_noActiveProvider_routesMoonshot(
    modelID: String
) async throws {
    let anthropic = SpyAdapter(providerId: "anthropic")
    let openAI = SpyAdapter(providerId: "openai")
    let codex = SpyAdapter(providerId: "codex")
    let moonshot = SpyAdapter(providerId: "moonshot", response: "M")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codex,
        anthropic: anthropic,
        openAI: openAI,
        moonshot: moonshot
    )
    let out = try await client.complete(prompt: "p", system: nil, model: modelID)
    #expect(out == "M")
    #expect(moonshot.lastModel == modelID)
    #expect(codex.lastModel == nil)
    #expect(openAI.lastModel == nil)
    #expect(anthropic.lastModel == nil)
}

/// M-F3 (review round 2): the guard must also recognize LIVE-catalog ids —
/// the authenticated /v1/models cache can carry account-visible model ids
/// with NO kimi-/moonshot- prefix, which the static first-party list will
/// never contain. This is the test that actually exercises the non-prefix
/// branch TODAY (the static-list parametrized test above can't until a
/// non-prefixed id ships): write a fake live cache into a temp data root,
/// point the client's moonshotCatalogDataRoot at it, and prove the
/// non-prefixed id routes to moonshot instead of falling through to codex.
@Test func swiftNativeLLMClient_livecacheMoonshotId_nonPrefixed_routesMoonshot() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("moonshot-livecache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let providersDir = tmp.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
    let cache = """
    {"schema_version":1,"source":"test","models":[{"id":"k3-enterprise","name":"K3 Enterprise","context_length":262144}]}
    """
    try Data(cache.utf8).write(to: providersDir.appendingPathComponent("moonshot-models-cache.json"))

    let anthropic = SpyAdapter(providerId: "anthropic")
    let openAI = SpyAdapter(providerId: "openai")
    let codex = SpyAdapter(providerId: "codex")
    let moonshot = SpyAdapter(providerId: "moonshot", response: "M")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codex,
        anthropic: anthropic,
        openAI: openAI,
        moonshot: moonshot,
        moonshotCatalogDataRoot: tmp
    )
    let out = try await client.complete(prompt: "p", system: nil, model: "k3-enterprise")
    #expect(out == "M")
    #expect(moonshot.lastModel == "k3-enterprise")
    #expect(codex.lastModel == nil, "a live-cache moonshot id must not fall through to codex")

    // And a genuinely unknown id in the SAME data root still routes codex —
    // the membership guard must not over-capture.
    let out2 = try await client.complete(prompt: "p", system: nil, model: "llama-3")
    _ = out2
    #expect(codex.lastModel == "llama-3")
}

/// M-F3 oracle: the catalog-membership guard the router leans on
/// (`descriptor(for:providerID:"moonshot")`) resolves every pinned Moonshot
/// id and rejects a non-moonshot id. Proves the fallthrough guard's lookup is
/// sound even though no current catalog id is missing the prefix.
@Test func moonshotCatalogMembershipOracle_isSound() {
    for id in FirstPartyModelCatalog.moonshotModels.map(\.id) {
        #expect(
            FirstPartyModelCatalog.descriptor(for: id, providerID: "moonshot") != nil,
            "expected \(id) to be a recognized moonshot catalog id"
        )
    }
    #expect(FirstPartyModelCatalog.descriptor(for: "llama-3", providerID: "moonshot") == nil)
}

@Test func swiftNativeLLMClient_nil_model_resolves_via_router_modelForSurface() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic", response: "fromRouter")
    let openAI = SpyAdapter(providerId: "openai")
    let codex = SpyAdapter(providerId: "codex")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "claude-3-haiku"),
        codex: codex, anthropic: anthropic, openAI: openAI
    )
    let out = try await client.complete(prompt: "p", system: nil, model: nil)
    #expect(out == "fromRouter")
    #expect(anthropic.lastModel == "claude-3-haiku")
}

@Test func swiftNativeLLMClient_activeProviderOverridesStaleModelForSurface() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic", response: "A")
    let openAI = SpyAdapter(providerId: "openai", response: "O")
    let codex = SpyAdapter(providerId: "codex")
    let provider = Provider(
        id: "anthropic",
        modelCatalog: .array([
            .object(["id": .string("claude-opus-4-8")])
        ])
    )
    let client = SwiftNativeLLMClient(
        router: MockRouter(
            chatModel: "gpt-5.5",
            active: ["telegram": "anthropic"],
            providers: ["anthropic": provider]
        ),
        codex: codex, anthropic: anthropic, openAI: openAI
    )
    let out = try await client.completeMessages(
        messages: [.user("p")],
        system: nil,
        model: "gpt-5.5",
        surface: "telegram",
        tools: nil
    )
    #expect(out == "A")
    #expect(anthropic.lastModel == "claude-opus-4-8")
    #expect(openAI.lastModel == nil)
    #expect(codex.lastModel == nil)
}

@Test func swiftNativeLLMClient_swarmsExplicitWorkerModelMayCrossProvider() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic", response: "A")
    let openAI = SpyAdapter(providerId: "openai", response: "O")
    let client = SwiftNativeLLMClient(
        router: MockRouter(
            chatModel: "claude-opus-4-8",
            active: ["swarms": "anthropic"]
        ),
        codex: SpyAdapter(providerId: "codex"),
        anthropic: anthropic,
        openAI: openAI
    )

    let out = try await client.complete(
        prompt: "p",
        system: nil,
        model: "gpt-5.6-sol",
        surface: "swarms"
    )

    #expect(out == "O")
    #expect(openAI.lastModel == "gpt-5.6-sol")
    #expect(anthropic.lastModel == nil)
}

@Test func swiftNativeLLMClientExplicitModelStillFailsClosedWhenRoutingAuthorityIsUnavailable() async throws {
    let codex = SpyAdapter(providerId: "codex")
    let anthropic = SpyAdapter(providerId: "anthropic")
    let openAI = SpyAdapter(providerId: "openai")
    let client = SwiftNativeLLMClient(
        router: MockRouter(
            chatModel: "gpt-5.6-sol",
            active: ["chat": "openai"],
            checkedSnapshotFails: true
        ),
        codex: codex,
        anthropic: anthropic,
        openAI: openAI
    )

    await #expect(throws: MockRouter.CheckedFailure.unavailable) {
        _ = try await client.complete(
            prompt: "p",
            system: nil,
            model: "gpt-5.6-sol",
            surface: "chat"
        )
    }
    #expect(codex.lastModel == nil)
    #expect(anthropic.lastModel == nil)
    #expect(openAI.lastModel == nil)
}

@Test func swiftNativeLLMClient_exactAPIKeyProviderDoesNotSwapToInstalledOAuth() async throws {
    let apiKey = SpyAdapter(providerId: "openai", response: "api-key")
    let oauth = SpyAdapter(providerId: "openai_oauth_direct", response: "oauth")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "gpt-5.6-sol", active: ["chat": "openai"]),
        codex: SpyAdapter(providerId: "codex"),
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: apiKey,
        openAIOAuthDirect: oauth
    )
    let out = try await client.completeMessages(
        messages: [.user("p")], system: nil, model: "gpt-5.6-sol",
        surface: "chat", tools: nil
    )
    #expect(out == "api-key")
    #expect(apiKey.lastModel == "gpt-5.6-sol")
    #expect(oauth.lastModel == nil)
}

@Test func swiftNativeLLMClient_explicitCodexKeepsBareGPT56Model() async throws {
    let codex = SpyAdapter(providerId: "codex", response: "codex")
    let openAI = SpyAdapter(providerId: "openai", response: "api-key")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "gpt-5.6-sol", active: ["chat": "codex"]),
        codex: codex,
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: openAI
    )

    let out = try await client.completeMessages(
        messages: [.user("p")], system: nil, model: "gpt-5.6-sol",
        surface: "chat", tools: nil
    )

    #expect(out == "codex")
    #expect(codex.lastModel == "gpt-5.6-sol")
    #expect(openAI.lastModel == nil)
}

@Test func swiftNativeLLMClient_turnProviderOverridesPersistedSurfaceProvider() async throws {
    let apiKey = SpyAdapter(providerId: "openai", response: "api-key")
    let oauth = SpyAdapter(providerId: "openai_oauth_direct", response: "oauth")
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "gpt-5.6-sol", active: ["ios": "openai"]),
        codex: SpyAdapter(providerId: "codex"),
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: apiKey,
        openAIOAuthDirect: oauth
    )
    let out = try await LLMCallContext.$providerId.withValue("openai_oauth_direct") {
        try await client.complete(
            prompt: "p", system: nil, model: "gpt-5.6-sol",
            surface: "ios", tools: nil
        )
    }
    #expect(out == "oauth")
    #expect(oauth.lastModel == "gpt-5.6-sol")
    #expect(apiKey.lastModel == nil)
}

@Test func swiftNativeLLMClient_activeXAIProviderOverridesStaleModelForSurface() async throws {
    let anthropic = SpyAdapter(providerId: "anthropic", response: "A")
    let openAI = SpyAdapter(providerId: "openai", response: "O")
    let xai = SpyAdapter(providerId: "xai_oauth_direct", response: "X")
    let codex = SpyAdapter(providerId: "codex")
    let provider = Provider(
        id: "xai_oauth_direct",
        modelCatalog: .array([
            .object(["id": .string("grok-4.3")])
        ])
    )
    let client = SwiftNativeLLMClient(
        router: MockRouter(
            chatModel: "gpt-5.5",
            active: ["telegram": "xai_oauth_direct"],
            providers: ["xai_oauth_direct": provider]
        ),
        codex: codex,
        anthropic: anthropic,
        openAI: openAI,
        xaiOAuthDirect: xai
    )
    let out = try await client.completeMessages(
        messages: [.user("p")],
        system: nil,
        model: "gpt-5.5",
        surface: "telegram",
        tools: nil
    )
    #expect(out == "X")
    #expect(xai.lastModel == "grok-4.3")
    #expect(openAI.lastModel == nil)
    #expect(anthropic.lastModel == nil)
    #expect(codex.lastModel == nil)
}

// MARK: - Streaming adapter tests

@Test func anthropic_adapter_streams_text_deltas_in_order_from_sse() async throws {
    StubURLProtocol.reset()
    // Three text deltas plus noise frames the parser must ignore.
    let sse = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m1"}}

    event: content_block_start
    data: {"type":"content_block_start","index":0}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"lo, "}}

    event: ping
    data: {"type":"ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_stop
    data: {"type":"message_stop"}

    """
    let body = sse.data(using: .utf8)!
    StubURLProtocol.responder = { _ in
        .init(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
    }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    var collected: [String] = []
    for try await chunk in adapter.stream(prompt: "p", system: nil, model: "claude-x") {
        collected.append(chunk)
    }
    #expect(collected == ["Hel", "lo, ", "world"])

    // Body must have stream:true and correct messages payload.
    let bodyData = try #require(StubURLProtocol.lastBody)
    let parsed = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
    #expect(parsed["stream"] as? Bool == true)
    #expect(parsed["model"] as? String == "claude-x")
}

// A3.1: key present → streaming 401 is a positive credential rejection.
@Test func anthropic_adapter_stream_401_throws_authRejected() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in
        .init(status: 401, body: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8))
    }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    var thrown: Error?
    do {
        for try await _ in adapter.stream(prompt: "p", system: nil, model: "m") {}
    } catch {
        thrown = error
    }
    let err = try #require(thrown as? LLMError)
    guard case .authRejected(let provider, _) = err else {
        Issue.record("expected .authRejected, got \(err)")
        return
    }
    #expect(provider == "anthropic")
}

@Test func openai_adapter_streams_text_deltas_in_order_from_sse() async throws {
    StubURLProtocol.reset()
    // Role-only opener, two content deltas, [DONE] sentinel.
    let sse = """
    data: {"choices":[{"delta":{"role":"assistant"}}]}

    data: {"choices":[{"delta":{"content":"foo"}}]}

    data: {"choices":[{"delta":{"content":"bar"}}]}

    data: {"choices":[{"delta":{}}]}

    data: [DONE]

    """
    let body = sse.data(using: .utf8)!
    StubURLProtocol.responder = { _ in
        .init(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
    }
    let adapter = OpenAIAdapter(session: stubSession(), apiKeyOverride: "k")
    var collected: [String] = []
    for try await chunk in adapter.stream(prompt: "p", system: "s", model: "gpt-5.5") {
        collected.append(chunk)
    }
    #expect(collected == ["foo", "bar"])

    let bodyData = try #require(StubURLProtocol.lastBody)
    let parsed = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
    #expect(parsed["stream"] as? Bool == true)
    #expect(parsed["model"] as? String == "gpt-5.5")
}

@Test func openai_adapter_stream_429_throws_transient() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responder = { _ in .init(status: 429, body: Data()) }
    let adapter = OpenAIAdapter(session: stubSession(), apiKeyOverride: "k")
    var thrown: Error?
    do {
        for try await _ in adapter.stream(prompt: "p", system: nil, model: "m") {}
    } catch {
        thrown = error
    }
    let err = try #require(thrown as? LLMError)
    if case .transient = err {} else { Issue.record("wrong: \(err)") }
}

@Test func codex_adapter_streams_chunks_incrementally_from_process_stdout() async throws {
    // Proves: CodexAdapter.stream now flows through CodexStreamingProcessRunner,
    // and three discrete chunks pushed by a mock runner arrive in order through
    // the adapter (no longer collapsed to one). This is the test that would have
    // FAILED before the override existed — the default LLMAdapter.stream impl
    // would have called complete() and yielded one concatenated chunk.
    let streamingRunner: CodexStreamingProcessRunner = { _ in
        AsyncThrowingStream { c in
            c.yield("chunk1-")
            c.yield("chunk2-")
            c.yield("chunk3")
            c.finish()
        }
    }
    let adapter = CodexAdapter(
        codexBin: "/usr/bin/codex",
        timeout: 10,
        streamingRunner: streamingRunner
    )
    var collected: [String] = []
    for try await chunk in adapter.stream(prompt: "p", system: nil, model: "gpt-5.5") {
        collected.append(chunk)
    }
    #expect(collected == ["chunk1-", "chunk2-", "chunk3"])
}

@Test func codex_adapter_streams_multibyte_split_across_reads_preserves_bytes() async throws {
    // Bug A regression: a multibyte UTF-8 codepoint split across two pipe
    // reads used to be silently dropped because String(data:encoding:) returned
    // nil for the read carrying the partial bytes. After the fix the
    // defaultStreamingRunner threads each read through Utf8StreamDecoder, which
    // carries trailing 1-3 bytes of an in-progress codepoint into the next
    // read so the full character round-trips.
    //
    // We use a tiny Swift helper to deterministically emit the 4-byte emoji
    // 😀 (U+1F600 = F0 9F 98 80) split across two separate writes with a
    // sleep in between, so the Process's readabilityHandler is forced to see
    // them as distinct reads.
    let script = """
    import Foundation
    import Darwin
    FileHandle.standardOutput.write(Data("hello ".utf8))
    FileHandle.standardOutput.write(Data([0xf0, 0x9f]))
    usleep(80_000)
    FileHandle.standardOutput.write(Data([0x98, 0x80]))
    FileHandle.standardOutput.write(Data(" world".utf8))
    """
    let inv = CodexProcessInvocation(
        executable: "swift",
        arguments: ["-e", script],
        stdin: "",
        timeout: 10
    )
    let stream = CodexAdapter.defaultStreamingRunner(inv)
    var collected: [String] = []
    for try await chunk in stream {
        collected.append(chunk)
    }
    let joined = collected.joined()
    // The full emoji must survive the split read boundary.
    #expect(joined == "hello \u{1F600} world",
            "split-byte emoji corrupted; got: \(joined.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: ","))")
    // Byte-count check: 6 ("hello ") + 4 (emoji) + 6 (" world") = 16 UTF-8 bytes.
    #expect(joined.utf8.count == 16)
}

@Test func utf8StreamDecoder_carries_partial_codepoint_across_appends() throws {
    // Direct unit test of the decoder logic — deterministic, no subprocess.
    let dec = Utf8StreamDecoder()
    // 😀 = F0 9F 98 80 split 2/2.
    let part1 = Data([0x68, 0x69, 0x20, 0xF0, 0x9F])      // "hi " + first half of emoji
    let part2 = Data([0x98, 0x80, 0x21])                   // second half + "!"
    let out1 = dec.append(part1)
    #expect(out1 == "hi ", "expected only 'hi ' decoded; got: \(String(describing: out1))")
    let out2 = dec.append(part2)
    #expect(out2 == "\u{1F600}!", "expected emoji+'!' after carryover; got: \(String(describing: out2))")
    let (tail, dropped) = dec.drain()
    #expect(tail == nil)
    #expect(dropped == 0)
}

@Test func utf8StreamDecoder_drain_reports_dropped_malformed_trailing_bytes() throws {
    let dec = Utf8StreamDecoder()
    // Only the leading 2 bytes of a 4-byte codepoint, never completed.
    _ = dec.append(Data([0x41, 0xF0, 0x9F]))
    let (tail, dropped) = dec.drain()
    // "A" should have been yielded on the append; only F0 9F linger and drop.
    #expect(tail == nil)
    #expect(dropped == 2)
}

@Test func codex_adapter_stream_terminates_with_throw_on_non_zero_exit() async throws {
    // Proves: a runner that finishes its continuation with an error (the
    // production analog of proc.terminationStatus != 0) propagates that error
    // up through CodexAdapter.stream so the consumer sees it instead of a
    // silent clean-end.
    let streamingRunner: CodexStreamingProcessRunner = { _ in
        AsyncThrowingStream { c in
            c.yield("partial-")
            c.finish(throwing: LLMError.underlying(message: "codex exited 2: boom"))
        }
    }
    let adapter = CodexAdapter(
        codexBin: "/usr/bin/codex",
        timeout: 10,
        streamingRunner: streamingRunner
    )
    var collected: [String] = []
    var thrown: Error?
    do {
        for try await chunk in adapter.stream(prompt: "p", system: nil, model: "gpt-5.5") {
            collected.append(chunk)
        }
    } catch {
        thrown = error
    }
    #expect(collected == ["partial-"])
    let err = try #require(thrown as? LLMError)
    if case .underlying(let msg) = err {
        #expect(msg.contains("boom"))
    } else {
        Issue.record("expected underlying, got: \(err)")
    }
}

@Test func codex_adapter_stream_cancellation_terminates_process() async throws {
    // Proves: a cancelled stream consumer fires the invocation's terminator
    // hook, which in production calls proc.terminate(). Mirrors the existing
    // complete()-path cancellation test for the new streaming path.
    final class TerminateRecorder: @unchecked Sendable {
        let lock = NSLock()
        private var _called = false
        var called: Bool { lock.lock(); defer { lock.unlock() }; return _called }
        func mark() { lock.lock(); _called = true; lock.unlock() }
    }
    let recorder = TerminateRecorder()
    let streamingRunner: CodexStreamingProcessRunner = { inv in
        AsyncThrowingStream { c in
            inv.terminator.register { recorder.mark(); c.finish() }
            c.yield("first")
            // Park indefinitely — only the terminator fire path should end this.
        }
    }
    let adapter = CodexAdapter(
        codexBin: "/usr/bin/codex",
        timeout: 60,
        streamingRunner: streamingRunner
    )
    let consumer = Task {
        do {
            for try await chunk in adapter.stream(prompt: "p", system: nil, model: "gpt-5.5") {
                if chunk == "first" { break }
            }
        } catch {}
    }
    // Give the worker time to enter its parked state and yield "first".
    try? await Task.sleep(nanoseconds: 30_000_000)
    consumer.cancel()
    for _ in 0..<50 {
        if recorder.called { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(recorder.called, "terminator was never fired when stream consumer cancelled")
}

@Test func swiftNativeLLMClient_stream_codex_model_uses_streaming_adapter() async throws {
    // Proves: the SwiftNativeLLMClient prefix dispatch routes codex/* model ids
    // (anything not matching claude*/anthropic/*/gpt*/openai/*) into the codex
    // adapter's stream override — i.e. multiple chunks land, not one. Were the
    // dispatch falling through to LLMAdapter.stream default, the 3-chunk runner
    // output would still arrive in 3 frames (default yields 1 + finish), so we
    // also force a non-yieldable signature: the runner sends 3 distinct chunks
    // and we count them at the consumer.
    let streamingRunner: CodexStreamingProcessRunner = { _ in
        AsyncThrowingStream { c in
            c.yield("a")
            c.yield("b")
            c.yield("c")
            c.finish()
        }
    }
    let codexAdapter = CodexAdapter(
        codexBin: "/usr/bin/codex",
        timeout: 10,
        streamingRunner: streamingRunner
    )
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codexAdapter,
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: SpyAdapter(providerId: "openai")
    )
    var collected: [String] = []
    // "llama-3" doesn't match claude/anthropic/gpt/openai prefixes — falls into
    // the codex branch of the dispatch.
    for try await chunk in client.stream(prompt: "p", system: nil, model: "llama-3") {
        collected.append(chunk)
    }
    #expect(collected == ["a", "b", "c"])
}

@Test func swiftNativeLLMClient_stream_dispatches_by_prefix_to_anthropic() async throws {
    // SwiftNativeLLMClient.stream must route by model-prefix exactly like complete().
    // We verify by using a SpyAdapter that overrides stream() — easier than
    // building a real SSE round-trip through three adapters at once.
    final class StreamSpyAdapter: LLMAdapter, @unchecked Sendable {
        let providerId: String
        var lastModel: String?
        let scripted: [String]
        init(providerId: String, scripted: [String] = []) {
            self.providerId = providerId
            self.scripted = scripted
        }
        func complete(prompt: String, system: String?, model: String) async throws -> String {
            lastModel = model
            return scripted.joined()
        }
        func stream(prompt: String, system: String?, model: String) -> AsyncThrowingStream<String, Error> {
            lastModel = model
            let scripted = self.scripted
            return AsyncThrowingStream { c in
                Task {
                    for s in scripted { c.yield(s) }
                    c.finish()
                }
            }
        }
    }
    let anthropic = StreamSpyAdapter(providerId: "anthropic", scripted: ["A1", "A2"])
    let openAI = StreamSpyAdapter(providerId: "openai", scripted: ["O"])
    let codex = StreamSpyAdapter(providerId: "codex", scripted: ["C"])
    let client = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: codex, anthropic: anthropic, openAI: openAI
    )
    var collected: [String] = []
    for try await chunk in client.stream(prompt: "p", system: nil, model: "claude-3-opus") {
        collected.append(chunk)
    }
    #expect(collected == ["A1", "A2"])
    #expect(anthropic.lastModel == "claude-3-opus")
    #expect(openAI.lastModel == nil)
    #expect(codex.lastModel == nil)
}

// MARK: - Bug A: Anthropic SSE event:error + EOF-without-message_stop tests

@Test func anthropic_adapter_throws_on_event_error_mid_stream() async throws {
    // Anthropic emits `event: error\ndata: {"error":{...}}` mid-stream for
    // overloaded / rate-limit / server-side failures. Previously the parser
    // dropped the whole `event:` line and never saw the data — the consumer
    // got a clean partial reply with no indication of the failure. Now the
    // first delta lands, then the error frame surfaces as providerError.
    StubURLProtocol.reset()
    let sse = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m1"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

    event: error
    data: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}

    """
    let body = sse.data(using: .utf8)!
    StubURLProtocol.responder = { _ in
        .init(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
    }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    var collected: [String] = []
    var thrown: Error?
    do {
        for try await chunk in adapter.stream(prompt: "p", system: nil, model: "claude-x") {
            collected.append(chunk)
        }
    } catch {
        thrown = error
    }
    #expect(collected == ["Hi"])
    let err = try #require(thrown as? LLMError)
    if case .providerError(let msg) = err {
        #expect(msg.contains("overloaded"))
        #expect(msg.contains("Anthropic"))
    } else {
        Issue.record("expected providerError, got: \(err)")
    }
}

@Test func anthropic_adapter_throws_on_eof_without_message_stop() async throws {
    // Stream ends cleanly (EOF) after two deltas with no `event: message_stop`
    // terminal frame — this is what a truncated/dropped connection looks like
    // mid-reply. Previously this returned a clean partial; now it surfaces as
    // streamTruncated so the consumer knows the reply is incomplete.
    StubURLProtocol.reset()
    let sse = """
    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"foo"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"bar"}}

    """
    let body = sse.data(using: .utf8)!
    StubURLProtocol.responder = { _ in
        .init(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
    }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    var collected: [String] = []
    var thrown: Error?
    do {
        for try await chunk in adapter.stream(prompt: "p", system: nil, model: "claude-x") {
            collected.append(chunk)
        }
    } catch {
        thrown = error
    }
    #expect(collected == ["foo", "bar"])
    let err = try #require(thrown as? LLMError)
    if case .streamTruncated(let msg) = err {
        #expect(msg.contains("message_stop"))
    } else {
        Issue.record("expected streamTruncated, got: \(err)")
    }
}

@Test func anthropic_adapter_thinking_only_max_tokens_is_not_blank_success() async throws {
    StubURLProtocol.reset()
    let sse = """
    event: message_start
    data: {"type":"message_start","message":{"usage":{"input_tokens":20}}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"reasoning"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":4096}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    StubURLProtocol.responder = { _ in
        .init(
            status: 200,
            body: Data(sse.utf8),
            headers: ["Content-Type": "text/event-stream"]
        )
    }
    let adapter = AnthropicAdapter(session: stubSession(), apiKeyOverride: "k")
    var thrown: Error?
    do {
        for try await _ in adapter.stream(
            prompt: "build it",
            system: nil,
            model: "claude-opus-5"
        ) {}
    } catch {
        thrown = error
    }
    guard case .providerError(let message)? = thrown as? LLMError else {
        Issue.record("expected providerError, got \(String(describing: thrown))")
        return
    }
    #expect(message.contains("thinking consumed"))
    #expect(message.contains("stop_reason=max_tokens"))
}

// MARK: - Bug B: Stream cancellation propagates to underlying work

@Test func streaming_consumer_cancellation_cancels_underlying_task() async throws {
    // SwiftNativeLLMClient.stream wraps adapter.stream in a Task and now
    // registers continuation.onTermination -> task.cancel(). A consumer that
    // cancels its iteration Task must propagate the cancel into the worker
    // Task so the upstream adapter stops doing work (network reads, etc).
    final class CancelFlag: @unchecked Sendable {
        let lock = NSLock()
        private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    }
    final class CancelTrackingAdapter: LLMAdapter, @unchecked Sendable {
        let providerId = "tracker"
        let cancelled = CancelFlag()
        func complete(prompt: String, system: String?, model: String) async throws -> String {
            return ""
        }
        func stream(prompt: String, system: String?, model: String) -> AsyncThrowingStream<String, Error> {
            return AsyncThrowingStream { continuation in
                let cancelled = self.cancelled
                let task = Task {
                    // Emit one chunk so the consumer has something to receive,
                    // then loop forever until cancelled. If cancellation doesn't
                    // propagate, this loop runs indefinitely.
                    continuation.yield("first")
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    cancelled.set()
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
    let tracker = CancelTrackingAdapter()
    let routedClient = SwiftNativeLLMClient(
        router: MockRouter(chatModel: "ignored"),
        codex: tracker,
        anthropic: SpyAdapter(providerId: "anthropic"),
        openAI: SpyAdapter(providerId: "openai")
    )
    let consumer = Task { () -> Void in
        do {
            for try await chunk in routedClient.stream(prompt: "p", system: nil, model: "llama-3") {
                // After receiving the first chunk, break out of the loop. This
                // causes the AsyncThrowingStream iterator to deinit, which fires
                // onTermination on every continuation in the chain.
                if chunk == "first" { break }
            }
        } catch {
            // Cancellation may surface as CancellationError on the for-await
            // iteration — fine, we just want the upstream cancelled flag.
        }
    }
    // Wait briefly for first chunk + break.
    try? await Task.sleep(nanoseconds: 50_000_000)
    // Belt-and-suspenders: also cancel the consumer Task explicitly, so we
    // exercise both cancellation paths.
    consumer.cancel()
    // Wait up to ~1s for cancel signal to propagate down through wrapper
    // task -> tracker's stream task and the sleep loop to wake.
    for _ in 0..<100 {
        if tracker.cancelled.get() { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(tracker.cancelled.get() == true,
            "tracker's inner task was never cancelled when consumer cancelled")
}

@Test func codex_stream_cancellation_terminates_process() async throws {
    // CodexAdapter.complete() wraps the runner call in
    // withTaskCancellationHandler. A cancelled consumer's Task should fire
    // the terminator the runner published, which in production calls
    // proc.terminate(). We verify by injecting a runner that records the
    // terminator call instead of running a real process.
    //
    // Note: this test exercises the COMPLETE() path's cancellation wiring.
    // The streaming path has its own dedicated cancellation test —
    // codex_adapter_stream_cancellation_terminates_process — since
    // CodexAdapter.stream now overrides the default LLMAdapter.stream and no
    // longer routes through complete().
    final class TerminateRecorder: @unchecked Sendable {
        let lock = NSLock()
        private var _called = false
        var called: Bool {
            lock.lock(); defer { lock.unlock() }; return _called
        }
        func mark() { lock.lock(); _called = true; lock.unlock() }
    }
    let recorder = TerminateRecorder()
    let runner: CodexProcessRunner = { inv in
        // Register the terminator hook the way defaultRunner does.
        inv.terminator.register { recorder.mark() }
        // Block until the task is cancelled, then return a synthesized result.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return CodexProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: false)
    }
    let adapter = CodexAdapter(codexBin: "/usr/bin/codex", timeout: 60, runner: runner)
    let consumer = Task {
        // Direct complete() call — withTaskCancellationHandler in complete()
        // fires the terminator when this consumer Task is cancelled.
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-5.5")
        } catch {}
    }
    // Give the worker time to enter its wait loop.
    try? await Task.sleep(nanoseconds: 30_000_000)
    consumer.cancel()
    // Wait for terminator.fire() to land.
    for _ in 0..<50 {
        if recorder.called { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(recorder.called, "terminate() was never called when consumer cancelled")
}

@Test func codex_stream_fast_exit_immediately_after_run_finishes_stream_cleanly() async throws {
    // Regression for the pre-run() terminationHandler fix: a fast-exit CLI used
    // to be able to terminate BEFORE proc.terminationHandler was assigned (the
    // old code installed it after proc.run()), orphaning the stream so the
    // consumer hung forever. Spawn /usr/bin/true through the real
    // defaultStreamingRunner — it exits ~immediately — and assert the stream
    // finishes inside a 2s window.
    let inv = CodexProcessInvocation(
        executable: "true",
        arguments: [],
        stdin: "",
        timeout: 5
    )
    let consumer = Task<Bool, Never> {
        do {
            for try await _ in CodexAdapter.defaultStreamingRunner(inv) {}
            return true
        } catch {
            return true // exit-0 path expects no throw, but either way the stream finished — not hung
        }
    }
    let timeout = Task<Bool, Never> {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return false
    }
    let finishedCleanly = await withTaskGroup(of: Bool.self) { group -> Bool in
        group.addTask { await consumer.value }
        group.addTask { await timeout.value }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    #expect(finishedCleanly, "stream hung past 2s — terminationHandler race window not closed")
}

@Test func codex_stream_fast_exit_does_not_schedule_orphan_timeout() async throws {
    // Wave 8 round-2: Round-1's 3-layer `finished.get()` guard only flips
    // when the stream's continuation is finished — which happens AFTER
    // terminationHandler completes its drain. During the drain window the
    // scheduler can still pass every guard and successfully store +
    // asyncAfter a no-op DispatchWorkItem that retains proc/pipes/
    // continuation for the full inv.timeout window.
    //
    // Round-2 adds a process-lifecycle `terminating` flag (set as the FIRST
    // statement of terminationHandler, before any drain work) plus a
    // symmetric end-of-handler slot sweep. The invariant under test:
    // every timeout work item that gets scheduled is positively cancelled —
    // i.e. `scheduled == cancelled` across the test run. Pre-fix this is
    // strictly less (orphan leak); post-fix it is equal.
    //
    // Also keeps the original 2s-per-iteration completion assertion as a
    // regression check against the no-hang property from round-1.
    #if DEBUG
    let s0 = CodexAdapterDebugCounters.timeoutScheduled.get()
    let c0 = CodexAdapterDebugCounters.timeoutCancelled.get()
    for _ in 0..<20 {
        let inv = CodexProcessInvocation(
            executable: "true",
            arguments: [],
            stdin: "",
            timeout: 60 // long: a leaked work item would be pending for a full minute
        )
        let consumer = Task<Bool, Never> {
            do {
                for try await _ in CodexAdapter.defaultStreamingRunner(inv) {}
                return true
            } catch {
                return true
            }
        }
        let timeout = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return false
        }
        let finishedCleanly = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await consumer.value }
            group.addTask { await timeout.value }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finishedCleanly, "fast-exit stream did not finish within 2s")
    }
    // Let any pending DispatchWork drain (terminationHandler runs on a
    // background queue; the terminal slot sweep might fire fractionally
    // after the consumer's stream finishes).
    try? await Task.sleep(nanoseconds: 250_000_000)
    let s1 = CodexAdapterDebugCounters.timeoutScheduled.get()
    let c1 = CodexAdapterDebugCounters.timeoutCancelled.get()
    let scheduled = s1 - s0
    let cancelled = c1 - c0
    #expect(
        scheduled == cancelled,
        "orphan timeout work items: scheduled=\(scheduled) cancelled=\(cancelled) — terminationHandler scheduling race not closed"
    )
    #else
    // CodexAdapterDebugCounters is gated behind #if DEBUG in the source.
    // Skip the orphan-timeout invariant assertion in release builds; the
    // no-hang regression assertion above still holds and is exercised by
    // the prior @Test (codex_stream_terminationHandler_no_orphan_timeout).
    Issue.record("skipped in release build: CodexAdapterDebugCounters unavailable")
    return
    #endif
}
} // end @Suite LLMClientRealTests

@Suite("CodexAdapter: defaultRunner fast-exit")
struct CodexDefaultRunnerFastExitTests {
    // Exercises the fast-exit path that BLOCKING #3 left racy: a CLI that
    // terminates between proc.run() returning and a post-run
    // terminationHandler assignment would orphan the continuation and the
    // consumer would hang forever. We point the adapter at /bin/echo (always
    // exits ~immediately with code 0) and assert the call returns within a
    // bounded wall-clock window. A regression here surfaces as the test
    // timing out instead of completing.
    @Test func codexDefaultRunnerFastExitDoesNotHang() async throws {
        let adapter = CodexAdapter(codexBin: "/bin/echo", timeout: 30)
        let done = LockBox<Bool>(false)
        let work = Task<Void, Never> {
            _ = try? await adapter.complete(prompt: "hi", system: nil, model: "fast-exit-test")
            _ = done.swap(true)
        }
        // Bounded wait — 15s is generous for a /bin/echo fast-exit; if the
        // race window reopens the call hangs and we hit this deadline.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if done.get() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        work.cancel()
        #expect(done.get(), "defaultRunner hung — BLOCKING #3 regressed")
    }
}

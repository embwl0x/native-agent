import Testing
import Foundation
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - Round-3 audit, fence W1 (provider routing) regression pins.
//
// F1-H1  native-lane keepalive heartbeat keeps ProviderStreamGuard alive during
//        a slow blocking call (and proves the guard WOULD kill it without one).
// F1-M1  a tools[] bind to a non-native RESOLVED provider throws a loud named
//        error (gate/resolver disagreement) — never silently strips tools.
// F3-M4  OpenRouter streaming lane maps 5xx → .transient (was terminal
//        .invalidResponse); 4xx semantics unchanged.
// F1-L1  applyThinkingControls clamps an unrecognized reasoning_effort to a
//        safe known value instead of silently omitting → provider default.

// ---------------------------------------------------------------------------
// F1-H1 — native-lane keepalive heartbeat
// ---------------------------------------------------------------------------

/// URLProtocol stub that DELAYS its response so the native lane's blocking
/// `completeMessagesWithTools` stays in flight long enough for the guard's idle
/// window to matter. Owns its own static state → the suite is `.serialized`.
private final class DelayingStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var delaySeconds: TimeInterval = 0
    nonisolated(unsafe) static var body: Data = Data("{}".utf8)
    nonisolated(unsafe) static var status: Int = 200

    static func reset() {
        delaySeconds = 0
        body = Data("{}".utf8)
        status = 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Drain any body stream so the request completes cleanly.
        if let stream = request.httpBodyStream {
            stream.open(); while stream.hasBytesAvailable { _ = stream.read(UnsafeMutablePointer<UInt8>.allocate(capacity: 1), maxLength: 1) }; stream.close()
        }
        let delay = Self.delaySeconds
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func delayingSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [DelayingStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

private func w1TempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("w1-round3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let w1Schema = LLMToolSchema(
    name: "git_status",
    description: "Repo state",
    parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
)

@Suite(.serialized)
struct NativeLaneKeepAliveTests {
    /// The heartbeat yields guard-visible activity during a slow blocking call,
    /// so a healthy long-thinking kimi-code turn survives the idle window.
    @Test func heartbeat_keeps_guard_alive_through_slow_blocking_call() async throws {
        DelayingStubURLProtocol.reset()
        DelayingStubURLProtocol.delaySeconds = 3.0
        DelayingStubURLProtocol.body = Data(#"""
        {"content":[{"type":"tool_use","id":"tool_slow","name":"git_status","input":{}}],
         "stop_reason":"tool_use"}
        """#.utf8)
        let root = try w1TempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Heartbeat every 100ms; guard idle window 1.0s. The response does not
        // arrive for 3.0s — WITHOUT the heartbeat the guard kills it at 1.0s.
        // The 10:1 interval-to-idle-window ratio (was 5:1 at 20ms/100ms) gives
        // the heartbeat room to slip repeatedly under full-suite CPU contention
        // before the idle clock could ever trip. wallTimeout stays 10s > 3.0s.
        let adapter = AnthropicAdapter.kimiCode(
            session: delayingSession(),
            apiKeyOverride: "kc",
            dataRootOverride: root,
            telemetryDataRootOverride: root,
            nativeToolKeepAliveInterval: 0.10
        )
        let guarded = ProviderStreamGuard.wrap(
            adapter.streamMessages(messages: [.user("go")], system: nil, model: "k3", tools: [w1Schema]),
            config: ProviderStreamGuardConfig(idleTimeout: 1.0, wallTimeout: 10, checkInterval: 0.05),
            providerLabel: "kimi-code"
        )

        var keepAlives = 0
        var toolCalls: [String] = []
        var thrown: Error?
        do {
            for try await event in guarded {
                switch event {
                case .keepAlive: keepAlives += 1
                case .toolCall(let c): toolCalls.append(c.id)
                case .textDelta: break
                }
            }
        } catch { thrown = error }

        #expect(thrown == nil, "heartbeat should have kept the guard's idle clock alive")
        #expect(keepAlives >= 1, "at least one .keepAlive must reach the guard as activity")
        #expect(toolCalls == ["tool_slow"], "the tool call must still be delivered after the slow call")
    }

    /// NEGATIVE control: with the heartbeat effectively disabled (interval far
    /// beyond the idle window), the SAME slow call is killed by the guard —
    /// proving the heartbeat, not some other slack, is what saves the turn.
    @Test func without_heartbeat_the_guard_kills_the_slow_call() async throws {
        DelayingStubURLProtocol.reset()
        DelayingStubURLProtocol.delaySeconds = 0.40
        DelayingStubURLProtocol.body = Data(#"""
        {"content":[{"type":"tool_use","id":"tool_slow","name":"git_status","input":{}}],
         "stop_reason":"tool_use"}
        """#.utf8)
        let root = try w1TempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = AnthropicAdapter.kimiCode(
            session: delayingSession(),
            apiKeyOverride: "kc",
            dataRootOverride: root,
            telemetryDataRootOverride: root,
            nativeToolKeepAliveInterval: 100  // no beat within the 100ms idle window
        )
        let guarded = ProviderStreamGuard.wrap(
            adapter.streamMessages(messages: [.user("go")], system: nil, model: "k3", tools: [w1Schema]),
            config: ProviderStreamGuardConfig(idleTimeout: 0.10, wallTimeout: 10, checkInterval: 0.01),
            providerLabel: "kimi-code"
        )

        var thrown: Error?
        do {
            for try await _ in guarded {}
        } catch { thrown = error }

        let err = try #require(thrown as? LLMError)
        guard case .transient(let msg) = err else {
            Issue.record("expected idle-timeout .transient, got \(err)")
            return
        }
        #expect(msg.contains("idle timeout"))
        #expect(msg.contains("kimi-code"))
    }
}

// ---------------------------------------------------------------------------
// F1-M1 — gate/resolver disagreement throws a loud named error
// ---------------------------------------------------------------------------

private struct W1Router: ProviderRoutingProtocol {
    var chatModel: String
    var active: [String: String] = [:]
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
    func activeProvidersForSurfaces() async -> [String: String] { active }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        ProviderRoutingSnapshot(
            preferences: try await computeModelPreferences(),
            activeProviders: active,
            pinnedModels: [:]
        )
    }
}

private final class W1NoopAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    init(_ id: String) { providerId = id }
    func complete(prompt: String, system: String?, model: String) async throws -> String { "ok" }
    func streamMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { c in c.yield(.textDelta("SHOULD-NOT-DISPATCH")); c.finish() }
    }
}

@Suite(.serialized)
struct GateResolverDisagreementTests {
    /// A non-nil tools[] means the native GATE opted this turn in. If the
    /// RESOLVER lands on a non-native provider, that's a gate/resolver
    /// disagreement — it must throw LOUD (never hand tools[] to a Claude
    /// adapter, never silently strip them) BEFORE any adapter dispatch.
    @Test func tools_bound_to_non_native_resolved_provider_throws_named_error() async throws {
        // model "claude-opus-4-8" with no active pin resolves to providerId
        // "anthropic" (NOT native-tools capable), while tools[] were supplied.
        let client = SwiftNativeLLMClient(
            router: W1Router(chatModel: "claude-opus-4-8"),
            codex: W1NoopAdapter("codex"),
            anthropic: W1NoopAdapter("anthropic"),
            openAI: W1NoopAdapter("openai")
        )

        var events: [LLMMessageStreamEvent] = []
        var thrown: Error?
        do {
            for try await ev in client.streamMessages(
                messages: [.user("go")], system: nil, model: "claude-opus-4-8",
                surface: "chat", tools: [w1Schema]
            ) { events.append(ev) }
        } catch { thrown = error }

        #expect(events.isEmpty, "must fail BEFORE dispatching to the non-native adapter")
        let err = try #require(thrown as? LLMError)
        guard case .providerError(let msg) = err else {
            Issue.record("expected .providerError, got \(err)")
            return
        }
        #expect(msg.contains("non-native Anthropic-family adapter"))
        #expect(msg.contains("anthropic"))
        #expect(msg.contains("gate/resolver disagreement"))
    }

    /// Round-3 regression pin (caught by chatClient_streamingFreezesOneChecked
    /// RouteAcrossIOSProviderCalls): `tools != nil` is NOT native-lane-
    /// exclusive — the structured tool loop passes provider tool schemas to
    /// EVERY provider for function calling. The guard is scoped to the
    /// `.anthropic` dispatch case; an OpenAI-resolved turn WITH tools[] must
    /// dispatch normally, never throw.
    @Test func tools_bound_to_openai_resolved_provider_dispatches_normally() async throws {
        let client = SwiftNativeLLMClient(
            router: W1Router(chatModel: "gpt-5.5"),
            codex: W1NoopAdapter("codex"),
            anthropic: W1NoopAdapter("anthropic"),
            openAI: W1NoopAdapter("openai")
        )
        var texts: [String] = []
        for try await ev in client.streamMessages(
            messages: [.user("go")], system: nil, model: "gpt-5.5",
            surface: "chat", tools: [w1Schema]
        ) {
            if case .textDelta(let s) = ev { texts.append(s) }
        }
        #expect(texts == ["SHOULD-NOT-DISPATCH"])  // adapter DID dispatch, guard silent
    }

    /// Sanity: tools == nil (the non-native turn shape) never trips the guard —
    /// the same claude model streams normally.
    @Test func nil_tools_does_not_trip_the_guard() async throws {
        let client = SwiftNativeLLMClient(
            router: W1Router(chatModel: "claude-opus-4-8"),
            codex: W1NoopAdapter("codex"),
            anthropic: W1NoopAdapter("anthropic"),
            openAI: W1NoopAdapter("openai")
        )
        var texts: [String] = []
        for try await ev in client.streamMessages(
            messages: [.user("go")], system: nil, model: "claude-opus-4-8",
            surface: "chat", tools: nil
        ) {
            if case .textDelta(let s) = ev { texts.append(s) }
        }
        #expect(texts == ["SHOULD-NOT-DISPATCH"])  // i.e. the adapter DID dispatch
    }
}

// ---------------------------------------------------------------------------
// F3-M4 — OpenRouter streaming 5xx → transient
// ---------------------------------------------------------------------------

private final class OpenRouterW1StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status: Int = 200
    nonisolated(unsafe) static var body: Data = Data()
    static func reset() { status = 200; body = Data() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func openRouterW1Session() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [OpenRouterW1StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

@Suite(.serialized)
struct OpenRouterStreamingStatusTests {
    private func collect(_ stream: AsyncThrowingStream<String, Error>) async -> Error? {
        do { for try await _ in stream {} ; return nil } catch { return error }
    }

    @Test func streaming_5xx_maps_to_transient_with_body() async throws {
        OpenRouterW1StubURLProtocol.reset()
        OpenRouterW1StubURLProtocol.status = 502
        OpenRouterW1StubURLProtocol.body = Data("upstream bad gateway".utf8)
        let adapter = OpenRouterAdapter(session: openRouterW1Session(), apiKeyOverride: "or-key")
        let err = try #require(await collect(
            adapter.stream(prompt: "p", system: nil, model: "anthropic/claude-opus-4-8")
        ) as? LLMError)
        guard case .transient(let msg) = err else {
            Issue.record("expected .transient for streaming 5xx, got \(err)")
            return
        }
        #expect(msg.contains("bad gateway"), "provider body preserved")
    }

    // A3.1: key present (apiKeyOverride) → 401 is a positive credential
    // rejection → .authRejected, not the misleading .notConfigured.
    @Test func streaming_401_maps_to_authRejected() async throws {
        OpenRouterW1StubURLProtocol.reset()
        OpenRouterW1StubURLProtocol.status = 401
        OpenRouterW1StubURLProtocol.body = Data(#"{"error":{"message":"No auth credentials"}}"#.utf8)
        let adapter = OpenRouterAdapter(session: openRouterW1Session(), apiKeyOverride: "or-key")
        let err = try #require(await collect(
            adapter.stream(prompt: "p", system: nil, model: "anthropic/claude-opus-4-8")
        ) as? LLMError)
        guard case .authRejected(let provider, _) = err else {
            Issue.record("expected .authRejected for 401, got \(err)")
            return
        }
        #expect(provider == "openrouter")
    }

    @Test func streaming_4xx_other_stays_invalidResponse() async throws {
        OpenRouterW1StubURLProtocol.reset()
        OpenRouterW1StubURLProtocol.status = 404
        let adapter = OpenRouterAdapter(session: openRouterW1Session(), apiKeyOverride: "or-key")
        let err = try #require(await collect(
            adapter.stream(prompt: "p", system: nil, model: "anthropic/claude-opus-4-8")
        ) as? LLMError)
        guard case .invalidResponse(let status) = err else {
            Issue.record("expected .invalidResponse for other 4xx, got \(err)")
            return
        }
        #expect(status == 404)
    }
}

// ---------------------------------------------------------------------------
// F1-L1 — unknown reasoning_effort clamps to a safe known value
// ---------------------------------------------------------------------------

@Suite(.serialized)
struct ThinkingControlsClampTests {
    private func kimiAdapter(_ root: URL) -> AnthropicAdapter {
        AnthropicAdapter.kimiCode(apiKeyOverride: "kc", dataRootOverride: root, telemetryDataRootOverride: root)
    }

    private func effortAfter(_ value: String?, adapter: AnthropicAdapter) -> String? {
        var body: [String: Any] = [:]
        if let value {
            LLMCallContext.$reasoningEffort.withValue(value) {
                adapter.applyThinkingControls(to: &body)
            }
        } else {
            adapter.applyThinkingControls(to: &body)
        }
        return body["reasoning_effort"] as? String
    }

    @Test func unknown_effort_clamps_to_high_not_provider_default() async throws {
        let root = try w1TempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let adapter = kimiAdapter(root)
        // The bug: an unrecognized string omitted the key → provider default
        // (max). The fix clamps to "high" (a catalog-supported value).
        #expect(effortAfter("banana", adapter: adapter) == "high")
        #expect(effortAfter("ultra", adapter: adapter) == "high")
        #expect(effortAfter("HIGH-ish", adapter: adapter) == "high")
    }

    @Test func known_efforts_are_preserved() async throws {
        let root = try w1TempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let adapter = kimiAdapter(root)
        #expect(effortAfter("low", adapter: adapter) == "low")
        #expect(effortAfter("high", adapter: adapter) == "high")
        #expect(effortAfter("medium", adapter: adapter) == "high")  // legacy medium → high
        #expect(effortAfter("max", adapter: adapter) == "max")
    }

    @Test func none_and_empty_still_omit_the_key() async throws {
        let root = try w1TempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let adapter = kimiAdapter(root)
        // Deliberate "no pin" → omit → provider default. NOT a misconfiguration.
        #expect(effortAfter("none", adapter: adapter) == nil)
        #expect(effortAfter("", adapter: adapter) == nil)
        #expect(effortAfter(nil, adapter: adapter) == nil)
    }

    @Test func non_kimi_provider_never_sets_effort_even_for_unknown_value() async throws {
        let root = try w1TempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        // Plain Anthropic api-key adapter: applyThinkingControls is a no-op
        // (guard providerId == "kimi-code") regardless of the effort string.
        let adapter = AnthropicAdapter(
            apiKeyOverride: "sk", dataRootOverride: root, telemetryDataRootOverride: root)
        #expect(effortAfter("banana", adapter: adapter) == nil)
        #expect(effortAfter("max", adapter: adapter) == nil)
    }
}

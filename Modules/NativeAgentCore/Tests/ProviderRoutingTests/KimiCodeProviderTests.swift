import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// Kimi Code SUBSCRIPTION provider: rides the shared Anthropic Messages wire
// path (AnthropicAdapter) at api.kimi.com/coding with its own credential seam,
// coexisting with the token-billed "moonshot" developer API.

/// Private stub — NOT LLMClientRealTests' shared `StubURLProtocol`. Its
/// `lastRequest`/`reset()` statics are clobbered by concurrently-running
/// suites under parallel execution (flaked canonical 2026-07-20: lastRequest
/// → nil mid-assertion). Same isolation pattern as VisionStubURLProtocol.
private final class KimiStubURLProtocol: URLProtocol, @unchecked Sendable {
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
        KimiStubURLProtocol.lastRequest = request
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
            KimiStubURLProtocol.lastBody = data
        } else {
            KimiStubURLProtocol.lastBody = request.httpBody
        }
        let response = KimiStubURLProtocol.responder?(request)
            ?? Response(status: 200, body: Data("{}".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: nil, headerFields: response.headers)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func kimiStubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [KimiStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

// MARK: - (a) adapter endpoint + key header

@Test func kimiCode_adapter_POSTs_subscription_endpoint_with_key_header() async throws {
    KimiStubURLProtocol.reset()
    KimiStubURLProtocol.responder = { _ in
        let body = #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
        return .init(status: 200, body: body)
    }
    let adapter = AnthropicAdapter.kimiCode(
        session: kimiStubSession(),
        apiKeyOverride: "kc-secret"
    )
    #expect(adapter.providerId == "kimi-code")
    let out = try await adapter.complete(prompt: "p", system: "s", model: "kimi-for-coding")
    #expect(out == "ok")

    let req = try #require(KimiStubURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.kimi.com/coding/v1/messages")
    // Anthropic-style api-key auth (same header the AnthropicAdapter emits).
    #expect(req.value(forHTTPHeaderField: "x-api-key") == "kc-secret")
    #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let body = try #require(KimiStubURLProtocol.lastBody)
    let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(parsed["model"] as? String == "kimi-for-coding")
}

// MARK: - (b) inferProvider classification (+ moonshot coexistence)

@Test func kimiCode_inferProvider_pins_exact_ids_and_preserves_moonshot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimicode-infer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sn = SwiftNativeProviderRouting(dataRoot: root)

    // Kimi Code subscription ids -> kimi-code (ALWAYS), even the kimi- prefixed
    // ones that would otherwise match the moonshot prefix branch.
    #expect(sn.inferProviderForModel("kimi-for-coding") == "kimi-code")
    #expect(sn.inferProviderForModel("kimi-for-coding-highspeed") == "kimi-code")
    #expect(sn.inferProviderForModel("k3") == "kimi-code")
    // Case-insensitive.
    #expect(sn.inferProviderForModel("KIMI-FOR-CODING") == "kimi-code")

    // Existing moonshot ids keep resolving to moonshot.
    #expect(sn.inferProviderForModel("kimi-k3") == "moonshot")
    #expect(sn.inferProviderForModel("kimi-k2.7-code") == "moonshot")
    #expect(sn.inferProviderForModel("kimi-latest") == "moonshot")
    #expect(sn.inferProviderForModel("moonshot-v1-8k") == "moonshot")
}

// MARK: - (c) static catalog

@Test func kimiCode_catalog_lists_exactly_three_models_with_context_lengths() throws {
    let models = FirstPartyModelCatalog.kimiCodeModels
    #expect(models.count == 3)
    #expect(models.map { $0.id } == ["kimi-for-coding", "k3", "kimi-for-coding-highspeed"])

    let byId = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
    #expect(byId["k3"]?.contextLength == 1_048_576)
    #expect(byId["kimi-for-coding"]?.contextLength == 262_144)
    #expect(byId["kimi-for-coding-highspeed"]?.contextLength == 262_144)

    // Provider-scoped descriptor lookup routes "kimi-code" to this catalog.
    let k3 = try #require(FirstPartyModelCatalog.descriptor(for: "k3", providerID: "kimi-code"))
    #expect(k3.contextLength == 1_048_576)
    // A moonshot id is NOT visible under the kimi-code provider scope.
    #expect(FirstPartyModelCatalog.descriptor(for: "kimi-k3", providerID: "kimi-code") == nil)
}

// MARK: - (d) missing key -> notConfigured(provider: "kimi-code")

@Test func kimiCode_adapter_missing_key_throws_notConfigured_kimiCode() async throws {
    // A non-default data root disables process-environment credential reads and
    // has no kimi-code.json, so no key resolves.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimicode-nokey-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let adapter = AnthropicAdapter.kimiCode(
        session: kimiStubSession(),
        dataRootOverride: root
    )
    do {
        _ = try await adapter.complete(prompt: "p", system: nil, model: "kimi-for-coding")
        Issue.record("expected notConfigured throw")
    } catch let err as LLMError {
        #expect(err == .notConfigured(provider: "kimi-code"))
    }
}

// Launch-bug fix round (2026-07-19, User's first live test):
// K3 is a THINKING model — its 200 response leads with a thinking block, and
// the old parse guard demanded content[0].text → "invalid response status 200"
// on success. These pin the tolerant extraction + the thinking request knob.
@Test func joinedTextBlocksSkipsThinkingBlocks() {
    let content: [[String: Any]] = [
        ["type": "thinking", "thinking": "let me reason about this"],
        ["type": "text", "text": "Hello"],
        ["type": "text", "text": " world"],
    ]
    #expect(AnthropicAdapter.joinedTextBlocks(content) == "Hello world")
    // No text blocks at all → empty (caller throws invalidResponse).
    #expect(AnthropicAdapter.joinedTextBlocks([["type": "thinking", "thinking": "x"]]).isEmpty)
}

@Test func kimiCodeThinkingBudgetRidesReasoningEffort() async throws {
    final class CaptureProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
            let reply = #"{"content":[{"type":"text","text":"ok"}],"usage":{}}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CaptureProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config),
        apiKeyOverride: "test-key"
    )
    _ = try await LLMCallContext.$reasoningEffort.withValue("max") {
        try await adapter.complete(prompt: "hi", system: nil, model: "k3")
    }
    let body = try #require(CaptureProtocol.lastBody)
    let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    // Kimi's canonical knob: TOP-LEVEL reasoning_effort, never the K2.x/
    // Anthropic thinking parameter (live-probed contract, 2026-07-19).
    #expect(obj["reasoning_effort"] as? String == "max")
    #expect(obj["thinking"] == nil)

    // Legacy saved "medium" maps to "high"; "none"/unset omits the field
    // (provider default — thinking is always on server-side regardless).
    CaptureProtocol.lastBody = nil
    _ = try await LLMCallContext.$reasoningEffort.withValue("medium") {
        try await adapter.complete(prompt: "hi", system: nil, model: "k3")
    }
    let bodyMed = try #require(CaptureProtocol.lastBody)
    let objMed = try #require(try JSONSerialization.jsonObject(with: bodyMed) as? [String: Any])
    #expect(objMed["reasoning_effort"] as? String == "high")

    CaptureProtocol.lastBody = nil
    _ = try await LLMCallContext.$reasoningEffort.withValue("none") {
        try await adapter.complete(prompt: "hi", system: nil, model: "k3")
    }
    let body2 = try #require(CaptureProtocol.lastBody)
    let obj2 = try #require(try JSONSerialization.jsonObject(with: body2) as? [String: Any])
    #expect(obj2["reasoning_effort"] == nil)
    #expect(obj2["thinking"] == nil)
}

@Test func thinkingResponseParsesOnNonStreamingPath() async throws {
    // A 200 whose content leads with a thinking block must parse, not throw
    // invalidResponse(200) — the exact launch failure.
    final class ThinkingReplyProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let reply = #"{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"hey User"}],"usage":{}}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ThinkingReplyProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config),
        apiKeyOverride: "test-key"
    )
    let reply = try await adapter.complete(prompt: "hi", system: nil, model: "k3")
    #expect(reply == "hey User")
}

@Test func thinkingOnlyMaxTokensTruncationIsNamedNotInvalid() async throws {
    // Live-probed failure shape (2026-07-19): stop_reason=max_tokens with a
    // thinking-only content array. Must surface as a NAMED provider error
    // (budget/effort guidance), never "invalid response status 200".
    final class StarvedReplyProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let reply = #"{"content":[{"type":"thinking","thinking":"deep in thought"}],"stop_reason":"max_tokens","usage":{}}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StarvedReplyProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config),
        apiKeyOverride: "test-key"
    )
    do {
        _ = try await adapter.complete(prompt: "hi", system: nil, model: "k3")
        Issue.record("starved response must throw")
    } catch let error as LLMError {
        guard case .providerError(let message) = error else {
            Issue.record("expected providerError, got \(error)")
            return
        }
        #expect(message.contains("max_tokens"))
        #expect(message.contains("reasoning effort"))
    }
}

@Test func non2xxPreservesProviderErrorBody() async throws {
    // Live incident 2026-07-19: Kimi 403 carried "usage limit for this
    // billing cycle…" and the adapter discarded it → Telegram showed
    // "(internal error)". Non-2xx with an Anthropic error body must surface
    // the provider's own message.
    final class QuotaReplyProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let reply = #"{"error":{"type":"permission_error","message":"You've reached your usage limit for this billing cycle."},"type":"error"}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QuotaReplyProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config), apiKeyOverride: "test-key")
    do {
        _ = try await adapter.complete(prompt: "hi", system: nil, model: "k3")
        Issue.record("403 must throw")
    } catch let error as LLMError {
        guard case .providerError(let message) = error else {
            Issue.record("expected providerError with body, got \(error)"); return
        }
        #expect(message.contains("usage limit for this billing cycle"))
        #expect(message.contains("kimi-code"))
        #expect(message.contains("403"))
    }
}

@Test func emptyText200NonMaxTokensIsNamedTransient() async throws {
    // Live incident 2026-07-20 08:12Z: K3 returned a 200 with zero text
    // blocks and a non-max_tokens stop_reason → the anonymous
    // "invalid response status 200" killed the turn with no retry. Must
    // surface as a NAMED transient (retry ladders match "llm: transient")
    // that says what actually came back.
    final class ThinkingOnlyStopProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let reply = #"{"content":[{"type":"thinking","thinking":"pondering"}],"stop_reason":"end_turn","usage":{}}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ThinkingOnlyStopProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config), apiKeyOverride: "test-key")
    do {
        _ = try await adapter.complete(prompt: "hi", system: nil, model: "k3")
        Issue.record("textless 200 must throw")
    } catch let error as LLMError {
        guard case .transient(let message) = error else {
            Issue.record("expected transient, got \(error)"); return
        }
        #expect(message.contains("no answer text"))
        #expect(message.contains("stop_reason=end_turn"))
        #expect(message.contains("thinking×1"))
        #expect(error.errorDescription?.hasPrefix("llm: transient") == true)
    }
}

@Test func hidden200ErrorEnvelopeSurfacesProviderMessage() async throws {
    // A 200 whose body is an error envelope (no content array) must surface
    // the provider's own message, not "invalid response status 200".
    final class ErrorEnvelope200Protocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let reply = #"{"type":"error","error":{"type":"server_error","message":"internal capacity shortage, please retry"}}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ErrorEnvelope200Protocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config), apiKeyOverride: "test-key")
    do {
        _ = try await adapter.complete(prompt: "hi", system: nil, model: "k3")
        Issue.record("error-envelope 200 must throw")
    } catch let error as LLMError {
        guard case .providerError(let message) = error else {
            Issue.record("expected providerError, got \(error)"); return
        }
        #expect(message.contains("internal capacity shortage"))
        #expect(message.contains("kimi-code"))
    }
}

@Test func streamWithNoTextThrowsTransientNotSilentEmpty() async throws {
    // Streaming parity for the 2026-07-20 empty-200 class: message_stop with
    // zero yielded text and a non-max_tokens stop must throw transient, not
    // finish clean into a silent empty reply.
    final class EmptyStreamProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let sse = [
                "event: message_start",
                #"data: {"type":"message_start","message":{"usage":{}}}"#,
                "",
                "event: message_delta",
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{}}"#,
                "",
                "event: message_stop",
                #"data: {"type":"message_stop"}"#,
                "",
                ""
            ].joined(separator: "\n")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["content-type": "text/event-stream"])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(sse.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [EmptyStreamProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config), apiKeyOverride: "test-key")
    do {
        for try await _ in adapter.stream(prompt: "hi", system: nil, model: "k3") {}
        Issue.record("textless stream must throw")
    } catch let error as LLMError {
        guard case .transient(let message) = error else {
            Issue.record("expected transient, got \(error)"); return
        }
        #expect(message.contains("no answer text"))
        #expect(message.contains("stop_reason=end_turn"))
    }
}

@Test func refusalStop200IsProviderErrorNotTransient() async throws {
    // Anthropic documents stop_reason=refusal as a NORMAL empty-content 200.
    // Deterministic — must be a named providerError (no retry), never
    // transient (gpt-5.5 review, 2026-07-20).
    final class RefusalReplyProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let reply = #"{"content":[],"stop_reason":"refusal","usage":{}}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RefusalReplyProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config), apiKeyOverride: "test-key")
    do {
        _ = try await adapter.complete(prompt: "hi", system: nil, model: "k3")
        Issue.record("refusal must throw")
    } catch let error as LLMError {
        guard case .providerError(let message) = error else {
            Issue.record("expected providerError, got \(error)"); return
        }
        #expect(message.contains("declined"))
        #expect(message.contains("refusal"))
    }
}

@Test func streamRefusalStopIsProviderErrorNotTransient() async throws {
    final class RefusalStreamProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let sse = [
                "event: message_start",
                #"data: {"type":"message_start","message":{"usage":{}}}"#,
                "",
                "event: message_delta",
                #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{}}"#,
                "",
                "event: message_stop",
                #"data: {"type":"message_stop"}"#,
                "",
                ""
            ].joined(separator: "\n")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["content-type": "text/event-stream"])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(sse.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RefusalStreamProtocol.self]
    let adapter = AnthropicAdapter.kimiCode(
        session: URLSession(configuration: config), apiKeyOverride: "test-key")
    do {
        for try await _ in adapter.stream(prompt: "hi", system: nil, model: "k3") {}
        Issue.record("refusal stream must throw")
    } catch let error as LLMError {
        guard case .providerError(let message) = error else {
            Issue.record("expected providerError, got \(error)"); return
        }
        #expect(message.contains("refusal"))
    }
}

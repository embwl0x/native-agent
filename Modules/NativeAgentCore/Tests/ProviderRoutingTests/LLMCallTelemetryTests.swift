import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// U1 steps 1/3/4 (2026-06-10) — telemetry parsing, llm.call row shape,
// Anthropic cache_control breakpoints, OpenAI prompt_cache_key, TTFT.
//
// Suite-private URLProtocol stub: Swift Testing runs suites in parallel and
// `.serialized` only serializes WITHIN a suite — sharing another suite's
// stub class would stomp its static state (same isolation rationale as
// OAuthStubURLProtocol in LLMClient+OpenAIOAuthDirectTests.swift).

final class U1StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        /// When non-nil, the body is delivered as these chunks with
        /// `interChunkDelayMs` of wall-clock between them (and `body` is
        /// ignored) — lets TTFT tests separate "first output frame arrived"
        /// from "stream finished".
        var chunks: [Data]? = nil
        var interChunkDelayMs: Int = 0
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
        U1StubURLProtocol.lastRequest = request
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
        U1StubURLProtocol.lastBody = capturedBody
        guard let responder = U1StubURLProtocol.responder else {
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
        if let chunks = resp.chunks {
            for (i, chunk) in chunks.enumerated() {
                if i > 0, resp.interChunkDelayMs > 0 {
                    Thread.sleep(forTimeInterval: Double(resp.interChunkDelayMs) / 1000.0)
                }
                client?.urlProtocol(self, didLoad: chunk)
            }
        } else {
            client?.urlProtocol(self, didLoad: resp.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Fixtures / helpers

private func u1StubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [U1StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

private func makeTmpDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u1-telemetry-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func readLLMCallRows(dataRoot: URL) -> [[String: Any]] {
    let path = dataRoot
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return [] }
    return raw.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["kind"] as? String) == "llm.call" else { return nil }
        return obj
    }
}

/// Anthropic OAuth auth.json with a long-lived setup_token shape (no
/// expires_at → adapter returns the token as-is, no refresh traffic).
private func writeAnthropicAuthFixture() -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("u1-anth-auth-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("anthropic_oauth_direct.json")
    let blob: [String: Any] = ["access_token": "tok-u1-test"]
    try! JSONSerialization.data(withJSONObject: blob).write(to: path)
    return path
}

/// codex_home/auth.json with a fresh (1h) JWT carrying the chatgpt account
/// claim + persisted account_id so no refresh fires.
private func writeOpenAIAuthFixture() -> URL {
    func b64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
             .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
    let header = b64url(#"{"alg":"none","typ":"JWT"}"#.data(using: .utf8)!)
    let payload: [String: Any] = [
        "exp": Int(Date().timeIntervalSince1970) + 3600,
        "https://api.openai.com/auth": ["chatgpt_account_id": "acct_u1"],
    ]
    let payloadB64 = b64url(try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    let jwt = "\(header).\(payloadB64).sig"
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("u1-oai-auth-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("auth.json")
    let blob: [String: Any] = [
        "tokens": ["access_token": jwt, "account_id": "acct_u1"],
    ]
    try! JSONSerialization.data(withJSONObject: blob).write(to: path)
    return path
}

private func anthropicMessagesResponse(usage: [String: Any]?) -> Data {
    var obj: [String: Any] = [
        "content": [["type": "text", "text": "hello from stub"]],
    ]
    if let usage { obj["usage"] = usage }
    return try! JSONSerialization.data(withJSONObject: obj)
}

private func openAIResponsesSSE(usage: [String: Any]?) -> Data {
    var frames = [
        #"data: {"type":"response.output_text.delta","delta":"hello"}"#,
    ]
    if let usage {
        let usageJSON = String(
            data: try! JSONSerialization.data(withJSONObject: usage),
            encoding: .utf8
        )!
        frames.append(#"data: {"type":"response.completed","response":{"usage":\#(usageJSON)}}"#)
    } else {
        frames.append(#"data: {"type":"response.completed","response":{}}"#)
    }
    return Data((frames.joined(separator: "\n\n") + "\n\n").utf8)
}

// MARK: - Usage parsing (fixture payloads, cache fields present/absent)

@Suite struct LLMUsageParsingTests {
    @Test func anthropicUsage_allFieldsPresent() {
        let usage = LLMUsage.fromAnthropic([
            "input_tokens": 1200,
            "output_tokens": 84,
            "cache_read_input_tokens": 950,
            "cache_creation_input_tokens": 130,
        ])
        #expect(usage.inputTokens == 1200)
        #expect(usage.outputTokens == 84)
        #expect(usage.cacheReadInputTokens == 950)
        #expect(usage.cacheCreationInputTokens == 130)
    }

    @Test func anthropicUsage_cacheFieldsAbsent() {
        let usage = LLMUsage.fromAnthropic(["input_tokens": 10, "output_tokens": 2])
        #expect(usage.inputTokens == 10)
        #expect(usage.outputTokens == 2)
        #expect(usage.cacheReadInputTokens == nil)
        #expect(usage.cacheCreationInputTokens == nil)
        #expect(!usage.isEmpty)
    }

    @Test func anthropicUsage_nilObject_isEmpty() {
        #expect(LLMUsage.fromAnthropic(nil).isEmpty)
    }

    @Test func openAIResponsesUsage_mapsCachedTokens() {
        let usage = LLMUsage.fromOpenAIResponses([
            "input_tokens": 400,
            "input_tokens_details": ["cached_tokens": 256],
            "output_tokens": 31,
        ])
        #expect(usage.inputTokens == 400)
        #expect(usage.outputTokens == 31)
        #expect(usage.cacheReadInputTokens == 256)
        #expect(usage.cacheCreationInputTokens == nil)
    }

    @Test func openAIResponsesUsage_cachedTokensAbsent() {
        let usage = LLMUsage.fromOpenAIResponses(["input_tokens": 5, "output_tokens": 1])
        #expect(usage.cacheReadInputTokens == nil)
    }

    @Test func openAIChatCompletionsUsage_mapsPromptFields() {
        let usage = LLMUsage.fromOpenAIChatCompletions([
            "prompt_tokens": 77,
            "completion_tokens": 9,
            "prompt_tokens_details": ["cached_tokens": 64],
        ])
        #expect(usage.inputTokens == 77)
        #expect(usage.outputTokens == 9)
        #expect(usage.cacheReadInputTokens == 64)
    }

    @Test func merge_laterNonNilWins_nilNeverClobbers() {
        var usage = LLMUsage.fromAnthropic([
            "input_tokens": 100, "cache_read_input_tokens": 60,
        ])
        usage.merge(LLMUsage.fromAnthropic(["output_tokens": 12]))
        #expect(usage.inputTokens == 100)
        #expect(usage.cacheReadInputTokens == 60)
        #expect(usage.outputTokens == 12)
    }

    @Test func parseResponsesSSEDetailed_capturesUsageFromCompleted() {
        let data = openAIResponsesSSE(usage: [
            "input_tokens": 321,
            "input_tokens_details": ["cached_tokens": 300],
            "output_tokens": 7,
        ])
        let parsed = OpenAIOAuthDirectAdapter.parseResponsesSSEDetailed(from: data)
        guard case .text(let s) = parsed.result else {
            Issue.record("expected .text")
            return
        }
        #expect(s == "hello")
        #expect(parsed.usage?.inputTokens == 321)
        #expect(parsed.usage?.cacheReadInputTokens == 300)
        #expect(parsed.usage?.outputTokens == 7)
    }

    @Test func parseResponsesSSEDetailed_noUsage_isNil() {
        let parsed = OpenAIOAuthDirectAdapter.parseResponsesSSEDetailed(
            from: openAIResponsesSSE(usage: nil)
        )
        #expect(parsed.usage == nil)
    }

    // Review nit (2026-06-10): the trailing-unterminated-buffer drain used
    // to only handle text deltas — a final response.completed frame without
    // a blank-line terminator dropped its usage object. The trailing buf now
    // routes through the same payload processor as in-loop frames.
    @Test func parseResponsesSSEDetailed_trailingCompletedFrameWithoutBlankLine_capturesUsage() {
        let raw = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"usage\":"
            + "{\"input_tokens\":50,\"output_tokens\":5,\"input_tokens_details\":{\"cached_tokens\":40}}}}"
        let parsed = OpenAIOAuthDirectAdapter.parseResponsesSSEDetailed(from: Data(raw.utf8))
        guard case .text(let s) = parsed.result else {
            Issue.record("expected .text")
            return
        }
        #expect(s == "hi")
        #expect(parsed.usage?.inputTokens == 50)
        #expect(parsed.usage?.outputTokens == 5)
        #expect(parsed.usage?.cacheReadInputTokens == 40)
    }

    /// Trailing item.done (no blank-line terminator) now emits its marker
    /// through the shared processor — and exactly ONCE (the trailing drain
    /// runs before the defensive pending flush, not after).
    @Test func parseResponsesSSEDetailed_trailingToolDoneFrame_emitsMarkerOnce() {
        let added = #"data: {"type":"response.output_item.added","item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"tool_a","arguments":"{}"}}"#
        let done = #"data: {"type":"response.output_item.done","item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"tool_a"}}"#
        let raw = added + "\n\n" + done // trailing frame, no terminator
        let parsed = OpenAIOAuthDirectAdapter.parseResponsesSSEDetailed(from: Data(raw.utf8))
        guard case .text(let s) = parsed.result else {
            Issue.record("expected .text")
            return
        }
        let markerCount = s.components(separatedBy: "<tool_use").count - 1
        #expect(markerCount == 1)
        #expect(s.contains("id=\"call_1\""))
        #expect(s.contains("name=\"tool_a\""))
    }
}

// MARK: - llm.call row shape

@Suite struct LLMCallTraceRowTests {
    @Test func row_shape_identifiersAndNumbersOnly() async {
        let root = makeTmpDataRoot()
        let recorder = LLMCallTraceRecorder(dataRootOverride: root)
        await LLMCallContext.$surface.withValue("telegram") {
            await recorder.record(
                provider: "anthropic_oauth_direct",
                model: "claude-opus-4-8",
                streaming: true,
                usage: LLMUsage(
                    inputTokens: 1500, outputTokens: 60,
                    cacheReadInputTokens: 1400, cacheCreationInputTokens: 80
                ),
                ttftMs: 412,
                durationMs: 2200
            )
        }
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        #expect(row["kind"] as? String == "llm.call")
        #expect(row["title"] as? String == "claude-opus-4-8")
        #expect(row["status"] as? String == "ok")
        let payload = row["payload"] as? [String: Any] ?? [:]
        #expect(payload["provider"] as? String == "anthropic_oauth_direct")
        #expect(payload["model"] as? String == "claude-opus-4-8")
        #expect(payload["surface"] as? String == "telegram")
        #expect(payload["streaming"] as? Bool == true)
        #expect(payload["inputTokens"] as? Int == 1500)
        #expect(payload["outputTokens"] as? Int == 60)
        #expect(payload["cacheReadInputTokens"] as? Int == 1400)
        #expect(payload["cacheCreationInputTokens"] as? Int == 80)
        #expect(payload["ttftMs"] as? Int == 412)
        #expect(payload["durationMs"] as? Int == 2200)
        // Numbers/identifiers only — the allowed key set IS the contract.
        // turnId (Turn Inspector W1) is an identifier — a UUID correlating the
        // row to its chat turn — not prompt/completion content.
        let allowed: Set<String> = [
            "provider", "model", "surface", "streaming", "durationMs",
            "ttftMs", "inputTokens", "outputTokens",
            "cacheReadInputTokens", "cacheCreationInputTokens",
            "turnId",
        ]
        #expect(Set(payload.keys).isSubset(of: allowed))
        // Unbound (no turn in this hermetic recorder test) → "unknown".
        #expect(payload["turnId"] as? String == "unknown")
    }

    @Test func row_nilFieldsOmitted_surfaceDefaultsUnknown() async {
        let root = makeTmpDataRoot()
        let recorder = LLMCallTraceRecorder(dataRootOverride: root)
        await recorder.record(
            provider: "openai",
            model: "gpt-5.5",
            streaming: false,
            usage: nil,
            ttftMs: nil,
            durationMs: 900
        )
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["surface"] as? String == "unknown")
        #expect(payload["ttftMs"] == nil)
        #expect(payload["inputTokens"] == nil)
    }

    /// Review nit (2026-06-10): production writes are fire-and-forget
    /// (detached task off the provider call's return path). The row still
    /// lands — poll with a deadline instead of expecting it synchronously.
    @Test func record_detachedMode_rowLandsOffReturnPath() async throws {
        let root = makeTmpDataRoot()
        let recorder = LLMCallTraceRecorder(
            dataRootOverride: root,
            synchronousWrites: false
        )
        await recorder.record(
            provider: "anthropic",
            model: "claude-opus-4-8",
            streaming: false,
            usage: nil,
            ttftMs: nil,
            durationMs: 7
        )
        var rows: [[String: Any]] = []
        for _ in 0..<400 {  // 10s deadline — positive step under suite load
            rows = readLLMCallRows(dataRoot: root)
            if !rows.isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(rows.count == 1)
        #expect((rows.first?["payload"] as? [String: Any])?["provider"] as? String == "anthropic")
    }
}

// MARK: - Adapter request-body + streaming telemetry (stub-driven)
//
// ONE serialized suite for every test that touches U1StubURLProtocol's
// static state — Swift Testing parallelizes ACROSS suites, so splitting
// these into multiple suites lets them stomp each other's responder.

@Suite(.serialized) struct U1AdapterRequestBodyTests {
    private func makeOAuthAdapter(telemetryRoot: URL) -> AnthropicOAuthDirectAdapter {
        AnthropicOAuthDirectAdapter(
            session: u1StubSession(),
            authPathOverride: writeAnthropicAuthFixture(),
            telemetryDataRootOverride: telemetryRoot
        )
    }

    private func makeTools() -> [LLMToolSchema] {
        let schema = try! JSONSerialization.data(withJSONObject: [
            "type": "object", "properties": ["q": ["type": "string"]],
        ])
        return [
            LLMToolSchema(name: "tool_a", description: "first", parametersJSON: schema),
            LLMToolSchema(name: "tool_b", description: "last", parametersJSON: schema),
        ]
    }

    @Test func oauthComplete_breakpoints_systemBlocksAndLastTool() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: [
                "input_tokens": 90, "output_tokens": 8,
            ]))
        }
        let root = makeTmpDataRoot()
        let adapter = makeOAuthAdapter(telemetryRoot: root)
        _ = try await adapter.complete(
            prompt: "hi", system: "persona+pins block",
            model: "claude-opus-4-8", tools: makeTools()
        )
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]

        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 2)
        #expect((system[0]["text"] as? String)?.contains("Claude Code") == true)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[1]["text"] as? String == "persona+pins block")
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let tools = body["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 2)
        #expect(tools[0]["cache_control"] == nil)
        #expect((tools[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        // 3 breakpoints total (last tool + 2 system blocks) — under the
        // Anthropic max of 4.
        let breakpoints = system.filter { $0["cache_control"] != nil }.count
            + tools.filter { $0["cache_control"] != nil }.count
        #expect(breakpoints == 3)

        // Telemetry row landed with the parsed usage.
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["inputTokens"] as? Int == 90)
        #expect(payload["outputTokens"] as? Int == 8)
        #expect(payload["streaming"] as? Bool == false)
    }

    @Test func oauthCompleteMessages_sameBreakpoints() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        _ = try await adapter.completeMessages(
            messages: [.user("hi")], system: "sys",
            model: "claude-opus-4-8", tools: makeTools()
        )
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.allSatisfy { $0["cache_control"] != nil })
        let tools = body["tools"] as? [[String: Any]] ?? []
        #expect(tools.last?["cache_control"] != nil)
        #expect(tools.first?["cache_control"] == nil)
        // U1 item 8: UNSEGMENTED tool-capable messages call — identity + sys
        // + last tool + current message breakpoint = 4 ≤ 4 (budget pin).
        let messages = body["messages"] as? [[String: Any]] ?? []
        let messageBlocks: [[String: Any]] = messages.flatMap { msg -> [[String: Any]] in
            (msg["content"] as? [[String: Any]]) ?? []
        }
        let messageBreakpoints = messageBlocks.filter { $0["cache_control"] != nil }.count
        #expect(messageBreakpoints == 1)
        let systemBreakpoints = system.filter { $0["cache_control"] != nil }.count
        let toolBreakpoints = tools.filter { $0["cache_control"] != nil }.count
        #expect(systemBreakpoints + toolBreakpoints + messageBreakpoints == 4)
    }

    @Test func oauthComplete_noTools_omitsToolsKey() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        _ = try await adapter.complete(
            prompt: "hi", system: "sys", model: "claude-opus-4-8", tools: nil
        )
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        #expect(body["tools"] == nil)
    }

    @Test func apiKeyComplete_systemIsBlockArrayWithCacheControl() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: [
                "input_tokens": 40, "output_tokens": 4,
                "cache_read_input_tokens": 30,
            ]))
        }
        let root = makeTmpDataRoot()
        let adapter = AnthropicAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            telemetryDataRootOverride: root
        )
        // 2026-07-21 audit: the combined-block cache breakpoint is gated on
        // the chat-turn signal (LLMCallContext.sessionId) — bind it so this
        // test exercises the chat-turn shape it always represented.
        _ = try await LLMCallContext.$sessionId.withValue("sess-cache") {
            try await adapter.complete(
                prompt: "hi", system: "api-key system prompt", model: "claude-opus-4-8"
            )
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == "api-key system prompt")
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["cacheReadInputTokens"] as? Int == 30)
    }

    /// 2026-07-21 audit (fix 4): a ONE-SHOT caller (no chat-turn session
    /// bound — background loops, dream/REM) must NOT get the ephemeral
    /// breakpoint on the combined system block: stamping it would pay
    /// Anthropic's 1.25x cache-write premium with ~zero read probability.
    /// The block text itself is byte-identical.
    @Test func apiKeyComplete_oneShotCaller_skipsCacheBreakpoint() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = AnthropicAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            telemetryDataRootOverride: makeTmpDataRoot()
        )
        _ = try await adapter.complete(
            prompt: "hi", system: "api-key system prompt", model: "claude-opus-4-8"
        )
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == "api-key system prompt")
        #expect(system[0]["cache_control"] == nil)
    }

    @Test func apiKeyComplete_nilSystem_omitsSystemKey() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = AnthropicAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            telemetryDataRootOverride: makeTmpDataRoot()
        )
        _ = try await adapter.complete(prompt: "hi", system: nil, model: "claude-opus-4-8")
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        #expect(body["system"] == nil)
    }

    @Test func apiKeyAdaptersKeepTelemetryInsideInjectedProviderRoot() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }

        let anthropicRoot = makeTmpDataRoot()
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        _ = try await AnthropicAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            dataRootOverride: anthropicRoot
        ).complete(prompt: "hi", system: nil, model: "claude-opus-4-8")
        #expect(readLLMCallRows(dataRoot: anthropicRoot).count == 1)

        let openAIRoot = makeTmpDataRoot()
        let openAIResponse: [String: Any] = [
            "choices": [["message": ["content": "hello"]]],
        ]
        U1StubURLProtocol.responder = { _ in
            .init(
                status: 200,
                body: try! JSONSerialization.data(withJSONObject: openAIResponse)
            )
        }
        _ = try await OpenAIAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            dataRootOverride: openAIRoot
        ).complete(prompt: "hi", system: nil, model: "gpt-5.5")
        #expect(readLLMCallRows(dataRoot: openAIRoot).count == 1)
    }

    // MARK: OpenAI prompt_cache_key (request-body seam)

    private func makeAdapter(telemetryRoot: URL) -> OpenAIOAuthDirectAdapter {
        OpenAIOAuthDirectAdapter(
            session: u1StubSession(),
            authPathOverride: writeOpenAIAuthFixture(),
            telemetryDataRootOverride: telemetryRoot
        )
    }

    @Test func promptCacheKey_presentWhenSessionBound() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: openAIResponsesSSE(usage: [
                "input_tokens": 200,
                "input_tokens_details": ["cached_tokens": 150],
                "output_tokens": 10,
            ]))
        }
        let root = makeTmpDataRoot()
        let adapter = makeAdapter(telemetryRoot: root)
        let reply = try await LLMCallContext.$sessionId.withValue("sess-42") {
            try await adapter.complete(
                prompt: "hi", system: "sys", model: "gpt-5.5", tools: nil
            )
        }
        #expect(reply == "hello")
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        #expect(body["prompt_cache_key"] as? String == "nativeagent-session-sess-42")
        // store:false intentionally NOT flipped.
        #expect(body["store"] as? Bool == false)

        // Usage telemetry captured from response.completed.
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["inputTokens"] as? Int == 200)
        #expect(payload["cacheReadInputTokens"] as? Int == 150)
        #expect(payload["outputTokens"] as? Int == 10)
    }

    @Test func promptCacheKey_absentWithoutSession() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: openAIResponsesSSE(usage: nil))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpDataRoot())
        _ = try await adapter.complete(
            prompt: "hi", system: "sys", model: "gpt-5.5", tools: nil
        )
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        #expect(body["prompt_cache_key"] == nil)
    }

    @Test func oauthResponsesBodyMapsAccountMaxPresetAndCarriesFastTier() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: openAIResponsesSSE(usage: nil))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpDataRoot())
        _ = try await LLMCallContext.$reasoningEffort.withValue("max") {
            try await LLMCallContext.$serviceTier.withValue("priority") {
                try await adapter.complete(
                    prompt: "hi", system: "sys", model: "gpt-5.6-sol", tools: nil
                )
            }
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let reasoning = body["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "xhigh")
        #expect(body["service_tier"] as? String == "priority")
    }

    @Test func promptCacheKey_presentInStreamMessagesBody() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: openAIResponsesSSE(usage: [
                "input_tokens": 11, "output_tokens": 3,
            ]))
        }
        let root = makeTmpDataRoot()
        let adapter = makeAdapter(telemetryRoot: root)
        let stream = LLMCallContext.$sessionId.withValue("sess-stream") {
            adapter.streamMessages(
                messages: [.user("hi")], system: "sys", model: "gpt-5.5", tools: nil
            )
        }
        var text = ""
        for try await event in stream {
            if case .textDelta(let d) = event { text += d }
        }
        #expect(text == "hello")
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        #expect(body["prompt_cache_key"] as? String == "nativeagent-session-sess-stream")

        // Streaming row: TTFT stamped at first delta + usage from terminal.
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["streaming"] as? Bool == true)
        #expect(payload["ttftMs"] as? Int != nil)
        #expect(payload["inputTokens"] as? Int == 11)
    }

    // MARK: Anthropic streaming TTFT + usage

    @Test func oauthStream_recordsTTFTAndMergedUsage() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        let sse = [
            #"event: message_start"#,
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":500,"cache_read_input_tokens":450,"cache_creation_input_tokens":20}}}"#,
            "",
            #"event: content_block_delta"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hey"}}"#,
            "",
            #"event: message_delta"#,
            #"data: {"type":"message_delta","usage":{"output_tokens":42}}"#,
            "",
            #"event: message_stop"#,
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        U1StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }

        let root = makeTmpDataRoot()
        let adapter = AnthropicOAuthDirectAdapter(
            session: u1StubSession(),
            authPathOverride: writeAnthropicAuthFixture(),
            telemetryDataRootOverride: root
        )
        var text = ""
        for try await chunk in adapter.stream(prompt: "hi", system: "sys", model: "claude-opus-4-8") {
            text += chunk
        }
        #expect(text == "hey")

        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["streaming"] as? Bool == true)
        #expect(payload["ttftMs"] as? Int != nil)
        #expect(payload["inputTokens"] as? Int == 500)
        #expect(payload["cacheReadInputTokens"] as? Int == 450)
        #expect(payload["cacheCreationInputTokens"] as? Int == 20)
        #expect(payload["outputTokens"] as? Int == 42)

        // Streaming body also carries the system-block breakpoints.
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 2)
        #expect(system.allSatisfy { $0["cache_control"] != nil })
    }

    // MARK: U1 step 2b/3b — segmented system blocks (stable/dynamic split)

    private static let segStable = "PERSONA-STABLE persona packet\n\n# Pinned facts (REM-approved overrides)\n- pin"
    private static let segDynamic = "Recent memory:\n- recall hit\n\nConversation history:\n[user] hi"
    private static var segCombined: String { segStable + "\n\n" + segDynamic }

    /// U1 item 8 (F1 lane (b)) repin — was
    /// `oauthCompleteMessages_withSegmentsAndTools_dynamicEndBreakpoint_fourTotal`.
    /// On tool-capable MESSAGES calls the current MESSAGE breakpoint now
    /// takes the budget slot the lane-(a) dynamic-end breakpoint used (the
    /// message breakpoint's prefix covers every system block, so the dynamic
    /// block is cached from iteration 1's write on — lane (a) subsumed).
    /// The lever test below pins the OLD layout under
    /// NATIVE_AGENT_GROWN_PROMPT_COMPAT.
    @Test func oauthCompleteMessages_withSegmentsAndTools_currentMessageBreakpoint_fourTotal() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        _ = try await LLMCallContext.$systemSegments.withValue(segments) {
            try await adapter.completeMessages(
                messages: [.user("hi")], system: Self.segCombined,
                model: "claude-opus-4-8", tools: makeTools()
            )
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]

        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 3)
        // [identity + cc] [stable+"\n\n" + cc] [dynamic, NO cc — covered by
        // the current MESSAGE breakpoint from iteration 1 on].
        // The "\n\n" separator rides as a suffix on the stable block so the
        // emitted block texts concatenate byte-for-byte to the combined sys
        // string.
        #expect((system[0]["text"] as? String)?.contains("Claude Code") == true)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[1]["text"] as? String == Self.segStable + "\n\n")
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[2]["text"] as? String == Self.segDynamic)
        #expect(system[2]["cache_control"] == nil)

        // Current message breakpoint: LAST block of the LAST message.
        let messages = body["messages"] as? [[String: Any]] ?? []
        let lastContent = messages.last?["content"] as? [[String: Any]] ?? []
        #expect((lastContent.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        // Total breakpoints: identity + stable + last tool + current
        // message = 4 — exactly at Anthropic's 4-breakpoint limit, never
        // above.
        let tools = body["tools"] as? [[String: Any]] ?? []
        let systemBreakpoints = system.filter { $0["cache_control"] != nil }.count
        let toolBreakpoints = tools.filter { $0["cache_control"] != nil }.count
        let messageBlocks: [[String: Any]] = messages.flatMap { msg -> [[String: Any]] in
            (msg["content"] as? [[String: Any]]) ?? []
        }
        let messageBreakpoints = messageBlocks.filter { $0["cache_control"] != nil }.count
        #expect(systemBreakpoints + toolBreakpoints + messageBreakpoints == 4)

        // BYTE IDENTITY: the plain concat of the [stable, dynamic] block
        // texts — no separator assumed from the API join — must equal the
        // combined sys string exactly.
        #expect((system[1]["text"] as? String ?? "") + (system[2]["text"] as? String ?? "") == Self.segCombined)
    }

    /// Rollback lever: NATIVE_AGENT_GROWN_PROMPT_COMPAT restores the exact
    /// pre-item-8 wire layout — dynamic-end breakpoint on tool-capable
    /// requests, NO message breakpoint, still ==4 total.
    @Test func oauthCompleteMessages_grownPromptCompatLever_restoresDynamicEndShape() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        _ = try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride.withValue(true) {
            try await LLMCallContext.$systemSegments.withValue(segments) {
                try await adapter.completeMessages(
                    messages: [.user("hi")], system: Self.segCombined,
                    model: "claude-opus-4-8", tools: makeTools()
                )
            }
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]

        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 3)
        #expect((system[2]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let messages = body["messages"] as? [[String: Any]] ?? []
        let messageBlocks: [[String: Any]] = messages.flatMap { msg -> [[String: Any]] in
            (msg["content"] as? [[String: Any]]) ?? []
        }
        let messageBreakpoints = messageBlocks.filter { $0["cache_control"] != nil }.count
        #expect(messageBreakpoints == 0)
        let tools = body["tools"] as? [[String: Any]] ?? []
        let systemBreakpoints = system.filter { $0["cache_control"] != nil }.count
        let toolBreakpoints = tools.filter { $0["cache_control"] != nil }.count
        #expect(systemBreakpoints + toolBreakpoints == 4)
    }

    /// QA-equivalence (adapter layer): the lever moves CACHE MARKERS ONLY.
    /// A multi-iteration tool conversation encoded under both lever states
    /// must produce deep-equal request bodies once every cache_control key
    /// is stripped — model-visible content, order, ids, and roles identical.
    @Test func oauthCompleteMessages_leverStates_bodiesEquivalentModuloCacheControl() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        // Mid-loop fixture: user → assistant(prose + tool_use) → user
        // (tool_result) — the exact shape iteration 2 of the structured
        // tool loop sends.
        let convo: [LLMMessage] = [
            .user("read the file"),
            LLMMessage(role: .assistant, content: [
                .text("reading it"),
                .toolUse(id: "toolu_1", name: "read_file", inputJSON: Data(#"{"path":"a.txt"}"#.utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "toolu_1", content: "contents-of-a", isError: false),
            ]),
        ]

        func capture(compat: Bool) async throws -> [String: Any] {
            try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride.withValue(compat) {
                try await LLMCallContext.$systemSegments.withValue(segments) {
                    _ = try await adapter.completeMessages(
                        messages: convo, system: Self.segCombined,
                        model: "claude-opus-4-8", tools: makeTools()
                    )
                }
            }
            return try JSONSerialization.jsonObject(
                with: U1StubURLProtocol.lastBody ?? Data()
            ) as? [String: Any] ?? [:]
        }

        func stripCacheControl(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                dict["cache_control"] = nil
                return dict.mapValues { stripCacheControl($0) }
            }
            if let arr = value as? [Any] {
                return arr.map { stripCacheControl($0) }
            }
            return value
        }

        let newBody = try await capture(compat: false)
        let oldBody = try await capture(compat: true)
        let newStripped = stripCacheControl(newBody) as? [String: Any] ?? [:]
        let oldStripped = stripCacheControl(oldBody) as? [String: Any] ?? [:]
        #expect(NSDictionary(dictionary: newStripped) == NSDictionary(dictionary: oldStripped))

        // And the new shape's current breakpoint sits ONLY on the last block
        // of the last message — older messages carry none on this structured
        // tool path.
        let messages = newBody["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 3)
        for (i, msg) in messages.enumerated() {
            let blocks = msg["content"] as? [[String: Any]] ?? []
            for (j, block) in blocks.enumerated() {
                let isLastBlockOfLastMessage = i == messages.count - 1 && j == blocks.count - 1
                #expect((block["cache_control"] != nil) == isLastBlockOfLastMessage)
            }
        }
    }

    /// Non-tool messages calls without a reuse hint have no message
    /// breakpoint — body byte-identical to the pre-item-8 shape.
    @Test func oauthCompleteMessages_noTools_noTrailingMessageBreakpoint() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        _ = try await adapter.completeMessages(
            messages: [.user("hi")], system: "sys",
            model: "claude-opus-4-8", tools: nil
        )
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let messageBlocks: [[String: Any]] = messages.flatMap { msg -> [[String: Any]] in
            (msg["content"] as? [[String: Any]]) ?? []
        }
        let messageBreakpoints = messageBlocks.filter { $0["cache_control"] != nil }.count
        #expect(messageBreakpoints == 0)
    }

    @Test func grownPromptCompat_envParser_acceptsTruthyRejectsOthers() async throws {
        typealias Lever = AnthropicOAuthDirectAdapter.GrownPromptCompat
        #expect(Lever.isForced(env: [Lever.envVar: "1"]))
        #expect(Lever.isForced(env: [Lever.envVar: "true"]))
        #expect(Lever.isForced(env: [Lever.envVar: " YES "]))
        #expect(Lever.isForced(env: [Lever.envVar: "on"]))
        #expect(!Lever.isForced(env: [Lever.envVar: "0"]))
        #expect(!Lever.isForced(env: [Lever.envVar: ""]))
        #expect(!Lever.isForced(env: [:]))
    }

    @Test func oauthCompleteMessages_withSegmentsNoTools_dynamicBlockHasNoBreakpoint() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        _ = try await LLMCallContext.$systemSegments.withValue(segments) {
            try await adapter.completeMessages(
                messages: [.user("hi")], system: Self.segCombined,
                model: "claude-opus-4-8", tools: nil
            )
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]

        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 3)
        // NON-tool turn: one call per turn, dynamic churns across turns —
        // a dynamic-end breakpoint would pay the 1.25x write premium with
        // ~zero read probability. The toolCapable gate must hold it off.
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[2]["cache_control"] == nil)
        #expect(body["tools"] == nil)
        let breakpoints = system.filter { $0["cache_control"] != nil }.count
        #expect(breakpoints == 2)
    }

    @Test func oauthComplete_withMismatchedSegments_fallsBackToCombinedBlock() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = makeOAuthAdapter(telemetryRoot: makeTmpDataRoot())
        // Segments that do NOT reassemble into the sys string → the safety
        // guard must keep today's 2-block combined shape.
        let segments = SystemPromptSegments(stable: "OTHER-STABLE", dynamic: "OTHER-DYNAMIC")
        _ = try await LLMCallContext.$systemSegments.withValue(segments) {
            try await adapter.complete(
                prompt: "hi", system: Self.segCombined,
                model: "claude-opus-4-8", tools: nil
            )
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 2)
        #expect(system[1]["text"] as? String == Self.segCombined)
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test func oauthStream_withSegments_dynamicBlockHasNoBreakpoint() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        let sse = [
            #"event: content_block_delta"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hey"}}"#,
            "",
            #"event: message_stop"#,
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        U1StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let adapter = AnthropicOAuthDirectAdapter(
            session: u1StubSession(),
            authPathOverride: writeAnthropicAuthFixture(),
            telemetryDataRootOverride: makeTmpDataRoot()
        )
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        // Sync binding around stream construction — the adapter's inner Task
        // inherits the TaskLocal (same mechanism as sessionId / U1 step 4).
        let stream = LLMCallContext.$systemSegments.withValue(segments) {
            adapter.stream(prompt: "hi", system: Self.segCombined, model: "claude-opus-4-8")
        }
        var text = ""
        for try await chunk in stream { text += chunk }
        #expect(text == "hey")

        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 3)
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[2]["cache_control"] == nil)
        #expect(system[1]["text"] as? String == Self.segStable + "\n\n")
        #expect(system[2]["text"] as? String == Self.segDynamic)
        // BYTE IDENTITY: concat of [stable, dynamic] block texts == combined.
        #expect((system[1]["text"] as? String ?? "") + (system[2]["text"] as? String ?? "") == Self.segCombined)
    }

    @Test func apiKeyComplete_withSegments_twoBlocks_breakpointOnStableOnly() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = AnthropicAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            telemetryDataRootOverride: makeTmpDataRoot()
        )
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        _ = try await LLMCallContext.$systemSegments.withValue(segments) {
            try await adapter.complete(
                prompt: "hi", system: Self.segCombined, model: "claude-opus-4-8"
            )
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 2)
        #expect(system[0]["text"] as? String == Self.segStable + "\n\n")
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[1]["text"] as? String == Self.segDynamic)
        #expect(system[1]["cache_control"] == nil)
        // BYTE IDENTITY: concat of [stable, dynamic] block texts == combined.
        #expect((system[0]["text"] as? String ?? "") + (system[1]["text"] as? String ?? "") == Self.segCombined)
    }

    @Test func apiKeyComplete_withoutSegments_singleCombinedBlock_unchanged() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: anthropicMessagesResponse(usage: nil))
        }
        let adapter = AnthropicAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            telemetryDataRootOverride: makeTmpDataRoot()
        )
        // 2026-07-21 audit: the unsegmented combined block keeps its pre-2b/3b
        // byte shape (breakpoint included) ONLY for cache-eligible chat-turn
        // callers — bind the chat-turn signal (sessionId) so this stays the
        // byte-identity pin it always was. The one-shot shape (no breakpoint)
        // is pinned in apiKeyComplete_oneShotCaller_skipsCacheBreakpoint.
        _ = try await LLMCallContext.$sessionId.withValue("sess-unseg") {
            try await adapter.complete(
                prompt: "hi", system: Self.segCombined, model: "claude-opus-4-8"
            )
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == Self.segCombined)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    // OpenAI prefix note (U1 step 2b/3b item 4): the Responses path sends
    // `instructions` as ONE string — with segments bound it must remain the
    // SAME combined system string (stable + "\n\n" + dynamic order), so
    // implicit prefix caching + prompt_cache_key keep benefiting and the
    // segments never alter the OpenAI body.
    @Test func openAIInstructions_withSegmentsBound_equalsCombinedSystem() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: openAIResponsesSSE(usage: nil))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpDataRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        #expect(segments.combined == Self.segCombined)
        _ = try await LLMCallContext.$systemSegments.withValue(segments) {
            try await LLMCallContext.$sessionId.withValue("sess-seg") {
                try await adapter.complete(
                    prompt: "hi", system: Self.segCombined, model: "gpt-5.5", tools: nil
                )
            }
        }
        let body = try JSONSerialization.jsonObject(
            with: U1StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
        // instructions == stable + "\n\n" + dynamic (same bytes as the
        // combined systemPrompt) — segments must not perturb the OpenAI body.
        #expect(body["instructions"] as? String == Self.segCombined)
        #expect(body["prompt_cache_key"] as? String == "nativeagent-session-sess-seg")
    }

    // MARK: Review blocker 2 — no "ok" row before pieces validation

    /// A 200 whose content has only unsupported block types (thinking-only)
    /// must throw invalidResponse AND record NO llm.call row — the record
    /// used to fire before the pieces.isEmpty check.
    @Test func oauthComplete_unsupportedContentOnly_throwsWithoutOkRow() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        let body: [String: Any] = [
            "content": [["type": "thinking", "thinking": "hmm"]],
            "usage": ["input_tokens": 10, "output_tokens": 1],
        ]
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        }
        let root = makeTmpDataRoot()
        let adapter = makeOAuthAdapter(telemetryRoot: root)
        await #expect(throws: LLMError.self) {
            _ = try await adapter.complete(
                prompt: "hi", system: "sys", model: "claude-opus-4-8", tools: nil
            )
        }
        #expect(readLLMCallRows(dataRoot: root).isEmpty)
    }

    @Test func oauthCompleteMessages_unsupportedContentOnly_throwsWithoutOkRow() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        let body: [String: Any] = [
            "content": [] as [[String: Any]],
            "usage": ["input_tokens": 10, "output_tokens": 1],
        ]
        U1StubURLProtocol.responder = { _ in
            .init(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        }
        let root = makeTmpDataRoot()
        let adapter = makeOAuthAdapter(telemetryRoot: root)
        await #expect(throws: LLMError.self) {
            _ = try await adapter.completeMessages(
                messages: [.user("hi")], system: "sys",
                model: "claude-opus-4-8", tools: nil
            )
        }
        #expect(readLLMCallRows(dataRoot: root).isEmpty)
    }

    // MARK: Review blocker 3 — api-key OpenAI STREAMING telemetry

    /// The Chat Completions SSE path records a timing-only row at [DONE]:
    /// durationMs + ttftMs present, token fields nil (no stream_options
    /// request change — behavior constraint stands).
    @Test func apiKeyOpenAIStream_recordsTimingOnlyRowAtDone() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        // R15: events are delimited by blank lines (spec-valid SSE, what
        // providers actually send). The old per-line parser tolerated the
        // missing delimiters; the shared decoder frames per spec so that
        // legitimately multi-line `data:` payloads accumulate correctly.
        let sse = [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"hel"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
            "data: [DONE]",
            "",
        ].joined(separator: "\n\n")
        U1StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let root = makeTmpDataRoot()
        let adapter = OpenAIAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            telemetryDataRootOverride: root
        )
        var text = ""
        for try await chunk in adapter.stream(prompt: "hi", system: "sys", model: "gpt-5.5") {
            text += chunk
        }
        #expect(text == "hello")
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["provider"] as? String == "openai")
        #expect(payload["streaming"] as? Bool == true)
        #expect(payload["ttftMs"] as? Int != nil)
        #expect(payload["durationMs"] as? Int != nil)
        #expect(payload["inputTokens"] == nil)
        #expect(payload["outputTokens"] == nil)
        #expect(payload["cacheReadInputTokens"] == nil)
    }

    /// Truncation (EOF without [DONE]) throws streamTruncated and records
    /// NO row — the row is success-only.
    @Test func apiKeyOpenAIStream_truncated_recordsNoRow() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        let sse = #"data: {"choices":[{"delta":{"content":"partial"}}]}"# + "\n"
        U1StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let root = makeTmpDataRoot()
        let adapter = OpenAIAdapter(
            session: u1StubSession(),
            apiKeyOverride: "sk-test",
            telemetryDataRootOverride: root
        )
        await #expect(throws: LLMError.self) {
            for try await _ in adapter.stream(prompt: "hi", system: "sys", model: "gpt-5.5") {}
        }
        #expect(readLLMCallRows(dataRoot: root).isEmpty)
    }

    // MARK: Review blocker 4 — TTFT for tool-call-first responses

    /// TTFT must stamp at the FIRST meaningful output frame
    /// (output_item.added for a function_call), NOT at output_item.done
    /// after the whole argument stream. The stub delivers the `added` frame
    /// immediately, then sleeps 500ms before the argument/done/completed
    /// frames — so a done-stamped TTFT would read ≥500ms while an
    /// added-stamped one reads near-zero.
    @Test func oauthOpenAIStreamMessages_toolCallFirst_ttftStampsAtFirstOutputFrame() async throws {
        U1StubURLProtocol.reset()
        defer { U1StubURLProtocol.reset() }
        // CFNetwork holds the first body bytes in an internal buffer
        // (~512B) before handing them to AsyncBytes — pad the first chunk
        // with an ignorable non-`data:` line so the `added` frame actually
        // reaches the parser BEFORE the inter-chunk sleep.
        let addedChunk = Data((
            String(repeating: ":", count: 4096) + "\n"
            + #"data: {"type":"response.output_item.added","item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"tool_a","arguments":""}}"#
            + "\n\n"
        ).utf8)
        let tailChunk = Data((
            #"data: {"type":"response.function_call_arguments.delta","item_id":"item_1","delta":"{\"q\":\"x\"}"}"#
            + "\n\n"
            + #"data: {"type":"response.output_item.done","item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"tool_a"}}"#
            + "\n\n"
            + #"data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2}}}"#
            + "\n\n"
        ).utf8)
        U1StubURLProtocol.responder = { _ in
            .init(
                status: 200, body: Data(),
                chunks: [addedChunk, tailChunk], interChunkDelayMs: 500
            )
        }
        let root = makeTmpDataRoot()
        let adapter = makeAdapter(telemetryRoot: root)
        var toolCallNames: [String] = []
        let stream = adapter.streamMessages(
            messages: [.user("hi")], system: "sys", model: "gpt-5.5", tools: nil
        )
        for try await event in stream {
            if case .toolCall(let call) = event { toolCallNames.append(call.name) }
        }
        #expect(toolCallNames == ["tool_a"])
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        let ttftMs = payload["ttftMs"] as? Int
        let durationMs = payload["durationMs"] as? Int
        #expect(ttftMs != nil)
        #expect(durationMs != nil)
        // The stream itself spanned the gap.
        #expect((durationMs ?? 0) >= 400)
        if let ttftMs, let durationMs {
            // Under the full package's parallel run, the first chunk can be
            // delayed by scheduler contention. The contract is ordering: TTFT
            // must stamp before the delayed tail, not at output_item.done.
            #expect(ttftMs < durationMs)
            #expect(durationMs - ttftMs >= 350)
        }
        #expect(payload["inputTokens"] as? Int == 10)
        #expect(payload["outputTokens"] as? Int == 2)
    }
}

// MARK: - Trace write serialization (2026-07-21 audit)

@Suite(.serialized) struct LLMCallTraceRecorderConcurrencyTests {
    /// record() writes fire-and-forget on a detached utility task. Before the
    /// fix, concurrent provider calls serialized on the events.jsonl flock in
    /// nondeterministic order and a racing trimLocked could drop a sibling's
    /// fresh row. Writes now route through ONE shared actor queue (the
    /// SessionUsageReceiptWriter pattern) — this pins the observable contract:
    /// N concurrent records → N durable, distinct rows.
    @Test func concurrentDetachedRecordsDoNotLoseRows() async throws {
        let root = makeTmpDataRoot()
        let recorder = LLMCallTraceRecorder(
            dataRootOverride: root,
            synchronousWrites: false
        )
        let count = 40
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    await recorder.record(
                        provider: "provider-\(i)",
                        model: "m",
                        streaming: false,
                        usage: nil,
                        ttftMs: nil,
                        durationMs: i
                    )
                }
            }
        }
        // Detached writes settle asynchronously — poll with a hard bound.
        let deadline = Date().addingTimeInterval(15)
        var rows: [[String: Any]] = []
        while Date() < deadline {
            rows = readLLMCallRows(dataRoot: root)
            if rows.count >= count { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(rows.count == count)
        let providers = Set(rows.compactMap {
            ($0["payload"] as? [String: Any])?["provider"] as? String
        })
        #expect(providers.count == count)
    }
}

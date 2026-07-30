import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// U1 item 9 (2026-06-11) — real SSE over messages-shaped bodies in the
// Anthropic OAuth adapter. Pins:
//   (1) streamMessages is TRUE streaming: text deltas arrive as MULTIPLE
//       events while the response is still in flight (the LLMAdapter
//       default fell back to non-streaming completeMessages and yielded ONE
//       flattened delta — that fallback killed live deltas on the
//       text-compat chat path); TTFT is recorded from the first output
//       frame, strictly earlier than stream completion.
//   (2) ONE shared body encoder: the streamMessages request body deep-equals
//       the completeMessages body modulo the `stream` key, so the streaming
//       transport can never drift from the item-8 wire shape.
//   (3) Breakpoint budget on the text-compat shape (tools nil +
//       MessagesCacheHint.withinTurnReuse): identity + stable-end +
//       current message = 3 on the first request, then previous+current = 4;
//       with tools (structured streaming loop): identity + stable-end +
//       last-tool + current message = 4.
//   (4) The ONE rollback lever (NATIVE_AGENT_GROWN_PROMPT_COMPAT) restores
//       the legacy layout on this transport too: no message breakpoint.
//   (5) Structured tool_use SSE blocks (content_block_start →
//       input_json_delta → content_block_stop) assemble into .toolCall
//       events with the provider id + full JSON input.
//   (6) .notConfigured propagates BEFORE any yield (api-key fallback chain
//       contract in SwiftNativeLLMClient stays intact).
// Fix-round pins (gpt-5.5 review 2026-06-11):
//   (7) Breakpoint-contract matrix — trailing message breakpoint iff
//       (tool-capable OR withinTurnReuse-hinted) AND eligible AND not
//       compat; budget ≤ 4 across all 16 hint × tools × segmented × compat
//       combinations (never a 5th).
//   (8) Tool-call-first TTFT stamps at content_block_start (OpenAI
//       structured-parser parity), strictly before content_block_stop.
//   (9) Mid-stream bytes.lines transport errors classify .transient via
//       transientNetworkError; consumer cancellation tears down the
//       URLSession task (stub stopLoading observed).
//
// Suite-private URLProtocol stub: Swift Testing parallelizes ACROSS suites
// — sharing another suite's stub class would stomp its static state (same
// isolation rationale as U1StubURLProtocol).

final class Item9StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var chunks: [Data]? = nil
        var interChunkDelayMs: Int = 0
        /// Mid-stream transport failure: after delivering body/chunks, fail
        /// the load with this error instead of finishing — exercises the
        /// bytes.lines error path (transient classification pin).
        var midStreamError: Error? = nil
        /// Leave the connection OPEN after delivering body/chunks (no
        /// didFinishLoading): the consumer can read the first delta while
        /// the stream is still live, then cancel (cancellation pin).
        var stallAfterDelivery: Bool = false
    }
    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var lastBody: Data?
    /// Cancellation observation hook: URLSession calls stopLoading() on the
    /// protocol instance when the underlying data task is cancelled — the
    /// cancellation test uses this to prove onTermination → task.cancel()
    /// actually tears the URLSession task down.
    nonisolated(unsafe) static var onStopLoading: (() -> Void)?

    static func reset() {
        responder = nil
        lastBody = nil
        onStopLoading = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
        Item9StubURLProtocol.lastBody = capturedBody
        guard let responder = Item9StubURLProtocol.responder else {
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
        if let err = resp.midStreamError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        if resp.stallAfterDelivery {
            // Connection intentionally left open — no finish. startLoading
            // returns so URLSession can call stopLoading() on cancel.
            return
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Item9StubURLProtocol.onStopLoading?()
    }
}

private func item9StubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [Item9StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

private func makeTmpRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u1-item9-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeAuthFixture() -> URL {
    let base = makeTmpRoot()
    let path = base.appendingPathComponent("anthropic_oauth_direct.json")
    try! JSONSerialization.data(withJSONObject: ["access_token": "tok-item9"]).write(to: path)
    return path
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

/// URLSession coalesces small URLProtocol `didLoad` writes in an internal
/// buffer, so a chunked stub does NOT reach `AsyncBytes` incrementally —
/// the timing-sensitive tests in this file saw all events land in one
/// burst (ttft == duration; deltas dropped before a mid-stream error).
/// Appending a slab of SSE comment lines after each meaningful chunk
/// flushes it through (": ..." lines are skipped by the adapter's
/// "event: "/"data: " prefix guards, exactly like real SSE keep-alive
/// comments). 64KB comfortably exceeds the coalescing threshold.
/// MUST be appended only at LINE boundaries.
private let sseFlushPadding: Data = {
    let line = ": padding-flush\n"
    return Data(String(repeating: line, count: (64 * 1024) / line.utf8.count + 1).utf8)
}()

private func sseTextStream(deltas: [String]) -> String {
    var frames: [String] = [
        "event: message_start",
        #"data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":100}}}"#,
        "",
    ]
    for d in deltas {
        frames.append("event: content_block_delta")
        frames.append(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(d)"}}"#)
        frames.append("")
    }
    frames.append(contentsOf: [
        "event: message_delta",
        #"data: {"type":"message_delta","usage":{"output_tokens":9}}"#,
        "",
        "event: message_stop",
        #"data: {"type":"message_stop"}"#,
        "",
    ])
    return frames.joined(separator: "\n")
}

@Suite(.serialized) struct AnthropicStreamMessagesSSETests {
    private func makeAdapter(telemetryRoot: URL, authPath: URL? = nil) -> AnthropicOAuthDirectAdapter {
        AnthropicOAuthDirectAdapter(
            session: item9StubSession(),
            authPathOverride: authPath ?? writeAuthFixture(),
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

    private static let segStable = "PERSONA-STABLE persona packet\n\n# Pinned facts\n- pin"
    private static let segDynamic = "Recent memory:\n- hit\n\nConversation history:\n[user] hi"
    private static var segCombined: String { segStable + "\n\n" + segDynamic }

    private func lastRequestBody() throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: Item9StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any] ?? [:]
    }

    private func breakpointCounts(_ body: [String: Any]) -> (system: Int, tools: Int, messages: Int) {
        let system = (body["system"] as? [[String: Any]] ?? [])
            .filter { $0["cache_control"] != nil }.count
        let tools = (body["tools"] as? [[String: Any]] ?? [])
            .filter { $0["cache_control"] != nil }.count
        let messages = (body["messages"] as? [[String: Any]] ?? [])
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["cache_control"] != nil }.count
        return (system, tools, messages)
    }

    // (1) TRUE streaming: multiple delta events, TTFT strictly before
    // completion. Chunked stub with wall-clock gaps separates "first output
    // frame arrived" from "stream finished" — the dead fallback yielded
    // exactly ONE flattened delta after the whole response.
    @Test func streamMessages_yieldsIncrementalDeltas_ttftBeforeCompletion() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        // Line-bounded chunks with 60ms gaps: first delta frame in chunk 1,
        // rest later. Each non-final chunk carries flush padding so it
        // genuinely reaches AsyncBytes before the next gap (the old
        // byte-third split also cut lines mid-frame — padding requires
        // line-boundary chunking).
        func frame(_ text: String) -> String {
            "event: content_block_delta\n"
                + #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(text)"}}"#
                + "\n\n"
        }
        let head = "event: message_start\n"
            + #"data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":100}}}"#
            + "\n\n"
        let tail = "event: message_delta\n"
            + #"data: {"type":"message_delta","usage":{"output_tokens":9}}"#
            + "\n\nevent: message_stop\n"
            + #"data: {"type":"message_stop"}"#
            + "\n\n"
        let chunks = [
            Data((head + frame("Hel")).utf8) + sseFlushPadding,
            Data(frame("lo ").utf8) + sseFlushPadding,
            Data((frame("the user") + tail).utf8),
        ]
        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(), chunks: chunks, interChunkDelayMs: 60)
        }
        let root = makeTmpRoot()
        let adapter = makeAdapter(telemetryRoot: root)
        var deltas: [String] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: "sys",
            model: "claude-opus-4-8", tools: nil
        ) {
            if case .textDelta(let s) = event { deltas.append(s) }
        }
        // MULTIPLE incremental deltas — not one flattened reply.
        #expect(deltas == ["Hel", "lo ", "the user"])
        #expect(deltas.count > 1)

        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        #expect(payload["streaming"] as? Bool == true)
        let ttft = payload["ttftMs"] as? Int
        let duration = payload["durationMs"] as? Int
        #expect(ttft != nil)
        #expect(duration != nil)
        // Two 60ms inter-chunk gaps follow the first delta frame: TTFT must
        // land strictly before total duration (live deltas, not flatten).
        if let ttft, let duration {
            #expect(ttft < duration)
        }
        #expect(payload["inputTokens"] as? Int == 120)
        #expect(payload["cacheReadInputTokens"] as? Int == 100)
        #expect(payload["outputTokens"] as? Int == 9)
    }

    // (5) Structured tool_use SSE: start → input_json_delta x2 → stop
    // assembles ONE .toolCall with id + full JSON.
    @Test func streamMessages_toolUseBlocks_yieldToolCallEvents() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let sse = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"calling"}}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_9","name":"tool_a"}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"\"x\"}"}}"#,
            "",
            "event: content_block_stop",
            #"data: {"type":"content_block_stop"}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: "sys",
            model: "claude-opus-4-8", tools: makeTools()
        ) {
            events.append(event)
        }
        // input_json_delta frames emit `.keepAlive` (liveness, no content) —
        // filter them; the CONTENT events are the text delta + the tool call.
        let content = events.filter { $0 != .keepAlive }
        #expect(content.count == 2)
        #expect(content.first == .textDelta("calling"))
        if case .toolCall(let call)? = content.last {
            #expect(call.id == "toolu_9")
            #expect(call.name == "tool_a")
            #expect(String(data: call.inputJSON, encoding: .utf8) == #"{"q":"x"}"#)
        } else {
            Issue.record("expected a .toolCall event")
        }
        // No empty content delta ever leaks (the bug this guards): keepalives
        // are `.keepAlive`, never `.textDelta("")`.
        #expect(!events.contains(.textDelta("")))
        // Liveness IS emitted (audit #4): the 2 input_json_delta frames each
        // produce a keepalive so ProviderStreamGuard's idle clock survives.
        #expect(events.filter { $0 == .keepAlive }.count == 2)
    }

    // keepAlive liveness (audit #4 + empty-delta-leak fix, 2026-06-15): a
    // thinking_delta carries NO user-visible content but must still yield a
    // `.keepAlive` (so ProviderStreamGuard's idle clock doesn't kill a long
    // reasoning turn) — and NEVER a `.textDelta("")` (the leak this fixes).
    @Test func streamMessages_thinkingDelta_yieldsKeepAliveNotEmptyText() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let sse = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"pondering"}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: "sys", model: "claude-opus-4-8", tools: nil
        ) { events.append(event) }
        #expect(events.contains(.keepAlive))         // liveness preserved
        #expect(!events.contains(.textDelta("")))    // no empty content leak
        let texts = events.compactMap { e -> String? in
            if case .textDelta(let s) = e { return s }; return nil
        }
        #expect(texts == ["answer"])                 // thinking never enters reply text
    }

    @Test func streamMessages_thinkingExhaustsBudget_throwsHonestProviderError() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let sse = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_creation_input_tokens":90}}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"still reasoning"}}"#,
            "",
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":4096}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let root = makeTmpRoot()
        let adapter = makeAdapter(telemetryRoot: root)
        var thrown: Error?
        do {
            for try await _ in adapter.streamMessages(
                messages: [.user("build it")], system: "sys",
                model: "claude-opus-5", tools: makeTools()
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
        let payload = readLLMCallRows(dataRoot: root).first?["payload"] as? [String: Any]
        #expect(payload?["outputTokens"] as? Int == 4096)
        #expect(payload?["cacheCreationInputTokens"] as? Int == 90)
    }

    @Test func streamMessages_cleanEndTurnWithoutTextOrTool_throwsTransient() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let sse = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
            "",
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        var thrown: Error?
        do {
            for try await _ in adapter.streamMessages(
                messages: [.user("hello")], system: "sys",
                model: "claude-opus-5", tools: nil
            ) {}
        } catch {
            thrown = error
        }
        guard case .transient(let message)? = thrown as? LLMError else {
            Issue.record("expected transient, got \(String(describing: thrown))")
            return
        }
        #expect(message.contains("no answer text or tool call"))
        #expect(message.contains("stop_reason=end_turn"))
    }

    // (2) ONE shared encoder: streaming body == non-streaming body modulo
    // the `stream` key (same messages, system, segments, tools).
    @Test func streamMessages_bodyDeepEqualsCompleteMessages_moduloStreamKey() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let convo: [LLMMessage] = [
            .user("read the file"),
            LLMMessage(role: .assistant, content: [
                .text("reading it"),
                .toolUse(id: "toolu_1", name: "tool_a", inputJSON: Data(#"{"q":"a"}"#.utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "toolu_1", content: "contents", isError: false),
            ]),
        ]
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())

        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "ok"]],
            ]))
        }
        _ = try await LLMCallContext.$systemSegments.withValue(segments) {
            try await adapter.completeMessages(
                messages: convo, system: Self.segCombined,
                model: "claude-opus-4-8", tools: makeTools()
            )
        }
        let completeBody = try lastRequestBody()

        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(sseTextStream(deltas: ["ok"]).utf8))
        }
        let stream = LLMCallContext.$systemSegments.withValue(segments) {
            adapter.streamMessages(
                messages: convo, system: Self.segCombined,
                model: "claude-opus-4-8", tools: makeTools()
            )
        }
        for try await _ in stream {}
        var streamBody = try lastRequestBody()

        #expect(streamBody["stream"] as? Bool == true)
        streamBody["stream"] = nil
        #expect(NSDictionary(dictionary: streamBody) == NSDictionary(dictionary: completeBody))
    }

    // (3a) Text-compat shape: tools nil + withinTurnReuse hint → current
    // message breakpoint; identity + stable-end + current = 3 ≤ 4;
    // dynamic block carries NO breakpoint (covered by the trailing prefix).
    @Test func streamMessages_noTools_withReuseHint_trailingBreakpoint_threeTotal() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(sseTextStream(deltas: ["ok"]).utf8))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        let stream = AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
            LLMCallContext.$systemSegments.withValue(segments) {
                adapter.streamMessages(
                    messages: [.user("hi")], system: Self.segCombined,
                    model: "claude-opus-4-8", tools: nil
                )
            }
        }
        for try await _ in stream {}
        let body = try lastRequestBody()

        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 3)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[2]["cache_control"] == nil)
        #expect(body["tools"] == nil)
        let messages = body["messages"] as? [[String: Any]] ?? []
        let lastContent = messages.last?["content"] as? [[String: Any]] ?? []
        #expect((lastContent.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let counts = breakpointCounts(body)
        #expect(counts.system + counts.tools + counts.messages == 3)
    }

    @Test func messagesBody_textCompatibilityRetainsPreviousAndCurrentRequestBoundaries() {
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        let body = AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
            LLMCallContext.$systemSegments.withValue(segments) {
                AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                    messages: [
                        .user("first request"),
                        LLMMessage(role: .assistant, content: [.text("first response")]),
                        .user("second request"),
                    ],
                    system: Self.segCombined,
                    coercedModel: "claude-opus-5",
                    maxTokens: 32,
                    tools: nil,
                    stream: true
                )
            }
        }
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 3)
        for index in messages.indices {
            let blocks = messages[index]["content"] as? [[String: Any]] ?? []
            let marked = blocks.last?["cache_control"] != nil
            #expect(marked == (index == 0 || index == 2))
        }
        let counts = breakpointCounts(body)
        #expect(counts.system == 2)
        #expect(counts.tools == 0)
        #expect(counts.messages == 2)
        #expect(counts.system + counts.tools + counts.messages == 4)
    }

    // (3b) Structured shape via SSE: tools + segments → same item-8 layout,
    // 4 ≤ 4 (identity + stable-end + last-tool + current message).
    @Test func streamMessages_withTools_trailingBreakpoint_fourTotal() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(sseTextStream(deltas: ["ok"]).utf8))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        let stream = LLMCallContext.$systemSegments.withValue(segments) {
            adapter.streamMessages(
                messages: [.user("hi")], system: Self.segCombined,
                model: "claude-opus-4-8", tools: makeTools()
            )
        }
        for try await _ in stream {}
        let body = try lastRequestBody()
        let counts = breakpointCounts(body)
        #expect(counts.system == 2)   // identity + stable-end (dynamic: none)
        #expect(counts.tools == 1)    // last tool def
        #expect(counts.messages == 1) // current message
        #expect(counts.system + counts.tools + counts.messages == 4)
    }

    // (4) Rollback lever on the streaming transport: hint bound but compat
    // forced → NO conversation cache (legacy layout restored).
    @Test func streamMessages_grownPromptCompatLever_dropsTrailingBreakpoint() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(sseTextStream(deltas: ["ok"]).utf8))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        let stream = AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride.withValue(true) {
            AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
                LLMCallContext.$systemSegments.withValue(segments) {
                    adapter.streamMessages(
                        messages: [.user("hi")], system: Self.segCombined,
                        model: "claude-opus-4-8", tools: nil
                    )
                }
            }
        }
        for try await _ in stream {}
        let body = try lastRequestBody()
        let counts = breakpointCounts(body)
        #expect(counts.messages == 0)
        // identity + stable-end remain (no tools, dynamic uncached) — the
        // exact pre-item-9 legacy system layout.
        #expect(counts.system == 2)
        #expect(counts.tools == 0)
    }

    // Hint unbound + tools nil → byte-identical legacy body (no trailing
    // breakpoint): other streamMessages callers see no change.
    @Test func streamMessages_noTools_noHint_noTrailingBreakpoint() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(sseTextStream(deltas: ["ok"]).utf8))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        for try await _ in adapter.streamMessages(
            messages: [.user("hi")], system: "sys",
            model: "claude-opus-4-8", tools: nil
        ) {}
        let counts = breakpointCounts(try lastRequestBody())
        #expect(counts.messages == 0)
    }

    // Mid-stream provider error frame → providerError; missing message_stop
    // → streamTruncated (silent EOF must not look like a clean end).
    @Test func streamMessages_errorFrame_andTruncation_throw() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let errorSSE = [
            "event: error",
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(errorSSE.utf8)) }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        await #expect(throws: LLMError.providerError(message: "Anthropic OAuth: Overloaded")) {
            for try await _ in adapter.streamMessages(
                messages: [.user("hi")], system: nil,
                model: "claude-opus-4-8", tools: nil
            ) {}
        }

        let truncatedSSE = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"par"}}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(truncatedSSE.utf8)) }
        var thrown: Error?
        do {
            for try await _ in adapter.streamMessages(
                messages: [.user("hi")], system: nil,
                model: "claude-opus-4-8", tools: nil
            ) {}
        } catch { thrown = error }
        if case .streamTruncated? = thrown as? LLMError {} else {
            Issue.record("expected streamTruncated, got \(String(describing: thrown))")
        }
    }

    // Turn Inspector W2 — thinking lane: a thinking_delta SSE frame fires a
    // bus `thinking.delta` event (bus-only, secret-redacted) WITHOUT entering
    // the text stream; a redacted_thinking block_start fires "[redacted]";
    // text deltas flow through untouched. signature_delta is ignored.
    @Test func streamMessages_thinkingDelta_firesBusEvent_notTextStream() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let sse = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            "",
            // Summarized thinking delta — must go to the bus, NOT the text stream.
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Let me check the file sk-ant-SECRET0123456789ABCD"}}"#,
            "",
            // signature_delta — must be IGNORED entirely.
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"signature_delta","signature":"abc123"}}"#,
            "",
            // Redacted thinking block — rendered honestly as "[redacted]".
            "event: content_block_start",
            #"data: {"type":"content_block_start","content_block":{"type":"redacted_thinking","data":"ENCRYPTED"}}"#,
            "",
            // Real reply text delta — flows through the text stream.
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello the user"}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())

        let id = TurnTraceContext.mintTurnId()
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: makeTmpRoot()))
        let sub = await bus.subscribe()
        var textDeltas: [String] = []
        // Start draining before stream consumption. TurnTraceBus.fire is
        // detached by design, so full-suite contention can delay delivery even
        // after the provider stream has finished.
        let drain = Task { () -> [TurnTraceEvent] in
            var out: [TurnTraceEvent] = []
            for await e in sub.stream where e.turnId == id && e.kind == "thinking.delta" {
                out.append(e)
                if out.count == 2 { break }
            }
            return out
        }
        // Bind the turnId around the SYNCHRONOUS stream construction; the
        // adapter's inner Task inherits it (production propagation pattern).
        // Use a private bus so full-suite shared-bus backpressure cannot drop
        // these exact thinking-lane assertions.
        let stream = TurnTraceContext.$bus.withValue(bus) {
            TurnTraceContext.$turnId.withValue(id) {
                // The lane gate must be ON for thinking frames to reach the bus
                // (emission is gated, not just the request-body key).
                InspectorThinkingLane.$summarizedThinking.withValue(true) {
                    adapter.streamMessages(
                        messages: [.user("hi")], system: "sys",
                        model: "claude-opus-4-8", tools: nil
                    )
                }
            }
        }
        do {
            for try await event in stream {
                if case .textDelta(let s) = event { textDeltas.append(s) }
            }
        } catch {
            Issue.record("unexpected stream error: \(error)")
        }
        // Text stream carries ONLY the reply — thinking never leaks into it.
        #expect(textDeltas == ["Hello the user"])

        // Drain the bus for this turn's thinking.delta events (bounded window).
        let sleeper = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await bus.unsubscribe(sub.id) // ends the stream → drain returns
        }
        let thinking = await drain.value
        sleeper.cancel()
        await bus.unsubscribe(sub.id)

        #expect(thinking.count == 2, "one summarized + one redacted thinking event")
        // The summarized event's secret must be REDACTED (redact-at-emission).
        let summarized = thinking.first { ev in
            guard case .object(let p) = ev.payload, p["redacted"] == .bool(false) else { return false }
            return true
        }
        if case .object(let p)? = summarized?.payload, case .string(let t)? = p["text"] {
            #expect(!t.contains("sk-ant-SECRET0123456789ABCD"), "thinking secret must be redacted")
            #expect(t.contains("REDACTED_"))
        } else {
            Issue.record("expected a summarized thinking.delta with text")
        }
        // The redacted block renders honestly as "[redacted]".
        let redacted = thinking.first { ev in
            guard case .object(let p) = ev.payload, p["redacted"] == .bool(true) else { return false }
            return true
        }
        if case .object(let p)? = redacted?.payload {
            #expect(p["text"] == .string("[redacted]"))
        } else {
            Issue.record("expected a redacted thinking.delta")
        }
    }

    // gpt-5.5 W2 review regression: thinking frames arriving while the lane is
    // OFF (provider quirk, stub, future default change) must NOT reach the bus
    // — emission is gated on InspectorThinkingLane, not just the request body.
    @Test func streamMessages_thinkingDelta_laneOff_firesNothing() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let sse = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"UNINVITED-THOUGHT"}}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","content_block":{"type":"redacted_thinking","data":"ENCRYPTED"}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"reply"}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        Item9StubURLProtocol.responder = { _ in .init(status: 200, body: Data(sse.utf8)) }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())

        let id = TurnTraceContext.mintTurnId()
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: makeTmpRoot()))
        let sub = await bus.subscribe()
        // turnId bound, lane NOT bound (the production default everywhere).
        let stream = TurnTraceContext.$bus.withValue(bus) {
            TurnTraceContext.$turnId.withValue(id) {
                adapter.streamMessages(
                    messages: [.user("hi")], system: "sys",
                    model: "claude-opus-4-8", tools: nil
                )
            }
        }
        var textDeltas: [String] = []
        for try await event in stream {
            if case .textDelta(let s) = event { textDeltas.append(s) }
        }
        #expect(textDeltas == ["reply"], "text handling unchanged with lane off")

        // Short drain window: NO thinking.delta for this turn may arrive.
        let drain = Task { () -> Bool in
            for await e in sub.stream where e.turnId == id && e.kind == "thinking.delta" {
                _ = e
                return true
            }
            return false
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await bus.unsubscribe(sub.id)
        let leaked = await drain.value
        #expect(!leaked, "lane-OFF thinking frame must never reach the bus")
    }

    // (6) Missing credentials → .notConfigured BEFORE any yield, so the
    // routing layer's api-key fallback chain still engages.
    @Test func streamMessages_missingAuth_throwsNotConfigured() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let missing = makeTmpRoot().appendingPathComponent("absent.json")
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot(), authPath: missing)
        await #expect(throws: LLMError.notConfigured(provider: "anthropic_oauth_direct")) {
            for try await _ in adapter.streamMessages(
                messages: [.user("hi")], system: nil,
                model: "claude-opus-4-8", tools: nil
            ) {}
        }
    }

    // Preflight helper used by the text-compat loop's transport decision.
    @Test func hasUsableOAuthCredentials_presentAndAbsent() async throws {
        let present = writeAuthFixture()
        #expect(AnthropicOAuthDirectAdapter.hasUsableOAuthCredentials(at: present))
        let absent = makeTmpRoot().appendingPathComponent("nope.json")
        #expect(!AnthropicOAuthDirectAdapter.hasUsableOAuthCredentials(at: absent))
        let empty = makeTmpRoot().appendingPathComponent("empty.json")
        try! JSONSerialization.data(withJSONObject: ["access_token": ""]).write(to: empty)
        #expect(!AnthropicOAuthDirectAdapter.hasUsableOAuthCredentials(at: empty))
    }

    // (gpt-5.5 review 2026-06-11, finding 1) Full breakpoint-contract
    // matrix: hint × tools × segmented × compat (16 cells). CONTRACT: the
    // conversation caching ships iff (tool-capable OR
    // withinTurnReuse-hinted) AND trailing-eligible AND not compat — and NO
    // combination can ever emit a 5th breakpoint (whenever the trailing
    // breakpoint ships, the lane-(a) dynamic-end breakpoint is suppressed).
    // Calls the shared builder directly: both transports are already pinned
    // body-deep-equal to it, so the matrix covers completeMessages AND
    // streamMessages at once.
    @Test func makeMessagesRequestBody_breakpointBudgetMatrix_neverExceedsFour() throws {
        let segments = SystemPromptSegments(stable: Self.segStable, dynamic: Self.segDynamic)
        for hint in [false, true] {
            for withTools in [false, true] {
                for segmented in [false, true] {
                    for compat in [false, true] {
                        let body = AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride.withValue(compat) {
                            AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(hint) {
                                LLMCallContext.$systemSegments.withValue(segmented ? segments : nil) {
                                    AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                                        messages: [.user("hi")],
                                        system: segmented ? Self.segCombined : "sys",
                                        coercedModel: "claude-opus-4-8",
                                        maxTokens: 1024,
                                        tools: withTools ? makeTools() : nil,
                                        stream: true
                                    )
                                }
                            }
                        }
                        let counts = breakpointCounts(body)
                        let total = counts.system + counts.tools + counts.messages
                        let cell: Testing.Comment =
                            "hint=\(hint) tools=\(withTools) segmented=\(segmented) compat=\(compat) counts=\(counts)"

                        // Automatic conversation breakpoint: the contract above.
                        // (The last message here always carries a non-empty
                        // text block, so it is trailing-eligible.)
                        let expectTrailing = (withTools || hint) && !compat
                        #expect(counts.messages == (expectTrailing ? 1 : 0), cell)
                        // Tools block: last-definition breakpoint iff sent.
                        #expect(counts.tools == (withTools ? 1 : 0), cell)
                        // System: identity + (segmented: stable-end, plus
                        // dynamic-end ONLY under compat+tools — when the
                        // trailing breakpoint ships it subsumes lane (a);
                        // unsegmented: the combined sys block).
                        let expectedSystem = segmented
                            ? 2 + ((withTools && compat) ? 1 : 0)
                            : 2
                        #expect(counts.system == expectedSystem, cell)
                        // The hint can NEVER push any combination to 5.
                        #expect(total <= 4, cell)
                        // Budget pin for the item-9 text-compat shape:
                        // no-tools + hint → identity + stable-end +
                        // trailing = 3 ≤ 4.
                        if hint && !withTools && segmented && !compat {
                            #expect(total == 3, cell)
                        }
                    }
                }
            }
        }
    }

    // (gpt-5.5 review 2026-06-11, finding 2) Tool-call-FIRST stream: TTFT
    // stamps at the tool_use content_block_start — parity with the OpenAI
    // structured parser's output_item.added stamp — NOT at
    // content_block_stop after the whole input_json_delta stream. Chunk
    // layout: block_start arrives in chunk 1; two 250ms gaps separate it
    // from the argument delta and the block stop, so a stop-stamped TTFT
    // could never read under 250ms.
    @Test func streamMessages_toolCallFirst_ttftStampedBeforeBlockStop() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let chunk1 = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":50}}}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_1","name":"tool_a"}}"#,
            "",
        ].joined(separator: "\n") + "\n"
        let chunk2 = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"q\":\"x\"}"}}"#,
            "",
        ].joined(separator: "\n") + "\n"
        let chunk3 = [
            "event: content_block_stop",
            #"data: {"type":"content_block_stop"}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n") + "\n"
        Item9StubURLProtocol.responder = { _ in
            // Non-final chunks carry flush padding (see sseFlushPadding) so
            // block_start and the argument delta genuinely arrive before
            // their 250ms gaps instead of coalescing into one burst.
            .init(status: 200, body: Data(),
                  chunks: [Data(chunk1.utf8) + sseFlushPadding,
                           Data(chunk2.utf8) + sseFlushPadding,
                           Data(chunk3.utf8)],
                  interChunkDelayMs: 250)
        }
        let root = makeTmpRoot()
        let adapter = makeAdapter(telemetryRoot: root)
        var sawToolCall = false
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: "sys",
            model: "claude-opus-4-8", tools: makeTools()
        ) {
            if case .toolCall(let call) = event {
                sawToolCall = true
                #expect(call.name == "tool_a")
                #expect(String(data: call.inputJSON, encoding: .utf8) == #"{"q":"x"}"#)
            }
        }
        #expect(sawToolCall)
        let rows = readLLMCallRows(dataRoot: root)
        #expect(rows.count == 1)
        let payload = rows.first?["payload"] as? [String: Any] ?? [:]
        let ttft = payload["ttftMs"] as? Int
        let duration = payload["durationMs"] as? Int
        #expect(ttft != nil)
        #expect(duration != nil)
        if let ttft, let duration {
            // Under a full-package parallel run the first chunk can be delayed
            // by scheduler contention. The stable contract is ordering: TTFT
            // must still land well before block_stop/message_stop, not at the
            // terminal frame after both inter-chunk gaps.
            #expect(duration >= 500)
            #expect(ttft < duration)
            #expect(duration - ttft >= 250)
        }
    }

    // (gpt-5.5 review 2026-06-11, finding 3) Mid-stream transport errors
    // thrown while iterating bytes.lines route through the SAME
    // transientNetworkError mapping as initial-connect failures: a resource
    // timeout AFTER the first delta classifies .transient, not .underlying
    // (the generic streamMessages catch it previously fell into).
    @Test func streamMessages_midStreamTimeout_classifiedTransient() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let head = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"par"}}"#,
            "",
        ].joined(separator: "\n") + "\n"
        Item9StubURLProtocol.responder = { _ in
            // Flush padding forces the delta through URLSession's coalescing
            // buffer BEFORE the failure lands — otherwise the error wins the
            // race and the consumer never sees "par".
            .init(status: 200, body: Data(head.utf8) + sseFlushPadding,
                  midStreamError: URLError(.timedOut))
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        var deltas: [String] = []
        var thrown: Error?
        do {
            for try await event in adapter.streamMessages(
                messages: [.user("hi")], system: nil,
                model: "claude-opus-4-8", tools: nil
            ) {
                if case .textDelta(let s) = event { deltas.append(s) }
            }
        } catch { thrown = error }
        // PLATFORM LIMITATION (2026-06-11, found at integration): URLSession
        // DISCARDS its internal coalescing buffer when a URLProtocol fails —
        // data delivered via didLoad but not yet vended to AsyncBytes is
        // lost, padding or not. "Delta observed, THEN mid-stream error" is
        // therefore not constructible through a URLProtocol stub; the
        // body+error sequencing here still exercises the MID-STREAM error
        // path in the line loop (response headers + body bytes accepted →
        // past the initial connect mapping), which is the mechanism under
        // test. Incremental delta delivery itself is pinned by the TTFT
        // tests above. No assertion on `deltas`.
        _ = deltas
        if case .transient(let message)? = thrown as? LLMError {
            #expect(message.contains("streamMessages"))
            #expect(message.contains("timed out"))
        } else {
            Issue.record("expected .transient, got \(String(describing: thrown))")
        }
    }

    // (gpt-5.5 review 2026-06-11, finding 4) Consumer cancellation tears
    // down the URLSession task: streamMessages installs
    // continuation.onTermination = { task.cancel() } — cancelling the
    // consuming Task after the first delta must reach the stub's
    // stopLoading() (URLSession's task-cancel signal to the protocol).
    @Test func streamMessages_consumerCancellation_cancelsURLSessionTask() async throws {
        Item9StubURLProtocol.reset()
        defer { Item9StubURLProtocol.reset() }
        let head = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"first"}}"#,
            "",
        ].joined(separator: "\n") + "\n"
        let stopFlag = StopLoadingFlag()
        Item9StubURLProtocol.onStopLoading = { stopFlag.set() }
        // First delta delivered (flush padding forces it through
        // URLSession's coalescing buffer — without it the delta never
        // reaches the consumer and this test hangs at the first-delta
        // await, 26-minute wedge caught at integration), then the
        // connection stays OPEN (no finish) so the stream is live when
        // the consumer cancels.
        Item9StubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(head.utf8) + sseFlushPadding,
                  stallAfterDelivery: true)
        }
        let adapter = makeAdapter(telemetryRoot: makeTmpRoot())
        let (firstDelta, firstDeltaCont) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            do {
                for try await event in adapter.streamMessages(
                    messages: [.user("hi")], system: "sys",
                    model: "claude-opus-4-8", tools: nil
                ) {
                    if case .textDelta = event { firstDeltaCont.yield(()) }
                }
            } catch {
                // CancellationError is acceptable here — the pin is the
                // transport teardown below, not the thrown type.
            }
        }
        var deltaIterator = firstDelta.makeAsyncIterator()
        _ = await deltaIterator.next() // first delta consumed; stream live
        consumer.cancel()
        // onTermination → inner Task.cancel() → URLSession task.cancel() →
        // stub stopLoading(). Bounded poll (≤ 2s) — no stop means the
        // URLSession task leaked past cancellation.
        var sawStop = false
        for _ in 0..<200 {
            if stopFlag.isSet() { sawStop = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sawStop, "URLSession task not torn down after consumer cancellation")
        await consumer.value
    }
}

/// Lock-protected bool for observing the stub's stopLoading() across
/// threads (URLSession's workloop → test task).
private final class StopLoadingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

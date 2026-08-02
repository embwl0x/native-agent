import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore

// F-B2 (2026-08-02) — the api-key OpenAI lane dropped `tools[]` entirely.
//
// Pre-fix state: `OpenAIAdapter` inherited the protocol's default tools-aware
// `complete`, which discards `tools`; the request body carried only
// model+messages; and there was NO `streamMessages` override, so the protocol
// default ran one `completeMessages` round-trip and yielded a single
// `.textDelta`. A `.toolCall` event was structurally impossible. Provider
// `openai` + API key = the agent silently had zero tools and told the user it
// had no access.
//
// The Moonshot and xAI adapters speak the identical Chat-Completions wire; the
// tests below hold OpenAI to that same contract.

@Suite(.serialized)
struct OpenAIApiKeyToolsParityTests {

    final class Stub: URLProtocol, @unchecked Sendable {
        struct Response { let status: Int; let body: Data }
        nonisolated(unsafe) static var responses: [Response] = []
        nonisolated(unsafe) static var bodies: [Data] = []

        static func reset(_ next: [Response]) { responses = next; bodies = [] }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var captured = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8_192)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: 8_192)
                    if read <= 0 { break }
                    captured.append(buffer, count: read)
                }
                stream.close()
            } else {
                captured = request.httpBody ?? Data()
            }
            Self.bodies.append(captured)
            guard !Self.responses.isEmpty else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = Self.responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: response.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    private func adapter(root: URL) -> OpenAIAdapter {
        OpenAIAdapter(
            session: session(),
            apiKeyOverride: "sk-test",
            dataRootOverride: root,
            telemetryDataRootOverride: root
        )
    }

    private func tempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-tools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var weatherTool: LLMToolSchema {
        LLMToolSchema(
            name: "get_weather",
            description: "Look up the weather",
            parametersJSON: Data(#"{"type":"object","properties":{"city":{"type":"string"}}}"#.utf8)
        )
    }

    // MARK: - Non-streaming

    /// PRE-FIX: `body["tools"]` is absent — the sole `tools` occurrence in the
    /// file was the unused parameter name.
    @Test func completeMessages_sendsToolsOnTheWire() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        Stub.reset([.init(
            status: 200,
            body: Data(#"{"choices":[{"message":{"role":"assistant","content":"sunny"}}]}"#.utf8)
        )])

        _ = try await adapter(root: root).completeMessages(
            messages: [.user("weather in Boston?")],
            system: "be terse",
            model: "gpt-5.5",
            tools: [weatherTool]
        )

        let body = try #require(
            try JSONSerialization.jsonObject(with: Stub.bodies[0]) as? [String: Any]
        )
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
        #expect(function["parameters"] is [String: Any])
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["parallel_tool_calls"] as? Bool == true)
    }

    /// BYTE-IDENTITY guard: no tools → the body must not grow tool keys.
    @Test func completeMessages_withoutToolsKeepsBodyUnchanged() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        Stub.reset([.init(
            status: 200,
            body: Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.utf8)
        )])

        _ = try await adapter(root: root).completeMessages(
            messages: [.user("hi")], system: nil, model: "gpt-5.5", tools: nil
        )

        let body = try #require(
            try JSONSerialization.jsonObject(with: Stub.bodies[0]) as? [String: Any]
        )
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(body["parallel_tool_calls"] == nil)
    }

    /// PRE-FIX: a tool-only reply carries `content: null`, which failed the
    /// `message["content"] as? String` guard and threw `.invalidResponse` —
    /// the tool call never reached the caller.
    @Test func completeMessages_parsesToolOnlyReplyIntoToolUseMarkers() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        Stub.reset([.init(status: 200, body: Data("""
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_w1","type":"function",
           "function":{"name":"get_weather","arguments":"{\\"city\\":\\"Boston\\"}"}}
        ]},"finish_reason":"tool_calls"}]}
        """.utf8))])

        let reply = try await adapter(root: root).completeMessages(
            messages: [.user("weather?")], system: nil, model: "gpt-5.5", tools: [weatherTool]
        )
        #expect(reply.contains(#"<tool_use id="call_w1" name="get_weather">"#))
        #expect(reply.contains(#"{"city":"Boston"}"#))
    }

    /// PRE-FIX: tool_use / tool_result blocks were flattened into
    /// `"[tool_use get_weather {...}]"` text, so the second turn of a tool loop
    /// was unintelligible to the provider.
    @Test func completeMessages_secondTurnSendsStructuredToolCallsAndToolRole() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        Stub.reset([.init(
            status: 200,
            body: Data(#"{"choices":[{"message":{"role":"assistant","content":"It is sunny."}}]}"#.utf8)
        )])

        _ = try await adapter(root: root).completeMessages(
            messages: [
                .user("weather?"),
                .init(role: .assistant, content: [
                    .toolUse(id: "call_w1", name: "get_weather", inputJSON: Data(#"{"city":"Boston"}"#.utf8)),
                ]),
                .init(role: .user, content: [
                    .toolResult(toolUseId: "call_w1", content: "sunny, 72F", isError: false),
                ]),
            ],
            system: nil, model: "gpt-5.5", tools: [weatherTool]
        )

        let body = try #require(
            try JSONSerialization.jsonObject(with: Stub.bodies[0]) as? [String: Any]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls[0]["id"] as? String == "call_w1")
        let toolRow = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(toolRow["tool_call_id"] as? String == "call_w1")
        #expect(toolRow["content"] as? String == "sunny, 72F")
        // The old flattening must be gone entirely.
        let encoded = String(decoding: Stub.bodies[0], as: UTF8.self)
        #expect(!encoded.contains("[tool_use "))
        #expect(!encoded.contains("[tool_result]"))
    }

    // MARK: - Streaming

    /// PRE-FIX: no `streamMessages` override existed, so this yielded exactly
    /// one `.textDelta` from a non-streaming round-trip and ZERO `.toolCall`.
    @Test func streamMessages_emitsToolCallEvents() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_w1","type":"function","function":{"name":"get_weather","arguments":"{\\"city\\":"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Boston\\"}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":9,"completion_tokens":5,"total_tokens":14}}

        data: [DONE]

        """
        Stub.reset([.init(status: 200, body: Data(sse.utf8))])

        var toolCalls: [LLMStreamToolCall] = []
        var text = ""
        for try await event in adapter(root: root).streamMessages(
            messages: [.user("weather?")], system: nil, model: "gpt-5.5", tools: [weatherTool]
        ) {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCall(let call): toolCalls.append(call)
            case .keepAlive: break
            }
        }

        #expect(text.isEmpty)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_w1")
        #expect(toolCalls.first?.name == "get_weather")
        #expect(
            String(decoding: toolCalls.first?.inputJSON ?? Data(), as: UTF8.self)
                == #"{"city":"Boston"}"#
        )

        // ... and the streaming request carried the tools too.
        let body = try #require(
            try JSONSerialization.jsonObject(with: Stub.bodies[0]) as? [String: Any]
        )
        #expect((body["tools"] as? [[String: Any]])?.count == 1)
        #expect(body["stream"] as? Bool == true)
    }

    @Test func streamMessages_stillYieldsPlainTextDeltas() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":" there"}}]}

        data: [DONE]

        """
        Stub.reset([.init(status: 200, body: Data(sse.utf8))])

        var text = ""
        for try await event in adapter(root: root).streamMessages(
            messages: [.user("hi")], system: nil, model: "gpt-5.5", tools: nil
        ) {
            if case .textDelta(let delta) = event { text += delta }
        }
        #expect(text == "Hello there")
    }
}

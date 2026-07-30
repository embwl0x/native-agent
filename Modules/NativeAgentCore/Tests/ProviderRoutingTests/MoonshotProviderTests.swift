import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore

@Test func MoonshotModelCatalog_parsesAuthenticatedModelCapabilities() throws {
    let data = Data("""
    {
      "object": "list",
      "data": [
        {
          "id": "kimi-k2.6",
          "object": "model",
          "owned_by": "moonshot",
          "context_length": 262144,
          "supports_image_in": true,
          "supports_video_in": true,
          "supports_reasoning": true
        },
        {
          "id": "kimi-k3",
          "object": "model",
          "owned_by": "moonshot",
          "context_length": 1048576,
          "supports_image_in": true,
          "supports_video_in": false,
          "supports_reasoning": true
        }
      ]
    }
    """.utf8)

    let models = try MoonshotModelCatalog.parseModelsResponse(data)
    #expect(models.map(\.id) == ["kimi-k3", "kimi-k2.6"])
    let k3 = try #require(models.first)
    #expect(k3.contextLength == 1_048_576)
    #expect(k3.supportsStreaming)
    #expect(k3.supportsVision)
    #expect(k3.supportsTools)
    #expect(k3.supportsJSONMode)
    #expect(MoonshotModelCatalog.supportedReasoningEfforts(for: k3.id) == ["max"])
}

@Test func MoonshotModelCatalog_cacheFirstReadDoesNotTouchNetwork() async {
    final class NoNetwork: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var count = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.count += 1
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("moonshot-catalog-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NoNetwork.self]
    let models = await MoonshotModelCatalog.models(
        dataRoot: root,
        session: URLSession(configuration: configuration),
        refresh: false
    )
    #expect(models.first?.id == "kimi-k3")
    #expect(NoNetwork.count == 0)
}

@Suite(.serialized)
struct MoonshotAdapterTests {
    final class ProtocolStub: URLProtocol, @unchecked Sendable {
        struct StubResponse {
            let status: Int
            let body: Data
            let headers: [String: String]
        }
        nonisolated(unsafe) static var responses: [StubResponse] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var bodies: [Data] = []

        static func reset(_ newResponses: [StubResponse]) {
            responses = newResponses
            requests = []
            bodies = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            let body: Data
            if let stream = request.httpBodyStream {
                stream.open()
                var captured = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4_096)
                    if count <= 0 { break }
                    captured.append(buffer, count: count)
                }
                stream.close()
                body = captured
            } else {
                body = request.httpBody ?? Data()
            }
            Self.bodies.append(body)
            guard !Self.responses.isEmpty else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = Self.responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: response.status,
                httpVersion: "HTTP/1.1", headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    @Test func k3PreservesReasoningAcrossStructuredToolLoop() async throws {
        let first = Data("""
        {
          "choices": [{
            "message": {
              "role": "assistant",
              "content": "",
              "reasoning_content": "I should check the clock.",
              "tool_calls": [{
                "id": "call_clock",
                "type": "function",
                "function": {"name": "time_now", "arguments": "{}"}
              }]
            },
            "finish_reason": "tool_calls"
          }],
          "usage": {"prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14}
        }
        """.utf8)
        let second = Data("""
        {"choices":[{"message":{"role":"assistant","content":"It is noon."},"finish_reason":"stop"}]}
        """.utf8)
        ProtocolStub.reset([
            .init(status: 200, body: first, headers: ["Content-Type": "application/json"]),
            .init(status: 200, body: second, headers: ["Content-Type": "application/json"]),
        ])
        let adapter = MoonshotAdapter(session: session(), apiKeyOverride: "moonshot-test-key")
        let tools = [LLMToolSchema(
            name: "time_now",
            description: "Read current time",
            parametersJSON: Data("{\"type\":\"object\",\"properties\":{}}".utf8)
        )]

        let firstReply = try await adapter.completeMessages(
            messages: [.user("What time is it?")],
            system: "Be helpful.",
            model: "kimi-k3",
            tools: tools
        )
        #expect(firstReply.contains("<tool_use id=\"call_clock\" name=\"time_now\">"))

        _ = try await adapter.completeMessages(
            messages: [
                .user("What time is it?"),
                .init(role: .assistant, content: [.toolUse(id: "call_clock", name: "time_now", inputJSON: Data("{}".utf8))]),
                .init(role: .user, content: [.toolResult(toolUseId: "call_clock", content: "12:00", isError: false)]),
            ],
            system: "Be helpful.",
            model: "kimi-k3",
            tools: tools
        )

        #expect(ProtocolStub.requests.count == 2)
        #expect(ProtocolStub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer moonshot-test-key")
        let firstBody = try #require(try JSONSerialization.jsonObject(with: ProtocolStub.bodies[0]) as? [String: Any])
        #expect(firstBody["reasoning_effort"] as? String == "max")
        #expect((firstBody["tools"] as? [[String: Any]])?.count == 1)
        let secondBody = try #require(try JSONSerialization.jsonObject(with: ProtocolStub.bodies[1]) as? [String: Any])
        let messages = try #require(secondBody["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first(where: { $0["role"] as? String == "assistant" }))
        #expect(assistant["reasoning_content"] as? String == "I should check the clock.")
    }

    // A3.1: a key IS present, so a 401 is a positive credential rejection →
    // .authRejected carrying the provider body, NOT the misleading .notConfigured.
    @Test func http401MapsToAuthRejectedWithBody() async throws {
        ProtocolStub.reset([
            .init(status: 401,
                  body: Data(#"{"error":{"message":"invalid moonshot api key"}}"#.utf8),
                  headers: ["Content-Type": "application/json"]),
        ])
        let adapter = MoonshotAdapter(session: session(), apiKeyOverride: "k")
        do {
            _ = try await adapter.completeMessages(
                messages: [.user("hi")], system: nil, model: "kimi-k3", tools: nil)
            Issue.record("expected throw")
        } catch let err as LLMError {
            guard case .authRejected(let provider, let detail) = err else {
                Issue.record("expected .authRejected, got \(err)")
                return
            }
            #expect(provider == "moonshot")
            #expect(detail?.contains("invalid moonshot api key") == true)
        }
    }

    // A3.4: a 429 with a Retry-After header carries the honored delay via the
    // ` [retry-after=Ns]` sentinel on the transient message.
    @Test func http429CarriesRetryAfter() async throws {
        ProtocolStub.reset([
            .init(status: 429, body: Data("slow down".utf8),
                  headers: ["Retry-After": "37"]),
        ])
        let adapter = MoonshotAdapter(session: session(), apiKeyOverride: "k")
        do {
            _ = try await adapter.completeMessages(
                messages: [.user("hi")], system: nil, model: "kimi-k3", tools: nil)
            Issue.record("expected throw")
        } catch let err as LLMError {
            #expect(err.retryAfterSeconds == 37)
        }
    }

    @Test func streamYieldsTextAndStructuredToolCallWithoutLeakingReasoning() async throws {
        let sse = Data("""
        data: {"choices":[{"delta":{"reasoning_content":"checking"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"Using a tool."},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"time_now","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """.utf8)
        ProtocolStub.reset([
            .init(status: 200, body: sse, headers: ["Content-Type": "text/event-stream"]),
        ])
        let adapter = MoonshotAdapter(session: session(), apiKeyOverride: "k")
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("time")], system: nil, model: "kimi-k3", tools: nil
        ) {
            events.append(event)
        }
        #expect(events.contains(.keepAlive))
        #expect(events.contains(.textDelta("Using a tool.")))
        #expect(events.contains(.toolCall(.init(id: "call_1", name: "time_now", inputJSON: Data("{}".utf8)))))
        #expect(!events.contains(.textDelta("checking")))
    }

    /// Audit round 2, M-F1: a mid-stream error frame carries no "choices",
    /// so the delta guard skipped it and the stream ended as a wrong-cause
    /// "ended without [DONE]" truncation. The real provider cause must
    /// surface loud instead.
    @Test func streamErrorFrameSurfacesRealCauseNotTruncation() async throws {
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}

        data: {"error":{"type":"rate_limit_reached_error","message":"quota exceeded for kimi-k3"}}

        """.utf8)
        ProtocolStub.reset([
            .init(status: 200, body: sse, headers: ["Content-Type": "text/event-stream"]),
        ])
        let adapter = MoonshotAdapter(session: session(), apiKeyOverride: "k")
        var caught: Error?
        do {
            for try await _ in adapter.streamMessages(
                messages: [.user("hi")], system: nil, model: "kimi-k3", tools: nil
            ) {}
        } catch { caught = error }
        guard case .providerError(let message)? = caught as? LLMError else {
            Issue.record("expected providerError, got \(String(describing: caught))")
            return
        }
        #expect(message.contains("quota exceeded"))
        #expect(!message.contains("[DONE]"))
    }

    /// Audit round 2, M-F2: root-level usage — on the dedicated final
    /// empty-choices frame OR riding the last delta frame — must land in the
    /// recorded telemetry row, not be dropped as usage: nil. Asserts the
    /// trace row's token fields (review d6ba3ffdc6a5: a text-only assert
    /// passed under the old dropped-usage behavior).
    @Test(arguments: [
        // Dedicated include_usage frame (empty choices).
        """
        data: {"choices":[{"delta":{"content":"All done."},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}

        data: [DONE]

        """,
        // Usage riding the final delta frame itself (mixed shape).
        """
        data: {"choices":[{"delta":{"content":"All done."},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}

        data: [DONE]

        """,
    ])
    func streamUsageLandsInTelemetry(sseText: String) async throws {
        let telemetryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonshot-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: telemetryRoot) }
        ProtocolStub.reset([
            .init(status: 200, body: Data(sseText.utf8), headers: ["Content-Type": "text/event-stream"]),
        ])
        let adapter = MoonshotAdapter(
            session: session(), apiKeyOverride: "k",
            telemetryDataRootOverride: telemetryRoot
        )
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: nil, model: "kimi-k3", tools: nil
        ) {
            events.append(event)
        }
        #expect(events.contains(.textDelta("All done.")))

        let trace = try String(
            contentsOf: telemetryRoot
                .appendingPathComponent("traces", isDirectory: true)
                .appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        #expect(trace.contains("12"), "prompt tokens must reach telemetry: \(trace)")
        #expect(trace.contains("utputTokens") || trace.contains("output_tokens"), "completion tokens must reach telemetry: \(trace)")
    }

    /// M-F2 negative case: a stream that carries NO usage frame (no dedicated
    /// empty-choices frame, no usage on the final delta) must complete cleanly
    /// and record `usage: nil` — the recorder omits nil usage keys, so the
    /// llm.call row carries no token fields and nothing crashes.
    @Test func streamWithoutUsageFrameRecordsNilUsageAndDoesNotCrash() async throws {
        let telemetryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonshot-nousage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: telemetryRoot) }
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"All done."},"finish_reason":"stop"}]}

        data: [DONE]

        """.utf8)
        ProtocolStub.reset([
            .init(status: 200, body: sse, headers: ["Content-Type": "text/event-stream"]),
        ])
        let adapter = MoonshotAdapter(
            session: session(), apiKeyOverride: "k",
            telemetryDataRootOverride: telemetryRoot
        )
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: nil, model: "kimi-k3", tools: nil
        ) {
            events.append(event)
        }
        #expect(events.contains(.textDelta("All done.")))

        let trace = try String(
            contentsOf: telemetryRoot
                .appendingPathComponent("traces", isDirectory: true)
                .appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        // Row was written (streaming call recorded) but carries no usage keys.
        #expect(trace.contains("\"kind\":\"llm.call\"") || trace.contains("llm.call"))
        #expect(!trace.contains("inputTokens"), "no usage frame → no inputTokens key: \(trace)")
        #expect(!trace.contains("outputTokens"), "no usage frame → no outputTokens key: \(trace)")
    }
}

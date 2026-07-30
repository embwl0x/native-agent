import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore

// C1 / B2 / B8 (tightness sweep 2026-07-17): unit tests for the shared
// ChatCompletionsStreamDecoder and adapter-level regression tests proving the
// OpenAI + OpenRouter mid-stream error frames now surface as providerError
// (B2) and the OpenAI streaming path captures usage into telemetry (B8).

// MARK: - Decoder unit tests (frames → events)

@Test func decoder_textDeltaThenDone_tracksContentAndSawDone() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    let f1 = try decoder.consume(payload: #"{"choices":[{"delta":{"role":"assistant"}}]}"#)
    #expect(f1.content == nil)  // role-only frame yields nothing
    let f2 = try decoder.consume(payload: #"{"choices":[{"delta":{"content":"Hello"}}]}"#)
    #expect(f2.content == "Hello")
    let f3 = try decoder.consume(payload: #"{"choices":[{"delta":{"content":""}}]}"#)
    #expect(f3.content == nil)  // empty content is not a delta
    #expect(!decoder.sawDone)
    let done = try decoder.consume(payload: "[DONE]")
    #expect(done.isDone)
    #expect(decoder.sawDone)
}

@Test func decoder_emptyAndMalformedFramesAreSkippedNotFatal() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    #expect(try decoder.consume(payload: "").content == nil)
    #expect(try decoder.consume(payload: "not json at all").content == nil)
    #expect(try decoder.consume(payload: #"{"choices":[]}"#).content == nil)
    #expect(!decoder.sawDone)
}

@Test func decoder_accumulatesToolCallArgumentsByIndexAcrossFrames() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "Moonshot")
    // id + name arrive first, then arguments stream in two chunks.
    let a = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup","arguments":"{\"q\":"}}]}}]}"#)
    #expect(a.toolCallDeltaCount == 1)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"cats\"}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "moonshot_tool")
    #expect(completed.count == 1)
    #expect(completed[0].id == "call_1")
    #expect(completed[0].name == "lookup")
    #expect(completed[0].arguments == #"{"q":"cats"}"#)
}

@Test func decoder_synthesizesToolIdAndDefaultsEmptyArgsWhenProviderOmits() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "xAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"ping"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "xai_tool")
    #expect(completed.count == 1)
    #expect(completed[0].id == "xai_tool_0_ping")  // synthesized from prefix+index+name
    #expect(completed[0].arguments == "{}")          // empty args → {}
}

@Test func decoder_skipsToolCallWhoseNameNeverArrived() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}"#)
    #expect(decoder.completedToolCalls(idPrefix: "p").isEmpty)
}

@Test func decoder_rootErrorFrameThrowsProviderErrorWithLabelAndMessage() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenRouter")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"content":"partial"}}]}"#)
    do {
        _ = try decoder.consume(payload: #"{"error":{"type":"rate_limit_exceeded","message":"upstream is overloaded"}}"#)
        Issue.record("expected providerError to throw")
    } catch let err as LLMError {
        guard case .providerError(let message) = err else {
            Issue.record("expected providerError, got \(err)")
            return
        }
        #expect(message == "OpenRouter: upstream is overloaded")
        #expect(!message.contains("[DONE]"))
    }
}

@Test func decoder_errorFrameFallsBackToTypeThenUnknown() throws {
    var d1 = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    do {
        _ = try d1.consume(payload: #"{"error":{"type":"server_error"}}"#)
        Issue.record("expected throw")
    } catch let err as LLMError {
        #expect(err == .providerError(message: "OpenAI: server_error"))
    }
    var d2 = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    do {
        _ = try d2.consume(payload: #"{"error":{}}"#)
        Issue.record("expected throw")
    } catch let err as LLMError {
        #expect(err == .providerError(message: "OpenAI: unknown error"))
    }
}

@Test func decoder_capturesUsageFromDedicatedEmptyChoicesFrame() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"content":"done"}}]}"#)
    #expect(decoder.usage == nil)
    _ = try decoder.consume(payload: #"{"choices":[],"usage":{"prompt_tokens":77,"completion_tokens":9,"total_tokens":86}}"#)
    #expect(decoder.usage?.inputTokens == 77)
    #expect(decoder.usage?.outputTokens == 9)
}

@Test func decoder_capturesUsageRidingTheFinalDeltaFrame() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "Moonshot")
    let f = try decoder.consume(payload: #"{"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#)
    #expect(f.content == "done")
    #expect(f.finishReason == "stop")
    #expect(decoder.usage?.inputTokens == 5)
}

@Test func decoder_surfacesReasoningDeltaAndAccumulates() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "Moonshot")
    let f1 = try decoder.consume(payload: #"{"choices":[{"delta":{"reasoning_content":"first "}}]}"#)
    #expect(f1.reasoning == "first ")
    #expect(f1.content == nil)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"reasoning_content":"second"}}]}"#)
    #expect(decoder.reasoning == "first second")
}

// MARK: - Adapter-level regression tests (B2 error frames, B8 usage)

@Suite(.serialized)
struct ChatCompletionsAdapterErrorAndUsageTests {
    final class ProtocolStub: URLProtocol, @unchecked Sendable {
        struct StubResponse {
            let status: Int
            let body: Data
            let headers: [String: String]
        }
        nonisolated(unsafe) static var response: StubResponse?
        nonisolated(unsafe) static var lastBody: Data?

        static func set(status: Int, body: Data, headers: [String: String]) {
            response = .init(status: status, body: body, headers: headers)
            lastBody = nil
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
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
                Self.lastBody = captured
            } else {
                Self.lastBody = request.httpBody
            }
            guard let response = Self.response else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
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

    /// B2: an OpenAI mid-stream `{"error":{…}}` frame must surface as
    /// providerError with the provider's real message, NOT a wrong-cause
    /// streamTruncated (the old no-`choices` guard swallowed it).
    @Test func openAIStreamErrorFrameSurfacesProviderErrorNotTruncation() async throws {
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"partial"}}]}

        data: {"error":{"type":"insufficient_quota","message":"You exceeded your current quota"}}

        """.utf8)
        ProtocolStub.set(status: 200, body: sse, headers: ["Content-Type": "text/event-stream"])
        let adapter = OpenAIAdapter(session: session(), apiKeyOverride: "k")
        var caught: Error?
        do {
            for try await _ in adapter.stream(prompt: "p", system: nil, model: "gpt-5.5") {}
        } catch { caught = error }
        guard case .providerError(let message)? = caught as? LLMError else {
            Issue.record("expected providerError, got \(String(describing: caught))")
            return
        }
        #expect(message.contains("You exceeded your current quota"))
        #expect(!message.contains("[DONE]"))
    }

    /// B2: same for OpenRouter (most exposed — it aggregates upstreams).
    @Test func openRouterStreamErrorFrameSurfacesProviderErrorNotTruncation() async throws {
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"partial"}}]}

        data: {"error":{"message":"upstream provider returned error 529"}}

        """.utf8)
        ProtocolStub.set(status: 200, body: sse, headers: ["Content-Type": "text/event-stream"])
        let adapter = OpenRouterAdapter(session: session(), apiKeyOverride: "k")
        var caught: Error?
        do {
            for try await _ in adapter.stream(prompt: "p", system: nil, model: "anthropic/claude-opus-4") {}
        } catch { caught = error }
        guard case .providerError(let message)? = caught as? LLMError else {
            Issue.record("expected providerError, got \(String(describing: caught))")
            return
        }
        #expect(message.contains("upstream provider returned error 529"))
        #expect(!message.contains("[DONE]"))
    }

    /// B8: the OpenAI api-key streaming path requests
    /// `stream_options.include_usage` and records the returned usage frame into
    /// the telemetry row (previously recorded usage: nil).
    @Test func openAIStreamRequestsUsageAndCapturesItIntoTelemetry() async throws {
        let telemetryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: telemetryRoot) }
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"All done."},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":41,"completion_tokens":8,"total_tokens":49}}

        data: [DONE]

        """.utf8)
        ProtocolStub.set(status: 200, body: sse, headers: ["Content-Type": "text/event-stream"])
        let adapter = OpenAIAdapter(
            session: session(),
            apiKeyOverride: "k",
            telemetryDataRootOverride: telemetryRoot
        )
        var collected: [String] = []
        for try await chunk in adapter.stream(prompt: "p", system: nil, model: "gpt-5.5") {
            collected.append(chunk)
        }
        #expect(collected == ["All done."])

        // The request body must carry stream_options.include_usage.
        let body = try #require(ProtocolStub.lastBody)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let streamOptions = try #require(parsed["stream_options"] as? [String: Any])
        #expect(streamOptions["include_usage"] as? Bool == true)

        // The telemetry row must carry the captured token counts.
        let trace = try String(
            contentsOf: telemetryRoot
                .appendingPathComponent("traces", isDirectory: true)
                .appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        #expect(trace.contains("41"), "prompt tokens must reach telemetry: \(trace)")
        #expect(trace.contains("utputTokens") || trace.contains("output_tokens"),
                "completion tokens must reach telemetry: \(trace)")
    }
}

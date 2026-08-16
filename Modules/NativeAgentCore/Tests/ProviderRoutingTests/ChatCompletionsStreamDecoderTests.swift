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

    @Test func openRouterStructuredStreamPreservesImagesToolsAndToolResults() async throws {
        let sse = Data("""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_7","function":{"name":"lookup","arguments":"{\\"q\\":\\"cats\\"}"}}]}}]}

        data: [DONE]

        """.utf8)
        ProtocolStub.set(status: 200, body: sse, headers: ["Content-Type": "text/event-stream"])
        let adapter = OpenRouterAdapter(session: session(), apiKeyOverride: "k")
        let schema = LLMToolSchema(
            name: "lookup",
            description: "Look something up",
            parametersJSON: Data(#"{"type":"object","properties":{"q":{"type":"string"}}}"#.utf8)
        )
        let messages: [LLMMessage] = [
            .userWithImages("what is this?", images: [
                .image(mediaType: "image/png", base64: "aGVsbG8=", name: "sample.png", byteSize: 5),
            ]),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "prior", name: "lookup", inputJSON: Data(#"{"q":"dogs"}"#.utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "prior", content: "done", isError: false),
            ]),
        ]
        var calls: [LLMStreamToolCall] = []
        for try await event in adapter.streamMessages(
            messages: messages, system: "system", model: "google/gemini-test", tools: [schema]
        ) {
            if case .toolCall(let call) = event { calls.append(call) }
        }
        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_7")
        #expect(calls.first?.name == "lookup")
        #expect(String(data: calls.first?.inputJSON ?? Data(), encoding: .utf8) == #"{"q":"cats"}"#)

        let body = try #require(ProtocolStub.lastBody)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["stream"] as? Bool == true)
        #expect((root["tools"] as? [[String: Any]])?.count == 1)
        let rows = try #require(root["messages"] as? [[String: Any]])
        let imageRow = try #require(rows.first { ($0["role"] as? String) == "user" })
        let parts = try #require(imageRow["content"] as? [[String: Any]])
        let imageURL = try #require(parts.first { ($0["type"] as? String) == "image_url" })
        #expect(((imageURL["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(rows.contains { ($0["role"] as? String) == "tool" && ($0["tool_call_id"] as? String) == "prior" })
    }
}

// MARK: - Absent-`index` tool-call fragmentation (gpt-5.5 BLOCKING 2026-08-02)
//
// The no-index branch keyed on `toolOrder.count`, so EVERY index-less fragment
// minted a NEW accumulator. A stream that opens a call and then streams the
// rest of its arguments in a second index-less frame built two slots; the
// second carried no `name` and was dropped by `completedToolCalls`, so the call
// surfaced with truncated arguments (or `{}`). Pre-existing, but live since the
// OpenAI api-key adapter began routing through this decoder.

@Test func decoder_noIndexFragments_continueTheSameToolCall() throws {
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    // The exact two-fragment sequence from the finding.
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"call_1","function":{"name":"search","arguments":"{\"q\""}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":":\"x\"}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "openai_tool")
    // Pre-fix: 2 accumulators, the second nameless and dropped → arguments
    // truncated to `{"q"`.
    #expect(completed.count == 1)
    #expect(completed[0].id == "call_1")
    #expect(completed[0].name == "search")
    #expect(completed[0].arguments == #"{"q":"x"}"#)
}

@Test func decoder_noIndexFragments_splitBeforeAnyArgumentText() throws {
    // The nastier split: the opening frame carries id+name only, so pre-fix the
    // ENTIRE argument body landed in a dropped nameless slot and the call
    // surfaced as `{}` — a silently argument-less tool invocation.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"call_9","function":{"name":"write_file"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"path\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"a.txt\"}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "openai_tool")
    #expect(completed.count == 1)
    #expect(completed[0].name == "write_file")
    #expect(completed[0].arguments == #"{"path":"a.txt"}"#)
}

@Test func decoder_noIndexStream_startsANewCallOnEachNewId() throws {
    // Two sequential calls in one index-less stream: a fragment carrying a NEW
    // `id` opens a new accumulator, id-less fragments continue the open one.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":"alpha","arguments":"{\"a\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"1}"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"c2","function":{"name":"beta","arguments":"{\"b\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"2}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 2)
    #expect(completed[0].id == "c1")
    #expect(completed[0].name == "alpha")
    #expect(completed[0].arguments == #"{"a":1}"#)
    #expect(completed[1].id == "c2")
    #expect(completed[1].name == "beta")
    #expect(completed[1].arguments == #"{"b":2}"#)
}

@Test func decoder_noIndexStream_rejoinsACallWhenTheIdIsRepeated() throws {
    // Some providers echo the id on every fragment of the same call. That must
    // rejoin the open accumulator, not fork a second one.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenRouter")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":"alpha","arguments":"{\"a\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"arguments":"1}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 1)
    #expect(completed[0].arguments == #"{"a":1}"#)
}

@Test func decoder_interleavedIndexedCalls_stayIndependent() throws {
    // Indexed multi-call streams interleave freely; `index` stays authoritative
    // and the fix must not have made them share the "currently open" slot.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c0","function":{"name":"alpha","arguments":"{\"a\":"}},{"index":1,"id":"c1","function":{"name":"beta","arguments":"{\"b\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"2}"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 2)
    #expect(completed[0].id == "c0")
    #expect(completed[0].arguments == #"{"a":1}"#)
    #expect(completed[1].id == "c1")
    #expect(completed[1].arguments == #"{"b":2}"#)
}

@Test func decoder_mixedIndexedThenIndexLessFragments_doNotCollide() throws {
    // A stream that starts indexed and then drops `index` mid-call: the id-less
    // continuation must land on the last-written slot (1), and a later NEW id
    // must allocate a slot that cannot collide with the explicit indices.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c0","function":{"name":"alpha","arguments":"{\"a\":1}"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c1","function":{"name":"beta","arguments":"{\"b\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"2}"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"c2","function":{"name":"gamma","arguments":"{}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 3)
    #expect(completed[0].arguments == #"{"a":1}"#)
    #expect(completed[1].id == "c1")
    #expect(completed[1].arguments == #"{"b":2}"#)   // pre-fix: dropped nameless slot
    #expect(completed[2].id == "c2")
    #expect(completed[2].name == "gamma")
}

// MARK: - Absent-`index` INTERLEAVED multi-call fragments (gpt-5.5 BLOCKING 2026-08-02)
//
// The first fix keyed an id-less fragment to `currentToolIndex`, a decoder-GLOBAL
// cursor. Interleaving defeats it: frame 1 opens `A` then `B` (cursor left on
// `B`), frame 2 carries `[A_args, B_args]` id-less — both appended to `B`, so `A`
// surfaced truncated and `B` carried both halves. Slot resolution is now keyed to
// the fragment's POSITION WITHIN ITS OWN FRAME.

@Test func decoder_noIndexInterleavedTwoCalls_eachKeepsItsOwnArguments() throws {
    // The exact failure: two calls opened in one frame, both continued id-less
    // in array order in the next.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"A","function":{"name":"alpha","arguments":"{\"a\":"}},{"id":"B","function":{"name":"beta","arguments":"{\"b\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"1}"}},{"function":{"arguments":"2}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "openai_tool")
    // Pre-fix: alpha == `{"a":` and beta == `{"b":1}2}`.
    #expect(completed.count == 2)
    #expect(completed[0].id == "A")
    #expect(completed[0].name == "alpha")
    #expect(completed[0].arguments == #"{"a":1}"#)
    #expect(completed[1].id == "B")
    #expect(completed[1].name == "beta")
    #expect(completed[1].arguments == #"{"b":2}"#)
}

@Test func decoder_noIndexInterleavedThreeCalls_surviveManyContinuationFrames() throws {
    // Three calls, three id-less continuation frames — position must stay
    // stable across every frame, not just the one right after the opener.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "xAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"A","function":{"name":"a","arguments":"{\"k\":\""}},{"id":"B","function":{"name":"b","arguments":"{\"k\":\""}},{"id":"C","function":{"name":"c","arguments":"{\"k\":\""}}]}}]}"#)
    for chunk in ["1", "2", "3"] {
        let entry = #"{"function":{"arguments":"\#(chunk)"}}"#
        _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[\#(entry),\#(entry),\#(entry)]}}]}"#)
    }
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"}"}},{"function":{"arguments":"\"}"}},{"function":{"arguments":"\"}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 3)
    #expect(completed.map(\.id) == ["A", "B", "C"])
    for call in completed {
        #expect(call.arguments == #"{"k":"123"}"#, "\(call.id) got \(call.arguments)")
    }
}

@Test func decoder_noIndexFrameMixingIdBearingAndIdLessEntries_doesNotCrossWires() throws {
    // A frame that opens a NEW call and continues an OPEN one in the same array.
    // The id-less entry sits at a position the previous frame never addressed,
    // so it falls back to the just-opened call rather than stealing a slot from
    // an unrelated one.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "Moonshot")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"A","function":{"name":"alpha","arguments":"{\"a\":"}},{"id":"B","function":{"name":"beta","arguments":"{\"b\":"}}]}}]}"#)
    // Mixed frame: position 0 is an id-less continuation of A (the slot position
    // 0 addressed last frame), position 1 opens C by id. Pre-fix the id-less
    // entry followed the global cursor and appended A's tail to B.
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"1}"}},{"id":"C","function":{"name":"gamma","arguments":"{\"c\":"}}]}}]}"#)
    // The mixed shape in the other order: a new id at position 0 shifts the
    // frame's layout, so the id-less entry behind it continues that call (D),
    // NOT whatever position 1 held a frame ago.
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"D","function":{"name":"delta_fn","arguments":"{\"d\":"}},{"function":{"arguments":"4}"}}]}}]}"#)
    // B and C finish by explicit id.
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"id":"B","function":{"arguments":"2}"}},{"id":"C","function":{"arguments":"3}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 4)
    #expect(completed[0].id == "A")
    #expect(completed[0].arguments == #"{"a":1}"#)
    #expect(completed[1].id == "B")
    #expect(completed[1].arguments == #"{"b":2}"#)
    #expect(completed[2].id == "C")
    #expect(completed[2].arguments == #"{"c":3}"#)
    #expect(completed[3].id == "D")
    #expect(completed[3].arguments == #"{"d":4}"#)
}

@Test func decoder_noIndexIdLessFragmentNamingADifferentFunction_opensItsOwnCall() throws {
    // Fully id-less AND index-less stream: two calls, distinguished only by
    // `function.name`. A named fragment that disagrees with the slot its
    // position resolved to must open a new call, not overwrite that one.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"name":"alpha","arguments":"{\"a\":1}"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"name":"beta","arguments":"{\"b\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"2}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 2)
    #expect(completed[0].name == "alpha")
    #expect(completed[0].arguments == #"{"a":1}"#)
    #expect(completed[1].name == "beta")
    #expect(completed[1].arguments == #"{"b":2}"#)
}

@Test func decoder_explicitIndexInterleaved_isUnaffectedByThePositionalRule() throws {
    // Guard the with-`index` path: two calls opened in one frame, then
    // continued in REVERSE array order in later frames. `index` stays
    // authoritative — array position must not touch this path at all.
    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c0","function":{"name":"alpha","arguments":"{\"a\":"}},{"index":1,"id":"c1","function":{"name":"beta","arguments":"{\"b\":"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"2"}},{"index":0,"function":{"arguments":"1"}}]}}]}"#)
    _ = try decoder.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}},{"index":1,"function":{"arguments":"}"}}]}}]}"#)
    let completed = decoder.completedToolCalls(idPrefix: "p")
    #expect(completed.count == 2)
    #expect(completed[0].id == "c0")
    #expect(completed[0].arguments == #"{"a":1}"#)
    #expect(completed[1].id == "c1")
    #expect(completed[1].arguments == #"{"b":2}"#)
}

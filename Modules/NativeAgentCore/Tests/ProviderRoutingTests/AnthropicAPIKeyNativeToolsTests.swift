import Testing
import Foundation
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - Anthropic API-KEY native tool lane
//
// docs/build_plans/fable51-sweep-2026-09-01.md item 34. Until now every Claude
// turn on every surface rode the text-compatibility marker protocol, parsing
// tool calls out of prose. The api-key path (api.anthropic.com + x-api-key) is
// the documented public Messages API, so it ships a real `tools` array; the
// OAuth-direct subscription path stays on markers, and the SAME predicate
// decides both.
//
// FABLE 5.1 CONTRACT pinned here:
//   * forced tool_choice ("any"/"tool") returns 400 → the key is never emitted;
//   * `strict: true` is a top-level tool-definition field, valid only on a
//     closed schema;
//   * parallel tool use is the default → every tool_use block must surface;
//   * tool inputs are JSON → assembled from input_json_delta and parsed, never
//     string-matched.
//
// ISOLATION: this file owns its OWN URLProtocol stub class (the same reason
// KimiCodeNativeToolsWireTests owns one) — a shared static responder races
// under swift-testing's parallel execution.

private final class APIKeyToolsStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }
    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        responder = nil
        lastBody = nil
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
            APIKeyToolsStubURLProtocol.lastBody = data
            APIKeyToolsStubURLProtocol.bodies.append(data)
        } else {
            APIKeyToolsStubURLProtocol.lastBody = request.httpBody
            APIKeyToolsStubURLProtocol.bodies.append(request.httpBody ?? Data())
        }
        let response = APIKeyToolsStubURLProtocol.responder?(request)
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

private func apiKeyToolsStubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [APIKeyToolsStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

/// Hermetic root so telemetry rows never touch the live personal data root.
private func apiKeyToolsTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("anthropic-apikey-native-tools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The DEFAULT init — providerId "anthropic", api.anthropic.com, x-api-key.
/// That default is exactly what production constructs (`AnthropicAdapter()`).
private func makeAPIKeyAdapter(root: URL) -> AnthropicAdapter {
    AnthropicAdapter(
        session: apiKeyToolsStubSession(),
        apiKeyOverride: "sk-ant-test",
        dataRootOverride: root,
        telemetryDataRootOverride: root
    )
}

private func makeKimiAdapterForContrast(root: URL) -> AnthropicAdapter {
    AnthropicAdapter.kimiCode(
        session: apiKeyToolsStubSession(),
        apiKeyOverride: "kc-secret",
        dataRootOverride: root,
        telemetryDataRootOverride: root
    )
}

/// A CLOSED schema — `additionalProperties: false` — so it earns `strict`.
private let closedSchema = LLMToolSchema(
    name: "git_status",
    description: "Repo state",
    parametersJSON: Data(#"""
    {"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}
    """#.utf8)
)

/// An OPEN schema — the MCP schemaless passthrough shape. It genuinely accepts
/// extra keys, so `strict` must NOT be asserted for it.
private let openSchema = LLMToolSchema(
    name: "mcp_passthrough",
    description: "Anything goes",
    parametersJSON: Data(#"""
    {"type":"object","properties":{},"additionalProperties":true}
    """#.utf8)
)

/// CLOSED at the root, OPEN one level down: `settings` declares properties but
/// no `additionalProperties`, and JSON Schema's DEFAULT is OPEN. A root-only
/// check certifies this as strict; the recursive one must not.
private let nestedOpenSchema = LLMToolSchema(
    name: "configure",
    description: "Nested object, open child",
    parametersJSON: Data(#"""
    {"type":"object","additionalProperties":false,"required":["settings"],
     "properties":{"settings":{"type":"object","properties":{"mode":{"type":"string"}}}}}
    """#.utf8)
)

/// The same shape with EVERY level closed — reachable through `properties`,
/// `items`, `anyOf` and `$defs`, which is the whole traversal surface.
private let nestedClosedSchema = LLMToolSchema(
    name: "configure_closed",
    description: "Nested objects, all closed",
    parametersJSON: Data(#"""
    {"type":"object","additionalProperties":false,"required":["settings","tags"],
     "properties":{
       "settings":{"type":"object","additionalProperties":false,"properties":{"mode":{"type":"string"}}},
       "tags":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"k":{"type":"string"}}}},
       "either":{"anyOf":[{"type":"string"},{"$ref":"#/$defs/leaf"}]}
     },
     "$defs":{"leaf":{"type":"object","additionalProperties":false,"properties":{"n":{"type":"integer"}}}}}
    """#.utf8)
)

/// Every `cache_control` marker anywhere in the request body. Anthropic allows
/// at most 4 breakpoints per request, so the count is the budget.
private func cacheControlCount(_ node: Any) -> Int {
    if let dict = node as? [String: Any] {
        return dict.reduce(0) { total, entry in
            total + (entry.key == "cache_control" ? 1 : cacheControlCount(entry.value))
        }
    }
    if let list = node as? [Any] {
        return list.reduce(0) { $0 + cacheControlCount($1) }
    }
    return 0
}

private func lastBodyObject() throws -> [String: Any] {
    let body = try #require(APIKeyToolsStubURLProtocol.lastBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func bodyObject(at index: Int) throws -> [String: Any] {
    let bodies = APIKeyToolsStubURLProtocol.bodies
    try #require(index < bodies.count)
    return try #require(JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
}

private func sse(_ frames: [String]) -> Data {
    Data(frames.map { $0 + "\n\n" }.joined().utf8)
}

@Suite(.serialized)
struct AnthropicAPIKeyNativeToolsTests {

    // MARK: - The single predicate

    @Test func predicate_admits_apiKeyAnthropic_and_still_refuses_oauth() {
        // The api-key provider id — the whole point of item 34.
        #expect(NativeToolCapability.providerSupportsNativeTools("anthropic"))
        #expect(NativeToolCapability.providerSupportsNativeTools("  ANTHROPIC "))
        // kimi-code is unchanged.
        #expect(NativeToolCapability.providerSupportsNativeTools("kimi-code"))
        #expect(NativeToolCapability.providerSupportsNativeTools("kimi_code"))

        // THE INVARIANT: the Claude SUBSCRIPTION connection must never be
        // handed a tools array. Both spellings, since the predicate folds `_`
        // to `-` and a family-prefix match would have swept these in.
        #expect(!NativeToolCapability.providerSupportsNativeTools("anthropic_oauth_direct"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("anthropic-oauth-direct"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("ANTHROPIC_OAUTH_DIRECT"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("anthropic_mcp"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("moonshot"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("openai"))
        #expect(!NativeToolCapability.providerSupportsNativeTools(nil))

        // The MODEL backstop stays kimi-only: a `claude-*` id is served by BOTH
        // Claude transports, so it can never decide the lane on its own.
        #expect(!NativeToolCapability.modelImpliesNativeToolProvider("claude-fable-5-1"))
        #expect(!NativeToolCapability.modelImpliesNativeToolProvider("claude-opus-4-8"))
    }

    // MARK: - Request shape: tools[], strict, and NO forced tool_choice

    @Test func apiKeyNative_sends_tools_and_never_forces_tool_choice() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        _ = try await adapter.completeMessagesWithTools(
            messages: [.user("status?")], system: "sys",
            model: "claude-fable-5-1", tools: [closedSchema, openSchema]
        )

        let body = try lastBodyObject()
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools[0]["name"] as? String == "git_status")

        // FABLE 5.1: tool_choice "any"/"tool" is a 400. The correct wire is the
        // ABSENT key (auto is the default) — not an explicit auto.
        #expect(body["tool_choice"] == nil)
    }

    @Test func apiKeyNative_strict_rides_only_closed_schemas() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        _ = try await adapter.completeMessagesWithTools(
            messages: [.user("status?")], system: nil,
            model: "claude-fable-5-1", tools: [closedSchema, openSchema]
        )

        let strictBody = try lastBodyObject()
        let tools = try #require(strictBody["tools"] as? [[String: Any]])
        // Closed schema → provider-side argument validation.
        #expect(tools[0]["strict"] as? Bool == true)
        let closed = try #require(tools[0]["input_schema"] as? [String: Any])
        #expect(closed["additionalProperties"] as? Bool == false)
        #expect((closed["required"] as? [String]) == ["path"])
        // Open schema → NO strict claim, and its declared openness is intact.
        #expect(tools[1]["strict"] == nil)
        let open = try #require(tools[1]["input_schema"] as? [String: Any])
        #expect(open["additionalProperties"] as? Bool == true)
    }

    @Test func kimiCode_keeps_its_probed_wire_no_strict_no_stream() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeKimiAdapterForContrast(root: root)
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: nil, model: "k3", tools: [closedSchema]
        ) {
            events.append(event)
        }
        let body = try lastBodyObject()
        // kimi-code was probed for shapes A/B/C only: still the blocking call
        // (no "stream": true) and no unprobed `strict` key on its tools.
        #expect(body["stream"] == nil)
        #expect(body["tool_choice"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools[0]["strict"] == nil)
        // Nor the unprobed tool-list cache breakpoint: kimi's wire is exactly
        // what shapes A/B/C established.
        #expect(tools[0]["cache_control"] == nil)
        #expect(events.contains(.textDelta("ok")))
    }

    // MARK: - Structured loop: parallel tool_use → tool_result round-trip

    @Test func apiKeyNative_parallel_toolUse_roundTrips_through_structured_loop() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        // Iteration 1: TEXTLESS 200 carrying TWO tool_use blocks — the happy
        // path on this lane (parallel tool use is the family default), and the
        // exact shape the pre-native empty-reply guard would have rejected.
        // Iteration 2: the model's answer after seeing both results.
        APIKeyToolsStubURLProtocol.responder = { _ in
            let n = APIKeyToolsStubURLProtocol.bodies.count
            if n <= 1 {
                return .init(status: 200, body: Data(#"""
                {"content":[
                  {"type":"thinking","thinking":"…","signature":"sig"},
                  {"type":"tool_use","id":"toolu_1","name":"git_status","input":{"path":"/repo"}},
                  {"type":"tool_use","id":"toolu_2","name":"git_status","input":{"path":"/other"}}
                ],"stop_reason":"tool_use"}
                """#.utf8))
            }
            return .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"both clean"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)

        let first = try await adapter.completeMessagesWithTools(
            messages: [.user("status of both?")], system: nil,
            model: "claude-fable-5-1", tools: [closedSchema]
        )
        #expect(first.stopReason == "tool_use")
        #expect(first.text.isEmpty)
        #expect(first.toolCalls.count == 2)
        #expect(first.toolCalls.map(\.id) == ["toolu_1", "toolu_2"])
        // Tool inputs are JSON — PARSED, never string-matched.
        let firstInput = try #require(
            JSONSerialization.jsonObject(with: first.toolCalls[0].inputJSON) as? [String: Any])
        #expect(firstInput["path"] as? String == "/repo")

        // Replay: assistant tool_use blocks + ONE user message carrying BOTH
        // tool_result blocks (splitting them trains the model out of parallel
        // calls), one of them an error result.
        let conversation: [LLMMessage] = [
            .user("status of both?"),
            LLMMessage(role: .assistant, content: first.toolCalls.map {
                .toolUse(id: $0.id, name: $0.name, inputJSON: $0.inputJSON)
            }),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "toolu_1", content: "clean", isError: false),
                .toolResult(toolUseId: "toolu_2", content: "no such repo", isError: true),
            ]),
        ]
        let second = try await adapter.completeMessagesWithTools(
            messages: conversation, system: nil,
            model: "claude-fable-5-1", tools: [closedSchema]
        )
        #expect(second.text == "both clean")
        #expect(second.toolCalls.isEmpty)

        let replayBody = try bodyObject(at: 1)
        let messages = try #require(replayBody["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        // Thinking FIRST (fable 5.1 requires the signed block back), then both
        // tool_use blocks — parallel calls stay on one assistant message.
        #expect(assistantBlocks.count == 3)
        #expect(assistantBlocks[0]["type"] as? String == "thinking")
        #expect(assistantBlocks[0]["signature"] as? String == "sig")
        #expect(assistantBlocks.dropFirst().allSatisfy { ($0["type"] as? String) == "tool_use" })
        // The input round-tripped as a JSON OBJECT, not a stringified blob.
        #expect((assistantBlocks[1]["input"] as? [String: Any])?["path"] as? String == "/repo")

        let resultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(messages[2]["role"] as? String == "user")
        #expect(resultBlocks.count == 2)
        #expect(resultBlocks[0]["tool_use_id"] as? String == "toolu_1")
        #expect(resultBlocks[0]["is_error"] == nil)
        #expect(resultBlocks[1]["tool_use_id"] as? String == "toolu_2")
        #expect(resultBlocks[1]["is_error"] as? Bool == true)
    }

    // MARK: - Streaming: input_json_delta assembly

    @Test func apiKeyNative_streaming_assembles_input_json_delta_per_block() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        // Fragments deliberately split MID-TOKEN and mid-string so a naive
        // per-frame parse or a shared accumulator would fail loudly.
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: sse([
                #"event: message_start"# + "\n" +
                #"data: {"type":"message_start","message":{"usage":{"input_tokens":42}}}"#,
                #"event: content_block_start"# + "\n" +
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"event: content_block_delta"# + "\n" +
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking "}}"#,
                #"event: content_block_delta"# + "\n" +
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"both."}}"#,
                #"event: content_block_stop"# + "\n" +
                #"data: {"type":"content_block_stop","index":0}"#,
                #"event: content_block_start"# + "\n" +
                #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_a","name":"git_status"}}"#,
                #"event: content_block_delta"# + "\n" +
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}"#,
                #"event: content_block_delta"# + "\n" +
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"th\":\"/re"}}"#,
                #"event: content_block_delta"# + "\n" +
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"po\"}"}}"#,
                #"event: content_block_stop"# + "\n" +
                #"data: {"type":"content_block_stop","index":1}"#,
                #"event: content_block_start"# + "\n" +
                #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_b","name":"git_status"}}"#,
                #"event: content_block_delta"# + "\n" +
                #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
                #"event: content_block_delta"# + "\n" +
                #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"/other\"}"}}"#,
                #"event: content_block_stop"# + "\n" +
                #"data: {"type":"content_block_stop","index":2}"#,
                #"event: message_delta"# + "\n" +
                #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":31}}"#,
                #"event: message_stop"# + "\n" +
                #"data: {"type":"message_stop"}"#,
            ]))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)

        var text = ""
        var calls: [LLMStreamToolCall] = []
        var keepAlives = 0
        for try await event in adapter.streamMessages(
            messages: [.user("status of both?")], system: nil,
            model: "claude-fable-5-1", tools: [closedSchema]
        ) {
            switch event {
            case .textDelta(let t): text += t
            case .toolCall(let c): calls.append(c)
            case .keepAlive: keepAlives += 1
            }
        }

        // Live deltas survived — the api-key chat surface still streams.
        #expect(text == "Checking both.")
        // PARALLEL: both blocks surfaced, in wire order, each with its OWN
        // assembled input. No fragment leaked across the block boundary.
        #expect(calls.count == 2)
        #expect(calls.map(\.id) == ["toolu_a", "toolu_b"])
        #expect(calls.map(\.name) == ["git_status", "git_status"])
        let a = try #require(JSONSerialization.jsonObject(with: calls[0].inputJSON) as? [String: Any])
        let b = try #require(JSONSerialization.jsonObject(with: calls[1].inputJSON) as? [String: Any])
        #expect(a["path"] as? String == "/repo")
        #expect(b["path"] as? String == "/other")
        // Argument accumulation is guard-visible activity, not silence.
        #expect(keepAlives >= 5)

        // The streamed request is the same body plus `stream` — and still no
        // forced tool choice.
        let body = try lastBodyObject()
        #expect(body["stream"] as? Bool == true)
        #expect(body["tool_choice"] == nil)
        #expect((body["tools"] as? [[String: Any]])?.first?["strict"] as? Bool == true)
    }

    @Test func apiKeyNative_streaming_toolOnly_response_is_not_an_empty_reply() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        // CONTRACT NOTE 1 on the streaming lane: a stream that produced a tool
        // call and NO text is the happy path, not the empty-reply class.
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: sse([
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_z","name":"git_status"}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
                #"data: {"type":"content_block_stop","index":0}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
                #"data: {"type":"message_stop"}"#,
            ]))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        var calls: [LLMStreamToolCall] = []
        for try await event in adapter.streamMessages(
            messages: [.user("status?")], system: nil,
            model: "claude-fable-5-1", tools: [closedSchema]
        ) {
            if case .toolCall(let c) = event { calls.append(c) }
        }
        #expect(calls.count == 1)
        #expect(calls[0].id == "toolu_z")
        #expect(String(data: calls[0].inputJSON, encoding: .utf8) == "{}")
    }

    @Test func apiKeyNative_withoutTools_is_untouched_legacy_path() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"plain"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        var events: [LLMMessageStreamEvent] = []
        for try await event in adapter.streamMessages(
            messages: [.user("hi")], system: nil, model: "claude-fable-5-1", tools: nil
        ) {
            events.append(event)
        }
        // tools == nil is every non-tool caller: no tools array, no stream key,
        // byte-identical to the pre-item-34 wire.
        let body = try lastBodyObject()
        #expect(body["tools"] == nil)
        #expect(body["stream"] == nil)
        #expect(events.contains(.textDelta("plain")))
    }

    // MARK: - strict is a RECURSIVE claim about the schema

    @Test func apiKeyNative_strict_is_withheld_when_a_nested_object_is_open() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        _ = try await adapter.completeMessagesWithTools(
            messages: [.user("go")], system: nil,
            model: "claude-fable-5-1", tools: [nestedOpenSchema, nestedClosedSchema]
        )
        let tools = try #require(try lastBodyObject()["tools"] as? [[String: Any]])
        // Root says additionalProperties:false, but `settings` does not — JSON
        // Schema's default is OPEN, so the tool never earned the strict claim.
        #expect(tools[0]["strict"] == nil)
        // The schema itself is untouched: we withhold the claim, never close
        // a schema on the tool's behalf.
        let nested = try #require(tools[0]["input_schema"] as? [String: Any])
        let settings = try #require(
            (nested["properties"] as? [String: Any])?["settings"] as? [String: Any])
        #expect(settings["additionalProperties"] == nil)
        // Closed at every level reachable via properties / items / anyOf / $defs.
        #expect(tools[1]["strict"] as? Bool == true)
    }

    @Test func closedSchemaPredicate_walks_every_subschema_edge() {
        func closed(_ json: String) -> Bool {
            let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8))
            return AnthropicAdapter.schemaIsRecursivelyClosed(obj ?? [:])
        }
        // Each edge, one open object hidden behind it.
        #expect(closed(#"{"type":"object","additionalProperties":false,"properties":{}}"#))
        #expect(!closed(#"{"type":"object"}"#))
        #expect(!closed(
            #"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"object"}}}"#))
        #expect(!closed(
            #"{"type":"object","additionalProperties":false,"items":{"type":"object"}}"#))
        #expect(!closed(
            #"{"type":"object","additionalProperties":false,"anyOf":[{"type":"object"}]}"#))
        #expect(!closed(
            #"{"type":"object","additionalProperties":false,"oneOf":[{"type":"object"}]}"#))
        #expect(!closed(
            #"{"type":"object","additionalProperties":false,"allOf":[{"type":"object"}]}"#))
        #expect(!closed(
            #"{"type":"object","additionalProperties":false,"$defs":{"d":{"type":"object"}}}"#))
        // A node that constrains `properties` IS an object schema even without
        // a declared type — and `additionalProperties` as a SCHEMA is not false.
        #expect(!closed(#"{"properties":{"a":{"type":"string"}}}"#))
        #expect(!closed(#"{"type":"object","additionalProperties":{"type":"string"}}"#))
        // Leaves close nothing and block nothing.
        #expect(closed(#"{"type":"string"}"#))
    }

    // MARK: - Prompt-cache breakpoint on the tool declarations

    @Test func apiKeyNative_caches_tools_at_the_last_definition_only() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        APIKeyToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        _ = try await adapter.completeMessagesWithTools(
            messages: [.user("status?")], system: "sys",
            model: "claude-fable-5-1", tools: [closedSchema, openSchema]
        )
        let body = try lastBodyObject()
        let tools = try #require(body["tools"] as? [[String: Any]])
        // Caching is a PREFIX match: one marker at the end of the tools block
        // caches the whole declaration mass. A marker on every tool would burn
        // the 4-breakpoint budget for no extra coverage.
        #expect(tools.count == 2)
        #expect(tools[0]["cache_control"] == nil)
        #expect((tools[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        // Whole-request budget: tools (1) + system (at most 1) — Anthropic
        // allows 4.
        #expect(cacheControlCount(body) <= 4)
    }

    // MARK: - Signed thinking blocks replay across a tool round

    @Test func apiKeyNative_replays_signed_thinking_blocks_in_order() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        // claude-fable-5-1 has extended thinking ALWAYS on: the tool-calling
        // response carries thinking blocks, and the assistant turn that comes
        // back with the tool_result must carry them again — signed, redacted
        // ones included, in the ORIGINAL order — or the API 400s.
        APIKeyToolsStubURLProtocol.responder = { _ in
            if APIKeyToolsStubURLProtocol.bodies.count <= 1 {
                return .init(status: 200, body: Data(#"""
                {"content":[
                  {"type":"thinking","thinking":"first","signature":"sig-1"},
                  {"type":"redacted_thinking","data":"opaque-payload"},
                  {"type":"thinking","thinking":"second","signature":"sig-2"},
                  {"type":"tool_use","id":"toolu_1","name":"git_status","input":{"path":"/repo"}}
                ],"stop_reason":"tool_use"}
                """#.utf8))
            }
            return .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"clean"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        let first = try await adapter.completeMessagesWithTools(
            messages: [.user("status?")], system: nil,
            model: "claude-fable-5-1", tools: [closedSchema]
        )
        #expect(first.toolCalls.count == 1)
        // Thinking is NOT reply text and never reaches the surface.
        #expect(first.text.isEmpty)

        _ = try await adapter.completeMessagesWithTools(
            messages: [
                .user("status?"),
                LLMMessage(role: .assistant, content: [
                    .text("checking"),
                    .toolUse(id: "toolu_1", name: "git_status",
                             inputJSON: Data(#"{"path":"/repo"}"#.utf8)),
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(toolUseId: "toolu_1", content: "clean", isError: false),
                ]),
            ],
            system: nil, model: "claude-fable-5-1", tools: [closedSchema]
        )

        let replay = try bodyObject(at: 1)
        let messages = try #require(replay["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        // Thinking FIRST, in original order, then the turn's own blocks.
        #expect(assistant.map { $0["type"] as? String }
            == ["thinking", "redacted_thinking", "thinking", "text", "tool_use"])
        #expect(assistant[0]["thinking"] as? String == "first")
        #expect(assistant[0]["signature"] as? String == "sig-1")
        // A redacted block replays its opaque payload verbatim and carries no
        // thinking text of its own.
        #expect(assistant[1]["data"] as? String == "opaque-payload")
        #expect(assistant[1]["thinking"] == nil)
        #expect(assistant[2]["thinking"] as? String == "second")
        #expect(assistant[2]["signature"] as? String == "sig-2")
        // The user turn is untouched — no thinking leaks onto a non-assistant
        // message.
        let user = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(user.allSatisfy { ($0["type"] as? String) == "tool_result" })
    }

    @Test func apiKeyNative_streaming_banks_thinking_and_signature_deltas() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        // Streaming delivers the thinking text and its signature as SEPARATE
        // delta streams; both must land on the SAME block or the replayed
        // signature attests to nothing.
        APIKeyToolsStubURLProtocol.responder = { _ in
            if APIKeyToolsStubURLProtocol.bodies.count <= 1 {
                return .init(status: 200, body: sse([
                    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"weigh"}}"#,
                    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ing it"}}"#,
                    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-"}}"#,
                    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"tail"}}"#,
                    #"data: {"type":"content_block_stop","index":0}"#,
                    #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_s","name":"git_status"}}"#,
                    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{"path":"/r"}"}}"#,
                    #"data: {"type":"content_block_stop","index":1}"#,
                    #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
                    #"data: {"type":"message_stop"}"#,
                ]))
            }
            return .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeAPIKeyAdapter(root: root)
        var text = ""
        var calls: [LLMStreamToolCall] = []
        for try await event in adapter.streamMessages(
            messages: [.user("status?")], system: nil,
            model: "claude-fable-5-1", tools: [closedSchema]
        ) {
            switch event {
            case .textDelta(let t): text += t
            case .toolCall(let c): calls.append(c)
            case .keepAlive: continue
            }
        }
        #expect(calls.map(\.id) == ["toolu_s"])
        // Thinking is liveness, never reply text — nothing leaked into the
        // surface's bubble.
        #expect(text.isEmpty)

        _ = try await adapter.completeMessagesWithTools(
            messages: [
                .user("status?"),
                LLMMessage(role: .assistant, content: [
                    .toolUse(id: "toolu_s", name: "git_status",
                             inputJSON: Data(#"{"path":"/r"}"#.utf8)),
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(toolUseId: "toolu_s", content: "clean", isError: false),
                ]),
            ],
            system: nil, model: "claude-fable-5-1", tools: [closedSchema]
        )
        let assistant = try #require(
            (try bodyObject(at: 1)["messages"] as? [[String: Any]])?[1]["content"]
                as? [[String: Any]])
        #expect(assistant[0]["type"] as? String == "thinking")
        #expect(assistant[0]["thinking"] as? String == "weighing it")
        #expect(assistant[0]["signature"] as? String == "sig-tail")
    }

    @Test func kimiCode_does_not_replay_thinking() async throws {
        APIKeyToolsStubURLProtocol.reset()
        defer { APIKeyToolsStubURLProtocol.reset() }
        APIKeyToolsStubURLProtocol.responder = { _ in
            if APIKeyToolsStubURLProtocol.bodies.count <= 1 {
                return .init(status: 200, body: Data(#"""
                {"content":[
                  {"type":"thinking","thinking":"x","signature":"sig"},
                  {"type":"tool_use","id":"toolu_k","name":"git_status","input":{}}
                ],"stop_reason":"tool_use"}
                """#.utf8))
            }
            return .init(status: 200, body: Data(#"""
            {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
            """#.utf8))
        }
        let root = try apiKeyToolsTempRoot()
        let adapter = makeKimiAdapterForContrast(root: root)
        _ = try await adapter.completeMessagesWithTools(
            messages: [.user("hi")], system: nil, model: "k3", tools: [closedSchema]
        )
        _ = try await adapter.completeMessagesWithTools(
            messages: [
                .user("hi"),
                LLMMessage(role: .assistant, content: [
                    .toolUse(id: "toolu_k", name: "git_status", inputJSON: Data("{}".utf8)),
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(toolUseId: "toolu_k", content: "ok", isError: false),
                ]),
            ],
            system: nil, model: "k3", tools: [closedSchema]
        )
        // Probe B established kimi's replay shape WITHOUT thinking; it stays
        // exactly as launched.
        let assistant = try #require(
            (try bodyObject(at: 1)["messages"] as? [[String: Any]])?[1]["content"]
                as? [[String: Any]])
        #expect(assistant.allSatisfy { ($0["type"] as? String) == "tool_use" })
    }
}

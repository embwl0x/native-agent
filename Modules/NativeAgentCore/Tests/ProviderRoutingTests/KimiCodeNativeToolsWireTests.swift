import Testing
import Foundation
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - Kimi-code NATIVE tool-use wire pins
//
// docs/build_plans/kimi-native-tools.md P3. These pin the shapes recorded by
// the P0 LIVE probe (2026-07-20, real key, k3) — treat them as ground truth
// over any vendor documentation:
//   A. request tools[] → response content:[thinking, tool_use{id,name,input}],
//      stop_reason "tool_use".
//   B. assistant [tool_use] + user [tool_result{tool_use_id,content}] replay.
//   C. parallel tool_use blocks in one response.
// Plus the load-bearing contract note: a textless 200 WITH tool_use blocks is
// the happy path and must NOT throw, while a textless 200 WITHOUT them is
// still the transient empty-reply class.
//
// ISOLATION: this file owns its OWN URLProtocol stub class. It deliberately
// does not reuse LLMClientRealTests' shared StubURLProtocol — that one races
// under swift-testing's parallel execution because its static responder is
// shared process-wide.

private final class NativeToolsStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }
    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        responder = nil
        lastBody = nil
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
            NativeToolsStubURLProtocol.lastBody = data
        } else {
            NativeToolsStubURLProtocol.lastBody = request.httpBody
        }
        let response = NativeToolsStubURLProtocol.responder?(request)
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

private func nativeToolsStubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [NativeToolsStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

/// Hermetic root so telemetry rows never touch the live personal data root.
private func nativeToolsTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-native-tools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeKimiAdapter(root: URL) -> AnthropicAdapter {
    AnthropicAdapter.kimiCode(
        session: nativeToolsStubSession(),
        apiKeyOverride: "kc-secret",
        dataRootOverride: root,
        telemetryDataRootOverride: root
    )
}

private let echoSchema = LLMToolSchema(
    name: "git_status",
    description: "Repo state",
    parametersJSON: try! JSONSerialization.data(withJSONObject: [
        "type": "object",
        "properties": ["path": ["type": "string"]],
        "required": ["path"],
    ])
)

private func parsedBody() throws -> [String: Any] {
    let body = try #require(NativeToolsStubURLProtocol.lastBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}


/// SERIALIZED (.serialized): every test in this file drives the SAME
/// URLProtocol stub class, whose responder/lastBody are necessarily static
/// (URLProtocol is instantiated by URLSession, so there is nowhere to hang
/// per-test state). Under swift-testing's default parallel execution the tests
/// overwrite each other's responder and read each other's captured body —
/// observed live while writing these: an "Index out of range" crash plus two
/// phantom failures. Serializing the suite is the isolation boundary; the stub
/// class itself is still private to this file so no OTHER suite can collide.
@Suite(.serialized)
struct KimiCodeNativeToolsWireTests {
    // MARK: - Capability flag

    @Test func nativeToolCapability_admits_only_kimiCode() {
        #expect(NativeToolCapability.providerSupportsNativeTools("kimi-code"))
        #expect(NativeToolCapability.providerSupportsNativeTools("kimi_code"))
        #expect(NativeToolCapability.providerSupportsNativeTools("  KIMI-CODE "))
        // The OAuth-direct Claude adapters must NEVER be admitted — sending a
        // tools array on a Claude subscription connection is documented history.
        #expect(!NativeToolCapability.providerSupportsNativeTools("anthropic"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("anthropic_oauth_direct"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("moonshot"))
        #expect(!NativeToolCapability.providerSupportsNativeTools("openai"))
        #expect(!NativeToolCapability.providerSupportsNativeTools(nil))
    }

    // MARK: - P0 shape A: request carries tools[], response yields tool_use

    @Test func kimiNative_request_carries_tools_array_and_parses_tool_use_blocks() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            // EXACT P0 shape A: thinking block (with signature) leads, then a
            // tool_use block, stop_reason "tool_use", and ZERO text blocks.
            let body = """
            {"content":[
              {"type":"thinking","thinking":"considering","signature":"sig-abc"},
              {"type":"tool_use","id":"tool_01xyz","name":"git_status","input":{"path":"."}}
            ],"stop_reason":"tool_use"}
            """.data(using: .utf8)!
            return .init(status: 200, body: body)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await makeKimiAdapter(root: root).completeMessagesWithTools(
            messages: [.user("what's the repo state?")],
            system: "sys",
            model: "k3",
            tools: [echoSchema]
        )

        // Response parse.
        #expect(result.stopReason == "tool_use")
        #expect(result.text.isEmpty, "thinking blocks must not leak into text")
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].id == "tool_01xyz")
        #expect(result.toolCalls[0].name == "git_status")
        let input = try #require(
            JSONSerialization.jsonObject(with: result.toolCalls[0].inputJSON) as? [String: Any])
        #expect(input["path"] as? String == ".")

        // Request encoding: Anthropic tools array with input_schema from
        // parametersJSON.
        let body = try parsedBody()
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "git_status")
        #expect(tools[0]["description"] as? String == "Repo state")
        let schema = try #require(tools[0]["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect((schema["properties"] as? [String: Any])?["path"] != nil)
    }

    // MARK: - P0 shape B: tool_result round-trip encoding

    @Test func kimiNative_encodes_native_tool_use_and_tool_result_blocks() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: #"{"content":[{"type":"text","text":"clean tree"}],"stop_reason":"end_turn"}"#.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let conversation: [LLMMessage] = [
            .user("what's the repo state?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "tool_01xyz", name: "git_status",
                         inputJSON: Data(#"{"path":"."}"#.utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "tool_01xyz", content: #"{"clean":true}"#, isError: false),
            ]),
        ]
        let result = try await makeKimiAdapter(root: root).completeMessagesWithTools(
            messages: conversation, system: "sys", model: "k3", tools: [echoSchema]
        )
        #expect(result.text == "clean tree")
        #expect(result.toolCalls.isEmpty)

        let body = try parsedBody()
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)

        // Assistant turn: a NATIVE tool_use block, not flattened prose.
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(assistantBlocks[0]["type"] as? String == "tool_use")
        #expect(assistantBlocks[0]["id"] as? String == "tool_01xyz")
        #expect(assistantBlocks[0]["name"] as? String == "git_status")
        #expect((assistantBlocks[0]["input"] as? [String: Any])?["path"] as? String == ".")

        // User turn: tool_result paired by tool_use_id (P0 note 3).
        let userBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(messages[2]["role"] as? String == "user")
        #expect(userBlocks[0]["type"] as? String == "tool_result")
        #expect(userBlocks[0]["tool_use_id"] as? String == "tool_01xyz")
        #expect(userBlocks[0]["content"] as? String == #"{"clean":true}"#)
        // No is_error key on a successful result.
        #expect(userBlocks[0]["is_error"] == nil)
    }

    @Test func kimiNative_marks_failed_tool_results_with_is_error() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await makeKimiAdapter(root: root).completeMessagesWithTools(
            messages: [
                .user("go"),
                LLMMessage(role: .user, content: [
                    .toolResult(toolUseId: "tool_9", content: "boom", isError: true),
                ]),
            ],
            system: nil, model: "k3", tools: [echoSchema]
        )
        let messages = try #require(try parsedBody()["messages"] as? [[String: Any]])
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks[0]["is_error"] as? Bool == true)
    }

    // MARK: - P0 shape C: parallel tool calls

    @Test func kimiNative_parses_all_parallel_tool_use_blocks_in_wire_order() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            let body = """
            {"content":[
              {"type":"tool_use","id":"tool_a","name":"git_status","input":{"path":"a"}},
              {"type":"tool_use","id":"tool_b","name":"git_log","input":{"path":"b"}}
            ],"stop_reason":"tool_use"}
            """.data(using: .utf8)!
            return .init(status: 200, body: body)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await makeKimiAdapter(root: root).completeMessagesWithTools(
            messages: [.user("both please")], system: nil, model: "k3", tools: [echoSchema]
        )
        #expect(result.toolCalls.map(\.id) == ["tool_a", "tool_b"])
        #expect(result.toolCalls.map(\.name) == ["git_status", "git_log"])
    }

    // MARK: - CONTRACT NOTE 1: textless 200 classification

    @Test func kimiNative_textless200_with_tool_use_is_the_happy_path_not_an_error() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: """
            {"content":[{"type":"tool_use","id":"tool_1","name":"git_status","input":{}}],
             "stop_reason":"tool_use"}
            """.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Must NOT throw: the emptyTextResponseError guard was built for the
        // text-compat lane, where a textless 200 is a dead turn. Here it is a
        // perfectly good tool call.
        let result = try await makeKimiAdapter(root: root).completeMessagesWithTools(
            messages: [.user("go")], system: nil, model: "k3", tools: [echoSchema]
        )
        #expect(result.text.isEmpty)
        #expect(result.toolCalls.count == 1)
    }

    @Test func kimiNative_textless200_without_tool_use_still_throws_transient() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            // The real K3 empty-reply shape: everything went into thinking.
            .init(status: 200, body: """
            {"content":[{"type":"thinking","thinking":"…","signature":"s"}],
             "stop_reason":"end_turn"}
            """.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: LLMError.self) {
            _ = try await makeKimiAdapter(root: root).completeMessagesWithTools(
                messages: [.user("go")], system: nil, model: "k3", tools: [echoSchema]
            )
        }
        // And it is the TRANSIENT class specifically — the surface retry ladders
        // match on that grammar.
        do {
            _ = try await makeKimiAdapter(root: root).completeMessagesWithTools(
                messages: [.user("go")], system: nil, model: "k3", tools: [echoSchema]
            )
            Issue.record("expected a throw")
        } catch let error as LLMError {
            guard case .transient(let message) = error else {
                Issue.record("expected .transient, got \(error)")
                return
            }
            #expect(message.contains("no answer text"))
        }
    }

    @Test func kimiNative_maxTokens_truncation_stays_providerError_not_transient() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: """
            {"content":[{"type":"thinking","thinking":"…"}],"stop_reason":"max_tokens"}
            """.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await makeKimiAdapter(root: root).completeMessagesWithTools(
                messages: [.user("go")], system: nil, model: "k3", tools: [echoSchema]
            )
            Issue.record("expected a throw")
        } catch let error as LLMError {
            guard case .providerError = error else {
                Issue.record("expected .providerError for max_tokens, got \(error)")
                return
            }
        }
    }

    // MARK: - streamMessages bridges native calls as .toolCall events

    @Test func kimiNative_streamMessages_emits_text_then_toolCall_events() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: """
            {"content":[
              {"type":"text","text":"checking"},
              {"type":"tool_use","id":"tool_s","name":"git_status","input":{"path":"."}}
            ],"stop_reason":"tool_use"}
            """.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var texts: [String] = []
        var calls: [LLMStreamToolCall] = []
        for try await event in makeKimiAdapter(root: root).streamMessages(
            messages: [.user("go")], system: nil, model: "k3", tools: [echoSchema]
        ) {
            switch event {
            case .textDelta(let s): texts.append(s)
            case .toolCall(let c): calls.append(c)
            case .keepAlive: break
            }
        }
        #expect(texts == ["checking"])
        #expect(calls.map(\.id) == ["tool_s"])
    }

    // MARK: - REGRESSION: non-kimi providers keep the exact pre-change wire shape

    @Test func anthropicApiKeyAdapter_never_ships_a_tools_array_even_when_tools_are_passed() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: #"{"content":[{"type":"text","text":"hi"}]}"#.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Plain Anthropic api-key adapter (providerId "anthropic"): NOT native-
        // tool capable. Handing it tools must change nothing on the wire.
        let adapter = AnthropicAdapter(
            session: nativeToolsStubSession(),
            apiKeyOverride: "sk-test",
            dataRootOverride: root,
            telemetryDataRootOverride: root
        )
        let reply = try await adapter.completeMessages(
            messages: [
                .user("hello"),
                LLMMessage(role: .assistant, content: [
                    .toolUse(id: "t1", name: "git_status", inputJSON: Data("{}".utf8)),
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(toolUseId: "t1", content: "clean", isError: false),
                ]),
            ],
            system: "sys",
            model: "claude-opus-4-8",
            tools: [echoSchema]
        )
        #expect(reply == "hi")

        let body = try parsedBody()
        #expect(body["tools"] == nil, "the Claude api-key path must never ship tools[]")
        // And the conversation still flattens to the legacy single-prompt shape
        // (no structured messages array beyond the one flattened user message).
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        let flattened = try #require(messages[0]["content"] as? String)
        #expect(flattened.contains("[tool_use git_status"))
        #expect(flattened.contains("[tool_result] clean"))
    }

    @Test func kimiCode_without_tools_keeps_the_legacy_flattened_shape() async throws {
        NativeToolsStubURLProtocol.reset()
        NativeToolsStubURLProtocol.responder = { _ in
            .init(status: 200, body: #"{"content":[{"type":"text","text":"hi"}]}"#.data(using: .utf8)!)
        }
        let root = try nativeToolsTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // kimi-code IS native-capable, but with no tools supplied the request must
        // stay byte-identical to the pre-change path — the capability gate is
        // provider AND tools, never provider alone.
        _ = try await makeKimiAdapter(root: root).completeMessages(
            messages: [.user("hello")], system: "sys", model: "k3", tools: nil
        )
        let body = try parsedBody()
        #expect(body["tools"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "USER: hello")
    }
}

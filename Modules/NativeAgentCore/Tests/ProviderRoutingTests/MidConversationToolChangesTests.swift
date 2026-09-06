import Foundation
import Testing
import NativeAgentCore
@testable import ProviderRouting

// Mid-conversation tool changes, WIRE layer (2026-09-02).
//
// `tools` sits FIRST in Anthropic's hashed prefix, so a session load that
// edits the array invalidates the cache for the whole conversation. The
// Anthropic STRUCTURED api-key lanes now declare the session's full pinned
// catalog once — every non-floor tool marked `defer_loading: true` — and move
// the per-turn OFFERED set into `tool_addition` / `tool_removal` blocks on a
// `role: "system"` message behind the cache breakpoint.
//
// These tests drive the pure builders plus one stubbed transport for the
// per-request beta header. The orchestration half (which tools go in the
// array, which get added, byte-stability across turns) lives in
// ChatOrchestrationTests/MidConversationToolChangePlanTests.swift.

private func schema(
    _ name: String,
    deferLoading: Bool = false
) -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: "\(name) description",
        parametersJSON: try! JSONSerialization.data(withJSONObject: [
            "type": "object",
            "properties": [String: Any](),
            "additionalProperties": false,
        ] as [String: Any]),
        deferLoading: deferLoading
    )
}

@Suite struct MidConversationToolChangeWireShapeTests {

    // MARK: - defer_loading on the tools array

    @Test func deferLoadingRidesOnlyTheSchemasThatAskForIt() {
        let out = AnthropicAdapter.nativeToolsArray(
            [schema("tool_catalog"), schema("git_status", deferLoading: true)],
            strict: true,
            cacheBreakpoint: true
        )
        #expect(out.count == 2)
        // Floor tool: offered from the start of the conversation.
        #expect(out[0]["defer_loading"] == nil)
        // Deferred tool: declared (so it rides the cached prefix and can be
        // referenced by name) but withheld until a tool_addition offers it.
        #expect(out[1]["defer_loading"] as? Bool == true)
    }

    /// V1 BYTE IDENTITY: a schema that does not defer must produce the exact
    /// pre-2026-09-02 tool object — no new key anywhere.
    @Test func noDeferLoadingSchema_emitsNoNewKey() {
        let out = AnthropicAdapter.nativeToolsArray(
            [schema("tool_catalog"), schema("recall_memory")],
            strict: true,
            cacheBreakpoint: true
        )
        #expect(out.allSatisfy { $0["defer_loading"] == nil })
        #expect(Set(out[0].keys) == ["name", "description", "input_schema", "strict"])
    }

    /// The LAST tool keeps the single tools-block breakpoint even when the
    /// array is now the whole catalog.
    @Test func lastToolKeepsTheCacheBreakpoint() {
        let out = AnthropicAdapter.nativeToolsArray(
            [schema("a"), schema("b", deferLoading: true), schema("c", deferLoading: true)],
            strict: true,
            cacheBreakpoint: true
        )
        #expect(out.filter { $0["cache_control"] != nil }.count == 1)
        #expect(out.last?["cache_control"] as? [String: String] == ["type": "ephemeral"])
    }

    /// BREAKPOINT BUDGET: Anthropic allows 4 per request. This lane spends at
    /// most one on the tools array and one in the system blocks.
    @Test func requestSpendsAtMostFourBreakpoints() {
        let tools = AnthropicAdapter.nativeToolsArray(
            [schema("a"), schema("b", deferLoading: true)],
            strict: true,
            cacheBreakpoint: true
        )
        // 2026-09-06: the system blocks spend their breakpoint only when the
        // call is cache-eligible (6715b917's cache-write premium gate —
        // `cacheEligible: LLMCallContext.sessionId != nil`), because paying a
        // cache write on an unbound one-shot call buys nothing. A real chat
        // turn has a session bound, which is the lane this budget is about.
        let system = LLMCallContext.$sessionId.withValue("budget-test-session") {
            AnthropicAdapter.makeSystemBlocks("sys") ?? []
        }
        let total = tools.filter { $0["cache_control"] != nil }.count
            + system.filter { $0["cache_control"] != nil }.count
        #expect(total <= 4)
        #expect(total == 2)
    }

    // MARK: - tool_addition / tool_removal blocks

    @Test func toolChangeBlocksUseTheToolReferenceShape() {
        let message = LLMMessage.toolChanges([
            .addition("git_status"),
            .removal("tool_catalog"),
        ])
        let out = AnthropicAdapter.nativeAnthropicMessages([.user("go"), message])
        #expect(out.count == 2)
        #expect(out[1]["role"] as? String == "system")
        // A tool-change message is NOT turn-scoped: clear_at + a tool block is
        // a 400.
        #expect(out[1]["clear_at"] == nil)
        let blocks = out[1]["content"] as! [[String: Any]]
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "tool_addition")
        #expect(blocks[0]["tool"] as? [String: String]
            == ["type": "tool_reference", "name": "git_status"])
        #expect(blocks[1]["type"] as? String == "tool_removal")
        #expect(blocks[1]["tool"] as? [String: String]
            == ["type": "tool_reference", "name": "tool_catalog"])
    }

    /// The API rejects a tool-change block on a `clear_at` message, so the
    /// model type refuses the pairing outright — a turn-scoped message stays
    /// TEXT-ONLY no matter what a caller passes.
    @Test func turnScopedMessageStaysTextOnly() {
        let message = LLMMessage(
            role: .system,
            content: [.text("volatile")],
            turnScopedClearAtNextUserMessage: true,
            toolChanges: [.addition("git_status")]
        )
        #expect(message.toolChanges.isEmpty)
        let out = AnthropicAdapter.nativeAnthropicMessages([.user("go"), message])
        let blocks = out[1]["content"] as! [[String: Any]]
        #expect(blocks.allSatisfy { ($0["type"] as? String) == "text" })
        #expect(out[1]["clear_at"] as? String == "next_user_message")
    }

    /// PLACEMENT: tool changes go after the current user message and BEFORE
    /// the turn-scoped volatile block, which must end the array to render.
    @Test func toolChangeMessagePrecedesTheTurnScopedBlock() {
        let out = AnthropicAdapter.nativeAnthropicMessages([
            .user("go"),
            .toolChanges([.addition("git_status")]),
            LLMMessage.system("volatile", clearAtNextUserMessage: true),
        ])
        #expect(out.count == 3)
        #expect(out[0]["role"] as? String == "user")
        #expect(out[1]["clear_at"] == nil)
        #expect(((out[1]["content"] as! [[String: Any]])[0]["type"] as? String) == "tool_addition")
        #expect(out[2]["clear_at"] as? String == "next_user_message")
        #expect(((out[2]["content"] as! [[String: Any]])[0]["type"] as? String) == "text")
    }

    /// A `.system` message with neither text nor tool changes would serialize
    /// as an empty `content` array, which the Messages API rejects.
    @Test func emptyToolChangeMessageIsDropped() {
        let out = AnthropicAdapter.nativeAnthropicMessages([
            .user("go"),
            LLMMessage(role: .system, content: [], toolChanges: []),
        ])
        #expect(out.count == 1)
    }

    // MARK: - Beta assembly

    @Test func toolChangeBetaRidesOnlyWhenAMessageCarriesABlock() {
        let plain: [LLMMessage] = [.user("a"), LLMMessage.system("v")]
        let changed: [LLMMessage] = [.user("a"), .toolChanges([.addition("git_status")])]
        #expect(AnthropicOAuthDirectAdapter.toolChangeBeta(for: plain) == nil)
        #expect(AnthropicOAuthDirectAdapter.toolChangeBeta(for: changed)
            == "mid-conversation-tool-changes-2026-07-01")
    }

    @Test func midConversationBetasJoinBothFeaturesAndStayAbsentOtherwise() {
        #expect(AnthropicOAuthDirectAdapter.midConversationBetas(for: [.user("a")]) == nil)
        let both: [LLMMessage] = [
            .user("a"),
            .toolChanges([.addition("git_status")]),
            LLMMessage.system("v", clearAtNextUserMessage: true),
        ]
        let value = AnthropicOAuthDirectAdapter.midConversationBetas(for: both) ?? ""
        let parts = value.split(separator: ",").map(String.init)
        #expect(parts.contains(AnthropicOAuthDirectAdapter.midConversationSystemClearAtBeta))
        #expect(parts.contains(AnthropicOAuthDirectAdapter.midConversationToolChangesBeta))
        #expect(parts.count == 2)
    }

    // MARK: - Catalog capability

    /// Verified against the doc file: the tool-change beta is available on
    /// exactly the models that take mid-conversation system messages, and NOT
    /// on Sonnet 5. Unknown id → false → fall back to a changing array.
    @Test func capabilityRowsMatchTheDocumentedModelList() {
        for id in ["claude-opus-4-8", "claude-opus-5", "claude-fable-5", "claude-fable-5-1"] {
            #expect(supportsMidConversationToolChanges(forModel: id))
        }
        #expect(!supportsMidConversationToolChanges(forModel: "claude-sonnet-5"))
        #expect(!supportsMidConversationToolChanges(forModel: "claude-opus-4-7"))
        #expect(!supportsMidConversationToolChanges(forModel: "gpt-5.6"))
        #expect(!supportsMidConversationToolChanges(forModel: "kimi-for-coding"))
        #expect(!supportsMidConversationToolChanges(forModel: "not-a-model"))
    }

    /// The refinement rule: a row can never claim the tool-change beta without
    /// the mid-conversation system capability it rides on.
    @Test func capabilityCannotBeClaimedWithoutTheBaseCapability() {
        let row = FirstPartyModelDescriptor(
            id: "x", name: "X", contextLength: 1,
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["high"],
            supportsMidConversationSystem: false,
            supportsMidConversationToolChanges: true
        )
        #expect(!row.supportsMidConversationToolChanges)
    }

    // MARK: - OpenAI is untouched

    /// The OpenAI Responses lane has no equivalent feature: it keeps a
    /// churn-on-load tools array with drops batched at turn start. It must
    /// never emit `defer_loading`, and a tool-change message (which carries no
    /// content blocks) contributes no input item at all.
    @Test func openAIResponsesBodyCarriesNoToolChangeArtifacts() throws {
        let adapter = OpenAIOAuthDirectAdapter()
        let body = adapter.buildResponsesBodyFromMessages(
            model: "gpt-5.6",
            messages: [.user("go"), .toolChanges([.addition("git_status")])],
            system: "sys",
            tools: [schema("git_status", deferLoading: true)]
        )
        let input = body["input"] as! [[String: Any]]
        #expect(input.count == 1)
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            as: UTF8.self
        )
        #expect(!json.contains("defer_loading"))
        #expect(!json.contains("tool_addition"))
        #expect(!json.contains("tool_removal"))
    }
}

// MARK: - Per-request beta header on the native tools transport

private final class ToolChangeHeaderStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastHeaders: [String: String]?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var responseBody = Data()
    static func reset() { lastHeaders = nil; lastBody = nil; responseBody = Data() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        ToolChangeHeaderStubURLProtocol.lastHeaders = request.allHTTPHeaderFields
        ToolChangeHeaderStubURLProtocol.lastBody = request.httpBody
            ?? request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(contentsOf: buffer[0..<read])
                }
                return data
            }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ToolChangeHeaderStubURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct MidConversationToolChangeBetaHeaderTests {
    private static let okBody =
        Data(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#.utf8)

    private func adapter() throws -> AnthropicAdapter {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-change-beta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ToolChangeHeaderStubURLProtocol.self]
        return AnthropicAdapter(
            session: URLSession(configuration: cfg),
            apiKeyOverride: "sk-ant-test",
            dataRootOverride: root,
            telemetryDataRootOverride: root
        )
    }

    /// BETA IFF BLOCKS. The body carries the blocks and the header carries the
    /// beta on exactly the same requests — a body with blocks and no header is
    /// a 400, and a header on every request opts ordinary turns into a beta
    /// they do not use.
    @Test func nativeToolsLane_betaPresentIffToolChangeBlocks() async throws {
        let adapter = try adapter()
        func send(_ trailing: LLMMessage) async throws -> [String: String] {
            ToolChangeHeaderStubURLProtocol.reset()
            ToolChangeHeaderStubURLProtocol.responseBody = Self.okBody
            _ = try await adapter.completeMessagesWithTools(
                messages: [.user("status?"), trailing],
                system: "sys",
                model: "claude-opus-5",
                tools: [schema("tool_catalog"), schema("git_status", deferLoading: true)]
            )
            return ToolChangeHeaderStubURLProtocol.lastHeaders ?? [:]
        }
        let without = try await send(LLMMessage.system("v"))
        #expect(without["anthropic-beta"] == nil)

        let with = try await send(.toolChanges([.addition("git_status")]))
        #expect(with["anthropic-beta"]
            == AnthropicOAuthDirectAdapter.midConversationToolChangesBeta)
        let body = try #require(ToolChangeHeaderStubURLProtocol.lastBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("tool_addition"))
        #expect(json.contains("defer_loading"))
    }
}

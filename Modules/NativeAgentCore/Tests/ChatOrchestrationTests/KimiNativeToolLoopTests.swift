import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
@testable import ProviderRouting
import TrustCenter

// MARK: - Native tool lane: the chat tool loop end-to-end
//
// docs/build_plans/kimi-native-tools.md P2/P3. Pins that when the provider is
// kimi-code the loop declares tools NATIVELY, consumes structured tool_use
// blocks (no ToolCallParser on this lane), dispatches through the SAME gated
// path, and replays results as native tool_result blocks — while every other
// provider's request shape is unchanged.

private func makeNativeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kimi-native-loop-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The transport gate for the NON-native regression case: the Anthropic OAuth
/// fixture is what makes the append-only messages shape eligible for a Claude
/// model, so the regression asserts against the messages transport rather than
/// silently falling back to the prompt one.
private func writeNativeOAuthFixture(_ root: URL) throws {
    let dir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["access_token": "tok-native"])
        .write(to: dir.appendingPathComponent("anthropic_oauth_direct.json"))
}

private final class StubRoutingNative: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "k3", reasoningEffort: "high")]
    }
}

private final class UnusedNativeLLM: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "structured-path-should-not-run"
    }
}

/// Scripted messages client that can emit STRUCTURED tool calls, which is what
/// the native lane consumes. One script per provider call.
private final class NativeScriptedLLM: StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    struct MessagesCall {
        let messages: [LLMMessage]
        let system: String?
        let tools: [LLMToolSchema]?
    }

    private let scripts: [[LLMMessageStreamEvent]]
    /// Call index → provider error text. Models an ADAPTER-level failure (the
    /// scripted client cannot produce the adapter's own textless-200
    /// classification, so the test injects the resulting error directly).
    private let errorAtCall: [Int: String]
    private let lock = NSLock()
    private var _messagesCalls: [MessagesCall] = []
    private var _promptCallCount = 0
    private var _serveIndex = 0

    init(scripts: [[LLMMessageStreamEvent]], errorAtCall: [Int: String] = [:]) {
        self.scripts = scripts
        self.errorAtCall = errorAtCall
    }

    var messagesCalls: [MessagesCall] {
        lock.lock(); defer { lock.unlock() }
        return _messagesCalls
    }
    var promptCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _promptCallCount
    }

    private func nextScript() -> [LLMMessageStreamEvent] {
        guard !scripts.isEmpty else { return [] }
        let s = scripts[min(_serveIndex, scripts.count - 1)]
        _serveIndex += 1
        return s
    }

    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        _promptCallCount += 1
        let events = nextScript()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                for e in events {
                    if case .textDelta(let s) = e { continuation.yield(s) }
                }
                continuation.finish()
            }
        }
    }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        lock.lock()
        let callIndex = _messagesCalls.count
        _messagesCalls.append(MessagesCall(messages: messages, system: system, tools: tools))
        let events = nextScript()
        let failure = errorAtCall[callIndex]
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                for e in events { continuation.yield(e) }
                if let failure {
                    continuation.finish(throwing: LLMError.transient(message: failure))
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

/// Tool client that ALSO advertises schemas. NOTE the tool NAMES used by this
/// file's scenarios are drawn from SwiftToolDispatcher.alwaysOnCoreNames on
/// purpose: ctx.toolSchemas is lazy-filtered per iteration to
/// `alwaysOnCore ∪ sessionActive`, so a non-always-on name would be filtered
/// out of the native tools array and the test would be asserting against an
/// empty declaration rather than a real one.
/// MockToolDispatchClient returns
/// `[]` from `listAvailableToolSchemas()`, and on this lane an empty schema
/// list means an empty native tools array — the model would be told it has no
/// tools. It also starves the announce detector, which is gated on a non-empty
/// available-tool set. So the native-lane harness needs a client that answers
/// both questions.
private final class SchemaToolDispatchClient: ToolDispatchClient, @unchecked Sendable {
    struct Dispatch: Sendable, Equatable {
        let tool: String
        let input: [String: JSONValue]
    }
    private let scripted: [String: JSONValue]
    private let lock = NSLock()
    private var _dispatches: [Dispatch] = []

    init(scripted: [String: JSONValue]) { self.scripted = scripted }

    var dispatches: [Dispatch] {
        lock.lock(); defer { lock.unlock() }
        return _dispatches
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        record(Dispatch(tool: tool, input: input))
        return scripted[tool] ?? .null
    }

    private func record(_ d: Dispatch) {
        lock.lock(); defer { lock.unlock() }
        _dispatches.append(d)
    }

    func listAvailableTools() async throws -> [String] { scripted.keys.sorted() }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        scripted.keys.sorted().map { name in
            LLMToolSchema(
                name: name,
                description: "test tool \(name)",
                parametersJSON: (try? JSONSerialization.data(withJSONObject: [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                ])) ?? Data("{}".utf8)
            )
        }
    }
}

private struct NativeLoopRun {
    let deltas: [String]
    let finalReply: String?
    let toolUses: [String]
    let toolResults: [String]
    let errors: [String]
    let llm: NativeScriptedLLM
    let tools: SchemaToolDispatchClient
}

private func runNativeLoop(
    tag: String,
    scripts: [[LLMMessageStreamEvent]],
    errorAtCall: [Int: String] = [:],
    model: String = "k3",
    scriptedTools: [String: JSONValue] = ["recall_memory": .string("clean tree")],
    writeOAuth: Bool = false,
    message: String = "what's the repo state?",
    preloadActiveTools: Set<String> = []
) async throws -> NativeLoopRun {
    let root = try makeNativeTempRoot(tag)
    if writeOAuth { try writeNativeOAuthFixture(root) }
    // Hermetic active-tools store: the engine's default falls back to the
    // process-global .shared (real data root) when the tool client doesn't
    // provide one — inject a temp-root instance so preloads are visible to
    // the lazy filter and nothing leaks into live state.
    let activeStore = ActiveToolsStore(dataRoot: root)
    if !preloadActiveTools.isEmpty {
        _ = try await activeStore
            .addLoaded(sessionId: "s-\(tag)", names: preloadActiveTools)
    }
    let llm = NativeScriptedLLM(scripts: scripts, errorAtCall: errorAtCall)
    let toolClient = SchemaToolDispatchClient(scripted: scriptedTools)
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: StubRoutingNative(),
        trust: hermeticTrust(),
        llm: UnusedNativeLLM(),
        tools: toolClient,
        activeToolsStore: activeStore
    )
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: toolClient,
        llm: UnusedNativeLLM(),
        streamingLLM: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    var deltas: [String] = []
    var finalReply: String?
    var toolUses: [String] = []
    var toolResults: [String] = []
    var errors: [String] = []
    for try await event in client.chatStream(
        message: message, sessionId: "s-\(tag)",
        model: model, reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], persona: nil,
        surface: "chat", suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .final(let r): finalReply = r.reply
        case .toolUse(let name, _): toolUses.append(name)
        case .toolResult(let name, _): toolResults.append(name)
        case .error(let m): errors.append(m)
        case .notice: break
        }
    }
    return NativeLoopRun(
        deltas: deltas, finalReply: finalReply, toolUses: toolUses,
        toolResults: toolResults, errors: errors, llm: llm, tools: toolClient
    )
}

private func toolCall(_ id: String, _ name: String, _ json: String) -> LLMMessageStreamEvent {
    .toolCall(LLMStreamToolCall(id: id, name: name, inputJSON: Data(json.utf8)))
}

// MARK: - Happy path: tool_use → dispatch → tool_result → final text

@Test func nativeLane_dispatches_toolUse_then_replays_toolResult_then_answers() async throws {
    let run = try await runNativeLoop(
        tag: "happy",
        scripts: [
            // Iteration 1: a TEXTLESS tool_use response — the P0 happy path.
            [toolCall("tool_01", "recall_memory", #"{"path":"."}"#)],
            // Iteration 2: the final answer.
            [.textDelta("The tree is clean.")],
        ]
    )

    #expect(run.errors.isEmpty, "native lane produced errors: \(run.errors)")
    #expect(run.finalReply == "The tree is clean.")
    // Dispatch went through the SAME path as the text lane.
    #expect(run.toolUses == ["recall_memory"])
    #expect(run.toolResults == ["recall_memory"])
    #expect(run.tools.dispatches.map(\.tool) == ["recall_memory"])
    #expect(run.tools.dispatches.first?.input["path"] == .string("."))

    // Two provider calls, both on the MESSAGES transport (the native lane
    // cannot ride the prompt transport — tool blocks have no string form).
    #expect(run.llm.messagesCalls.count == 2)
    #expect(run.llm.promptCallCount == 0)

    // Call 1 declared tools NATIVELY.
    let first = try #require(run.llm.messagesCalls.first)
    let firstTools = try #require(first.tools, "native lane must send a tools array")
    #expect(firstTools.contains { $0.name == "recall_memory" })
    // …and the system prompt dropped the marker-syntax protocol while KEEPING
    // the completion contract.
    #expect(first.system?.contains("<tool_use name=") != true)
    #expect(first.system?.contains("native tool use") == true)
    #expect(first.system?.contains("COMPLETION CONTRACT") == true)

    // Call 2's conversation carries NATIVE blocks, not prose.
    let second = try #require(run.llm.messagesCalls.last)
    // Tools are re-sent every request (P0 shape B).
    #expect(second.tools?.isEmpty == false)
    #expect(second.messages.count == 3)
    guard case .toolUse(let id, let name, _) = second.messages[1].content.first else {
        Issue.record("expected an assistant tool_use block, got \(second.messages[1].content)")
        return
    }
    #expect(id == "tool_01")
    #expect(name == "recall_memory")
    #expect(second.messages[1].role == .assistant)
    guard case .toolResult(let pairedId, let content, let isError) =
            second.messages[2].content.first else {
        Issue.record("expected a user tool_result block, got \(second.messages[2].content)")
        return
    }
    #expect(pairedId == "tool_01", "tool_result must pair by tool_use_id")
    #expect(isError == false)
    #expect(content.contains("clean tree"))
    #expect(second.messages[2].role == .user)
}

// MARK: - P0 shape C: parallel blocks all dispatch, in order

@Test func nativeLane_dispatches_every_parallel_toolUse_block_in_order() async throws {
    let run = try await runNativeLoop(
        tag: "parallel",
        scripts: [
            [
                toolCall("tool_a", "recall_memory", #"{"path":"a"}"#),
                toolCall("tool_b", "time_now", #"{"path":"b"}"#),
            ],
            [.textDelta("both done")],
        ],
        scriptedTools: ["recall_memory": .string("clean"), "time_now": .string("3 commits")]
    )

    #expect(run.errors.isEmpty)
    #expect(run.finalReply == "both done")
    // Assert on the LOOP's own dispatch record, not on the leaf tool client:
    // some always-on tools (time_now) are serviced by the gated dispatcher
    // itself and never reach an injected downstream client, so the client's
    // dispatch list is not a complete picture of what the loop ran.
    #expect(run.toolUses == ["recall_memory", "time_now"])
    #expect(run.toolResults == ["recall_memory", "time_now"])

    // BOTH tool_use blocks ride ONE assistant message, and BOTH tool_results
    // ride ONE user message — the Anthropic pairing contract.
    let second = try #require(run.llm.messagesCalls.last)
    #expect(second.messages[1].content.count == 2)
    #expect(second.messages[2].content.count == 2)
    let resultIds: [String] = second.messages[2].content.compactMap {
        if case .toolResult(let id, _, _) = $0 { return id }
        return nil
    }
    #expect(resultIds == ["tool_a", "tool_b"])
}

// MARK: - Preserved: the announce-without-act detector on FINAL prose

@Test func nativeLane_finalProse_that_only_announces_still_bounces() async throws {
    let run = try await runNativeLoop(
        tag: "announce",
        scripts: [
            // No tool call, just narration — invalid under the completion
            // contract whether or not the lane is native.
            [.textDelta("I'm reading the README now and will report back.")],
            [.textDelta("The README documents the build pipeline.")],
        ]
    )

    #expect(run.errors.isEmpty)
    // The bounce cost one extra provider call and the narration never became
    // the answer.
    #expect(run.llm.messagesCalls.count == 2)
    #expect(run.finalReply == "The README documents the build pipeline.")

    // The nudge told the model to make a TOOL CALL — not to emit marker text
    // this lane no longer parses.
    let nudge = try #require(run.llm.messagesCalls.last?.messages.last)
    guard case .text(let feedback) = try #require(nudge.content.last) else {
        Issue.record("expected a text nudge")
        return
    }
    #expect(feedback.contains("completion contract"))
    #expect(feedback.contains("make the next tool call"))
    #expect(!feedback.contains("<tool_use name="))
}

// MARK: - Preserved: empty-reply recovery

@Test func nativeLane_replyWithNeitherTextNorToolCalls_recovers_in_loop() async throws {
    let run = try await runNativeLoop(
        tag: "empty",
        scripts: [
            [],
            [.textDelta("recovered answer")],
        ],
        // A response with NEITHER text NOR tool_use is still the empty-reply
        // class — the adapter classifies it and throws in its own grammar,
        // which the loop recognizes and recovers from IN-loop.
        errorAtCall: [0: "kimi-code: HTTP 200 with no answer text (stop_reason=end_turn; content: thinking×1)"]
    )
    // The turn survived and produced a real answer rather than dying.
    #expect(run.finalReply == "recovered answer")
    #expect(run.llm.messagesCalls.count >= 2)
}

// MARK: - REGRESSION: a non-kimi provider is untouched by all of this

@Test func nonKimiProvider_through_the_same_loop_sends_no_tools_array() async throws {
    let run = try await runNativeLoop(
        tag: "regression",
        scripts: [
            // The text lane's marker protocol, unchanged.
            [.textDelta("<tool_use name=\"recall_memory\">{\"path\":\".\"}</tool_use>")],
            [.textDelta("clean")],
        ],
        model: "claude-opus-4-8",
        writeOAuth: true
    )

    #expect(run.errors.isEmpty)
    #expect(run.finalReply == "clean")
    // Tool STILL dispatched — via the text-compat marker protocol.
    #expect(run.tools.dispatches.map(\.tool) == ["recall_memory"])

    // The load-bearing regression: NO request on this lane carries tools[].
    #expect(run.llm.messagesCalls.count == 2)
    for (i, call) in run.llm.messagesCalls.enumerated() {
        #expect(call.tools == nil, "call \(i) leaked a tools array to a non-native provider")
    }
    // And the system prompt still carries the marker-syntax protocol.
    let first = try #require(run.llm.messagesCalls.first)
    #expect(first.system?.contains("NativeAgent Swift tool protocol (text compatibility)") == true)
    #expect(first.system?.contains("<tool_use name=\"tool_name\">") == true)

    // Text-lane conversation stays PROSE — no native blocks appear.
    let second = try #require(run.llm.messagesCalls.last)
    for message in second.messages {
        for block in message.content {
            switch block {
            case .toolUse, .toolResult:
                Issue.record("text lane must not emit native tool blocks")
            case .text, .image:
                break
            }
        }
    }
}

// MARK: - Wire-safe tool names (live 400, 2026-07-20 16:19Z)

@Test func nativeLane_dottedToolNames_ride_the_wire_sanitized_and_dispatch_internally() async throws {
    // Kimi validates tool names ("must start with a letter; letters, numbers,
    // underscores, dashes") and the catalog carries dotted names. The live
    // S3 marathon 400'd on exactly this. Pins the full round trip:
    // tools array sanitized → model calls the alias → dispatch reaches the
    // INTERNAL dotted tool → the replayed tool_use block is sanitized too.
    // The dotted tool is not in the always-loaded baseline, so pre-seed the
    // session's active-tools store — the same state a live tool_load leaves
    // behind — before the turn runs.
    let run = try await runNativeLoop(
        tag: "dotted-names",
        scripts: [
            [toolCall("tool_01", "mac_notify", #"{"title":"hi"}"#)],
            [.textDelta("Sent.")],
        ],
        scriptedTools: [
            "recall_memory": .string("clean tree"),
            "mac.notify": .object(["status": .string("ok")]),
        ],
        preloadActiveTools: ["mac.notify"]
    )

    #expect(run.errors.isEmpty, "native lane produced errors: \(run.errors)")
    #expect(run.finalReply == "Sent.")
    // Dispatch used the INTERNAL name — gating and records never see aliases.
    #expect(run.tools.dispatches.map(\.tool) == ["mac.notify"])

    let calls = run.llm.messagesCalls
    #expect(calls.count == 2)
    // Iteration 1: the tools array carries the provider-safe alias, and no
    // name anywhere in it violates Kimi's charset.
    let wireToolNames = (calls[0].tools ?? []).map(\.name)
    #expect(wireToolNames.contains("mac_notify"))
    #expect(!wireToolNames.contains("mac.notify"))
    for name in wireToolNames {
        #expect(name.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil,
                "wire tool name '\(name)' violates the provider charset")
    }
    // Iteration 2: the REPLAYED assistant tool_use block is sanitized too —
    // Kimi validates block names exactly like the tools array.
    var replayedNames: [String] = []
    for message in calls[1].messages {
        for block in message.content {
            if case .toolUse(_, let name, _) = block { replayedNames.append(name) }
        }
    }
    #expect(replayedNames == ["mac_notify"])
}

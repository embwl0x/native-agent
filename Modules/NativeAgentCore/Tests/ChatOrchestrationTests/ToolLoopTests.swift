import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - Test helpers

private func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolloop-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Scripted-routing stub: returns a fixed surface→preference map.
private final class StubRouting: ProviderRoutingProtocol, @unchecked Sendable {
    let prefs: [String: SurfacePreference]
    init(prefs: [String: SurfacePreference]) { self.prefs = prefs }
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] { prefs }
}

private func makeEngine(
    persona: any PersonaEngineProtocol,
    llm: any LLMClient,
    tools: any ToolDispatchClient
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: persona,
        memory: nil,
        router: StubRouting(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "test-model", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

/// Failing dispatcher used in error-recovery test.
private final class FailingToolDispatch: ToolDispatchClient, @unchecked Sendable {
    struct Boom: Error {}
    private let lock = NSLock()
    private var _dispatches: [String] = []
    var dispatches: [String] {
        lock.lock(); defer { lock.unlock() }
        return _dispatches
    }
    private func record(_ tool: String) {
        lock.lock(); defer { lock.unlock() }
        _dispatches.append(tool)
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        record(tool)
        throw Boom()
    }
    func listAvailableTools() async throws -> [String] { ["broken"] }
}

private final class SchemaToolDispatch: ToolDispatchClient, @unchecked Sendable {
    private let schemas: [LLMToolSchema]
    private let scripted: [String: JSONValue]
    private let lock = NSLock()
    private var _dispatches: [String] = []

    var dispatches: [String] {
        lock.lock(); defer { lock.unlock() }
        return _dispatches
    }

    init(schemas: [LLMToolSchema], scripted: [String: JSONValue]) {
        self.schemas = schemas
        self.scripted = scripted
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        record(tool)
        return scripted[tool] ?? .null
    }

    private func record(_ tool: String) {
        lock.lock()
        defer { lock.unlock() }
        _dispatches.append(tool)
    }

    func listAvailableTools() async throws -> [String] {
        schemas.map(\.name).sorted()
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        schemas
    }
}

private final class CapturingMessagesLLM: LLMClient, @unchecked Sendable {
    private let scriptedResponses: [String]
    private let lock = NSLock()
    private var _callCount = 0
    private var _toolNamesByCall: [[String]] = []

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    var toolNamesByCall: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _toolNamesByCall
    }

    init(scriptedResponses: [String]) {
        self.scriptedResponses = scriptedResponses
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        nextResponse(tools: nil)
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        nextResponse(tools: tools)
    }

    private func nextResponse(tools: [LLMToolSchema]?) -> String {
        lock.lock()
        let idx = _callCount
        _callCount += 1
        _toolNamesByCall.append((tools ?? []).map(\.name))
        lock.unlock()
        guard !scriptedResponses.isEmpty else { return "" }
        return scriptedResponses[idx % scriptedResponses.count]
    }
}

private actor ToolLoopEventCapture {
    private var events: [TurnStreamEvent] = []

    func append(_ event: TurnStreamEvent) {
        events.append(event)
    }

    func snapshot() -> [TurnStreamEvent] {
        events
    }
}

// MARK: - Tests

@Test
func ToolLoopBudget_restores_old_surface_defaults_and_clamps_overrides() async throws {
    #expect(ToolLoopBudget.defaultIterations(for: "chat") == 60)
    #expect(ToolLoopBudget.defaultIterations(for: "mac") == 60)
    #expect(ToolLoopBudget.defaultIterations(for: "telegram") == 180)
    #expect(ToolLoopBudget.defaultIterations(for: "ios") == 90)
    #expect(ToolLoopBudget.defaultIterations(for: "swarm") == 80)
    #expect(ToolLoopBudget.resolve(surface: "chat", requested: 0) == 1)
    #expect(ToolLoopBudget.resolve(surface: "telegram", requested: 999) == ToolLoopBudget.hardCap)
}

@Test
func executeTurnWithToolLoop_no_tools_returns_immediately() async throws {
    let dir = try makeTempDir("no-tools")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["just plain text, no tool calls here"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "hi", llm: llm, tools: tools
    )
    #expect(llm.callCount == 1)
    #expect(result.toolDispatches.isEmpty)
    #expect(result.reply.contains("plain text"))
}

@Test
func executeTurnWithToolLoop_default_chat_budget_allows_more_than_six_rounds() async throws {
    let dir = try makeTempDir("more-than-six")
    let persona = hermeticPersona(root: dir)
    let calls = (0..<7).map { idx in
        #"{"tool_calls":[{"id":"c\#(idx)","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    }
    let llm = MockLLMClient(scriptedResponses: calls + ["done after seven"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        surface: "chat",
        userMessage: "keep working",
        llm: llm,
        tools: tools
    )
    #expect(llm.callCount == 8)
    #expect(result.toolDispatches.count == 7)
    #expect(result.reply == "done after seven")
}

@Test
func executeTurnWithToolLoop_one_tool_call_dispatched_then_final() async throws {
    let dir = try makeTempDir("one-call")
    let persona = hermeticPersona(root: dir)
    // Iter 1: OpenAI-style tool call. Iter 2: plain final reply.
    let toolCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{\"x\":1}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [toolCall, "final answer using tool output"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "please use echo", llm: llm, tools: tools
    )
    #expect(llm.callCount == 2)
    #expect(result.toolDispatches.count == 1)
    #expect(result.toolDispatches[0].name == "echo")
    #expect(result.reply == "final answer using tool output")
}

@Test
func toolCallParserDropsPlaceholderToolNames() {
    let mixed = #"{"tool_calls":[{"id":"placeholder","type":"function","function":{"name":"...","arguments":"{}"}},{"id":"real","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    #expect(ToolCallParser.parse(mixed).map(\.name) == ["echo"])
    #expect(ToolCallParser.containsOnlyIgnorableCalls(mixed) == false)

    let placeholderOnly = #"{"tool_calls":[{"id":"placeholder","type":"function","function":{"name":"...","arguments":"{}"}}]}"#
    #expect(ToolCallParser.parse(placeholderOnly).isEmpty)
    #expect(ToolCallParser.containsOnlyIgnorableCalls(placeholderOnly) == true)

    let anthPlaceholder = #"<tool_use id="toolu_placeholder" name="...">{}</tool_use>"#
    #expect(ToolCallParser.parse(anthPlaceholder).isEmpty)
    #expect(ToolCallParser.containsOnlyIgnorableCalls(anthPlaceholder) == true)
}

@Test
func toolCallParserRejectsMarkdownPseudoCallsAndFencedMarkers() {
    let markdownPseudoCall = """
    1

    **Tool Call: codex_message**

    ```json
    {"text":"do the work","topic":"strict protocol"}
    ```

    **Tool Result: codex_message**

    ```json
    {"notified":true}
    ```
    """
    let markdownViolation = ToolCallParser.formattedToolCallViolation(in: markdownPseudoCall)
    #expect(markdownViolation?.kind == .markdownToolCallBlock)
    #expect(ToolCallParser.parse(markdownPseudoCall).isEmpty)

    let fencedMarker = """
    ```xml
    <tool_use name="echo">{"q":42}</tool_use>
    ```
    """
    let fencedViolation = ToolCallParser.formattedToolCallViolation(in: fencedMarker)
    #expect(fencedViolation?.kind == .formattedToolUseMarker)
    #expect(ToolCallParser.parse(fencedMarker).isEmpty)

    let bareMarker = #"<tool_use name="echo">{"q":42}</tool_use>"#
    #expect(ToolCallParser.formattedToolCallViolation(in: bareMarker) == nil)
    #expect(ToolCallParser.parse(bareMarker).map(\.name) == ["echo"])
}

@Test
func executeTurnWithToolLoopBouncesMarkdownPseudoCallBeforeDispatch() async throws {
    let dir = try makeTempDir("markdown-pseudo-call")
    let persona = hermeticPersona(root: dir)
    let malformed = """
    **Tool Call: echo**
    ```json
    {"q":42}
    ```
    """
    let bareMarker = #"<tool_use name="echo">{"q":42}</tool_use>"#
    let llm = MockLLMClient(scriptedResponses: [malformed, bareMarker, "done after correction"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "use echo",
        llm: llm,
        tools: tools
    )

    #expect(llm.callCount == 3)
    #expect(tools.dispatches.map(\.tool) == ["echo"])
    #expect(result.toolDispatches.map(\.name) == ["echo"])
    #expect(result.reply == "done after correction")
    #expect(!result.reply.contains("Tool Call"))
}

@Test
func dispatchIterationCallsDropsStructuredPlaceholderToolNames() async throws {
    let dir = try makeTempDir("placeholder-dispatch")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["done"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let providerTools = ProviderToolNameMap([])

    let (blocks, records) = await engine.dispatchIterationCalls(
        providerCalls: [
            ParsedToolCall(id: "placeholder", name: "...", input: [:]),
            ParsedToolCall(id: "real", name: "echo", input: [:]),
        ],
        pairedIds: ["placeholder", "real"],
        providerTools: providerTools,
        modelId: "test-model",
        surface: "chat",
        sessionId: nil,
        tools: tools,
        progress: nil
    )

    #expect(records.map(\.name) == ["echo"])
    #expect(blocks.count == 1)
    #expect(tools.dispatches.map(\.tool) == ["echo"])

    let empty = await engine.dispatchIterationCalls(
        providerCalls: [ParsedToolCall(id: "placeholder-only", name: "...", input: [:])],
        pairedIds: ["placeholder-only"],
        providerTools: providerTools,
        modelId: "test-model",
        surface: "chat",
        sessionId: nil,
        tools: tools,
        progress: nil
    )
    #expect(empty.blocks.isEmpty)
    #expect(empty.records.isEmpty)
    #expect(tools.dispatches.map(\.tool) == ["echo"])
}

@Test
func executeTurnWithToolLoop_emits_progress_for_tool_use_and_result() async throws {
    let dir = try makeTempDir("progress")
    let persona = hermeticPersona(root: dir)
    let toolCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{\"x\":1}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [toolCall, "final"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let capture = ToolLoopEventCapture()

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "please use echo",
        llm: llm,
        tools: tools,
        progress: { event in
            await capture.append(event)
        }
    )

    let events = await capture.snapshot()
    #expect(result.reply == "final")
    #expect(events.count == 2)
    if case .toolUse(let name, let input) = events.first {
        #expect(name == "echo")
        if case .object(let obj) = input {
            #expect(obj["x"] == .int(1))
        } else {
            Issue.record("expected object input")
        }
    } else {
        Issue.record("expected toolUse event")
    }
    if let second = events.dropFirst().first, case .toolResult(let name, let output) = second {
        #expect(name == "echo")
        #expect(output == .string("ok"))
    } else {
        Issue.record("expected toolResult event")
    }
}

@Test
func executeTurnWithToolLoop_providerSafeAliases_dispatchBackToInternalToolNames() async throws {
    let dir = try makeTempDir("provider-alias")
    let persona = hermeticPersona(root: dir)
    let internalName = "mcp__nativeagent-internal__agent.operating_map"
    let providerName = "mcp_nativeagent_internal_agent_operating_map"
    let params = Data(#"{"type":"object","properties":{}}"#.utf8)
    let tools = SchemaToolDispatch(
        schemas: [
            LLMToolSchema(
                name: internalName,
                description: "Return the live operating map.",
                parametersJSON: params
            ),
        ],
        scripted: [internalName: .string("ok")]
    )
    let toolCall = #"<tool_use id="toolu_1" name="\#(providerName)">{}</tool_use>"#
    let llm = CapturingMessagesLLM(scriptedResponses: [toolCall, "done"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let context = TurnContext(
        surface: "chat",
        personaDocs: [:],
        recalled: [],
        modelId: "test-model",
        reasoningEffort: "high",
        toolsAvailable: [internalName],
        systemPrompt: nil,
        userMessage: "use the operating map",
        toolSchemas: try await tools.listAvailableToolSchemas()
    )

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "use the operating map",
        llm: llm,
        tools: tools,
        preBuiltContext: context
    )

    #expect(llm.toolNamesByCall.first == [providerName])
    #expect(llm.toolNamesByCall.first?.contains(internalName) == false)
    #expect(tools.dispatches == [internalName])
    #expect(result.toolDispatches.map { $0.name } == [internalName])
    #expect(result.reply == "done")
}

@Test
func executeTurnWithToolLoop_multiple_tools_per_iteration() async throws {
    let dir = try makeTempDir("multi")
    let persona = hermeticPersona(root: dir)
    let twoCalls = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"alpha","arguments":"{}"}},{"id":"c2","type":"function","function":{"name":"beta","arguments":"{}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [twoCalls, "done"])
    let tools = MockToolDispatchClient(scripted: [
        "alpha": .string("a-ok"),
        "beta": .string("b-ok"),
    ])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "use both", llm: llm, tools: tools
    )
    #expect(result.toolDispatches.count == 2)
    #expect(result.toolDispatches[0].name == "alpha")
    #expect(result.toolDispatches[1].name == "beta")
    #expect(result.reply == "done")
}

@Test
func executeTurnWithToolLoop_max_iterations_returns_readable_fallback() async throws {
    let dir = try makeTempDir("max")
    let persona = hermeticPersona(root: dir)
    // Every response is a tool call → never reaches a final reply.
    let alwaysCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [alwaysCall])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("k")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "x", maxIterations: 3, llm: llm, tools: tools
    )
    #expect(result.reply.contains("tool loop exhausted after 3 iterations"))
    #expect(result.toolDispatches.count == 3)
    #expect(result.rawLLMResponse == alwaysCall)
}

@Test
func executeTurnWithToolLoop_stopsAnIdenticalNoProgressCycleWithoutDisablingTheTool() async throws {
    let dir = try makeTempDir("no-progress")
    let persona = hermeticPersona(root: dir)
    let alwaysCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{\"query\":\"same\"}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [alwaysCall])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("unchanged")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "keep trying", maxIterations: 20, llm: llm, tools: tools
    )

    #expect(result.reply.contains("stopped the tool loop after sixteen identical rounds"))
    #expect(result.reply.contains("No tool capability was disabled"))
    #expect(result.toolDispatches.count == 16)
    #expect(tools.dispatches.count == 16)
}

@Test
func toolLoopNoProgressGuard_resetsWhenArgumentsOrResultsChange() {
    func record(_ input: Int64, _ result: String) -> TurnEngineResult.ToolDispatchRecord {
        .init(name: "status", input: ["page": .int(input)], result: .string(result))
    }

    var guardrail = ToolLoopNoProgressGuard()
    #expect(guardrail.observe([record(0, "pending")]) == .none)
    #expect(guardrail.observe([record(0, "pending")]) == .none)
    #expect(guardrail.observe([record(1, "pending")]) == .none)
    #expect(guardrail.observe([record(1, "changed")]) == .none)
    for _ in 0..<6 {
        #expect(guardrail.observe([record(1, "changed")]) == .none)
    }
    guard case .warn = guardrail.observe([record(1, "changed")]) else {
        Issue.record("eighth exact no-progress round should warn")
        return
    }
}

@Test
func executeTurnWithToolLoop_OpenAI_function_call_format_detected() async throws {
    let dir = try makeTempDir("oai-fn")
    let persona = hermeticPersona(root: dir)
    // The older single-call shape: `function_call` object, not `tool_calls` array.
    let fnCall = #"{"function_call":{"name":"echo","arguments":"{\"k\":\"v\"}"}}"#
    let llm = MockLLMClient(scriptedResponses: [fnCall, "ok done"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "go", llm: llm, tools: tools
    )
    #expect(result.toolDispatches.count == 1)
    #expect(result.toolDispatches[0].name == "echo")
    if case .string(let v) = result.toolDispatches[0].input["k"] {
        #expect(v == "v")
    } else {
        Issue.record("expected input.k == \"v\"")
    }
}

@Test
func executeTurnWithToolLoop_Anthropic_tool_use_format_detected() async throws {
    let dir = try makeTempDir("anth")
    let persona = hermeticPersona(root: dir)
    let xml = "<tool_use name=\"echo\">{\"q\":42}</tool_use>"
    let llm = MockLLMClient(scriptedResponses: [xml, "all done"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "go", llm: llm, tools: tools
    )
    #expect(result.toolDispatches.count == 1)
    #expect(result.toolDispatches[0].name == "echo")
    if case .int(let n) = result.toolDispatches[0].input["q"] {
        #expect(n == 42)
    } else {
        Issue.record("expected input.q == 42")
    }
    #expect(result.reply == "all done")
}

@Test
func executeTurnWithToolLoop_tool_dispatch_failure_continues_with_error_in_prompt() async throws {
    let dir = try makeTempDir("err")
    let persona = hermeticPersona(root: dir)
    let call = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"broken","arguments":"{}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [call, "recovered from tool error"])
    let tools = FailingToolDispatch()
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "try", llm: llm, tools: tools
    )
    #expect(llm.callCount == 2)
    #expect(result.toolDispatches.count == 1)
    // The recorded result must be an error object — NOT a thrown error.
    if case .object(let o) = result.toolDispatches[0].result {
        #expect(o["error"] != nil)
    } else {
        Issue.record("expected error object as recorded result")
    }
    #expect(result.reply == "recovered from tool error")
}

@Test
func executeTurnWithToolLoop_toolDispatches_recorded_in_order() async throws {
    let dir = try makeTempDir("order")
    let persona = hermeticPersona(root: dir)
    // Iter 1: alpha. Iter 2: beta. Iter 3: final.
    let one = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"alpha","arguments":"{}"}}]}"#
    let two = #"{"tool_calls":[{"id":"c2","type":"function","function":{"name":"beta","arguments":"{}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [one, two, "fin"])
    let tools = MockToolDispatchClient(scripted: ["alpha": .string("a"), "beta": .string("b")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "x", llm: llm, tools: tools
    )
    #expect(result.toolDispatches.map { $0.name } == ["alpha", "beta"])
}

@Test
func executeTurnWithToolLoop_no_double_count_on_LLM_retry() async throws {
    let dir = try makeTempDir("nodup")
    let persona = hermeticPersona(root: dir)
    // The same tool name is called by the LLM in two SEPARATE iterations.
    // Each iteration must produce exactly one dispatch — never carry over.
    let call = #"{"tool_calls":[{"id":"c","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [call, call, "final"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "x", llm: llm, tools: tools
    )
    #expect(result.toolDispatches.count == 2)
    #expect(tools.dispatches.count == 2)
    #expect(llm.callCount == 3)
}

@Test
func executeTurnWithToolLoop_injects_session_id_for_scratchpad_read() async throws {
    let dir = try makeTempDir("scratch-session")
    let persona = hermeticPersona(root: dir)
    let call = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"scratchpad_read","arguments":"{\"key\":\"plan\"}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [call, "done"])
    let tools = MockToolDispatchClient(scripted: ["scratchpad_read": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "read scratch",
        sessionId: "telegram:12345",
        llm: llm,
        tools: tools
    )

    #expect(result.toolDispatches.count == 1)
    #expect(result.toolDispatches[0].name == "scratchpad_read")
    #expect(result.toolDispatches[0].input["key"] == .string("plan"))
    #expect(result.toolDispatches[0].input["session_id"] == .string("telegram:12345"))
    #expect(tools.dispatches.first?.input["session_id"] == .string("telegram:12345"))
    #expect(result.reply == "done")
}

@Test
func toolLoopExhausted_error_message_includes_iteration_count() async throws {
    let e = TurnEngineError.ToolLoopExhausted(iterations: 7)
    #expect(e.errorDescription?.contains("7") == true)
    #expect(e.errorDescription?.contains("tool loop") == true)
}

// MARK: - B7 — non-streaming loop honors the cross-process cancel flag

/// Writes the session cancel flag on its first dispatch, simulating a
/// cross-process Stop landing mid-turn.
private final class FlagWritingToolDispatch: ToolDispatchClient, @unchecked Sendable {
    private let flagPath: URL
    private let result: JSONValue
    private let lock = NSLock()
    private var _dispatchCount = 0
    var dispatchCount: Int { lock.lock(); defer { lock.unlock() }; return _dispatchCount }

    init(flagPath: URL, result: JSONValue) {
        self.flagPath = flagPath
        self.result = result
    }

    // Lock inside a sync helper — NSLock.lock() is unavailable directly in an
    // async body (matches FailingToolDispatch's pattern above).
    private func bump() { lock.lock(); _dispatchCount += 1; lock.unlock() }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        bump()
        try? Data().write(to: flagPath)
        return result
    }

    func listAvailableTools() async throws -> [String] { [] }
}

@Test
func executeTurnWithToolLoop_cancelFlagMidLoop_throwsCancellation() async throws {
    let dir = try makeTempDir("cancel-mid")
    let persona = hermeticPersona(root: dir)
    let flagPath = dir.appendingPathComponent("cancelled.flag")
    // The model keeps calling a tool forever; the tool writes the cancel flag
    // on its first dispatch. The loop's iteration-top poll then halts on the
    // NEXT iteration with a CancellationError instead of running to the cap.
    let alwaysCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [alwaysCall])
    let tools = FlagWritingToolDispatch(flagPath: flagPath, result: .string("ok"))
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    await #expect(throws: CancellationError.self) {
        _ = try await engine.executeTurnWithToolLoop(
            userMessage: "go", maxIterations: 10, llm: llm, tools: tools,
            cancelFlagPath: flagPath
        )
    }
    // Exactly one dispatch happened before the flag halted the loop (iter 1
    // dispatched → flag written → iter 2 top-check threw).
    #expect(tools.dispatchCount == 1)
}

@Test
func executeTurnWithToolLoop_preExistingCancelFlag_throwsBeforeFirstProviderCall() async throws {
    let dir = try makeTempDir("cancel-pre")
    let persona = hermeticPersona(root: dir)
    let flagPath = dir.appendingPathComponent("cancelled.flag")
    try Data().write(to: flagPath)
    let llm = MockLLMClient(scriptedResponses: ["unreached"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    await #expect(throws: CancellationError.self) {
        _ = try await engine.executeTurnWithToolLoop(
            userMessage: "go", llm: llm, tools: tools, cancelFlagPath: flagPath
        )
    }
    // The flag existed before the loop's first iteration-top poll, so no
    // provider call was ever made.
    #expect(llm.callCount == 0)
}

@Test
func executeTurnWithToolLoop_absentCancelFlag_completesNormally() async throws {
    let dir = try makeTempDir("cancel-none")
    let persona = hermeticPersona(root: dir)
    let flagPath = dir.appendingPathComponent("cancelled.flag")  // never created
    let toolCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    let llm = MockLLMClient(scriptedResponses: [toolCall, "final answer"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "go", llm: llm, tools: tools, cancelFlagPath: flagPath
    )
    #expect(result.reply == "final answer")
    #expect(result.toolDispatches.count == 1)
}

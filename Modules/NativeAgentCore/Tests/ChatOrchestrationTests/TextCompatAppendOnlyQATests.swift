import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
@testable import ProviderRouting
import TrustCenter

// MARK: - U1 item 9: text-compat append-only messages QA-equivalence gate
//
// THE CONTRACT THIS FILE PINS (stop-on-divergence gate for restructuring
// ChatOrchestrationClient.runTextStreamingCompatibility from ONE grown user
// message to an append-only [LLMMessage] conversation):
//   (1) EQUIVALENCE across shapes — every scenario runs the SAME scripted
//       provider replies through BOTH the legacy grown-prompt shape
//       (GrownPromptCompat lever ON → prompt transport) and the new
//       append-only messages shape (lever OFF + OAuth credentials + a
//       messages-capable client → messages transport), asserting identical:
//       final answers, tool dispatch sequences, visible delta streams
//       (order + content), and persisted session artifacts (role/content
//       rows). The lever is the ONE rollback switch item 8 shipped —
//       NATIVE_AGENT_GROWN_PROMPT_COMPAT restores the old wire shape on
//       this path too.
//   (2) APPEND-ONLY + CARRIER BYTE-EQUIVALENCE — the new shape's
//       conversation is [user(composed)] + per iteration [assistant(raw
//       reply incl. markers), user(tool results)], where the tool-result
//       text is the EXACT byte suffix the grown shape appends:
//       grownPrompt(iter N) == conversation[0].text + all prior tool-result
//       message texts. Only the carrier changed.
//   (3) FAIL-CLOSED TRANSPORT GATES — no OAuth auth file, a prompt-only
//       streaming client, or the compat lever each independently force the
//       legacy transport (today's exact wire), so no setup can silently
//       lose live deltas to the api-key streamMessages flatten fallback.
//   (4) PER-ITERATION CONTEXT REBUILD PRESERVED — streamTurn is re-entered
//       per iteration on the new shape too (one system prompt captured per
//       provider call, all carrying the text-tool protocol block), which is
//       the carrier of the lazy tool_load round-trip on this path (the
//       store re-read lives in streamTurn's context build, untouched).
//
// (The adapter-layer half — real SSE, trailing message breakpoint ≤4,
// stream-vs-complete body identity — is pinned in
// AnthropicStreamMessagesSSETests.)

// MARK: - Helpers

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("textcompat-qa-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Drop a usable OAuth auth fixture where the transport preflight looks
/// (dataRoot/providers/anthropic_oauth_direct.json).
private func writeOAuthFixture(_ root: URL) throws {
    let dir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["access_token": "tok-qa"])
        .write(to: dir.appendingPathComponent("anthropic_oauth_direct.json"))
}

private final class StubRoutingQA: ProviderRoutingProtocol, @unchecked Sendable {
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
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "qa-model", reasoningEffort: "high")]
    }
}

/// Structured-path LLM that must never be called on the compat path.
private final class UnusedLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        return "structured-path-should-not-run"
    }
}

/// Serves the SAME per-call chunk scripts over BOTH transports: the legacy
/// prompt stream (chunks as Strings) and the messages stream (chunks as
/// .textDelta events). A shared serve index keeps scripts sequential per
/// provider call regardless of transport, so the two shapes see identical
/// scripted replies. Captures every call's inputs for the QA assertions.
private final class DualTransportScriptedLLM: StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    struct PromptCall {
        let prompt: String
        let system: String?
        let model: String?
        let reasoningEffort: String?
    }
    struct MessagesCall {
        let messages: [LLMMessage]
        let system: String?
        let model: String?
        let tools: [LLMToolSchema]?
        let reasoningEffort: String?
    }

    private let scripts: [[String]]
    private let lock = NSLock()
    private var _promptCalls: [PromptCall] = []
    private var _messagesCalls: [MessagesCall] = []
    private var _serveIndex = 0

    init(scripts: [[String]]) { self.scripts = scripts }

    var promptCalls: [PromptCall] {
        lock.lock(); defer { lock.unlock() }
        return _promptCalls
    }
    var messagesCalls: [MessagesCall] {
        lock.lock(); defer { lock.unlock() }
        return _messagesCalls
    }

    private func nextScript() -> [String] {
        guard !scripts.isEmpty else { return [] }
        let s = scripts[min(_serveIndex, scripts.count - 1)]
        _serveIndex += 1
        return s
    }

    func stream(
        prompt: String,
        system: String?,
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        _promptCalls.append(PromptCall(
            prompt: prompt,
            system: system,
            model: model,
            reasoningEffort: LLMCallContext.reasoningEffort
        ))
        let chunks = nextScript()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                for c in chunks { continuation.yield(c) }
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
        _messagesCalls.append(MessagesCall(
            messages: messages,
            system: system,
            model: model,
            tools: tools,
            reasoningEffort: LLMCallContext.reasoningEffort
        ))
        let chunks = nextScript()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                for c in chunks { continuation.yield(.textDelta(c)) }
                continuation.finish()
            }
        }
    }
}

private func makeQAEngine(root: URL, llm: any LLMClient, tools: any ToolDispatchClient) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: StubRoutingQA(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

private func readPersistedRoleContent(_ root: URL, sessionId: String) -> [[String]] {
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    var out: [[String]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let d = String(line).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { continue }
        out.append([
            (parsed["role"] as? String) ?? "",
            (parsed["content"] as? String) ?? "",
        ])
    }
    return out
}

/// One compat run's full observable surface, for cross-shape comparison.
private struct CompatObservation {
    let deltas: [String]
    let finalReply: String?
    let toolUses: [String]
    let toolResults: [String]
    let errors: [String]
    let persistedRows: [[String]]
    let llm: DualTransportScriptedLLM
}

private func runCompatScenario(
    tag: String,
    scripts: [[String]],
    tools: any ToolDispatchClient,
    message: String = "hello",
    grownPromptCompat: Bool,
    writeAuth: Bool = true,
    promptOnlyClient: Bool = false,
    reasoningEffort: String = "high"
) async throws -> CompatObservation {
    let root = try makeTempRoot(tag)
    if writeAuth { try writeOAuthFixture(root) }
    let llm = UnusedLLM()
    let dual = DualTransportScriptedLLM(scripts: scripts)
    let streaming: any StreamingLLMClient = promptOnlyClient
        ? MockStreamingLLMClient(chunks: scripts.first ?? [])
        : dual
    let engine = makeQAEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: streaming,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let sessionId = "s-\(tag)"

    var deltas: [String] = []
    var finalReply: String?
    var toolUses: [String] = []
    var toolResults: [String] = []
    var errors: [String] = []
    try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(grownPromptCompat) {
            for try await event in client.chatStream(
                message: message, sessionId: sessionId,
                model: "claude-opus-4-8", reasoningEffort: reasoningEffort,
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
        }
    #expect(llm.calls == 0, "\(tag): structured LLM path must not run on compat")
    return CompatObservation(
        deltas: deltas,
        finalReply: finalReply,
        toolUses: toolUses,
        toolResults: toolResults,
        errors: errors,
        persistedRows: readPersistedRoleContent(root, sessionId: sessionId),
        llm: dual
    )
}

private func expectShapeEquivalent(
    _ new: CompatObservation, _ old: CompatObservation, scenario: String
) {
    #expect(new.finalReply == old.finalReply, "\(scenario): final answers diverge")
    #expect(new.deltas == old.deltas, "\(scenario): visible delta streams diverge")
    #expect(new.toolUses == old.toolUses, "\(scenario): tool dispatch sequences diverge")
    #expect(new.toolResults == old.toolResults, "\(scenario): tool result sequences diverge")
    #expect(new.errors == old.errors, "\(scenario): error streams diverge")
    #expect(new.persistedRows == old.persistedRows, "\(scenario): persisted artifacts diverge")
}

/// Extract the plain text of a single-text-block message.
private func textOf(_ message: LLMMessage) -> String? {
    guard message.content.count == 1, case .text(let t) = message.content[0] else { return nil }
    return t
}

// MARK: - QA1: plain reply (no tools)

@Test
func textCompatQA1_plainReply_equivalentAcrossShapes() async throws {
    let scripts = [["compat ", "reply"]]
    let new = try await runCompatScenario(
        tag: "qa1-new", scripts: scripts,
        tools: MockToolDispatchClient(), grownPromptCompat: false
    )
    let old = try await runCompatScenario(
        tag: "qa1-old", scripts: scripts,
        tools: MockToolDispatchClient(), grownPromptCompat: true
    )
    expectShapeEquivalent(new, old, scenario: "QA1")
    #expect(new.finalReply == "compat reply")
    #expect(new.persistedRows.map(\.[0]) == ["user", "assistant"])

    // Transport selection: new shape rode messages SSE; old rode the prompt
    // stream — with the SAME scripted chunks.
    #expect(new.llm.messagesCalls.count == 1)
    #expect(new.llm.promptCalls.isEmpty)
    #expect(old.llm.promptCalls.count == 1)
    #expect(old.llm.messagesCalls.isEmpty)

    // New-shape request shape: single user message carrying the composed
    // text; tools nil (text-compat contract); system carries the text-tool
    // protocol block; model override flowed through.
    let call = try #require(new.llm.messagesCalls.first)
    #expect(call.messages.count == 1)
    #expect(call.messages.first.flatMap(textOf) == "hello")
    #expect(call.tools == nil)
    #expect(call.model == "claude-opus-4-8")
    #expect(call.system?.contains("NativeAgent Swift tool protocol") == true)
    #expect(old.llm.promptCalls.first?.system?.contains("NativeAgent Swift tool protocol") == true)
}

@Test
func textCompatReasoningEffort_reachesProviderCall_andBlankUsesSurfacePreference() async throws {
    let messagesOverride = try await runCompatScenario(
        tag: "effort-messages-override",
        scripts: [["ok"]],
        tools: MockToolDispatchClient(),
        grownPromptCompat: false,
        reasoningEffort: "  low  "
    )
    #expect(messagesOverride.llm.messagesCalls.first?.reasoningEffort == "low")

    let messagesFallback = try await runCompatScenario(
        tag: "effort-messages-fallback",
        scripts: [["ok"]],
        tools: MockToolDispatchClient(),
        grownPromptCompat: false,
        reasoningEffort: " \n "
    )
    #expect(messagesFallback.llm.messagesCalls.first?.reasoningEffort == "high")

    let promptOverride = try await runCompatScenario(
        tag: "effort-prompt-override",
        scripts: [["ok"]],
        tools: MockToolDispatchClient(),
        grownPromptCompat: true,
        reasoningEffort: "low"
    )
    #expect(promptOverride.llm.promptCalls.first?.reasoningEffort == "low")

    let promptFallback = try await runCompatScenario(
        tag: "effort-prompt-fallback",
        scripts: [["ok"]],
        tools: MockToolDispatchClient(),
        grownPromptCompat: true,
        reasoningEffort: ""
    )
    #expect(promptFallback.llm.promptCalls.first?.reasoningEffort == "high")
}

// MARK: - QA2: tool round-trip (2 iterations) + carrier byte-equivalence

@Test
func textCompatQA2_toolRoundTrip_equivalent_appendOnly_byteCarrier() async throws {
    let marker = #"<tool_use id="t1" name="read_file">{"path":"a"}</tool_use>"#
    let scripts = [[marker], ["done ", "reading"]]
    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: ["read_file": .string("BODY-A")])
    }
    let new = try await runCompatScenario(
        tag: "qa2-new", scripts: scripts, tools: freshTools(), grownPromptCompat: false
    )
    let old = try await runCompatScenario(
        tag: "qa2-old", scripts: scripts, tools: freshTools(), grownPromptCompat: true
    )
    expectShapeEquivalent(new, old, scenario: "QA2")
    #expect(new.finalReply == "done reading")
    #expect(new.toolUses == ["read_file"])
    #expect(new.toolResults == ["read_file"])
    // Marker text never leaks into the visible delta stream — both shapes.
    #expect(new.deltas.allSatisfy { !$0.contains("<tool") })
    // Persisted artifacts: user + tool pill + assistant.
    #expect(new.persistedRows.map(\.[0]) == ["user", "tool", "assistant"])

    // New shape: TWO provider calls (context rebuilt per iteration — the
    // lazy tool_load carrier), append-only conversation growth.
    #expect(new.llm.messagesCalls.count == 2)
    let first = try #require(new.llm.messagesCalls.first)
    let second = try #require(new.llm.messagesCalls.last)
    #expect(first.messages.count == 1)
    #expect(second.messages.count == 3)
    // Strict append-only prefix: call 2 starts with call 1's array.
    #expect(Array(second.messages.prefix(1)) == first.messages)
    #expect(second.messages[1].role == .assistant)
    #expect(textOf(second.messages[1]) == marker)
    #expect(second.messages[2].role == .user)

    // CARRIER BYTE-EQUIVALENCE: the old shape's iteration-2 grown prompt is
    // exactly conversation[0].text + conversation[2].text — only the
    // carrier changed (message vs string growth).
    #expect(old.llm.promptCalls.count == 2)
    let composed = try #require(textOf(second.messages[0]))
    let toolResultsText = try #require(textOf(second.messages[2]))
    #expect(toolResultsText.contains("NativeAgent tool result for read_file:"))
    #expect(toolResultsText.contains("BODY-A"))
    #expect(old.llm.promptCalls[1].prompt == composed + toolResultsText,
            "QA2: grown prompt != conversation carrier bytes")

    // System prompt byte-stable across iterations on the new shape (the
    // within-turn cache precondition; recall keyed on the original message
    // both iterations) and rebuilt fresh each call (both carry the
    // text-tool protocol block).
    #expect(first.system == second.system)
    #expect(first.system?.contains("NativeAgent Swift tool protocol") == true)
}

// MARK: - QA3: two markers in one iteration → ONE tool-results user message

@Test
func textCompatQA3_multiCallIteration_singleResultsMessage_equivalent() async throws {
    let markers = #"<tool_use id="t1" name="read_file">{"path":"a"}</tool_use><tool_use id="t2" name="recall_memory">{"q":"x"}</tool_use>"#
    let scripts = [[markers], ["both done"]]
    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: [
            "read_file": .string("R-BODY"),
            "recall_memory": .string("M-BODY"),
        ])
    }
    let new = try await runCompatScenario(
        tag: "qa3-new", scripts: scripts, tools: freshTools(), grownPromptCompat: false
    )
    let old = try await runCompatScenario(
        tag: "qa3-old", scripts: scripts, tools: freshTools(), grownPromptCompat: true
    )
    expectShapeEquivalent(new, old, scenario: "QA3")
    #expect(new.finalReply == "both done")
    // Serial dispatch order preserved (this path's own loop is serial by
    // shipped design — item 9 does not fork its dispatch semantics).
    #expect(new.toolUses == ["read_file", "recall_memory"])

    // ONE appended user message carries BOTH results, in dispatch order.
    let second = try #require(new.llm.messagesCalls.last)
    #expect(second.messages.count == 3)
    let resultsText = try #require(textOf(second.messages[2]))
    let readRange = try #require(resultsText.range(of: "NativeAgent tool result for read_file:"))
    let recallRange = try #require(resultsText.range(of: "NativeAgent tool result for recall_memory:"))
    #expect(readRange.lowerBound < recallRange.lowerBound)
    // And the same single-message bytes match the old grown suffix.
    let composed = try #require(textOf(second.messages[0]))
    #expect(old.llm.promptCalls[1].prompt == composed + resultsText)
}

// MARK: - QA4: fail-closed transport gates

@Test
func textCompatQA4_noAuthFile_keepsLegacyPromptTransport() async throws {
    let obs = try await runCompatScenario(
        tag: "qa4-noauth", scripts: [["legacy ", "reply"]],
        tools: MockToolDispatchClient(), grownPromptCompat: false,
        writeAuth: false
    )
    // Capable client, lever off — but no OAuth credentials: the messages
    // transport would lose live deltas to the api-key flatten fallback, so
    // the loop must stay on the prompt transport.
    #expect(obs.llm.promptCalls.count == 1)
    #expect(obs.llm.messagesCalls.isEmpty)
    #expect(obs.finalReply == "legacy reply")
}

@Test
func textCompatQA5_promptOnlyClient_keepsLegacyTransport() async throws {
    let obs = try await runCompatScenario(
        tag: "qa5-promptonly", scripts: [["mock ", "reply"]],
        tools: MockToolDispatchClient(), grownPromptCompat: false,
        promptOnlyClient: true
    )
    // MockStreamingLLMClient is not messages-capable: dual transport unused,
    // turn completes through the legacy path.
    #expect(obs.llm.promptCalls.isEmpty)
    #expect(obs.llm.messagesCalls.isEmpty)
    #expect(obs.finalReply == "mock reply")
}

@Test
func textCompatQA6_compatLever_forcesGrownPromptShape() async throws {
    // Auth present + capable client, but the rollback lever is ON: the wire
    // must be the grown-prompt shape (prompt transport, growing string) —
    // the documented one-lever rollback for items 8 + 9 together.
    let marker = #"<tool_use id="t1" name="read_file">{"path":"a"}</tool_use>"#
    let obs = try await runCompatScenario(
        tag: "qa6-lever", scripts: [[marker], ["after tool"]],
        tools: MockToolDispatchClient(scripted: ["read_file": .string("B")]),
        grownPromptCompat: true
    )
    #expect(obs.llm.messagesCalls.isEmpty)
    #expect(obs.llm.promptCalls.count == 2)
    let p2 = try #require(obs.llm.promptCalls.last)
    #expect(p2.prompt.hasPrefix("hello"))
    #expect(p2.prompt.contains("NativeAgent tool result for read_file:"))
    #expect(obs.finalReply == "after tool")
}

// MARK: - QA7: malformed Markdown tool calls bounce inside the turn

@Test
func textCompatQA7_formattedToolCallsBounceWithoutDeliveryOrDispatch() async throws {
    let markdownPseudoCall = """
    1

    **Tool Call: read_file**

    ```json
    {"path":"private-plan.txt"}
    ```

    **Tool Result: read_file**

    ```json
    {"content":"invented success"}
    ```
    """
    let fencedMarker = """
    ```xml
    <tool_use name="read_file">{"path":"private-plan.txt"}</tool_use>
    ```
    """
    let bareMarker = #"<tool_use name="read_file">{"path":"private-plan.txt"}</tool_use>"#
    // Character-sized chunks pin the cross-SSE-boundary buffer: neither the
    // Markdown header/fenced JSON nor a fenced marker may leak into drafts.
    let pseudoChunks: [String] = markdownPseudoCall.map { String($0) }
    let fencedChunks: [String] = fencedMarker.map { String($0) }
    let bareChunks: [String] = bareMarker.map { String($0) }
    let finalChunks: [String] = "verified final".map { String($0) }
    let scripts: [[String]] = [pseudoChunks, fencedChunks, bareChunks, finalChunks]

    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: ["read_file": .string("REAL-BODY")])
    }
    let new = try await runCompatScenario(
        tag: "qa7-new",
        scripts: scripts,
        tools: freshTools(),
        grownPromptCompat: false
    )
    let old = try await runCompatScenario(
        tag: "qa7-old",
        scripts: scripts,
        tools: freshTools(),
        grownPromptCompat: true
    )

    expectShapeEquivalent(new, old, scenario: "QA7")
    #expect(new.finalReply == "verified final")
    #expect(new.toolUses == ["read_file"])
    #expect(new.toolResults == ["read_file"])
    #expect(new.llm.messagesCalls.count == 4)
    #expect(old.llm.promptCalls.count == 4)
    #expect(new.persistedRows.map { $0[0] } == ["user", "tool", "assistant"])
    let visible = new.deltas.joined()
    #expect(!visible.contains("Tool Call"))
    #expect(!visible.contains("<tool_use"))
    #expect(!visible.contains("private-plan.txt"))
    #expect(!visible.contains("invented success"))
}

// MARK: - QA: mid-turn tool_load must NOT mutate the system prompt
// turn-context-iteration-cache (2026-08-13): pre-fix, iteration N+1's context
// rebuild re-read ActiveToolsStore after a mid-turn tool_load and the grown
// tool catalog landed inside the stable cache-breakpointed system segment —
// byte-diff-proven prompt-cache kill on live turn 47ee5b6d (369k
// cache-creation tokens). The text-compat loop now pins its turn-start tool
// set for the whole turn. This test is the mutation-killer for that pin:
// revert the pin and the system-equality assertions fail.

/// Tools client that (a) exposes a lazily-gated probe schema, (b) simulates
/// the real impl_tool_load side effect by writing the probe into a HERMETIC
/// ActiveToolsStore, which the engine adopts via ActiveToolsStoreProviding.
private final class ToolLoadSimulatingTools: ToolDispatchClient, ActiveToolsStoreProviding, @unchecked Sendable {
    let activeToolsStore: ActiveToolsStore
    private let sessionId: String
    init(root: URL, sessionId: String) {
        self.activeToolsStore = ActiveToolsStore(dataRoot: root)
        self.sessionId = sessionId
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if tool == "tool_load" {
            _ = try await activeToolsStore.addLoaded(sessionId: sessionId, names: ["zz_lazy_probe"])
            return .object([
                "status": .string("loaded"),
                "loaded_now": .array([.string("zz_lazy_probe")]),
                "schemas_added": .array([.object([
                    "name": .string("zz_lazy_probe"),
                    "description": .string("probe"),
                    "parameters": .object(["type": .string("object")]),
                ])]),
            ])
        }
        if tool == "zz_lazy_probe" { return .string("PROBE-OK") }
        return .null
    }
    func listAvailableTools() async throws -> [String] { ["tool_load", "zz_lazy_probe"] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let params = try JSONSerialization.data(withJSONObject: ["type": "object"])
        return [
            LLMToolSchema(name: "tool_load", description: "load lazy tools", parametersJSON: params),
            LLMToolSchema(name: "zz_lazy_probe", description: "lazily gated probe", parametersJSON: params),
        ]
    }
}

@Test
func textCompatQA_systemPromptStableAcrossMidTurnToolLoad() async throws {
    let tag = "qa-pin-toolload"
    let loadMarker = #"<tool_use id="t1" name="tool_load">{"names":["zz_lazy_probe"]}</tool_use>"#
    let probeMarker = #"<tool_use id="t2" name="zz_lazy_probe">{}</tool_use>"#
    let scripts = [[loadMarker], [probeMarker], ["all ", "stable"]]
    let root = try makeTempRoot(tag)
    try writeOAuthFixture(root)
    let tools = ToolLoadSimulatingTools(root: root, sessionId: "s-\(tag)")

    let llm = UnusedLLM()
    let dual = DualTransportScriptedLLM(scripts: scripts)
    let engine = makeQAEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: dual,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    var toolUses: [String] = []
    var toolResults: [String] = []
    var finalReply: String?
    var errors: [String] = []
    for try await event in client.chatStream(
        message: "load the probe tool then run it", sessionId: "s-\(tag)",
        model: "claude-opus-4-8", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], persona: nil,
        surface: "chat", suppressUserAppend: false
    ) {
        switch event {
        case .toolUse(let name, _): toolUses.append(name)
        case .toolResult(let name, _): toolResults.append(name)
        case .final(let r): finalReply = r.reply
        case .error(let m): errors.append(m)
        default: break
        }
    }

    #expect(errors.isEmpty)
    #expect(finalReply == "all stable")
    // The just-loaded tool DISPATCHES this turn (store gate honors the load).
    #expect(toolUses == ["tool_load", "zz_lazy_probe"])
    #expect(toolResults == ["tool_load", "zz_lazy_probe"])

    // THE PIN: every iteration's system prompt is byte-identical — the
    // mid-turn store write must not grow the advertised catalog.
    let calls = dual.messagesCalls
    #expect(calls.count == 3)
    let systems = calls.map { $0.system ?? "" }
    #expect(Set(systems).count == 1, "system prompt changed across iterations")
    // And the growth really was suppressed, not absent: the probe's schema
    // stays OUT of every iteration's system text (it was never turn-start
    // active; pre-fix it appeared from iteration 2 on).
    #expect(systems.allSatisfy { !$0.contains("lazily gated probe") })
    // The store DID grow mid-turn — proves the mutation channel fired.
    let active = await tools.activeToolsStore.load(sessionId: "s-\(tag)").activeTools
    #expect(active.contains("zz_lazy_probe"))
}

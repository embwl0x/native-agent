import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
@testable import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - U1 item 8 (F1 lane (b)): append-only messages QA-equivalence gate
//
// THE CONTRACT THIS FILE PINS:
//   (1) The structured tool loops (executeTurnWithToolLoop +
//       executeTurnWithStreamingToolLoop) grow the provider-visible
//       conversation APPEND-ONLY: every iteration appends exactly one
//       assistant message (tool_use) and one user message (tool_result);
//       no earlier message is ever reordered or removed; the ONLY permitted
//       in-place rewrite is the U1 step-5 clearing stub on tool-result
//       bodies older than the keep window. This is the precondition for the
//       trailing MESSAGE cache breakpoint added in
//       LLMClient+AnthropicOAuthDirectAdapter.swift (item 8): iteration N+1
//       cache-READS everything through iteration N only if those bytes are
//       a stable prefix.
//   (2) QA-EQUIVALENCE across the rollback lever
//       (NATIVE_AGENT_GROWN_PROMPT_COMPAT — old breakpoint layout vs new
//       trailing-message layout): the lever lives ENTIRELY in the Anthropic
//       OAuth adapter's breakpoint placement; the loop's model-visible
//       framing, dispatch sequence, progress events, and results must be
//       IDENTICAL in both states. Each scenario below runs twice (lever
//       off/on) and asserts byte-level equality of everything observable.
//       (The adapter-layer half of the gate — request bodies deep-equal
//       modulo cache_control — is pinned in LLMCallTelemetryTests.)
//
// Scenario set (brief: ≥6 — multi-iteration reads, mixed parallel batches,
// error slots, clearing-window overflow at >5 iterations):
//   S1 multi-iteration sequential reads (3 iterations, Anthropic markers)
//   S2 mixed parallel batch (safe+unsafe+safe in one iteration, step 6)
//   S3 error slot (a tool throws; error becomes the slot's result)
//   S4 clearing-window overflow (8 iterations — step-5 stubs kick in)
//   S5 streaming loop, multi-iteration with streamed tool-call events
//   S6 legacy id-less markers (synthesized ids, pairing preserved)

// MARK: - Test helpers

private func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("appendonly-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

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

/// Captures the FULL messages array per completeMessages call.
private final class MessagesCapturingLLM: LLMClient, @unchecked Sendable {
    private let scriptedResponses: [String]
    private let lock = NSLock()
    private var _messagesByCall: [[LLMMessage]] = []

    var messagesByCall: [[LLMMessage]] {
        lock.lock(); defer { lock.unlock() }
        return _messagesByCall
    }

    init(scriptedResponses: [String]) {
        self.scriptedResponses = scriptedResponses
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "" }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let idx = lock.withLock {
            let i = _messagesByCall.count
            _messagesByCall.append(messages)
            return i
        }
        guard !scriptedResponses.isEmpty else { return "" }
        return scriptedResponses[idx % scriptedResponses.count]
    }
}

/// Streaming sibling: yields scripted events per call, captures messages.
private final class StreamingMessagesCapturingLLM: LLMClient, @unchecked Sendable {
    private let scriptedEvents: [[LLMMessageStreamEvent]]
    private let lock = NSLock()
    private var _messagesByCall: [[LLMMessage]] = []

    var messagesByCall: [[LLMMessage]] {
        lock.lock(); defer { lock.unlock() }
        return _messagesByCall
    }

    init(scriptedEvents: [[LLMMessageStreamEvent]]) {
        self.scriptedEvents = scriptedEvents
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "" }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let idx: Int = lock.withLock {
            let idx = _messagesByCall.count
            _messagesByCall.append(messages)
            return idx
        }
        let events = scriptedEvents.isEmpty ? [] : scriptedEvents[idx % scriptedEvents.count]
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

/// Dispatcher that throws for the named tools and answers the rest.
private final class MixedFailureToolDispatch: ToolDispatchClient, @unchecked Sendable {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "scripted-tool-failure" }
    }
    private let scripted: [String: JSONValue]
    private let failing: Set<String>
    private let lock = NSLock()
    private var _dispatches: [String] = []

    var dispatches: [String] {
        lock.lock(); defer { lock.unlock() }
        return _dispatches
    }

    init(scripted: [String: JSONValue], failing: Set<String>) {
        self.scripted = scripted
        self.failing = failing
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        lock.withLock { _dispatches.append(tool) }
        if failing.contains(tool) { throw Boom() }
        return scripted[tool] ?? .null
    }

    func listAvailableTools() async throws -> [String] { scripted.keys.sorted() }
}

private actor EventShapeCapture {
    private var shapes: [String] = []
    func append(_ event: TurnStreamEvent) {
        switch event {
        case .delta: shapes.append("delta")
        case .toolUse(let name, _): shapes.append("toolUse:\(name)")
        case .toolResult(let name, let output): shapes.append("toolResult:\(name):\((try? output.serialize(pretty: false)) ?? "")")
        case .notice(let kind, _): shapes.append("notice:\(kind)")
        case .final: shapes.append("final")
        case .error(let m): shapes.append("error:\(m)")
        }
    }
    func snapshot() -> [String] { shapes }
}

private func longBody(_ i: Int) -> String {
    "result-\(i)-" + String(repeating: "y\(i)", count: 300)
}

/// One run's full observable surface, for cross-lever-state comparison.
private struct RunObservation {
    let reply: String
    let dispatchNames: [String]
    let dispatchResults: [String]
    let messagesByCall: [[LLMMessage]]
    let eventShapes: [String]
}

/// Append-only invariant: each call's messages = previous call's messages
/// (allowing ONLY step-5 stub rewrites of toolResult content) + exactly one
/// appended assistant message and one appended user tool-result message.
private func expectAppendOnly(_ messagesByCall: [[LLMMessage]]) {
    for k in 1..<messagesByCall.count {
        let prev = messagesByCall[k - 1]
        let curr = messagesByCall[k]
        #expect(curr.count == prev.count + 2, "call \(k): expected exactly 2 appended messages")
        guard curr.count == prev.count + 2 else { continue }
        for i in 0..<prev.count {
            if prev[i] == curr[i] { continue }
            // The only permitted divergence: step-5 stubbing of an OLDER
            // tool-result body — same role, same block count, same ids,
            // every changed block is the stub of the previous content.
            #expect(prev[i].role == curr[i].role, "call \(k) msg \(i): role changed")
            #expect(prev[i].content.count == curr[i].content.count, "call \(k) msg \(i): block count changed")
            for (a, b) in zip(prev[i].content, curr[i].content) where a != b {
                guard case .toolResult(let idA, let contentA, let errA) = a,
                      case .toolResult(let idB, let contentB, let errB) = b else {
                    Issue.record("call \(k) msg \(i): non-toolResult block rewritten")
                    continue
                }
                #expect(idA == idB)
                #expect(errA == errB)
                #expect(IntraTurnToolResultClearing.stub(contentA) == contentB,
                        "call \(k) msg \(i): rewrite is not the step-5 stub")
            }
        }
        // The two appended messages: assistant (with ≥1 toolUse), then user
        // (all toolResult blocks).
        let assistant = curr[prev.count]
        let user = curr[prev.count + 1]
        #expect(assistant.role == .assistant)
        #expect(assistant.content.contains { if case .toolUse = $0 { return true }; return false })
        #expect(user.role == .user)
        #expect(user.content.allSatisfy { if case .toolResult = $0 { return true }; return false })
    }
}

private func expectEquivalent(_ a: RunObservation, _ b: RunObservation, scenario: String) {
    #expect(a.reply == b.reply, "\(scenario): final answers diverge")
    #expect(a.dispatchNames == b.dispatchNames, "\(scenario): dispatch sequence diverges")
    #expect(a.dispatchResults == b.dispatchResults, "\(scenario): dispatch results diverge")
    #expect(a.messagesByCall.count == b.messagesByCall.count, "\(scenario): LLM call count diverges")
    for (i, (ma, mb)) in zip(a.messagesByCall, b.messagesByCall).enumerated() {
        #expect(ma == mb, "\(scenario): call \(i) messages diverge")
    }
    #expect(a.eventShapes == b.eventShapes, "\(scenario): trace event shapes diverge")
}

// MARK: - Scenario runners

private func runNonStreamingScenario(
    tag: String,
    scriptedResponses: [String],
    tools: any ToolDispatchClient,
    userMessage: String,
    grownPromptCompat: Bool
) async throws -> RunObservation {
    let dir = try makeTempDir(tag)
    let persona = hermeticPersona(root: dir)
    let llm = MessagesCapturingLLM(scriptedResponses: scriptedResponses)
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let capture = EventShapeCapture()
    let result = try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(grownPromptCompat) {
            try await engine.executeTurnWithToolLoop(
                userMessage: userMessage,
                llm: llm,
                tools: tools,
                progress: { event in await capture.append(event) }
            )
        }
    return RunObservation(
        reply: result.reply,
        dispatchNames: result.toolDispatches.map(\.name),
        dispatchResults: result.toolDispatches.map { (try? $0.result.serialize(pretty: false)) ?? "" },
        messagesByCall: llm.messagesByCall,
        eventShapes: await capture.snapshot()
    )
}

private func runStreamingScenario(
    tag: String,
    scriptedEvents: [[LLMMessageStreamEvent]],
    tools: any ToolDispatchClient,
    userMessage: String,
    grownPromptCompat: Bool
) async throws -> RunObservation {
    let dir = try makeTempDir(tag)
    let persona = hermeticPersona(root: dir)
    let llm = StreamingMessagesCapturingLLM(scriptedEvents: scriptedEvents)
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let capture = EventShapeCapture()
    let result = try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(grownPromptCompat) {
            try await engine.executeTurnWithStreamingToolLoop(
                userMessage: userMessage,
                llm: llm,
                tools: tools,
                progress: { event in await capture.append(event) }
            )
        }
    return RunObservation(
        reply: result.reply,
        dispatchNames: result.toolDispatches.map(\.name),
        dispatchResults: result.toolDispatches.map { (try? $0.result.serialize(pretty: false)) ?? "" },
        messagesByCall: llm.messagesByCall,
        eventShapes: await capture.snapshot()
    )
}

// MARK: - S1: multi-iteration sequential reads

@Test
func appendOnlyQA_S1_multiIteration_reads_equivalent_across_lever() async throws {
    let calls = (1...3).map { i in
        #"<tool_use id="toolu_\#(i)" name="read_file">{"path":"f\#(i)"}</tool_use>"#
    }
    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: ["read_file": .string("file-body")])
    }
    let new = try await runNonStreamingScenario(
        tag: "s1-new", scriptedResponses: calls + ["all three read"],
        tools: freshTools(), userMessage: "read three files", grownPromptCompat: false
    )
    let old = try await runNonStreamingScenario(
        tag: "s1-old", scriptedResponses: calls + ["all three read"],
        tools: freshTools(), userMessage: "read three files", grownPromptCompat: true
    )
    expectEquivalent(new, old, scenario: "S1")
    #expect(new.reply == "all three read")
    #expect(new.dispatchNames == ["read_file", "read_file", "read_file"])
    #expect(new.messagesByCall.count == 4)
    expectAppendOnly(new.messagesByCall)
    expectAppendOnly(old.messagesByCall)
}

// MARK: - S2: mixed parallel batch (step-6 semantics preserved)

@Test
func appendOnlyQA_S2_mixedParallelBatch_equivalent_across_lever() async throws {
    // One iteration carrying [read_file (safe), search_kg (safe),
    // write_file (unsafe)] — step 6 plans [concurrent(read,search)]
    // [sequential(write)]. Results MUST reassemble in original index order
    // regardless of child completion order, and the step-5 contract groups
    // all three into ONE tool-result user message.
    let batch = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"read_file","arguments":"{}"}},{"id":"c2","type":"function","function":{"name":"search_kg","arguments":"{}"}},{"id":"c3","type":"function","function":{"name":"write_file","arguments":"{}"}}]}"#
    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: [
            "read_file": .string("r"),
            "search_kg": .string("s"),
            "write_file": .string("w"),
        ])
    }
    let new = try await runNonStreamingScenario(
        tag: "s2-new", scriptedResponses: [batch, "batch done"],
        tools: freshTools(), userMessage: "do the batch", grownPromptCompat: false
    )
    let old = try await runNonStreamingScenario(
        tag: "s2-old", scriptedResponses: [batch, "batch done"],
        tools: freshTools(), userMessage: "do the batch", grownPromptCompat: true
    )
    expectEquivalent(new, old, scenario: "S2")
    #expect(new.dispatchNames == ["read_file", "search_kg", "write_file"])
    // One iteration → ONE appended user message carrying all 3 results in
    // original index order (step-5/6 contract: results grouped per
    // iteration).
    #expect(new.messagesByCall.count == 2)
    let secondCall = try #require(new.messagesByCall.last)
    #expect(secondCall.count == 3)
    let resultBlocks = secondCall[2].content.compactMap { block -> String? in
        if case .toolResult(let id, _, _) = block { return id }
        return nil
    }
    #expect(resultBlocks == ["c1", "c2", "c3"])
    expectAppendOnly(new.messagesByCall)
}

// MARK: - S3: error slot

@Test
func appendOnlyQA_S3_errorSlot_equivalent_across_lever() async throws {
    let batch = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"read_file","arguments":"{}"}},{"id":"c2","type":"function","function":{"name":"search_kg","arguments":"{}"}}]}"#
    func freshTools() -> MixedFailureToolDispatch {
        MixedFailureToolDispatch(
            scripted: ["read_file": .string("ok-r"), "search_kg": .string("never")],
            failing: ["search_kg"]
        )
    }
    let new = try await runNonStreamingScenario(
        tag: "s3-new", scriptedResponses: [batch, "recovered"],
        tools: freshTools(), userMessage: "one will fail", grownPromptCompat: false
    )
    let old = try await runNonStreamingScenario(
        tag: "s3-old", scriptedResponses: [batch, "recovered"],
        tools: freshTools(), userMessage: "one will fail", grownPromptCompat: true
    )
    expectEquivalent(new, old, scenario: "S3")
    #expect(new.reply == "recovered")
    // The failing slot becomes an error-object result IN PLACE — loop
    // continues, pairing intact.
    let secondCall = try #require(new.messagesByCall.last)
    let lastMessage = try #require(secondCall.last)
    var sawError = false
    for block in lastMessage.content {
        if case .toolResult(let id, let content, let isError) = block, id == "c2" {
            sawError = true
            #expect(isError)
            #expect(content.contains("scripted-tool-failure"))
        }
    }
    #expect(sawError)
    expectAppendOnly(new.messagesByCall)
}

// MARK: - S4: clearing-window overflow (>5 iterations, step-5 stubs fire)

@Test
func appendOnlyQA_S4_clearingOverflow_equivalent_across_lever() async throws {
    let calls = (1...8).map { i in
        #"{"tool_calls":[{"id":"c\#(i)","type":"function","function":{"name":"t\#(i)","arguments":"{}"}}]}"#
    }
    func freshTools() -> MockToolDispatchClient {
        var scripted: [String: JSONValue] = [:]
        for i in 1...8 { scripted["t\(i)"] = .string(longBody(i)) }
        return MockToolDispatchClient(scripted: scripted)
    }
    let new = try await runNonStreamingScenario(
        tag: "s4-new", scriptedResponses: calls + ["eight done"],
        tools: freshTools(), userMessage: "run eight", grownPromptCompat: false
    )
    let old = try await runNonStreamingScenario(
        tag: "s4-old", scriptedResponses: calls + ["eight done"],
        tools: freshTools(), userMessage: "run eight", grownPromptCompat: true
    )
    // gpt-5.5 review fix (2026-06-10): clearing now fires ONLY in compat
    // mode — rewriting older tool-result bytes mutates the trailing-message
    // cached prefix and torches the cache hit. The lever states therefore
    // legitimately diverge on message bytes once clearing engages; what
    // must STILL be equivalent: final answers, dispatch sequences/results,
    // call counts, trace shapes.
    #expect(new.reply == old.reply, "S4: final answers diverge")
    #expect(new.dispatchNames == old.dispatchNames, "S4: dispatch sequence diverges")
    #expect(new.dispatchResults == old.dispatchResults, "S4: dispatch results diverge")
    #expect(new.messagesByCall.count == old.messagesByCall.count, "S4: call count diverges")
    #expect(new.eventShapes == old.eventShapes, "S4: trace shapes diverge")
    #expect(new.messagesByCall.count == 9)
    expectAppendOnly(new.messagesByCall)
    expectAppendOnly(old.messagesByCall)
    // DEFAULT shape: cross-iteration CACHE-PREFIX STABILITY (the review's
    // critical demand) — every call's messages must start byte-identical
    // to the previous call's FULL array (strict prefix, zero rewrites), so
    // iteration N+1's request matches what iteration N's breakpoint cached.
    for k in 1..<new.messagesByCall.count {
        let prev = new.messagesByCall[k - 1]
        let curr = new.messagesByCall[k]
        #expect(Array(curr.prefix(prev.count)) == prev,
                "S4 default shape: call \(k) rewrote bytes inside the cached prefix")
    }
    // Default shape: NO stubbing anywhere — prefix caching carries the cost.
    let finalNew = try #require(new.messagesByCall.last)
    for msg in finalNew where msg.role == .user {
        for block in msg.content {
            if case .toolResult(_, let content, _) = block {
                #expect(!IntraTurnToolResultClearing.isAlreadyStubbed(content),
                        "default shape must not stub (cache-prefix stability)")
            }
        }
    }
    // COMPAT shape: step-5 semantics preserved — on the final call,
    // iterations 1-2 are stubbed (8 results > keep window of 6), 3-8 full.
    let finalCall = try #require(old.messagesByCall.last)
    let resultContents = finalCall.compactMap { msg -> String? in
        guard msg.role == .user else { return nil }
        for block in msg.content {
            if case .toolResult(_, let content, _) = block { return content }
        }
        return nil
    }
    #expect(resultContents.count == 8)
    for (idx, content) in resultContents.enumerated() {
        let iteration = idx + 1
        if iteration <= 2 {
            #expect(IntraTurnToolResultClearing.isAlreadyStubbed(content),
                    "iteration \(iteration) should be stubbed (compat)")
        } else {
            #expect(content == longBody(iteration),
                    "iteration \(iteration) should be full (compat)")
        }
    }
    // Dispatch records (the persistence feed) still carry FULL bodies —
    // both lever states.
    for run in [new, old] {
        for (idx, serialized) in run.dispatchResults.enumerated() {
            #expect(serialized.contains("result-\(idx + 1)-"))
            #expect(!serialized.contains(IntraTurnToolResultClearing.clearedMarkerPrefix))
        }
    }
}

// MARK: - S5: streaming loop, multi-iteration

@Test
func appendOnlyQA_S5_streamingLoop_equivalent_across_lever() async throws {
    let events: [[LLMMessageStreamEvent]] = [
        [
            .textDelta("checking "),
            .toolCall(LLMStreamToolCall(id: "s1", name: "read_file", inputJSON: Data(#"{"path":"x"}"#.utf8))),
        ],
        [
            .toolCall(LLMStreamToolCall(id: "s2", name: "search_kg", inputJSON: Data("{}".utf8))),
        ],
        [.textDelta("streamed final")],
    ]
    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: [
            "read_file": .string("stream-file"),
            "search_kg": .string("stream-kg"),
        ])
    }
    let new = try await runStreamingScenario(
        tag: "s5-new", scriptedEvents: events,
        tools: freshTools(), userMessage: "stream it", grownPromptCompat: false
    )
    let old = try await runStreamingScenario(
        tag: "s5-old", scriptedEvents: events,
        tools: freshTools(), userMessage: "stream it", grownPromptCompat: true
    )
    expectEquivalent(new, old, scenario: "S5")
    // Transcript-fidelity fix (2026-07-31): the persisted reply carries EVERY
    // visible byte of the turn, including the "checking " narration streamed
    // before iteration 1's tool call. This assertion previously read
    // "streamed final" — that pinned the defect where the success path built
    // the reply from the last iteration only, so a reload dropped narration
    // the user had already watched render. See S8 below.
    #expect(new.reply == "checking streamed final")
    #expect(new.dispatchNames == ["read_file", "search_kg"])
    #expect(new.messagesByCall.count == 3)
    expectAppendOnly(new.messagesByCall)
}

// MARK: - S8: streamed bytes == persisted reply across tool rounds

/// Collects the TEXT payload of every `.delta` event, so a test can assert the
/// bytes the surface rendered are byte-identical to the bytes persisted.
private actor DeltaTextCapture {
    private var text = ""
    func append(_ event: TurnStreamEvent) {
        if case .delta(let chunk) = event { text += chunk }
    }
    func snapshot() -> String { text }
}

@Test
func appendOnlyQA_S8_streamingInterstitialProse_persistsInOrder() async throws {
    // prose → tool → prose → tool → prose. All three prose segments were
    // streamed to the surface; all three must survive into the persisted
    // reply, in order. Before the 2026-07-31 fix the success return built the
    // reply from the LAST iteration's accumulator only, so the transcript kept
    // segment 3 and silently dropped 1 and 2 — the user watched three
    // paragraphs render and a reload showed one.
    let first = "First I will read the file. "
    let second = "Now I will search the graph. "
    let third = "Both came back clean."
    let events: [[LLMMessageStreamEvent]] = [
        [
            .textDelta(first),
            .toolCall(LLMStreamToolCall(id: "p1", name: "read_file", inputJSON: Data(#"{"path":"x"}"#.utf8))),
        ],
        [
            .textDelta(second),
            .toolCall(LLMStreamToolCall(id: "p2", name: "search_kg", inputJSON: Data("{}".utf8))),
        ],
        [.textDelta(third)],
    ]
    let tools = MockToolDispatchClient(scripted: [
        "read_file": .string("file-body"),
        "search_kg": .string("kg-body"),
    ])
    let dir = try makeTempDir("s8")
    let persona = hermeticPersona(root: dir)
    let llm = StreamingMessagesCapturingLLM(scriptedEvents: events)
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let deltas = DeltaTextCapture()
    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "read then search",
        llm: llm,
        tools: tools,
        progress: { event in await deltas.append(event) }
    )

    #expect(result.toolDispatches.map(\.name) == ["read_file", "search_kg"])
    #expect(llm.messagesByCall.count == 3)

    // All three segments present…
    #expect(result.reply.contains(first))
    #expect(result.reply.contains(second))
    #expect(result.reply.contains(third))
    // …and in order.
    let i1 = try #require(result.reply.range(of: first))
    let i2 = try #require(result.reply.range(of: second))
    let i3 = try #require(result.reply.range(of: third))
    #expect(i1.upperBound <= i2.lowerBound)
    #expect(i2.upperBound <= i3.lowerBound)
    // The core contract: what the user SAW is what gets PERSISTED.
    let streamed = await deltas.snapshot()
    #expect(streamed == result.reply)
    #expect(result.reply == first + second + third)
}

// MARK: - S6: legacy id-less markers (synthesized ids)

@Test
func appendOnlyQA_S6_legacyIdlessMarkers_equivalent_across_lever() async throws {
    let calls = [
        #"<tool_use name="read_file">{"path":"legacy"}</tool_use>"#,
        #"<tool_use name="read_file">{"path":"legacy2"}</tool_use>"#,
    ]
    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: ["read_file": .string("legacy-body")])
    }
    let new = try await runNonStreamingScenario(
        tag: "s6-new", scriptedResponses: calls + ["legacy done"],
        tools: freshTools(), userMessage: "legacy markers", grownPromptCompat: false
    )
    let old = try await runNonStreamingScenario(
        tag: "s6-old", scriptedResponses: calls + ["legacy done"],
        tools: freshTools(), userMessage: "legacy markers", grownPromptCompat: true
    )
    expectEquivalent(new, old, scenario: "S6")
    #expect(new.reply == "legacy done")
    expectAppendOnly(new.messagesByCall)
    // Synthesized ids pair assistant toolUse ↔ user toolResult by position.
    let finalCall = try #require(new.messagesByCall.last)
    var useIds: [String] = []
    var resultIds: [String] = []
    for msg in finalCall {
        for block in msg.content {
            if case .toolUse(let id, _, _) = block { useIds.append(id) }
            if case .toolResult(let id, _, _) = block { resultIds.append(id) }
        }
    }
    #expect(useIds == resultIds)
    #expect(useIds.allSatisfy { $0.hasPrefix("toolu_synth_") })
}

// MARK: - S7: formatted pseudo-calls bounce before streaming or dispatch

@Test
func appendOnlyQA_S7_streamingFormattedCallsBounce_acrossLever() async throws {
    let pseudo = """
    **Tool Call: read_file**
    ```json
    {"path":"secret.txt"}
    ```
    """
    let fenced = """
    ```xml
    <tool_use name="read_file">{"path":"secret.txt"}</tool_use>
    ```
    """
    let bare = #"<tool_use name="read_file">{"path":"secret.txt"}</tool_use>"#
    let events: [[LLMMessageStreamEvent]] = [
        pseudo.map { .textDelta(String($0)) },
        fenced.map { .textDelta(String($0)) },
        bare.map { .textDelta(String($0)) },
        "clean final".map { .textDelta(String($0)) },
    ]
    func freshTools() -> MockToolDispatchClient {
        MockToolDispatchClient(scripted: ["read_file": .string("REAL")])
    }

    let new = try await runStreamingScenario(
        tag: "s7-new",
        scriptedEvents: events,
        tools: freshTools(),
        userMessage: "read it",
        grownPromptCompat: false
    )
    let old = try await runStreamingScenario(
        tag: "s7-old",
        scriptedEvents: events,
        tools: freshTools(),
        userMessage: "read it",
        grownPromptCompat: true
    )

    expectEquivalent(new, old, scenario: "S7")
    #expect(new.reply == "clean final")
    #expect(new.dispatchNames == ["read_file"])
    #expect(new.messagesByCall.count == 4)
    #expect(new.eventShapes == ["toolUse:read_file", "toolResult:read_file:\"REAL\"", "delta"])

    // The next provider call sees the rejected assistant output plus a
    // runtime-authored error, but no tool-result message exists because no
    // formatted call was executed.
    let afterPseudo = try #require(new.messagesByCall.dropFirst().first)
    #expect(afterPseudo.count == 3)
    #expect(afterPseudo[1].role == .assistant)
    #expect(afterPseudo[2].role == .user)
    #expect(afterPseudo[2].content.contains { block in
        if case .text(let text) = block { return text.contains("tool protocol error") }
        return false
    })
}

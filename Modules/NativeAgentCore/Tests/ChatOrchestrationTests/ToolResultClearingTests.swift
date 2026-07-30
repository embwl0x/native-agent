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

// MARK: - U1 step 5: intra-turn tool-result clearing
//
// (a) 10-iteration synthetic non-streaming loop: results 1-4 stubbed on the
//     final LLM call's in-flight messages, 5-10 full (exactly-5 is the
//     keep-window boundary: current + keepFullIterations=5 priors).
// (b) streaming variant of (a).
// (c) the ENGINE's persistence-facing surfaces (TurnEngineResult
//     .toolDispatches + progress .toolResult events — the inputs
//     ChatOrchestrationClient.appendMessage persists from) carry full
//     bodies, byte-identical to a control built from the scripted bodies.
//     This does NOT drive ChatOrchestrationClient's actual disk writes;
//     it proves the engine never feeds persistence from the in-flight
//     array the sweep rewrites.
// Plus unit tests pinning the exact stub format, the never-grow guard, and
// marker idempotence (terminal-marker structure match, not
// substring-anywhere).

// MARK: - Test helpers

private func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolclear-\(tag)-\(UUID().uuidString)", isDirectory: true)
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

/// Non-streaming mock that captures the FULL messages array per
/// completeMessages call — the assertion surface for clearing.
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

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        ""
    }

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

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        ""
    }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let idx: Int = {
            lock.lock()
            defer { lock.unlock() }
            let idx = _messagesByCall.count
            _messagesByCall.append(messages)
            return idx
        }()
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

private actor ProgressResultCapture {
    private var results: [(name: String, output: JSONValue)] = []
    func append(name: String, output: JSONValue) {
        results.append((name, output))
    }
    func snapshot() -> [(name: String, output: JSONValue)] {
        results
    }
}

/// Distinct, recognizable long body per iteration (> stub size so clearing
/// actually fires; the never-grow guard keeps short bodies as-is).
private func longBody(_ i: Int) -> String {
    "result-\(i)-" + String(repeating: "x\(i)", count: 300)
}

private func toolResultUserMessages(_ messages: [LLMMessage]) -> [LLMMessage] {
    messages.filter { msg in
        msg.role == .user && msg.content.contains { block in
            if case .toolResult = block { return true }
            return false
        }
    }
}

private func soleToolResultContent(_ message: LLMMessage) -> String? {
    for block in message.content {
        if case .toolResult(_, let content, _) = block { return content }
    }
    return nil
}

private func expectedStub(_ body: String) -> String {
    String(body.prefix(180))
        + "\n[cleared: full result was \(body.count) chars; re-run the tool if needed]"
}

// MARK: - Stub format unit tests

@Test
func providerToolResultProjection_capsGitHubAndSubprocessResultsAsValidJSON() async throws {
    let source = "HEAD" + String(repeating: "\"quoted\"\n", count: 30_000) + "TAIL"
    for tool in ["github_search", "invoke_codex", "invoke_claude"] {
        let projected = await ProviderToolResultProjection.project(toolName: tool, content: source)
        #expect(projected.utf8.count <= ProviderToolResultProjection.compactMaxUTF8Bytes)
        let parsed = try JSONValue.parse(Data(projected.utf8))
        guard case .object(let object) = parsed else {
            Issue.record("provider projection was not valid JSON")
            continue
        }
        #expect(object["provider_projection"] == .string("bounded_tool_result"))
        #expect(object["original_characters"] == .int(Int64(source.count)))
        if case .string(let head)? = object["preview_head"] { #expect(head.hasPrefix("HEAD")) }
        if case .string(let tail)? = object["preview_tail"] { #expect(tail.hasSuffix("TAIL")) }
    }
}

@Test
func providerToolResultProjection_preservesShortResultsAndBoundsOtherTools() async throws {
    #expect(await ProviderToolResultProjection.project(toolName: "github_search", content: "ok") == "ok")
    let source = String(repeating: "x", count: 100_000)
    let projected = await ProviderToolResultProjection.project(toolName: "read_file", content: source)
    #expect(projected.utf8.count <= ProviderToolResultProjection.defaultMaxUTF8Bytes)
    #expect(try JSONValue.parse(Data(projected.utf8)) != .null)
}

@Test
func providerToolResultProjection_boundsOneHugeUnicodeGraphemeByUTF8Bytes() async throws {
    let source = "e" + String(repeating: "\u{301}", count: 50_000)
    #expect(source.count == 1)
    let projected = await ProviderToolResultProjection.project(
        toolName: "github_search",
        content: source
    )
    #expect(projected.utf8.count <= ProviderToolResultProjection.compactMaxUTF8Bytes)
    let parsed = try JSONValue.parse(Data(projected.utf8))
    guard case .object(let object) = parsed else {
        Issue.record("byte-bounded Unicode projection was not valid JSON")
        return
    }
    #expect(object["original_bytes"] == .int(Int64(source.utf8.count)))
}

@Test
func providerToolResultProjection_retainsEveryPageWithinTheSameTurnOnly() async throws {
    await ProviderToolResultRecoveryStore.shared.resetForTests()
    defer { Task { await ProviderToolResultRecoveryStore.shared.resetForTests() } }

    let sessionId = "recovery-session"
    let turnId = "recovery-turn"
    let source = "HEAD|" + String(
        repeating: "0123456789abcdef\u{1F642}e\u{301}",
        count: 3_000
    ) + "|TAIL"
    let projected = await ProviderToolResultProjection.project(
        toolName: "github_search",
        content: source,
        sessionId: sessionId,
        turnId: turnId
    )
    let parsed = try JSONValue.parse(Data(projected.utf8))
    guard case .object(let projection) = parsed,
          case .string(let handle)? = projection["result_handle"],
          case .int(let pageCountRaw)? = projection["page_count"] else {
        Issue.record("projection did not expose a recovery handle")
        return
    }
    #expect(projection["full_result_retained"] == .bool(true))

    // 2026-07-21 audit: a bare SwiftToolDispatcher() resolves the shared
    // live-root stores (active tools, memory); pin it to a temp root. The
    // recovery payload itself lives in the process-global
    // ProviderToolResultRecoveryStore this test already resets.
    let dispatcherRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolresult-dispatcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dispatcherRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dispatcherRoot) }
    let dispatcher = SwiftToolDispatcher(dataRoot: dispatcherRoot)
    var rebuilt = ""
    let pageCount = Int(pageCountRaw)
    for page in 0..<pageCount {
        let value = await TurnTraceContext.$turnId.withValue(turnId) {
            try? await dispatcher.dispatch(
                tool: "tool_result_page",
                input: [
                    "result_handle": .string(handle),
                    "page": .int(Int64(page)),
                    "__session_id": .string(sessionId),
                ],
                surface: "chat"
            )
        }
        guard case .object(let object)? = value,
              case .string(let content)? = object["content"] else {
            Issue.record("recovery page \(page) was unavailable")
            return
        }
        rebuilt += content
    }
    #expect(rebuilt == source)

    let crossSession = await TurnTraceContext.$turnId.withValue(turnId) {
        try? await dispatcher.dispatch(
            tool: "tool_result_page",
            input: [
                "result_handle": .string(handle),
                "page": .int(0),
                "__session_id": .string("different-session"),
            ],
            surface: "chat"
        )
    }
    guard case .object(let denied)? = crossSession else {
        Issue.record("cross-session recovery returned an unexpected shape")
        return
    }
    #expect(denied["reason"] == .string("result_handle_unavailable"))
}

@Test
func intraTurnClearing_stub_format_is_exact_180_head_plus_marker() async throws {
    let body = longBody(1)
    let stubbed = try #require(IntraTurnToolResultClearing.stub(body))
    #expect(stubbed == expectedStub(body))
    #expect(stubbed.count < body.count)
}

@Test
func intraTurnClearing_keep_window_constant_holds_the_N5_floor() async throws {
    // the user's hard constraint: N=5 floor — lowering this is a capability cut.
    #expect(IntraTurnToolResultClearing.keepFullIterations >= 5)
}

@Test
func intraTurnClearing_stub_never_grows_short_bodies() async throws {
    // Typical tiny tool results must be left alone — stubbing "ok" would
    // GROW the payload.
    #expect(IntraTurnToolResultClearing.stub("ok") == nil)
    #expect(IntraTurnToolResultClearing.stub(String(repeating: "a", count: 180)) == nil)
}

@Test
func intraTurnClearing_stub_is_idempotent_via_marker() async throws {
    let body = longBody(2)
    let once = try #require(IntraTurnToolResultClearing.stub(body))
    #expect(IntraTurnToolResultClearing.stub(once) == nil)
}

@Test
func intraTurnClearing_original_body_mentioning_marker_phrase_is_still_cleared() async throws {
    // Review fix (2026-06-10): the sentinel is a terminal-marker STRUCTURE
    // match, not substring-anywhere — an ORIGINAL tool result that merely
    // contains the marker phrase mid-body (e.g. a log of a prior cleared
    // transcript) must still be cleared.
    let body = "log line: "
        + IntraTurnToolResultClearing.clearedMarkerPrefix
        + "999"
        + IntraTurnToolResultClearing.clearedMarkerSuffix
        + "\ntrailing original content "
        + longBody(3)
    #expect(!IntraTurnToolResultClearing.isAlreadyStubbed(body))
    let stubbed = try #require(IntraTurnToolResultClearing.stub(body))
    #expect(stubbed.hasSuffix(IntraTurnToolResultClearing.clearedMarkerSuffix))
    // And the resulting stub IS recognized — next sweep leaves it alone.
    #expect(IntraTurnToolResultClearing.isAlreadyStubbed(stubbed))
    #expect(IntraTurnToolResultClearing.stub(stubbed) == nil)
}

@Test
func intraTurnClearing_sentinel_requires_exact_terminal_marker_structure() async throws {
    // Ends with the suffix but the last line is not our marker line.
    #expect(!IntraTurnToolResultClearing.isAlreadyStubbed(
        "some result" + IntraTurnToolResultClearing.clearedMarkerSuffix
    ))
    // Prefix + NON-decimal count + suffix is not our marker.
    #expect(!IntraTurnToolResultClearing.isAlreadyStubbed(
        "head\n" + IntraTurnToolResultClearing.clearedMarkerPrefix
            + "many" + IntraTurnToolResultClearing.clearedMarkerSuffix
    ))
    // The real shape is.
    #expect(IntraTurnToolResultClearing.isAlreadyStubbed(
        "head\n" + IntraTurnToolResultClearing.clearedMarkerPrefix
            + "1234" + IntraTurnToolResultClearing.clearedMarkerSuffix
    ))
}

// MARK: - (a) 10-iteration synthetic loop, non-streaming

@Test
func toolLoop_10_iterations_stubs_results_1_to_4_keeps_5_to_10_full() async throws {
    // Keep-window boundary: current (10) + keepFullIterations=5 priors
    // (5-9) stay full — so exactly-5 is the FIRST kept iteration.
    let dir = try makeTempDir("ten-iter")
    let persona = SwiftNativePersonaEngine(root: dir)
    let calls = (1...10).map { i in
        #"{"tool_calls":[{"id":"c\#(i)","type":"function","function":{"name":"t\#(i)","arguments":"{}"}}]}"#
    }
    let llm = MessagesCapturingLLM(scriptedResponses: calls + ["final answer"])
    var scripted: [String: JSONValue] = [:]
    for i in 1...10 { scripted["t\(i)"] = .string(longBody(i)) }
    let tools = MockToolDispatchClient(scripted: scripted)
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    // U1 item 8 (review fix): clearing fires ONLY in compat mode — in the
    // default shape the trailing-message breakpoint caches the prefix and
    // stubbing would torch it. This test pins COMPAT-mode semantics.
    let result = try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(true) {
            try await engine.executeTurnWithToolLoop(
                userMessage: "run all ten", llm: llm, tools: tools
            )
        }
    #expect(result.reply == "final answer")
    #expect(result.toolDispatches.count == 10)

    let captured = llm.messagesByCall
    #expect(captured.count == 11)
    let finalCallMessages = try #require(captured.last)
    // Append-consistency: 1 initial user + 10 x (assistant + tool-result user).
    #expect(finalCallMessages.count == 21)
    let resultMessages = toolResultUserMessages(finalCallMessages)
    #expect(resultMessages.count == 10)

    for (idx, msg) in resultMessages.enumerated() {
        let iteration = idx + 1
        let content = try #require(soleToolResultContent(msg))
        let original = longBody(iteration)
        if iteration <= 4 {
            #expect(content == expectedStub(original), "iteration \(iteration) should be stubbed")
        } else {
            // Current (10) + last 5 prior (5-9) stay FULL.
            #expect(content == original, "iteration \(iteration) should be full")
        }
    }
}

@Test
func toolLoop_within_keep_window_nothing_is_stubbed() async throws {
    let dir = try makeTempDir("six-iter")
    let persona = SwiftNativePersonaEngine(root: dir)
    let calls = (1...6).map { i in
        #"{"tool_calls":[{"id":"c\#(i)","type":"function","function":{"name":"t\#(i)","arguments":"{}"}}]}"#
    }
    let llm = MessagesCapturingLLM(scriptedResponses: calls + ["done"])
    var scripted: [String: JSONValue] = [:]
    for i in 1...6 { scripted["t\(i)"] = .string(longBody(i)) }
    let tools = MockToolDispatchClient(scripted: scripted)
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    _ = try await engine.executeTurnWithToolLoop(
        userMessage: "run six", llm: llm, tools: tools
    )
    let finalCallMessages = try #require(llm.messagesByCall.last)
    let resultMessages = toolResultUserMessages(finalCallMessages)
    #expect(resultMessages.count == 6)
    for (idx, msg) in resultMessages.enumerated() {
        let content = try #require(soleToolResultContent(msg))
        #expect(content == longBody(idx + 1), "iteration \(idx + 1) must stay full inside the keep window")
    }
}

// MARK: - (b) streaming variant

@Test
func streamingToolLoop_10_iterations_stubs_results_1_to_4_keeps_5_to_10_full() async throws {
    // Same exactly-5 keep-window boundary as the non-streaming sibling.
    let dir = try makeTempDir("ten-iter-stream")
    let persona = SwiftNativePersonaEngine(root: dir)
    var events: [[LLMMessageStreamEvent]] = (1...10).map { i in
        [.toolCall(LLMStreamToolCall(id: "c\(i)", name: "t\(i)", inputJSON: Data("{}".utf8)))]
    }
    events.append([.textDelta("final answer")])
    let llm = StreamingMessagesCapturingLLM(scriptedEvents: events)
    var scripted: [String: JSONValue] = [:]
    for i in 1...10 { scripted["t\(i)"] = .string(longBody(i)) }
    let tools = MockToolDispatchClient(scripted: scripted)
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    // U1 item 8 (review fix): compat-mode pin — see the non-streaming
    // sibling test's comment.
    let result = try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(true) {
            try await engine.executeTurnWithStreamingToolLoop(
                userMessage: "run all ten", llm: llm, tools: tools
            )
        }
    #expect(result.reply == "final answer")
    #expect(result.toolDispatches.count == 10)

    let captured = llm.messagesByCall
    #expect(captured.count == 11)
    let finalCallMessages = try #require(captured.last)
    #expect(finalCallMessages.count == 21)
    let resultMessages = toolResultUserMessages(finalCallMessages)
    #expect(resultMessages.count == 10)

    for (idx, msg) in resultMessages.enumerated() {
        let iteration = idx + 1
        let content = try #require(soleToolResultContent(msg))
        let original = longBody(iteration)
        if iteration <= 4 {
            #expect(content == expectedStub(original), "iteration \(iteration) should be stubbed")
        } else {
            #expect(content == original, "iteration \(iteration) should be full")
        }
    }
}

// MARK: - (c) engine persistence-facing surfaces carry full bodies

@Test
func toolLoop_clearing_keeps_engine_persistence_surfaces_byte_identical() async throws {
    // Scope: this exercises the ENGINE's persistence-facing surfaces only —
    // TurnEngineResult.toolDispatches and progress .toolResult events, the
    // inputs ChatOrchestrationClient.appendMessage persists from. It does
    // NOT drive ChatOrchestrationClient's actual disk writes. What it
    // proves: the engine never feeds those surfaces from the loop's
    // in-flight conversation array (the thing the sweep rewrites).
    // Serialize both surfaces to JSONL files and compare bytes against a
    // control built straight from the scripted full bodies.
    let dir = try makeTempDir("persist")
    let persona = SwiftNativePersonaEngine(root: dir)
    let calls = (1...10).map { i in
        #"{"tool_calls":[{"id":"c\#(i)","type":"function","function":{"name":"t\#(i)","arguments":"{}"}}]}"#
    }
    let llm = MessagesCapturingLLM(scriptedResponses: calls + ["final"])
    var scripted: [String: JSONValue] = [:]
    for i in 1...10 { scripted["t\(i)"] = .string(longBody(i)) }
    let tools = MockToolDispatchClient(scripted: scripted)
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let capture = ProgressResultCapture()

    // U1 item 8 (review fix): compat-mode pin — the sweep must be ACTIVE
    // for this test to prove persistence isolation from the rewritten
    // array (in the default shape nothing rewrites, so the pin would be
    // vacuous).
    let result = try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(true) {
            try await engine.executeTurnWithToolLoop(
                userMessage: "run all ten",
                llm: llm,
                tools: tools,
                progress: { event in
                    if case .toolResult(let name, let output) = event {
                        await capture.append(name: name, output: output)
                    }
                }
            )
        }
    #expect(result.toolDispatches.count == 10)

    func jsonlLine(role: String, content: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["role": role, "content": content],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    // Control: what persistence WOULD write from the raw scripted bodies.
    let controlLines = try (1...10).map { try jsonlLine(role: "tool", content: longBody($0)) }
    let controlFile = dir.appendingPathComponent("control.jsonl")
    try Data((controlLines.joined(separator: "\n") + "\n").utf8).write(to: controlFile)

    // Actual: the same lines built from the loop's persistence-feeding
    // surface (dispatch records), with the feature active.
    let actualLines = try result.toolDispatches.map { record -> String in
        guard case .string(let s) = record.result else {
            throw NSError(domain: "test", code: 1)
        }
        return try jsonlLine(role: "tool", content: s)
    }
    let actualFile = dir.appendingPathComponent("actual.jsonl")
    try Data((actualLines.joined(separator: "\n") + "\n").utf8).write(to: actualFile)

    let controlBytes = try Data(contentsOf: controlFile)
    let actualBytes = try Data(contentsOf: actualFile)
    #expect(controlBytes == actualBytes)

    // Progress events (the streaming persistence feed) carry full bodies too.
    let progressResults = await capture.snapshot()
    #expect(progressResults.count == 10)
    for (idx, entry) in progressResults.enumerated() {
        #expect(entry.output == .string(longBody(idx + 1)))
    }

    // No cleared marker anywhere near persistence.
    for record in result.toolDispatches {
        if case .string(let s) = record.result {
            #expect(!s.contains(IntraTurnToolResultClearing.clearedMarkerPrefix))
        }
    }
}

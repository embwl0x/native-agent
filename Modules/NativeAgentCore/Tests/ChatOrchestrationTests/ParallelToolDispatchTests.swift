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

// MARK: - U1 step 6 — parallel dispatch of independent tool calls
//
// Covers: safe-set predicate, iteration planning, original-index
// reassembly, the concurrency cap, mixed-batch group ordering, per-slot
// failure isolation, turn cancellation, the serial-fallback rollback
// lever, and the step-5 (intra-turn clearing) interaction.

// MARK: - Helpers

private func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ptd-\(tag)-\(UUID().uuidString)", isDirectory: true)
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

/// LLM mock that captures the full messages array of every completeMessages
/// call so tests can assert the provider-visible wire shape (tool_use /
/// tool_result block order + id pairing).
private final class MessagesCapturingLLM: LLMClient, @unchecked Sendable {
    private let scripted: [String]
    private let lock = NSLock()
    private var _capturedMessages: [[LLMMessage]] = []

    var capturedMessages: [[LLMMessage]] {
        lock.lock(); defer { lock.unlock() }
        return _capturedMessages
    }
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _capturedMessages.count
    }

    init(scripted: [String]) { self.scripted = scripted }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        next([])
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        next(messages)
    }

    private func next(_ messages: [LLMMessage]) -> String {
        lock.lock()
        _capturedMessages.append(messages)
        let idx = _capturedMessages.count - 1
        lock.unlock()
        guard !scripted.isEmpty else { return "" }
        return scripted[min(idx, scripted.count - 1)]
    }
}

/// Dispatcher instrumented with start/end event ordering, an in-flight
/// high-water mark, optional per-tool delays, and per-tool throws.
private final class InstrumentedToolDispatch: ToolDispatchClient, @unchecked Sendable {
    struct Boom: Error {}
    struct Event: Equatable {
        let tool: String
        let phase: String  // "start" | "end"
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _startedCount = 0

    private let scripted: [String: JSONValue]
    private let delaysNs: [String: UInt64]
    private let throwing: Set<String>

    init(
        scripted: [String: JSONValue],
        delaysNs: [String: UInt64] = [:],
        throwing: Set<String> = []
    ) {
        self.scripted = scripted
        self.delaysNs = delaysNs
        self.throwing = throwing
    }

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }
    var maxInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return _maxInFlight
    }
    var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startedCount
    }

    private func recordStart(_ tool: String) {
        lock.lock()
        _events.append(Event(tool: tool, phase: "start"))
        _startedCount += 1
        _inFlight += 1
        _maxInFlight = max(_maxInFlight, _inFlight)
        lock.unlock()
    }

    private func recordEnd(_ tool: String) {
        lock.lock()
        _events.append(Event(tool: tool, phase: "end"))
        _inFlight -= 1
        lock.unlock()
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        recordStart(tool)
        defer { recordEnd(tool) }
        if let delay = delaysNs[tool] {
            try await Task.sleep(nanoseconds: delay)
        }
        if throwing.contains(tool) { throw Boom() }
        return scripted[tool] ?? .null
    }

    func listAvailableTools() async throws -> [String] { scripted.keys.sorted() }

    /// Index of the first event matching tool+phase, or nil.
    func eventIndex(tool: String, phase: String) -> Int? {
        events.firstIndex(of: Event(tool: tool, phase: phase))
    }
}

/// OpenAI-shape batch response for N (id, name) pairs.
private func openAIBatch(_ calls: [(id: String, name: String)]) -> String {
    let items = calls.map {
        #"{"id":"\#($0.id)","type":"function","function":{"name":"\#($0.name)","arguments":"{}"}}"#
    }
    return #"{"tool_calls":[\#(items.joined(separator: ","))]}"#
}

// MARK: - Safe-set predicate

@Test
func parallelSafe_readOnlyTools_areSafe() {
    for name in [
        "read_file", "list_dir", "recall_memory", "search_kg",
        "search_chat_history", "session_search", "mail_search", "x_search",
        "get_persona_doc", "persona_read", "scratchpad_read",
        "mac_calendar_list_upcoming", "mail_list_recent", "market_status",
        // allowlisted read-only names without a read keyword:
        "time_now", "agent_introspect", "daemon_introspect", "web_fetch",
        "recent_trace_summary", "music_now_playing", "market_quote",
    ] {
        #expect(ParallelToolDispatch.isParallelSafe(internalToolName: name),
                "expected \(name) parallel-safe")
    }
}

@Test
func parallelSafe_writeShellMacWriteGatedAndUnknown_areSerial() {
    for name in [
        // write class
        "write_file", "persona_write", "persona_append_section",
        "notes_create", "mac_calendar_create_event", "contacts_delete",
        "trash_file", "move_file",
        // shell / process class (Full-Mac surface)
        "shell", "bash", "git", "apply_patch", "run_tests",
        "swift_build", "swift_test",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
        "system_info", "grep", "file_excerpt", "restart_app", "install_app",
        "mac_focus_app", "mac_quit_app",
        // Mac-Integration write mode (gate-table derived)
        "mail_send", "messages_send", "music_control",
        "mac_reminders_complete", "mail_archive",
        // external send keyword class
        "messages_recent_threads", "mail_reply", "claude_message",
        // session-state mutators + subprocess spawners
        "tool_load", "tool_unload", "agent_swarm",
        "invoke_claude", "invoke_codex",
        // notify channels
        "mac_notify", "mobile_notify",
        // MCP — side effects unknowable
        "mcp__some-server__lookup_thing",
        // no positive read signal → fail closed
        "echo", "alpha", "context_lookup",
    ] {
        #expect(!ParallelToolDispatch.isParallelSafe(internalToolName: name),
                "expected \(name) serial")
    }
}

@Test
func parallelSafe_fullMacLists_areEntirelySerial() {
    // Rule 2 is derived from the dispatcher constants — every member of
    // every Full-Mac list must classify serial, whatever its name says.
    let all = SwiftToolDispatcher.fullMacFileToolNames
        + SwiftToolDispatcher.fullMacSystemToolNames
        + SwiftToolDispatcher.fullMacAppToolNames
        + SwiftToolDispatcher.fullMacBuilderToolNames
        + SwiftToolDispatcher.fullMacRestartToolNames
    for name in all {
        #expect(!ParallelToolDispatch.isParallelSafe(internalToolName: name))
    }
}

@Test
func parallelSafe_macIntegrationWriteModeTable_isEntirelySerial() {
    for (name, gate) in ToolPreloadHeuristics.macIntegrationGates
    where gate.mode == .write {
        #expect(!ParallelToolDispatch.isParallelSafe(internalToolName: name))
    }
    // Named regression (gpt-5.5 review, 2026-06-10): scheduler_list_jobs
    // gates on .write (scheduler has no read axis) but its "list" name
    // walked the positive read-signal branch into the parallel set while
    // the gates table lacked scheduler entries. The table is now pinned
    // complete by macIntegrationGateTableMatchesDispatchContract; this
    // asserts the veto outcome directly.
    #expect(!ParallelToolDispatch.isParallelSafe(internalToolName: "scheduler_list_jobs"))
    #expect(!ParallelToolDispatch.isParallelSafe(internalToolName: "mac_notify"))
}

// MARK: - Planning + rollback lever

@Test
func plan_coalescesConsecutiveSafeRuns_andIsolatesUnsafeSlots() {
    // [safe safe] [unsafe] [safe] [unsafe] [safe safe safe]
    let groups = ParallelToolDispatch.plan(
        parallelSafe: [true, true, false, true, false, true, true, true],
        forceSerial: false
    )
    #expect(groups == [
        .concurrent([0, 1]),
        .sequential(2),
        .sequential(3),  // lone safe call stays sequential (serial event order)
        .sequential(4),
        .concurrent([5, 6, 7]),
    ])
}

@Test
func plan_forceSerial_yieldsOnlySequentialSlots() {
    let groups = ParallelToolDispatch.plan(
        parallelSafe: [true, true, true],
        forceSerial: true
    )
    #expect(groups == [.sequential(0), .sequential(1), .sequential(2)])
}

@Test
func serialFallback_envFlagParsing() {
    let key = ParallelToolDispatch.serialFallbackEnvVar
    #expect(ParallelToolDispatch.isSerialFallbackForced(env: [key: "1"]))
    #expect(ParallelToolDispatch.isSerialFallbackForced(env: [key: "true"]))
    #expect(ParallelToolDispatch.isSerialFallbackForced(env: [key: "YES"]))
    #expect(ParallelToolDispatch.isSerialFallbackForced(env: [key: " on "]))
    #expect(!ParallelToolDispatch.isSerialFallbackForced(env: [key: "0"]))
    #expect(!ParallelToolDispatch.isSerialFallbackForced(env: [key: "false"]))
    #expect(!ParallelToolDispatch.isSerialFallbackForced(env: [key: ""]))
    #expect(!ParallelToolDispatch.isSerialFallbackForced(env: [:]))
}

// MARK: - Loop behavior

@Test
func parallelBatch_resultsReassembleInOriginalIndexOrder() async throws {
    let dir = try makeTempDir("reassembly")
    let persona = hermeticPersona(root: dir)
    // First call is the SLOWEST — completion order is the reverse of issue
    // order, so passing this test requires index-ordered reassembly.
    let tools = InstrumentedToolDispatch(
        scripted: [
            "recall_memory": .string("memory-result"),
            "read_file": .string("file-result"),
            "search_kg": .string("kg-result"),
        ],
        delaysNs: [
            "recall_memory": 120_000_000,
            "read_file": 60_000_000,
            "search_kg": 5_000_000,
        ]
    )
    let batch = openAIBatch([
        (id: "c1", name: "recall_memory"),
        (id: "c2", name: "read_file"),
        (id: "c3", name: "search_kg"),
    ])
    let llm = MessagesCapturingLLM(scripted: [batch, "done"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "fetch all three", llm: llm, tools: tools
    )

    #expect(result.reply == "done")
    #expect(result.toolDispatches.map(\.name) == ["recall_memory", "read_file", "search_kg"])
    #expect(result.toolDispatches.map(\.result) == [
        .string("memory-result"), .string("file-result"), .string("kg-result"),
    ])
    // It actually ran concurrently (the slow first call overlapped a sibling).
    #expect(tools.maxInFlight >= 2)

    // Provider wire shape on the SECOND call: assistant tool_use ids and the
    // single tool_result user message must both be in original order with
    // matched ids — out-of-order or interleaved results are a protocol
    // violation on both providers.
    let second = llm.capturedMessages[1]
    #expect(second.count == 3)  // user, assistant(tool_use x3), user(tool_result x3)
    let assistantBlocks = second[1].content
    let toolUseIds: [String] = assistantBlocks.compactMap {
        if case .toolUse(let id, _, _) = $0 { return id }
        return nil
    }
    #expect(toolUseIds == ["c1", "c2", "c3"])
    let resultBlocks = second[2].content
    let resultPairs: [(String, String)] = resultBlocks.compactMap {
        if case .toolResult(let id, let content, _) = $0 { return (id, content) }
        return nil
    }
    #expect(resultPairs.map(\.0) == ["c1", "c2", "c3"])
    #expect(resultPairs.map(\.1) == ["memory-result", "file-result", "kg-result"])
}

@Test
func parallelBatch_respectsConcurrencyCapOfFour() async throws {
    let dir = try makeTempDir("cap")
    let persona = hermeticPersona(root: dir)
    let names = [
        "read_file", "list_dir", "search_kg",
        "recall_memory", "session_search", "mail_search",
    ]
    let tools = InstrumentedToolDispatch(
        scripted: Dictionary(uniqueKeysWithValues: names.map { ($0, JSONValue.string("ok-\($0)")) }),
        delaysNs: Dictionary(uniqueKeysWithValues: names.map { ($0, UInt64(60_000_000)) })
    )
    let batch = openAIBatch(names.enumerated().map { (id: "c\($0.offset)", name: $0.element) })
    let llm = MessagesCapturingLLM(scripted: [batch, "done"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "fan out", llm: llm, tools: tools
    )

    #expect(result.reply == "done")
    #expect(result.toolDispatches.map(\.name) == names)
    #expect(tools.startedCount == 6)
    #expect(tools.maxInFlight <= ParallelToolDispatch.maxConcurrentPerIteration)
    #expect(tools.maxInFlight >= 2)
}

@Test
func mixedBatch_serialSlotNeverOverlapsNeighboringGroups_orderPreserved() async throws {
    let dir = try makeTempDir("mixed")
    let persona = hermeticPersona(root: dir)
    // [read_file, search_kg] parallel → write_file serial → [recall_memory,
    // list_dir] parallel. Groups must run strictly in order.
    let tools = InstrumentedToolDispatch(
        scripted: [
            "read_file": .string("r"), "search_kg": .string("s"),
            "write_file": .string("w"),
            "recall_memory": .string("m"), "list_dir": .string("l"),
        ],
        delaysNs: ["read_file": 30_000_000, "search_kg": 15_000_000]
    )
    let batch = openAIBatch([
        (id: "c1", name: "read_file"),
        (id: "c2", name: "search_kg"),
        (id: "c3", name: "write_file"),
        (id: "c4", name: "recall_memory"),
        (id: "c5", name: "list_dir"),
    ])
    let llm = MessagesCapturingLLM(scripted: [batch, "done"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "mixed batch", llm: llm, tools: tools
    )

    // Result/record order is the ORIGINAL index order regardless of groups.
    #expect(result.toolDispatches.map(\.name)
            == ["read_file", "search_kg", "write_file", "recall_memory", "list_dir"])

    // The write-class slot starts only after BOTH reads ended, and the
    // trailing parallel group starts only after the write ended.
    let writeStart = try #require(tools.eventIndex(tool: "write_file", phase: "start"))
    let writeEnd = try #require(tools.eventIndex(tool: "write_file", phase: "end"))
    let readEnd = try #require(tools.eventIndex(tool: "read_file", phase: "end"))
    let kgEnd = try #require(tools.eventIndex(tool: "search_kg", phase: "end"))
    let memStart = try #require(tools.eventIndex(tool: "recall_memory", phase: "start"))
    let listStart = try #require(tools.eventIndex(tool: "list_dir", phase: "start"))
    #expect(writeStart > readEnd)
    #expect(writeStart > kgEnd)
    #expect(memStart > writeEnd)
    #expect(listStart > writeEnd)

    // Wire shape: one tool_result user message, ids in original order.
    let second = llm.capturedMessages[1]
    let resultIds: [String] = second[2].content.compactMap {
        if case .toolResult(let id, _, _) = $0 { return id }
        return nil
    }
    #expect(resultIds == ["c1", "c2", "c3", "c4", "c5"])
}

@Test
func parallelBatch_oneFailureIsIsolated_siblingsAndOrderIntact() async throws {
    let dir = try makeTempDir("failure")
    let persona = hermeticPersona(root: dir)
    let tools = InstrumentedToolDispatch(
        scripted: ["read_file": .string("r-ok"), "search_kg": .string("s-ok")],
        delaysNs: ["read_file": 40_000_000, "search_kg": 40_000_000],
        throwing: ["list_dir"]
    )
    let batch = openAIBatch([
        (id: "c1", name: "read_file"),
        (id: "c2", name: "list_dir"),
        (id: "c3", name: "search_kg"),
    ])
    let llm = MessagesCapturingLLM(scripted: [batch, "recovered"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "one will fail", llm: llm, tools: tools
    )

    // The throw became slot 2's error-object result — exactly the serial
    // contract — and didn't cancel the siblings or the turn.
    #expect(result.reply == "recovered")
    #expect(result.toolDispatches.map(\.name) == ["read_file", "list_dir", "search_kg"])
    #expect(result.toolDispatches[0].result == .string("r-ok"))
    if case .object(let o) = result.toolDispatches[1].result {
        #expect(o["error"] != nil)
    } else {
        Issue.record("expected error object in failed slot")
    }
    #expect(result.toolDispatches[2].result == .string("s-ok"))
    #expect(tools.startedCount == 3)

    // The failed slot's tool_result block carries isError.
    let second = llm.capturedMessages[1]
    let errorFlags: [Bool] = second[2].content.compactMap {
        if case .toolResult(_, _, let isError) = $0 { return isError }
        return nil
    }
    #expect(errorFlags == [false, true, false])
}

@Test
func parallelBatch_turnCancellation_cancelsInFlightChildren() async throws {
    let dir = try makeTempDir("cancel")
    let persona = hermeticPersona(root: dir)
    // Children sleep 5s; the test cancels the turn once 2+ are in flight.
    // Task.sleep throws CancellationError on cancel → each slot resolves to
    // the serial-identical error-object result and the turn ends promptly.
    let tools = InstrumentedToolDispatch(
        scripted: ["read_file": .string("r"), "search_kg": .string("s")],
        delaysNs: ["read_file": 5_000_000_000, "search_kg": 5_000_000_000]
    )
    let batch = openAIBatch([
        (id: "c1", name: "read_file"),
        (id: "c2", name: "search_kg"),
    ])
    let llm = MessagesCapturingLLM(scripted: [batch, "post-cancel"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let turnTask = Task {
        try await engine.executeTurnWithToolLoop(
            userMessage: "cancel me", llm: llm, tools: tools
        )
    }
    // Wait until both children are actually dispatched, then cancel.
    var spins = 0
    while tools.startedCount < 2, spins < 400 {
        try await Task.sleep(nanoseconds: 10_000_000)
        spins += 1
    }
    #expect(tools.startedCount == 2)
    let cancelStarted = DispatchTime.now()
    turnTask.cancel()
    let result = try await turnTask.value
    let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- cancelStarted.uptimeNanoseconds) / 1_000_000)

    print("[parallel-tool-cancel] teardown_ms=\(elapsedMs)")
    // Structural guarantee: both children were dispatched and each recorded a
    // CancellationError (asserted below) — proving teardown, not await-out.
    // Always asserted.
    #expect(result.toolDispatches.count == 2)
    // CORRECTNESS bound, always on: teardown must beat the 5s child sleeps by a
    // clear margin, or "cancelled" just means we awaited the children out
    // (gpt-5.5 fix round: the gated-only version stopped proving promptness).
    // Loose enough (4.5s vs ~instant) that CI load cannot flake it.
    #expect(elapsedMs < 4_500)
    // The TIGHT teardown-latency bound is a perf-regression tripwire — gated
    // behind NATIVE_AGENT_PERF_ASSERTS so CI load can't flake it. See
    // nativeagent-hangproof-subprocess-tests.
    if ProcessInfo.processInfo.environment["NATIVE_AGENT_PERF_ASSERTS"] == "1" {
        #expect(elapsedMs < 3_000)
    }
    for record in result.toolDispatches {
        if case .object(let o) = record.result, case .string(let msg)? = o["error"] {
            #expect(msg.contains("Cancellation"))
        } else {
            Issue.record("expected CancellationError error object, got \(record.result)")
        }
    }
}

@Test
func serialFallbackOverride_forcesStrictlySequentialExecution() async throws {
    let dir = try makeTempDir("fallback")
    let persona = hermeticPersona(root: dir)
    let tools = InstrumentedToolDispatch(
        scripted: [
            "read_file": .string("r"), "list_dir": .string("l"), "search_kg": .string("s"),
        ],
        delaysNs: [
            "read_file": 20_000_000, "list_dir": 20_000_000, "search_kg": 20_000_000,
        ]
    )
    let batch = openAIBatch([
        (id: "c1", name: "read_file"),
        (id: "c2", name: "list_dir"),
        (id: "c3", name: "search_kg"),
    ])
    let llm = MessagesCapturingLLM(scripted: [batch, "done"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    // Task-local stand-in for NATIVE_AGENT_SERIAL_TOOL_DISPATCH=1 (same
    // switch, test-bindable without mutating process env).
    let result = try await ParallelToolDispatch.$forceSerialOverride.withValue(true) {
        try await engine.executeTurnWithToolLoop(
            userMessage: "serial please", llm: llm, tools: tools
        )
    }

    #expect(result.reply == "done")
    #expect(tools.maxInFlight == 1)
    // Strict start/end alternation in original order — the old serial path.
    #expect(tools.events == [
        .init(tool: "read_file", phase: "start"), .init(tool: "read_file", phase: "end"),
        .init(tool: "list_dir", phase: "start"), .init(tool: "list_dir", phase: "end"),
        .init(tool: "search_kg", phase: "start"), .init(tool: "search_kg", phase: "end"),
    ])
}

@Test
func streamingLoop_parallelBatch_sameReassemblyContract() async throws {
    let dir = try makeTempDir("streaming")
    let persona = hermeticPersona(root: dir)
    let tools = InstrumentedToolDispatch(
        scripted: ["read_file": .string("rr"), "search_kg": .string("kk")],
        delaysNs: ["read_file": 60_000_000, "search_kg": 5_000_000]
    )
    let batch = openAIBatch([
        (id: "c1", name: "read_file"),
        (id: "c2", name: "search_kg"),
    ])
    // Default protocol streamMessages wraps completeMessages → the loop's
    // text-parse fallback finds the calls; the shared dispatch core runs.
    let llm = MessagesCapturingLLM(scripted: [batch, "stream done"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "stream it", llm: llm, tools: tools
    )

    #expect(result.reply == "stream done")
    #expect(result.toolDispatches.map(\.name) == ["read_file", "search_kg"])
    #expect(result.toolDispatches.map(\.result) == [.string("rr"), .string("kk")])
    #expect(tools.maxInFlight >= 2)
    let second = llm.capturedMessages[1]
    let resultIds: [String] = second[2].content.compactMap {
        if case .toolResult(let id, _, _) = $0 { return id }
        return nil
    }
    #expect(resultIds == ["c1", "c2"])
}

// MARK: - B3 — streaming loop counts provider calls

@Test
func streamingLoop_countsProviderCallsAcrossIterations() async throws {
    let dir = try makeTempDir("stream-count")
    let persona = hermeticPersona(root: dir)
    let tools = InstrumentedToolDispatch(scripted: ["read_file": .string("rr")])
    let call = openAIBatch([(id: "c1", name: "read_file")])
    // Two tool-call iterations, then a plain final reply → 3 provider calls.
    let llm = MessagesCapturingLLM(scripted: [call, call, "final reply"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "count me", llm: llm, tools: tools
    )

    #expect(result.reply == "final reply")
    // B3: the streaming loop used to return nil here (undercounting the main
    // chat surface). One streamMessages call per iteration = 3.
    #expect(result.providerCallCount == 3)
    #expect(llm.callCount == 3)
}

@Test
func streamingLoop_countsSingleProviderCallOnImmediateReply() async throws {
    let dir = try makeTempDir("stream-count-1")
    let persona = hermeticPersona(root: dir)
    let tools = InstrumentedToolDispatch(scripted: [:])
    let llm = MessagesCapturingLLM(scripted: ["straight answer"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "hi", llm: llm, tools: tools
    )

    #expect(result.reply == "straight answer")
    #expect(result.providerCallCount == 1)
}

@Test
func streamingLoop_countsProviderCallOnExhaustion() async throws {
    let dir = try makeTempDir("stream-count-exhaust")
    let persona = hermeticPersona(root: dir)
    let tools = InstrumentedToolDispatch(scripted: ["read_file": .string("rr")])
    let call = openAIBatch([(id: "c1", name: "read_file")])
    // Every response is a tool call → the loop exhausts at maxIterations.
    let llm = MessagesCapturingLLM(scripted: [call])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "never done", maxIterations: 3, llm: llm, tools: tools
    )

    #expect(result.reply.contains("tool loop exhausted after 3 iterations"))
    // Exhausted-fallback return also carries the count (3 iterations = 3 calls).
    #expect(result.providerCallCount == 3)
}

// MARK: - F2-M4 — completion-contract enforcement on the STRUCTURED lane
//
// Round-3 audit fence W4: the announce-without-act bounce previously lived ONLY
// at the text-compat call site, so every OpenAI-wire provider + all
// missions/workshop/bridge surfaces (which ride the structured loop) got
// prompt-only enforcement. These pin the runtime bounce on the structured loop.

/// A tool dispatcher that advertises SCHEMAS (unlike InstrumentedToolDispatch,
/// which returns []), so the announce gate's `!providerTools.schemas.isEmpty`
/// pre-condition is satisfied — the model HAD a tool it could have called
/// instead of narrating. `recall_memory` is an always-on core name, so it
/// survives the loop's per-iteration lazy tool filter.
private final class SchemaAdvertisingToolDispatch: ToolDispatchClient, @unchecked Sendable {
    private let scripted: [String: JSONValue]
    init(scripted: [String: JSONValue]) { self.scripted = scripted }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        scripted[tool] ?? .null
    }
    func listAvailableTools() async throws -> [String] { scripted.keys.sorted() }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        scripted.keys.sorted().map { name in
            LLMToolSchema(
                name: name,
                description: "test tool \(name)",
                parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
            )
        }
    }
}

@Test
func structuredStreamingLoop_announceWithoutAct_bouncesOnceThenAccepts() async throws {
    let dir = try makeTempDir("struct-announce")
    let persona = hermeticPersona(root: dir)
    let tools = SchemaAdvertisingToolDispatch(scripted: ["recall_memory": .string("clean")])
    // Iteration 1: pure narration, no tool call → completion-contract bounce.
    // Iteration 2: the real final answer → accepted.
    let llm = MessagesCapturingLLM(scripted: [
        "Reading the README now.",
        "The build pipeline is documented across three files.",
    ])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "what does the readme say?", llm: llm, tools: tools
    )

    #expect(result.reply == "The build pipeline is documented across three files.")
    // announce → nudge → final = 2 provider calls; the narration never became
    // the answer.
    #expect(result.providerCallCount == 2)
    #expect(llm.callCount == 2)
    // The bounce fed back a NATIVE-lane completion-contract remedy — never the
    // text marker protocol.
    let nudged = llm.capturedMessages[1]
    guard case .text(let feedback) = nudged.last?.content.last else {
        Issue.record("expected a text nudge as the last message")
        return
    }
    #expect(feedback.contains("completion contract"))
    #expect(feedback.contains("make the next tool call"))
    #expect(!feedback.contains("<tool_use name="))
}

@Test
func structuredStreamingLoop_secondAnnounceAcceptedAsFinal_noLoop() async throws {
    let dir = try makeTempDir("struct-announce-cap")
    let persona = hermeticPersona(root: dir)
    let tools = SchemaAdvertisingToolDispatch(scripted: ["recall_memory": .string("clean")])
    // Three consecutive announcements: bounce twice, then accept the third as
    // final so a model that refuses to act can never loop.
    let llm = MessagesCapturingLLM(scripted: [
        "On it — checking now.",
        "Reading the README now.",
        "Looking into it now.",
        "never-reached",
    ])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "status?", llm: llm, tools: tools
    )

    #expect(result.providerCallCount == 3)
    #expect(result.reply == "Looking into it now.")
}

@Test
func structuredBlockingLoop_announceWithoutAct_bouncesOnceThenAccepts() async throws {
    let dir = try makeTempDir("struct-announce-blocking")
    let persona = hermeticPersona(root: dir)
    let tools = SchemaAdvertisingToolDispatch(scripted: ["recall_memory": .string("clean")])
    let llm = MessagesCapturingLLM(scripted: [
        "Reading the README now.",
        "The build pipeline is documented across three files.",
    ])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "what does the readme say?", llm: llm, tools: tools
    )

    #expect(result.reply == "The build pipeline is documented across three files.")
    #expect(result.providerCallCount == 2)
    let nudged = llm.capturedMessages[1]
    guard case .text(let feedback) = nudged.last?.content.last else {
        Issue.record("expected a text nudge as the last message")
        return
    }
    #expect(feedback.contains("completion contract"))
    #expect(feedback.contains("make the next tool call"))
}

// MARK: - FIX 1 (B1.1): empty-reply recovery on both structured loops
//
// The text-compat lane recovered from a thinking-only empty 200 (empty text +
// zero tool calls) via emptyReplyNudgeCount; the structured loops used to accept
// an empty reply as the final answer. These pin the ported bounce: an empty
// reply + empty tool calls → nudge (max 2) → then accept, mirroring the announce
// tests. An empty reply must hit the EMPTY nudge, never the announce detector.

@Test
func structuredBlockingLoop_emptyReply_bouncesOnceThenAccepts() async throws {
    let dir = try makeTempDir("struct-empty-blocking")
    let persona = hermeticPersona(root: dir)
    let tools = SchemaAdvertisingToolDispatch(scripted: ["recall_memory": .string("clean")])
    // Iteration 1: empty reply (thinking-only) → empty-reply bounce.
    // Iteration 2: the real final answer → accepted.
    let llm = MessagesCapturingLLM(scripted: [
        "",
        "The build pipeline is documented across three files.",
    ])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "what does the readme say?", llm: llm, tools: tools
    )

    #expect(result.reply == "The build pipeline is documented across three files.")
    #expect(result.providerCallCount == 2)
    #expect(llm.callCount == 2)
    // The bounce fed back the NATIVE-lane empty-reply remedy — never the text
    // marker protocol.
    let nudged = llm.capturedMessages[1]
    guard case .text(let feedback) = nudged.last?.content.last else {
        Issue.record("expected a text nudge as the last message")
        return
    }
    #expect(feedback.contains("internal reasoning"))
    #expect(feedback.contains("must never be empty"))
    #expect(!feedback.contains("<tool_use name="))
}

@Test
func structuredBlockingLoop_secondEmptyReplyAcceptedAsFinal_noLoop() async throws {
    let dir = try makeTempDir("struct-empty-blocking-cap")
    let persona = hermeticPersona(root: dir)
    let tools = SchemaAdvertisingToolDispatch(scripted: ["recall_memory": .string("clean")])
    // Three consecutive empty replies: bounce twice, then accept the third as
    // final so a provider that only ever thinks can never loop.
    let llm = MessagesCapturingLLM(scripted: ["", "", "", "never-reached"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "status?", llm: llm, tools: tools
    )

    #expect(result.providerCallCount == 3)
    #expect(result.reply == "")
    // Second bounce carried the escalated wording.
    let secondNudge = llm.capturedMessages[2]
    guard case .text(let feedback) = secondNudge.last?.content.last else {
        Issue.record("expected a text nudge as the last message")
        return
    }
    #expect(feedback.contains("SECOND empty response"))
}

@Test
func structuredStreamingLoop_emptyReply_bouncesOnceThenAccepts() async throws {
    let dir = try makeTempDir("struct-empty-streaming")
    let persona = hermeticPersona(root: dir)
    let tools = SchemaAdvertisingToolDispatch(scripted: ["recall_memory": .string("clean")])
    let llm = MessagesCapturingLLM(scripted: [
        "",
        "The build pipeline is documented across three files.",
    ])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "what does the readme say?", llm: llm, tools: tools
    )

    #expect(result.reply == "The build pipeline is documented across three files.")
    #expect(result.providerCallCount == 2)
    #expect(llm.callCount == 2)
    let nudged = llm.capturedMessages[1]
    guard case .text(let feedback) = nudged.last?.content.last else {
        Issue.record("expected a text nudge as the last message")
        return
    }
    #expect(feedback.contains("internal reasoning"))
    #expect(feedback.contains("must never be empty"))
    #expect(!feedback.contains("<tool_use name="))
}

@Test
func structuredStreamingLoop_secondEmptyReplyAcceptedAsFinal_noLoop() async throws {
    let dir = try makeTempDir("struct-empty-streaming-cap")
    let persona = hermeticPersona(root: dir)
    let tools = SchemaAdvertisingToolDispatch(scripted: ["recall_memory": .string("clean")])
    let llm = MessagesCapturingLLM(scripted: ["", "", "", "never-reached"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "status?", llm: llm, tools: tools
    )

    #expect(result.providerCallCount == 3)
    #expect(result.reply == "")
}

// MARK: - Step-5 (intra-turn clearing) interaction

@Test
func parallelBatches_groupPerIteration_clearingSweepAgesThemAsOneIteration() async throws {
    let dir = try makeTempDir("clearing")
    let persona = hermeticPersona(root: dir)
    // 8 iterations of a 2-call parallel batch, then a final reply. Results
    // are >180 chars so the sweep stubs them once they age out of the keep
    // window (current + keepFullIterations).
    let longA = String(repeating: "A", count: 300)
    let longB = String(repeating: "B", count: 300)
    let tools = InstrumentedToolDispatch(
        scripted: ["read_file": .string(longA), "list_dir": .string(longB)]
    )
    let batch = openAIBatch([
        (id: "a", name: "read_file"),
        (id: "b", name: "list_dir"),
    ])
    let llm = MessagesCapturingLLM(scripted: Array(repeating: batch, count: 8) + ["done"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    // U1 item 8 (review fix): clearing is compat-mode-only now — this test
    // pins the sweep's parallel-batch aging, so it binds compat.
    let result = try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(true) {
            try await engine.executeTurnWithToolLoop(
                userMessage: "loop a while", llm: llm, tools: tools
            )
        }
    #expect(result.reply == "done")
    #expect(llm.callCount == 9)

    // The 9th request sees 8 prior iterations. Each parallel batch must be
    // exactly ONE tool-result user message (the sweep counts messages, not
    // blocks — a batch ages as one iteration).
    let ninth = llm.capturedMessages[8]
    let toolResultMessages = ninth.filter { msg in
        msg.role == .user && msg.content.contains { block in
            if case .toolResult = block { return true }
            return false
        }
    }
    #expect(toolResultMessages.count == 8)
    // 2026-07-21 audit: the no-progress WARN now reaches the MODEL as a text
    // block riding the SAME user message as the tool results (previously it
    // was a user-only notice). 8 identical batches trip the warn at round 8,
    // so the LAST batch message carries 3 blocks; the rest carry 2.
    for msg in toolResultMessages.dropLast() {
        #expect(msg.content.count == 2)
    }
    if let last = toolResultMessages.last {
        #expect(last.content.count == 3)
        #expect(last.content.contains { block in
            if case .text(let t) = block { return t.contains("recovery guidance") || t.contains("No progress") }
            return false
        })
    }

    // keep window = current + 5 → with 8 result messages, the oldest 2 are
    // stubbed (BOTH blocks of each batch), the newest 6 stay full.
    func bodies(_ msg: LLMMessage) -> [String] {
        msg.content.compactMap {
            if case .toolResult(_, let content, _) = $0 { return content }
            return nil
        }
    }
    for stubbed in toolResultMessages.prefix(2) {
        for body in bodies(stubbed) {
            #expect(body.contains(IntraTurnToolResultClearing.clearedMarkerPrefix))
            #expect(body.count < 300)
        }
    }
    for full in toolResultMessages.suffix(6) {
        for body in bodies(full) {
            #expect(!body.contains(IntraTurnToolResultClearing.clearedMarkerPrefix))
            #expect(body.count == 300)
        }
    }
}

// MARK: - Single safe call keeps exact serial event order

@Test
func singleParallelSafeCall_runsSequential_keepsExactSerialProgressOrder() async throws {
    let dir = try makeTempDir("single")
    let persona = hermeticPersona(root: dir)
    let tools = InstrumentedToolDispatch(scripted: ["read_file": .string("ok")])
    let batch = openAIBatch([(id: "c1", name: "read_file")])
    let llm = MessagesCapturingLLM(scripted: [batch, "fin"])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)

    actor EventLog {
        var kinds: [String] = []
        func add(_ kind: String) { kinds.append(kind) }
    }
    let log = EventLog()
    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "one read",
        llm: llm,
        tools: tools,
        progress: { event in
            switch event {
            case .toolUse: await log.add("toolUse")
            case .toolResult: await log.add("toolResult")
            default: break
            }
        }
    )
    #expect(result.reply == "fin")
    let kinds = await log.kinds
    #expect(kinds == ["toolUse", "toolResult"])
}

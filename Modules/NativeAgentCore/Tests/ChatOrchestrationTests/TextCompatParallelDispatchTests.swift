import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
@testable import ProviderRouting
import TrustCenter

// MARK: - A1/A2 — the Claude text-compat tool loop on the shared dispatcher
//
// A1 retired this path's private serial dispatch loop: it now hands its
// prepared calls to the SAME `SwiftNativeTurnEngine.runIterationDispatchGroups`
// that backs ToolLoop's `dispatchIterationCalls`, so the fail-closed
// ParallelToolDispatch veto table, the fleet overrides and the
// NATIVE_AGENT_SERIAL_TOOL_DISPATCH lever are one implementation for every
// lane. What this file pins:
//   (1) parallel-safe calls in ONE iteration actually overlap here (in-flight
//       high-water mark, not wall clock),
//   (2) veto'd calls still run strictly one at a time, and the force-serial
//       lever still collapses a safe batch,
//   (3) index order survives — .toolUse events, dispatch records, the prose
//       result carrier and the transcript rows are all CALL order, never
//       completion order, even when the first call is the slowest,
//   (4) A2's off-critical-path receipt writer keeps the fail-loud contract:
//       a wedged transcript still raises the per-tool notice.

// MARK: - Helpers

private func makeParallelCompatRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tcpd-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class CompatStubRouting: ProviderRoutingProtocol, @unchecked Sendable {
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
private final class CompatUnusedLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        return "structured-path-should-not-run"
    }
}

/// Serves one scripted chunk list per provider call, in order.
private final class ScriptedCompatStream: StreamingLLMClient, @unchecked Sendable {
    private let scripts: [[String]]
    private let lock = NSLock()
    private var _index = 0

    init(scripts: [[String]]) { self.scripts = scripts }

    var callCount: Int { lock.withLock { _index } }

    func stream(
        prompt: String, system: String?, model: String?
    ) -> AsyncThrowingStream<String, Error> {
        let script: [String] = lock.withLock {
            guard !scripts.isEmpty else { return [] }
            let s = scripts[min(_index, scripts.count - 1)]
            _index += 1
            return s
        }
        return AsyncThrowingStream { continuation in
            for chunk in script { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

/// Dispatcher with an in-flight high-water mark, start/end event ordering and
/// optional per-tool delays. The delays exist only to create overlap; every
/// assertion reads counts or ordering, never elapsed time.
private final class CompatInstrumentedTools: ToolDispatchClient, @unchecked Sendable {
    struct Event: Equatable {
        let tool: String
        let phase: String  // "start" | "end"
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var _inFlight = 0
    private var _maxInFlight = 0

    private let scripted: [String: JSONValue]
    private let delaysNs: [String: UInt64]

    init(scripted: [String: JSONValue], delaysNs: [String: UInt64] = [:]) {
        self.scripted = scripted
        self.delaysNs = delaysNs
    }

    var events: [Event] { lock.withLock { _events } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var startedCount: Int { lock.withLock { _events.filter { $0.phase == "start" }.count } }

    func dispatch(
        tool: String, input: [String: JSONValue], surface: String
    ) async throws -> JSONValue {
        lock.withLock {
            _events.append(Event(tool: tool, phase: "start"))
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
        }
        defer {
            lock.withLock {
                _events.append(Event(tool: tool, phase: "end"))
                _inFlight -= 1
            }
        }
        if let delay = delaysNs[tool] {
            try await Task.sleep(nanoseconds: delay)
        }
        return scripted[tool] ?? .null
    }

    func listAvailableTools() async throws -> [String] { scripted.keys.sorted() }
}

private struct CompatRun {
    let toolUses: [String]
    let toolResults: [String]
    let notices: [(kind: String, text: String)]
    let finalReply: String?
    let promptOfLastCall: String?
    /// `metadata.toolName` of every persisted `role: "tool"` row, in file order.
    let persistedToolRows: [String]
}

/// Minimal text-compat driver. Pins the legacy grown-prompt transport (the
/// lever item 8 shipped) so the harness needs one StreamingLLMClient — the
/// dispatch loop under test is the same on either transport.
private func runTextCompatDispatch(
    tag: String,
    scripts: [[String]],
    tools: any ToolDispatchClient,
    wedgeToolTranscriptDirectory: Bool = false
) async throws -> CompatRun {
    let root = try makeParallelCompatRoot(tag)
    if wedgeToolTranscriptDirectory {
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(
            to: chat.appendingPathComponent("messages", isDirectory: false)
        )
    }
    let llm = CompatUnusedLLM()
    let streaming = ScriptedCompatStream(scripts: scripts)
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: CompatStubRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
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

    var toolUses: [String] = []
    var toolResults: [String] = []
    var notices: [(kind: String, text: String)] = []
    var finalReply: String?
    try await AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride
        .withValue(true) {
            for try await event in client.chatStream(
                message: "go", sessionId: sessionId,
                model: "claude-opus-4-8", reasoningEffort: "high",
                fileAccess: "workspace", attachments: [], persona: nil,
                surface: "chat", suppressUserAppend: true
            ) {
                switch event {
                case .toolUse(let name, _): toolUses.append(name)
                case .toolResult(let name, _): toolResults.append(name)
                case .notice(let kind, let text): notices.append((kind, text))
                case .final(let r): finalReply = r.reply
                default: break
                }
            }
        }
    #expect(llm.calls == 0, "\(tag): structured LLM path must not run on compat")
    return CompatRun(
        toolUses: toolUses,
        toolResults: toolResults,
        notices: notices,
        finalReply: finalReply,
        promptOfLastCall: nil,
        persistedToolRows: readPersistedToolRowNames(root, sessionId: sessionId)
    )
}

private func readPersistedToolRowNames(_ root: URL, sessionId: String) -> [String] {
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    var out: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let d = String(line).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (parsed["role"] as? String) == "tool",
              let metadata = parsed["metadata"] as? [String: Any],
              let name = metadata["toolName"] as? String
        else { continue }
        out.append(name)
    }
    return out
}

private func marker(_ id: String, _ name: String, _ argsJSON: String = "{}") -> String {
    "<tool_use id=\"\(id)\" name=\"\(name)\">\(argsJSON)</tool_use>"
}

// MARK: - A1: parallel-safe calls overlap on the text-compat path

@Test
func textCompatParallelSafeBatch_dispatchesConcurrently_inIndexOrder() async throws {
    // All three pass the fail-closed safe-set predicate.
    for name in ["read_file", "recall_memory", "search_kg"] {
        #expect(ParallelToolDispatch.isParallelSafe(internalToolName: name))
    }
    let tools = CompatInstrumentedTools(
        scripted: [
            "read_file": .string("R"),
            "recall_memory": .string("M"),
            "search_kg": .string("K"),
        ],
        // The FIRST call is the slowest: a serial loop could not start the
        // others before it ends, so overlap here is only possible in parallel.
        delaysNs: ["read_file": 60_000_000, "recall_memory": 10_000_000]
    )
    let batch = marker("c1", "read_file", #"{"path":"a"}"#)
        + marker("c2", "recall_memory", #"{"q":"x"}"#)
        + marker("c3", "search_kg", #"{"q":"y"}"#)

    let run = try await runTextCompatDispatch(
        tag: "safe-batch", scripts: [[batch], ["done"]], tools: tools
    )

    #expect(run.finalReply == "done")
    #expect(tools.startedCount == 3)
    #expect(tools.maxInFlight >= 2, "text-compat batch did not dispatch concurrently")
    #expect(tools.maxInFlight <= ParallelToolDispatch.maxConcurrentPerIteration)
    // UI order contract: .toolUse for the whole group up-front in index order,
    // .toolResult in index order — never completion order (read_file is last
    // to finish and still first on both streams).
    #expect(run.toolUses == ["read_file", "recall_memory", "search_kg"])
    #expect(run.toolResults == ["read_file", "recall_memory", "search_kg"])
    // And the transcript rows follow CALL order, not completion order (A2).
    #expect(run.persistedToolRows == ["read_file", "recall_memory", "search_kg"])
}

// MARK: - A1: the veto table stays fail-closed here too

@Test
func textCompatVetoedBatch_staysStrictlySerial() async throws {
    // "echo" carries no positive read signal, so rule 6 fails it closed —
    // the unknown-name half of the veto, alongside the write and shell classes.
    for name in ["write_file", "shell", "echo"] {
        #expect(!ParallelToolDispatch.isParallelSafe(internalToolName: name))
    }
    let tools = CompatInstrumentedTools(
        scripted: [
            "write_file": .string("W"),
            "shell": .string("S"),
            "echo": .string("E"),
        ],
        delaysNs: ["write_file": 30_000_000, "shell": 10_000_000]
    )
    let batch = marker("c1", "write_file", #"{"path":"a"}"#)
        + marker("c2", "shell", #"{"cmd":"ls"}"#)
        + marker("c3", "echo", #"{"say":"x"}"#)

    let run = try await runTextCompatDispatch(
        tag: "vetoed-batch", scripts: [[batch], ["done"]], tools: tools
    )

    #expect(run.finalReply == "done")
    #expect(tools.startedCount == 3)
    #expect(tools.maxInFlight == 1, "a vetoed tool must never overlap a sibling")
    // Strict start→end pairing proves serialization without reading a clock.
    #expect(tools.events.map(\.tool) == [
        "write_file", "write_file", "shell", "shell", "echo", "echo",
    ])
    #expect(tools.events.map(\.phase) == ["start", "end", "start", "end", "start", "end"])
    #expect(run.toolUses == ["write_file", "shell", "echo"])
}

@Test
func textCompatForceSerialLever_collapsesAnOtherwiseParallelBatch() async throws {
    let tools = CompatInstrumentedTools(
        scripted: ["read_file": .string("R"), "recall_memory": .string("M")],
        delaysNs: ["read_file": 30_000_000]
    )
    let batch = marker("c1", "read_file", #"{"path":"a"}"#)
        + marker("c2", "recall_memory", #"{"q":"x"}"#)

    let run = try await ParallelToolDispatch.$forceSerialOverride.withValue(true) {
        try await runTextCompatDispatch(
            tag: "force-serial", scripts: [[batch], ["done"]], tools: tools
        )
    }

    #expect(run.finalReply == "done")
    #expect(tools.maxInFlight == 1, "the rollback lever must reach the text-compat path")
    #expect(run.toolUses == ["read_file", "recall_memory"])
}

// MARK: - A2: receipts leave the dispatch critical path, fail-loud intact

@Test
func textCompatReceiptWriteFailure_stillSurfacesOneNoticePerCall() async throws {
    // Markers parse and dispatch normally; only the receipt append is wedged.
    let tools = CompatInstrumentedTools(
        scripted: ["read_file": .string("R"), "recall_memory": .string("M")]
    )
    let batch = marker("c1", "read_file", #"{"path":"a"}"#)
        + marker("c2", "recall_memory", #"{"q":"x"}"#)

    let run = try await runTextCompatDispatch(
        tag: "receipt-wedge",
        scripts: [[batch], ["done"]],
        tools: tools,
        wedgeToolTranscriptDirectory: true
    )

    #expect(run.toolResults == ["read_file", "recall_memory"])
    // Moving the write off the dispatch loop must not turn a lost receipt
    // into a silent one — the previously-fixed bug class (M2, 2026-07-09).
    let failures = run.notices.filter { $0.kind == "transcript_write_failed" }
    #expect(failures.count == 2)
    #expect(failures.contains { $0.text.contains("receipt for tool 'read_file'") })
    #expect(failures.contains { $0.text.contains("receipt for tool 'recall_memory'") })
    #expect(run.persistedToolRows.isEmpty)
}

@Test
func textCompatReceiptRows_followCallOrderNotCompletionOrder() async throws {
    // The staggered delays exist to make this batch complete OUT of call
    // order; the assertions deliberately do not depend on which out-of-order
    // sequence it lands in. An earlier revision pinned the exact completion
    // sequence and flaked under full-suite load (review NIT, 2026-08-28):
    // a 5ms tool can finish after a 60ms one when the machine is busy, which
    // says nothing about receipt ordering — the thing actually under test.
    let tools = CompatInstrumentedTools(
        scripted: [
            "read_file": .string("R"),
            "recall_memory": .string("M"),
            "search_kg": .string("K"),
        ],
        delaysNs: [
            "read_file": 60_000_000,
            "recall_memory": 30_000_000,
            "search_kg": 5_000_000,
        ]
    )
    let batch = marker("c1", "read_file", #"{"path":"a"}"#)
        + marker("c2", "recall_memory", #"{"q":"x"}"#)
        + marker("c3", "search_kg", #"{"q":"y"}"#)

    let run = try await runTextCompatDispatch(
        tag: "row-order", scripts: [[batch], ["done"]], tools: tools
    )

    // Overlap evidence that scheduling jitter cannot invalidate: all three
    // ran, and at least two were in flight at once — so the rows below were
    // produced by a CONCURRENT group, not by a serial walk that would order
    // them correctly for free.
    #expect(tools.startedCount == 3)
    #expect(tools.maxInFlight >= 2)
    // THE INVARIANT: transcript rows are CALL order, whatever order the
    // dispatches actually completed in.
    #expect(run.persistedToolRows == ["read_file", "recall_memory", "search_kg"])
}

import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - evals-total-coverage · fence core.chat.engine
//
// Ledger rows closed here:
//   * chat.streaming.streamTickHeartbeat  (UNCOVERED → COVERED)
//   * chat.streaming.toolNoticeBus        (UNCOVERED → COVERED)
//
// `stream.tick` is the only per-second evidence of whether a long stream was
// PRODUCING or STALLED — the difference between "the provider was slow" and "we
// stopped draining". Its throttle is a raw uptimeNanoseconds compare on the hot
// delta path: a wrong comparison silently emits either zero ticks (loses the
// evidence) or one per chunk (floods turn_traces and slows the very path it
// measures). Both failure directions are pinned below.
//
// `ToolNoticeBus.emit` is dead-control-by-construction: when the TaskLocal is
// unset tools just don't emit and NOTHING reports it. It is the wire that makes
// a long invoke_claude say "still working" instead of hanging. If a loop stops
// binding it around dispatch, every long tool goes back to a silent freeze and
// no test, trace, or log changes.

// MARK: - hermetic trace collection

private func intField(_ event: TurnTraceEvent, _ key: String) -> Int64? {
    guard case .object(let payload) = event.payload,
          case .int(let value)? = payload[key] else { return nil }
    return value
}

// MARK: - engine wiring

private struct HeartbeatPersona: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class HeartbeatRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "stream-model", reasoningEffort: "high")]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
}

private func makeHeartbeatEngine(
    llm: any LLMClient = MockLLMClient(scriptedResponses: ["unused"]),
    tools: any ToolDispatchClient = MockToolDispatchClient(),
    turnTraceBus: TurnTraceBus = .shared
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: HeartbeatPersona(),
        memory: nil,
        router: HeartbeatRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools,
        turnTraceBus: turnTraceBus
    )
}

// MARK: - chat.streaming.streamTickHeartbeat

@Test
func streamTick_isThrottledByElapsedTime_neverOncePerChunk() async throws {
    let chunkCount = 80
    let chunks = (0..<chunkCount).map { "chunk-\($0) " }
    let elapsed = LockedBox<Double>(0)

    let events = try await withHermeticTraceBus(kinds: ["stream.tick"]) { bus in
        let engine = makeHeartbeatEngine(turnTraceBus: bus)
        let started = Date()
        let streamer = MockStreamingLLMClient(chunks: chunks)
        var deltas = 0
        for try await event in engine.streamTurn(userMessage: "go", streamingLLM: streamer) {
            if case .delta = event { deltas += 1 }
        }
        elapsed.set(Date().timeIntervalSince(started))
        #expect(deltas == chunkCount)
    }

    // FAILURE DIRECTION 1 — flood: one tick per chunk would give 80. The
    // throttle allows at most ~1/second; the first chunk always opens the
    // window (lastTickNs starts at 0), so the honest bound is
    // 1 + elapsed seconds, with one second of slack for CI load.
    let allowed = Int(elapsed.get().rounded(.up)) + 2
    #expect(events.count <= allowed, "\(events.count) ticks for \(chunkCount) chunks in \(elapsed.get())s")
    #expect(events.count < chunkCount)

    // FAILURE DIRECTION 2 — silence: a stream that produced 80 chunks must
    // leave at least one piece of liveness evidence behind.
    #expect(events.count >= 1)

    // Each tick's accumulated char count is monotonically non-decreasing and
    // never exceeds what the stream actually produced.
    let totalChars = chunks.joined().count
    var previous: Int64 = -1
    for event in events {
        let chars = try #require(intField(event, "chars"))
        #expect(chars >= previous)
        #expect(chars <= Int64(totalChars))
        previous = chars
        let reportedChunks = try #require(intField(event, "chunks"))
        #expect(reportedChunks >= 1 && reportedChunks <= Int64(chunkCount))
        #expect(intField(event, "elapsedMs") != nil)
    }
    // The last tick must reflect real progress, not a zeroed counter.
    #expect(previous > 0)
}

@Test
func streamTick_zeroChunkStreamEmitsNoHeartbeat() async throws {
    let events = try await withHermeticTraceBus(kinds: ["stream.tick"], expecting: 0) { bus in
        let engine = makeHeartbeatEngine(turnTraceBus: bus)
        let streamer = MockStreamingLLMClient(chunks: [])
        for try await _ in engine.streamTurn(userMessage: "go", streamingLLM: streamer) {}
    }

    // No deltas ⇒ no liveness to report. A tick here would be a fabricated row.
    #expect(events.isEmpty)
}

// MARK: - chat.streaming.toolNoticeBus

/// A tool that pushes notices through ToolNoticeBus from BOTH its own body and
/// a child task it spawns — the two shapes a real long-running tool
/// (invoke_claude: start / 30s heartbeat / timeout) uses.
private final class NoticeEmittingToolDispatch: ToolDispatchClient, @unchecked Sendable {
    nonisolated(unsafe) private(set) var sawEmitInBody: Bool?
    nonisolated(unsafe) private(set) var sawEmitInChildTask: Bool?

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        sawEmitInBody = ToolNoticeBus.emit != nil
        await ToolNoticeBus.emit?("agent_bridge", "still working — 30s elapsed")
        // Structured-concurrency child: a task spawned INSIDE the tool must
        // still inherit the binding, otherwise a tool's own heartbeat loop
        // (which is exactly this shape) emits nothing.
        let child = Task { () -> Bool in
            let visible = ToolNoticeBus.emit != nil
            await ToolNoticeBus.emit?("agent_bridge", "still working — 60s elapsed")
            return visible
        }
        sawEmitInChildTask = await child.value
        return .object(["ok": .bool(true)])
    }

    func listAvailableTools() async throws -> [String] { ["recall_memory"] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [LLMToolSchema(
            name: "recall_memory",
            description: "slow tool",
            parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
        )]
    }
}

private final class ScriptedToolCallLLM: LLMClient, @unchecked Sendable {
    private let scripted: [String]
    nonisolated(unsafe) private var index = 0
    init(scripted: [String]) { self.scripted = scripted }
    func complete(prompt: String, system: String?, model: String?) async throws -> String { next() }
    func completeMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) async throws -> String { next() }
    private func next() -> String {
        guard !scripted.isEmpty else { return "" }
        let out = scripted[min(index, scripted.count - 1)]
        index += 1
        return out
    }
}

private func openAIToolCall(id: String, name: String) -> String {
    #"{"tool_calls":[{"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]}"#
}

private actor NoticeCollector {
    private(set) var notices: [(kind: String, text: String)] = []
    func record(kind: String, text: String) { notices.append((kind, text)) }
    func kinds() -> [String] { notices.map(\.kind) }
    func texts() -> [String] { notices.map(\.text) }
}

@Test
func toolNoticeBus_isBoundByTheLoopAroundDispatch_andReachesTheConsumer() async throws {
    let tools = NoticeEmittingToolDispatch()
    let llm = ScriptedToolCallLLM(scripted: [
        openAIToolCall(id: "c1", name: "recall_memory"),
        "done",
    ])
    let engine = makeHeartbeatEngine(llm: llm, tools: tools)
    let collector = NoticeCollector()

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "run the slow tool",
        llm: llm,
        tools: tools,
        progress: { event in
            if case .notice(let kind, let text) = event {
                await collector.record(kind: kind, text: text)
            }
        }
    )

    #expect(result.reply == "done")
    // The tool saw a live emit in BOTH positions — the loop bound it around
    // dispatch, and the binding survived into a child task.
    #expect(tools.sawEmitInBody == true)
    #expect(tools.sawEmitInChildTask == true)

    let kinds = await collector.kinds()
    let texts = await collector.texts()
    // The notice carries the TOOL's own kind, not a loop-owned label.
    #expect(kinds.filter { $0 == "agent_bridge" }.count == 2)
    #expect(texts.contains("still working — 30s elapsed"))
    #expect(texts.contains("still working — 60s elapsed"))
    // And the status line is NEVER folded into the durable reply.
    #expect(!result.reply.contains("still working"))
}

@Test
func toolNoticeBus_unboundDispatchIsANoOp_andTheCallStillSucceeds() async throws {
    // The negative control the "best effort by construction" contract needs:
    // outside a turn the TaskLocal is nil, the tool's emit does nothing, and
    // the dispatch still completes. (This is what makes an unbound loop
    // SILENT — which is why the positive test above has to exist.)
    #expect(ToolNoticeBus.emit == nil)
    let tools = NoticeEmittingToolDispatch()
    let out = try await tools.dispatch(tool: "recall_memory", input: [:], surface: "chat")
    #expect(out == .object(["ok": .bool(true)]))
    #expect(tools.sawEmitInBody == false)
    #expect(tools.sawEmitInChildTask == false)
}

@Test
func toolNoticeBus_isAlsoBoundByTheBlockingToolLoop() async throws {
    // The non-streaming structured loop shares runSingleDispatch; pin it so a
    // future divergence between the two loops can't silence one of them.
    let tools = NoticeEmittingToolDispatch()
    let llm = ScriptedToolCallLLM(scripted: [
        openAIToolCall(id: "c1", name: "recall_memory"),
        "done",
    ])
    let engine = makeHeartbeatEngine(llm: llm, tools: tools)
    let collector = NoticeCollector()

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "run the slow tool",
        llm: llm,
        tools: tools,
        progress: { event in
            if case .notice(let kind, let text) = event {
                await collector.record(kind: kind, text: text)
            }
        }
    )

    #expect(result.reply == "done")
    #expect(tools.sawEmitInBody == true)
    let kinds = await collector.kinds()
    #expect(kinds.filter { $0 == "agent_bridge" }.count == 2)
}

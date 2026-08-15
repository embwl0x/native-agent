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

// MARK: - CHAT-1 premise proof: the per-iteration TurnContext rebuild is NOT redundant
//
// CHAT-1 proposed memoizing `buildTurnContextWithHistory` per
// (sessionId, runId, historyLimit) and reusing it for tool-loop iterations
// >= 1 on the text-compatibility lane
// (ChatOrchestrationClient+TextCompatibility.swift:536). The stated premise
// was that for iterations >= 1 the inputs are constant, so the rebuilt
// context is byte-identical.
//
// THAT PREMISE IS FALSE, and these tests are the proof. The tool loop
// dispatches tools BETWEEN iterations, and several of those tools mutate
// stores that `buildTurnContextWithHistory` re-reads on the very next
// iteration. The rebuild is the ONLY channel by which a mid-turn tool
// effect reaches the model. Memoizing it would freeze the model's view of
// her own persona, memory, and tool catalog for the rest of the turn.
//
// Each test below pins ONE live feedback channel by mutating exactly what a
// real dispatchable tool mutates and asserting the rebuilt context CHANGES:
//
//   channel                     mutating tool (SwiftToolDispatcher+Dispatch.swift)
//   --------------------------  ------------------------------------------------
//   persona docs (stable seg)   persona_write / persona_append_section  (:150,:151)
//   memory recall (dynamic seg) commit_memory                            (:128)
//   tool catalog                save_skill / tool_load of a registry     (:161,:156)
//                               custom tool; MCP bridge additions
//   clock                       (wall clock — minute-resolution string)
//
// The one channel that IS closed is pinned too
// (`...midTurn_transcript_rows_do_NOT_feed_back`): rows appended mid-turn by
// `appendToolMessage(runId:)` carry the live runId and the history read
// passes `excludingRunId: runId`, so the transcript itself does not feed
// back. That single closed channel is what made the premise look plausible;
// it is not sufficient.

// MARK: - helpers

private func premiseTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chat1-premise-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func premiseWriteMessages(root: URL, sessionId: String, lines: [String]) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
                  .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(sessionId).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
}

private func premiseMsgLine(
    role: String,
    content: String,
    createdAt: String,
    runId: String? = nil
) -> String {
    var fields: [String: JSONValue] = [
        "id": .string(UUID().uuidString),
        "role": .string(role),
        "content": .string(content),
        "createdAt": .string(createdAt),
    ]
    if let runId { fields["runId"] = .string(runId) }
    return (try? JSONValue.object(fields).serialize(pretty: false)) ?? "{}"
}

private final class PremiseStubRouting: ProviderRoutingProtocol, @unchecked Sendable {
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
        ["chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high")]
    }
}

/// Recall store whose contents a mid-turn `commit_memory` can change.
private final class MutableRecallStub: MemoryRecalling, @unchecked Sendable {
    // Mutated and read strictly sequentially by the test body (build, mutate,
    // build) — no concurrency, so no lock is needed and none may be taken:
    // NSLock is unavailable from async contexts under strict concurrency.
    private var _hits: [MemoryRecallHit]
    private(set) var recallCallCount = 0

    init(hits: [MemoryRecallHit]) { self._hits = hits }

    /// Stand-in for the effect of the `commit_memory` tool running mid-turn.
    func commitMemory(_ hit: MemoryRecallHit) {
        _hits.append(hit)
    }

    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        recallCallCount += 1
        return _hits
    }

    func recall(
        _ query: String, k: Int, persona: String?, surface: String?
    ) async throws -> [MemoryRecallHit] {
        try await recall(query, k: k)
    }

    func recordServedContextHits(ids: [String]) async {}
}

/// Tool dispatcher whose catalog a mid-turn `save_skill` / registry write /
/// MCP-bridge change can grow. Also counts catalog reads so the tests can
/// show the rebuild is what re-reads it.
private final class MutableToolCatalogStub: ToolDispatchClient, @unchecked Sendable {
    // Sequential-by-construction, same reasoning as MutableRecallStub.
    private var _names: [String]
    private(set) var listCallCount = 0

    init(names: [String]) { self._names = names }

    func addTool(_ name: String) {
        _names.append(name)
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .null
    }

    func listAvailableTools() async throws -> [String] {
        listCallCount += 1
        return _names.sorted()
    }
}

private func premiseEngine(
    personaRoot: URL,
    memory: (any MemoryRecalling)? = nil,
    tools: any ToolDispatchClient = MockToolDispatchClient(),
    clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_000_000) }
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaRoot),
        memory: memory,
        router: PremiseStubRouting(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: tools,
        clock: clock,
        memoryPromoter: nil
    )
}

// MARK: - control: identical inputs DO produce an identical context

/// Baseline. With every mutable input held still (frozen clock, fixed
/// persona/memory/tool catalog), two consecutive builds ARE byte-identical.
/// Without this control the "differs" tests below would prove nothing — they
/// could just be measuring incidental nondeterminism.
@Test
func turnContextRebuild_isStable_whenNothingMutatesBetweenIterations() async throws {
    let root = try premiseTempRoot("stable")
    let personaDir = try premiseTempRoot("stable-persona")
    try premiseWriteMessages(root: root, sessionId: "s-stable", lines: [
        premiseMsgLine(role: "user", content: "PRIOR-USER", createdAt: "2026-07-31T10:00:00Z"),
        premiseMsgLine(role: "assistant", content: "PRIOR-ASST", createdAt: "2026-07-31T10:00:01Z"),
    ])
    let engine = premiseEngine(personaRoot: personaDir)
    let reader = SessionHistoryReader(dataRoot: root)

    let iter0 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-stable",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )
    let iter1 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-stable",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    #expect(iter0.systemPrompt == iter1.systemPrompt)
    #expect(iter0.userMessage == iter1.userMessage)
    #expect(iter0.toolsAvailable == iter1.toolsAvailable)
}

// MARK: - the ONE closed channel (this is what made the premise look plausible)

/// Rows the tool loop appends mid-turn (`appendToolMessage(runId:)`,
/// TextCompatibility:1050) carry the LIVE runId, and every history read in
/// `buildTurnContextWithHistory` passes `excludingRunId: excludeHistoryRunId`
/// (SessionHistory:700, :712). So the transcript does NOT feed back into the
/// rebuild. This channel alone is closed — the four below are not.
@Test
func turnContextRebuild_midTurnTranscriptRows_doNotFeedBack() async throws {
    let root = try premiseTempRoot("transcript")
    let personaDir = try premiseTempRoot("transcript-persona")
    let runId = "run-live-42"
    try premiseWriteMessages(root: root, sessionId: "s-tx", lines: [
        premiseMsgLine(role: "user", content: "PRIOR-USER", createdAt: "2026-07-31T10:00:00Z"),
        premiseMsgLine(role: "assistant", content: "PRIOR-ASST", createdAt: "2026-07-31T10:00:01Z"),
    ])
    let engine = premiseEngine(personaRoot: personaDir)
    let reader = SessionHistoryReader(dataRoot: root)

    let iter0 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-tx",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: runId
    )

    // A tool dispatch mid-turn appends a tool row stamped with the live runId.
    try premiseWriteMessages(root: root, sessionId: "s-tx", lines: [
        premiseMsgLine(role: "user", content: "PRIOR-USER", createdAt: "2026-07-31T10:00:00Z"),
        premiseMsgLine(role: "assistant", content: "PRIOR-ASST", createdAt: "2026-07-31T10:00:01Z"),
        premiseMsgLine(
            role: "tool", content: "MIDTURN-TOOL-ROW-MARKER",
            createdAt: "2026-07-31T10:00:02Z", runId: runId
        ),
    ])

    let iter1 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-tx",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: runId
    )

    #expect(!(iter0.systemPrompt ?? "").contains("MIDTURN-TOOL-ROW-MARKER"))
    #expect(!(iter1.systemPrompt ?? "").contains("MIDTURN-TOOL-ROW-MARKER"))
    #expect(iter0.systemPrompt == iter1.systemPrompt)
}

// MARK: - LIVE channel 1: persona docs (persona_write / persona_append_section)

/// `persona_write` (Dispatch:150) and `persona_append_section` (:151) are
/// dispatchable inside this very tool loop and write persona docs to disk.
/// `buildTurnContext` recompiles the persona packet on every build
/// (TurnEngine:~770), so iteration N+1 sees the new persona. Memoizing the
/// context would silently discard her own mid-turn persona edit.
@Test
func turnContextRebuild_reflectsMidTurnPersonaWrite() async throws {
    let root = try premiseTempRoot("persona-write")
    let personaDir = try premiseTempRoot("persona-write-docs")
    try "You are Agent. BEFORE-PERSONA-MARKER\n".write(
        to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8
    )
    try premiseWriteMessages(root: root, sessionId: "s-persona", lines: [
        premiseMsgLine(role: "user", content: "PRIOR-USER", createdAt: "2026-07-31T10:00:00Z"),
        premiseMsgLine(role: "assistant", content: "PRIOR-ASST", createdAt: "2026-07-31T10:00:01Z"),
    ])
    let engine = premiseEngine(personaRoot: personaDir)
    let reader = SessionHistoryReader(dataRoot: root)

    let iter0 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-persona",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    // Mid-turn `persona_write` effect.
    try "You are Agent. AFTER-PERSONA-MARKER\n".write(
        to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8
    )

    let iter1 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-persona",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    #expect((iter0.systemPrompt ?? "").contains("BEFORE-PERSONA-MARKER"))
    #expect((iter1.systemPrompt ?? "").contains("AFTER-PERSONA-MARKER"))
    #expect(iter0.systemPrompt != iter1.systemPrompt)
}

// MARK: - LIVE channel 2: memory recall (commit_memory)

/// `commit_memory` (Dispatch:128) writes a memory record mid-turn. The next
/// iteration's `memory.recall(...)` (TurnEngine:~866) surfaces it into the
/// DYNAMIC system segment. Memoizing would mean she writes a memory during
/// the turn and cannot see it for the rest of the turn.
@Test
func turnContextRebuild_reflectsMidTurnCommitMemory() async throws {
    let root = try premiseTempRoot("commit-memory")
    let personaDir = try premiseTempRoot("commit-memory-persona")
    try premiseWriteMessages(root: root, sessionId: "s-mem", lines: [
        premiseMsgLine(role: "user", content: "PRIOR-USER", createdAt: "2026-07-31T10:00:00Z"),
        premiseMsgLine(role: "assistant", content: "PRIOR-ASST", createdAt: "2026-07-31T10:00:01Z"),
    ])
    let memory = MutableRecallStub(hits: [
        MemoryRecallHit(score: 0.9, preview: "BEFORE-MEMORY-MARKER")
    ])
    let engine = premiseEngine(personaRoot: personaDir, memory: memory)
    let reader = SessionHistoryReader(dataRoot: root)

    let iter0 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-mem",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    // Mid-turn `commit_memory` effect.
    memory.commitMemory(
        MemoryRecallHit(score: 0.99, preview: "AFTER-MEMORY-MARKER")
    )

    let iter1 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-mem",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    #expect(memory.recallCallCount == 2)   // the rebuild IS the re-read
    #expect(!(iter0.systemPrompt ?? "").contains("AFTER-MEMORY-MARKER"))
    #expect((iter1.systemPrompt ?? "").contains("AFTER-MEMORY-MARKER"))
    #expect(iter0.systemPrompt != iter1.systemPrompt)
}

// MARK: - LIVE channel 3: the tool catalog

/// `buildTurnContext` re-reads the tool catalog every build (TurnEngine:~646
/// `listAvailableTools` / `listAvailableToolSchemas`). That catalog is not a
/// static superset: `SwiftToolDispatcher.listAvailableToolSchemas()`
/// (SwiftToolDispatcher.swift:199) folds in `fullMacToolAccess()` (a grant
/// that can EXPIRE mid-turn), `registryToolSchemas()` (data/tools/registry.json
/// — `save_skill`, Dispatch:161), and `mcpToolSchemas()`. The downstream lazy
/// filter (StructuredChat:874) can only ever NARROW `ctx.toolSchemas`, so
/// anything that leaves the memoized catalog can never come back and anything
/// that expires can never leave.
@Test
func turnContextRebuild_reflectsMidTurnToolCatalogChange() async throws {
    let root = try premiseTempRoot("tool-catalog")
    let personaDir = try premiseTempRoot("tool-catalog-persona")
    try premiseWriteMessages(root: root, sessionId: "s-tools", lines: [
        premiseMsgLine(role: "user", content: "PRIOR-USER", createdAt: "2026-07-31T10:00:00Z"),
        premiseMsgLine(role: "assistant", content: "PRIOR-ASST", createdAt: "2026-07-31T10:00:01Z"),
    ])
    let tools = MutableToolCatalogStub(names: ["read_file", "write_file"])
    let engine = premiseEngine(personaRoot: personaDir, tools: tools)
    let reader = SessionHistoryReader(dataRoot: root)

    let iter0 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-tools",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    // Mid-turn `save_skill` / registry write / MCP bridge addition.
    tools.addTool("newly_registered_tool")

    let iter1 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-tools",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    #expect(tools.listCallCount == 2)      // the rebuild IS the re-read
    #expect(!iter0.toolsAvailable.contains("newly_registered_tool"))
    #expect(iter1.toolsAvailable.contains("newly_registered_tool"))
}

// MARK: - LIVE channel 4: the clock

/// `contextByAppendingCurrentTurnFacts` stamps
/// `Local time: EEEE, MMMM d, yyyy at h:mm a zzz` into the system prompt every
/// build (TurnEngine:1260 → renderClockContext). Minute resolution: any
/// tool-loop iteration that crosses a minute boundary — a shell/build/test
/// dispatch routinely does — produces a different context by construction.
/// So "byte-identical across iterations" is false even with every store held
/// still.
@Test
func turnContextRebuild_clockAdvancesAcrossIterations() async throws {
    let root = try premiseTempRoot("clock")
    let personaDir = try premiseTempRoot("clock-persona")
    try premiseWriteMessages(root: root, sessionId: "s-clock", lines: [
        premiseMsgLine(role: "user", content: "PRIOR-USER", createdAt: "2026-07-31T10:00:00Z"),
        premiseMsgLine(role: "assistant", content: "PRIOR-ASST", createdAt: "2026-07-31T10:00:01Z"),
    ])
    let base = Date(timeIntervalSince1970: 1_780_000_000)
    nonisolated(unsafe) var callIndex = 0
    let engine = premiseEngine(personaRoot: personaDir, clock: {
        defer { callIndex += 1 }
        // Iteration 0 at T, iteration 1 ninety seconds later (one tool
        // dispatch). Each build calls clock() more than once; step by build
        // only when a fresh build starts is not observable here, so use a
        // monotonic 90s-per-call ramp — both builds land in different minutes.
        return base.addingTimeInterval(Double(callIndex) * 90)
    })
    let reader = SessionHistoryReader(dataRoot: root)

    let iter0 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-clock",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )
    let iter1 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-clock",
        historyLimit: 20, historyReader: reader,
        personaOverride: nil, excludeHistoryRunId: "run-1"
    )

    #expect((iter0.systemPrompt ?? "").contains("Local time:"))
    #expect(iter0.systemPrompt != iter1.systemPrompt)
}

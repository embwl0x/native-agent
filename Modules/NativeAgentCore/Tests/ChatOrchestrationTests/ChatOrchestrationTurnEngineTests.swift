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

// MARK: - Helpers

private func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("turnengine-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ url: URL, _ contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

/// Minimal ProviderRouting stub that returns a fixed picker map. We don't
/// want the test depending on PersistenceCore.defaultDataRoot()'s state.
private final class StubRouting: ProviderRoutingProtocol, @unchecked Sendable {
    let prefs: [String: SurfacePreference]
    let activeProviders: [String: String]
    nonisolated(unsafe) private var _activeProviderCallCount = 0
    init(
        prefs: [String: SurfacePreference],
        activeProviders: [String: String] = [:]
    ) {
        self.prefs = prefs
        self.activeProviders = activeProviders
    }
    var activeProviderCallCount: Int {
        _activeProviderCallCount
    }
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
    func activeProvidersForSurfaces() async -> [String: String] {
        _activeProviderCallCount += 1
        return activeProviders
    }
}

private final class ConflictingGenerationRouting: ProviderRoutingProtocol, @unchecked Sendable {
    nonisolated(unsafe) private var checkedCalls = 0
    nonisolated(unsafe) private var legacyPreferenceCalls = 0
    nonisolated(unsafe) private var legacyActiveCalls = 0

    var counts: (checked: Int, preferences: Int, active: Int) {
        (checkedCalls, legacyPreferenceCalls, legacyActiveCalls)
    }

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
        legacyPreferenceCalls += 1
        return [
            "workshop": SurfacePreference(
                surface: "workshop", model: "legacy-model", reasoningEffort: "low"
            )
        ]
    }
    func activeProvidersForSurfaces() async -> [String: String] {
        legacyActiveCalls += 1
        return ["workshop": "legacy-provider"]
    }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        checkedCalls += 1
        return ProviderRoutingSnapshot(
            preferences: [
                "chat": SurfacePreference(
                    surface: "chat", model: "chat-model", reasoningEffort: "low"
                ),
                "missions": SurfacePreference(
                    surface: "missions",
                    model: "execution-model",
                    reasoningEffort: "high",
                    serviceTier: "priority"
                ),
            ],
            activeProviders: ["chat": "chat-provider", "missions": "execution-provider"],
            pinnedModels: [:]
        )
    }
}

private final class SnapshotToolClient: ToolDispatchClient, @unchecked Sendable {
    let names: [String]
    let schemas: [LLMToolSchema]
    nonisolated(unsafe) private var _namesCalls = 0
    nonisolated(unsafe) private var _schemasCalls = 0

    init(names: [String], schemas: [LLMToolSchema]) {
        self.names = names
        self.schemas = schemas
    }

    var namesCalls: Int {
        _namesCalls
    }

    var schemasCalls: Int {
        _schemasCalls
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .null
    }

    func listAvailableTools() async throws -> [String] {
        _namesCalls += 1
        return names
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        _schemasCalls += 1
        return schemas
    }
}

private func collectTraceEvents(
    kind: String,
    turnId: String? = nil,
    expectedCount: Int = 1,
    timeoutMs: UInt64 = 3_000,
    _ body: @escaping () async -> Void
) async -> [TurnTraceEvent] {
    let sub = await TurnTraceBus.shared.subscribe()
    let drain = Task { () -> [TurnTraceEvent] in
        var out: [TurnTraceEvent] = []
        for await event in sub.stream {
            guard event.kind == kind else { continue }
            if let turnId, event.turnId != turnId { continue }
            out.append(event)
            if out.count >= expectedCount { break }
        }
        return out
    }
    await body()
    let stopper = Task {
        try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
        await TurnTraceBus.shared.unsubscribe(sub.id)
    }
    let events = await drain.value
    stopper.cancel()
    await TurnTraceBus.shared.unsubscribe(sub.id)
    return events
}

private func payloadContainsString(_ value: JSONValue, _ needle: String) -> Bool {
    switch value {
    case .string(let string):
        return string.contains(needle)
    case .array(let values):
        return values.contains { payloadContainsString($0, needle) }
    case .object(let object):
        return object.values.contains { payloadContainsString($0, needle) }
    case .null, .bool, .int, .double:
        return false
    }
}

private func objectValue(_ value: JSONValue?) throws -> [String: JSONValue] {
    guard case .object(let object)? = value else {
        Issue.record("expected object JSONValue")
        throw TestSupportError.expectedObject
    }
    return object
}

private enum TestSupportError: Error {
    case expectedObject
}

// MARK: - mock dispatch

@Test
func mockToolDispatch_returns_scripted() async throws {
    let mock = MockToolDispatchClient(scripted: [
        "echo": .string("ok"),
        "noop": .null,
    ])
    let r1 = try await mock.dispatch(tool: "echo", input: [:], surface: "chat")
    #expect(r1 == .string("ok"))
    let r2 = try await mock.dispatch(tool: "missing", input: [:], surface: "chat")
    #expect(r2 == .null)
    let avail = try await mock.listAvailableTools()
    #expect(avail == ["echo", "noop"])
}

@Test
func mockToolDispatch_tracks_dispatches() async throws {
    let mock = MockToolDispatchClient(scripted: ["x": .bool(true)])
    _ = try await mock.dispatch(tool: "x", input: ["a": .int(1)], surface: "chat")
    _ = try await mock.dispatch(tool: "x", input: ["b": .int(2)], surface: "ios")
    let d = mock.dispatches
    #expect(d.count == 2)
    #expect(d[0].tool == "x" && d[0].surface == "chat")
    #expect(d[1].surface == "ios")
}

// MARK: - turn engine

private final class ThrowingPersonaStub: PersonaEngineProtocol, @unchecked Sendable {
    struct Boom: Error {}
    func listPersonaDocs() async throws -> [PersonaDoc] { throw Boom() }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { throw Boom() }
}

private struct FixedPersonaStub: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class SpyMemoryRecaller: MemoryRecalling, @unchecked Sendable {
    nonisolated(unsafe) var calls: Int = 0
    nonisolated(unsafe) var lastPersona: String?
    nonisolated(unsafe) var lastSurface: String?
    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        calls += 1
        return []
    }

    func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit] {
        calls += 1
        lastPersona = persona
        lastSurface = surface
        return []
    }
}

private func makeEngine(
    persona: any PersonaEngineProtocol,
    memory: (any MemoryRecalling)? = nil,
    routerPrefs: [String: SurfacePreference] = [
        "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        "ios":  SurfacePreference(surface: "ios",  model: "gpt-5.5", reasoningEffort: "high"),
    ],
    activeProviders: [String: String] = [:],
    llm: any LLMClient,
    tools: any ToolDispatchClient = MockToolDispatchClient(),
    clock: @escaping @Sendable () -> Date = { Date() }
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: persona,
        memory: memory,
        router: StubRouting(prefs: routerPrefs, activeProviders: activeProviders),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools,
        clock: clock
    )
}

@Test
func turnEngine_executeTurn_calls_llm_once() async throws {
    let dir = try makeTempDir("llm-once")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["hello world"])
    let engine = makeEngine(persona: persona, llm: llm)
    _ = try await engine.executeTurn(userMessage: "hi", sessionId: nil)
    #expect(llm.callCount == 1)
}

@Test
func turnEngine_executeTurn_resolves_model_via_router() async throws {
    let dir = try makeTempDir("model-resolve")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(
        persona: persona,
        routerPrefs: [
            "chat": SurfacePreference(surface: "chat", model: "custom-model-X", reasoningEffort: "low"),
        ],
        llm: llm
    )
    let result = try await engine.executeTurn(userMessage: "hello", sessionId: nil)
    #expect(result.modelUsed == "custom-model-X")
}

@Test
func turnEngine_executeTurn_loads_persona_docs() async throws {
    let dir = try makeTempDir("persona-load")
    try writeFile(dir.appendingPathComponent("SOUL.md"),
                  "I am the soul of the agent.")
    try writeFile(dir.appendingPathComponent("VOICE.md"),
                  "Dry, sharp, fast.")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(persona: persona, llm: llm)
    let ctx = try await engine.buildTurnContext(surface: "chat", userMessage: "hi")
    #expect(ctx.personaDocs["SOUL"] == "I am the soul of the agent.")
    #expect(ctx.personaDocs["VOICE"] == "Dry, sharp, fast.")
}

@Test
func turnEngine_executeTurn_recalls_memory_when_memory_configured() async throws {
    let dir = try makeTempDir("recall")
    let persona = hermeticPersona(root: dir)
    let storeURL = dir.appendingPathComponent("emb.jsonl")
    let store = JSONLEmbeddingStore(path: storeURL)
    let embedder = MockEmbeddingProvider(dimensions: 64)
    let recaller = SwiftNativeMemoryRecaller(embedder: embedder, store: store)
    // Preload several entries; recall(k:5) must return >0.
    for i in 0..<8 {
        try await recaller.index(id: "rec-\(i)", text: "memory entry number \(i)")
    }
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(persona: persona, memory: recaller, llm: llm)
    let result = try await engine.executeTurn(userMessage: "memory entry number 3", sessionId: nil)
    #expect(result.recalledIds.count > 0)
    // Ids must be the ones we indexed.
    for id in result.recalledIds {
        #expect(id.hasPrefix("rec-"))
    }
}

@Test
func turnEngine_executeTurn_skips_memory_when_memory_nil() async throws {
    let dir = try makeTempDir("nomem")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(persona: persona, memory: nil, llm: llm)
    let result = try await engine.executeTurn(userMessage: "anything", sessionId: nil)
    #expect(result.recalledIds.isEmpty)
}

@Test
func turnEngine_fallbackRecallCarriesResolvedPersonaAndSurface() async throws {
    let recaller = SpyMemoryRecaller()
    let engine = makeEngine(
        persona: FixedPersonaStub(),
        memory: recaller,
        llm: MockLLMClient(scriptedResponses: ["ok"])
    )

    _ = try await engine.buildTurnContext(
        surface: "telegram",
        userMessage: "remember this",
        personaOverride: "Agent"
    )

    #expect(recaller.calls == 1)
    // A persona SLOT id is PRESENTATION-ONLY (User approved 2026-07-24), so the
    // recall lane is unfiltered no matter which slot is active — see
    // memoryRecallPersonaFilter. Surface, which is a real disclosure boundary,
    // still rides through untouched.
    #expect(recaller.lastPersona == nil)
    #expect(recaller.lastSurface == "telegram")
}

@Test
func turnEngine_executeTurn_returns_modelUsed_matches_resolved() async throws {
    let dir = try makeTempDir("model-match")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let prefs: [String: SurfacePreference] = [
        "chat": SurfacePreference(surface: "chat", model: "match-me-A", reasoningEffort: "high"),
        "ios":  SurfacePreference(surface: "ios",  model: "match-me-B", reasoningEffort: "high"),
    ]
    let engine = makeEngine(persona: persona, routerPrefs: prefs, llm: llm)
    let r1 = try await engine.executeTurn(surface: "chat", userMessage: "x")
    let r2 = try await engine.executeTurn(surface: "ios", userMessage: "x")
    #expect(r1.modelUsed == "match-me-A")
    #expect(r2.modelUsed == "match-me-B")
}

@Test
func turnEngine_executeTurn_returns_elapsedMs_nonneg() async throws {
    let dir = try makeTempDir("elapsed")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(persona: persona, llm: llm)
    let r = try await engine.executeTurn(userMessage: "x")
    #expect(r.elapsedMs >= 0)
}

@Test
func turnEngine_buildTurnContext_includes_systemPrompt_with_persona() async throws {
    let dir = try makeTempDir("sysprompt")
    try writeFile(dir.appendingPathComponent("SOUL.md"), "marker-content-soul")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(persona: persona, llm: llm)
    let ctx = try await engine.buildTurnContext(surface: "chat", userMessage: "hi")
    #expect(ctx.systemPrompt != nil)
    #expect(ctx.systemPrompt!.contains("marker-content-soul"))
}

@Test
func turnEngine_buildTurnContext_userMessage_in_context() async throws {
    let dir = try makeTempDir("userMsg")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(persona: persona, llm: llm)
    let ctx = try await engine.buildTurnContext(surface: "chat", userMessage: "unique-marker-XYZ")
    #expect(ctx.userMessage == "unique-marker-XYZ")
}

@Test
func turnEngine_clockContext_formats_local_and_central_time() async throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(utc.date(from: DateComponents(
        year: 2026, month: 6, day: 17, hour: 11, minute: 31
    )))

    let rendered = SwiftNativeTurnEngine.renderClockContext(
        now: now,
        localTimeZone: TimeZone(identifier: "America/Los_Angeles")!
    )

    #expect(rendered == "Current time: Wed 2026-06-17 04:31 PDT (America/Los_Angeles); Central: Wed 2026-06-17 06:31 CDT (America/Chicago).")
}

@Test
func turnEngine_buildTurnContext_appends_clock_context_to_dynamic_segment() async throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(utc.date(from: DateComponents(
        year: 2026, month: 6, day: 17, hour: 11, minute: 31
    )))
    let dir = try makeTempDir("clockctx")
    try writeFile(dir.appendingPathComponent("SOUL.md"), "CLOCK-STABLE-PERSONA")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(persona: persona, llm: llm, clock: { now })

    let ctx = try await engine.buildTurnContext(surface: "chat", userMessage: "hi")
    let seg = try #require(ctx.systemSegments)

    #expect(seg.stable.contains("CLOCK-STABLE-PERSONA"))
    #expect(!seg.stable.contains("Current time:"))
    #expect(seg.dynamic.contains("Current time:"))
    #expect(seg.dynamic.contains("Central:"))
    #expect(ctx.systemPrompt == seg.combined)
}

@Test
func turnEngine_buildTurnContext_appends_runtime_context_to_dynamic_segment() async throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(utc.date(from: DateComponents(
        year: 2026, month: 6, day: 18, hour: 18, minute: 0
    )))
    let dir = try makeTempDir("runtimectx")
    try writeFile(dir.appendingPathComponent("SOUL.md"), "RUNTIME-STABLE-PERSONA")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(
        persona: persona,
        routerPrefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
            "telegram": SurfacePreference(surface: "telegram", model: "grok-4.3", reasoningEffort: "high"),
        ],
        activeProviders: ["telegram": "xai_oauth_direct"],
        llm: llm,
        clock: { now }
    )

    let ctx = try await engine.buildTurnContext(surface: "telegram", userMessage: "what model are you on?")
    let seg = try #require(ctx.systemSegments)
    let clock = try #require(seg.dynamic.range(of: "Current time:"))
    let runtime = try #require(seg.dynamic.range(of: "Current runtime:"))

    #expect(seg.stable.contains("RUNTIME-STABLE-PERSONA"))
    #expect(!seg.stable.contains("Current runtime:"))
    #expect(seg.dynamic.contains("surface=telegram"))
    #expect(seg.dynamic.contains("provider=xai_oauth_direct"))
    #expect(seg.dynamic.contains("model=grok-4.3"))
    #expect(clock.lowerBound < runtime.lowerBound)
    #expect(ctx.systemPrompt == seg.combined)
}

@Test
func turnEngine_buildTurnContext_emits_metadata_only_context_summary() async throws {
    let traceRoot = try makeTempDir("trace-summary")
    TurnTracePersistLane.installTestRootOverrideIfUnset(traceRoot)
    let dir = try makeTempDir("context-summary")
    try writeFile(dir.appendingPathComponent("SOUL.md"), "SECRET-PERSONA-CONTENT")
    let persona = hermeticPersona(root: dir)
    let schema = LLMToolSchema(
        name: "secret_schema_tool",
        description: "SECRET-SCHEMA-DESCRIPTION",
        parametersJSON: Data(#"{"type":"object","properties":{"secret":{"type":"string"}}}"#.utf8)
    )
    let tools = SnapshotToolClient(names: ["secret_schema_tool"], schemas: [schema])
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let engine = makeEngine(
        persona: persona,
        activeProviders: ["chat": "openai"],
        llm: llm,
        tools: tools
    )
    let turnId = TurnTraceContext.mintTurnId()
    var caught: Error?

    let events = await collectTraceEvents(kind: "context.summary", turnId: turnId) {
        await TurnTraceContext.$turnId.withValue(turnId) {
            do {
                _ = try await engine.buildTurnContext(
                    surface: "chat",
                    userMessage: "SECRET-USER-MESSAGE"
                )
            } catch {
                caught = error
            }
        }
    }
    if let caught { throw caught }
    let event = try #require(events.first)
    let payload = try objectValue(event.payload)
    let stageMs = try objectValue(payload["stageMs"])
    let counts = try objectValue(payload["counts"])
    let flags = try objectValue(payload["flags"])

    #expect(stageMs["provider.preferences"] != nil)
    #expect(stageMs["persona.compile"] != nil)
    #expect(stageMs["memory.recall"] != nil)
    #expect(stageMs["tools.names"] != nil)
    #expect(stageMs["tools.schemas"] != nil)
    #expect(stageMs["prompt.render"] != nil)
    #expect(stageMs["context.clock_runtime"] != nil)
    #expect(counts["snapshot.toolNames"] == .int(1))
    #expect(counts["snapshot.toolSchemas"] == .int(1))
    #expect(flags["snapshot.requestScoped"] == .bool(true))
    #expect(!payloadContainsString(event.payload, "SECRET-USER-MESSAGE"))
    #expect(!payloadContainsString(event.payload, "SECRET-PERSONA-CONTENT"))
    #expect(!payloadContainsString(event.payload, "SECRET-SCHEMA-DESCRIPTION"))
}

@Test
func turnEngine_buildTurnContext_uses_one_active_provider_snapshot_for_runtime() async throws {
    let dir = try makeTempDir("provider-snapshot")
    try writeFile(dir.appendingPathComponent("SOUL.md"), "PROVIDER-SNAPSHOT-PERSONA")
    let persona = hermeticPersona(root: dir)
    let router = StubRouting(
        prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
            "telegram": SurfacePreference(surface: "telegram", model: "grok-4.3", reasoningEffort: "high"),
        ],
        activeProviders: ["telegram": "xai_oauth_direct"]
    )
    let engine = SwiftNativeTurnEngine(
        persona: persona,
        memory: nil,
        router: router,
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient()
    )

    let ctx = try await engine.buildTurnContext(
        surface: "telegram",
        userMessage: "what provider are you using?"
    )

    #expect(ctx.systemSegments?.dynamic.contains("provider=xai_oauth_direct") == true)
    #expect(router.activeProviderCallCount == 1)
}

@Test
func turnEngine_usesOneCheckedGenerationAndFoldsTheWorkshopSurface() async throws {
    // Mismatched pair (P2-3): the router fake below is keyed with the 0.3.x
    // `missions` while the turn asks for the canonical `workshop`. Falling
    // through to the chat preference here is the silent wrong-model bug.
    let dir = try makeTempDir("checked-provider-generation")
    let router = ConflictingGenerationRouting()
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: dir),
        memory: nil,
        router: router,
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient()
    )

    let context = try await engine.buildTurnContext(
        surface: "workshop",
        userMessage: "use the bounded execution route"
    )

    #expect(context.modelId == "execution-model")
    #expect(context.reasoningEffort == "high")
    #expect(context.providerId == "execution-provider")
    #expect(context.serviceTier == "priority")
    #expect(router.counts.checked == 1)
    #expect(router.counts.preferences == 0)
    #expect(router.counts.active == 0)
}

@Test
func turnEngine_buildTurnContext_snapshots_tool_catalog_and_schemas_once() async throws {
    let dir = try makeTempDir("tool-snapshot")
    let persona = hermeticPersona(root: dir)
    let schema = LLMToolSchema(
        name: "alpha",
        description: "Alpha tool",
        parametersJSON: Data(#"{"type":"object"}"#.utf8)
    )
    let tools = SnapshotToolClient(names: ["alpha"], schemas: [schema])
    let engine = makeEngine(
        persona: persona,
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: tools
    )

    let ctx = try await engine.buildTurnContext(surface: "chat", userMessage: "hi")

    #expect(ctx.toolsAvailable == ["alpha"])
    #expect(ctx.toolSchemas == [schema])
    #expect(tools.namesCalls == 1)
    #expect(tools.schemasCalls == 1)
}

@Test
func turnEngine_executeTurn_documents_carve_no_tool_loop() async throws {
    // Even with tools available, Phase B does a single LLM call and no
    // dispatch loop — toolDispatches must be empty.
    let dir = try makeTempDir("nolopp")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["I would call tool X here"])
    let tools = MockToolDispatchClient(scripted: [
        "alpha": .string("ok"),
        "beta": .string("ok"),
    ])
    let engine = makeEngine(persona: persona, llm: llm, tools: tools)
    let result = try await engine.executeTurn(userMessage: "please use tools")
    #expect(result.toolDispatches.isEmpty)
    // And the mock dispatcher saw zero dispatches.
    #expect(tools.dispatches.isEmpty)
    // But the context DID enumerate the tools available — the framework
    // surface is wired even though the loop is carved.
    let ctx = try await engine.buildTurnContext(surface: "chat", userMessage: "x")
    #expect(ctx.toolsAvailable == ["alpha", "beta"])
}

@Test
func turnEngine_executeTurn_surfaces_persona_load_error_before_memory_recall() async throws {
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let spy = SpyMemoryRecaller()
    let engine = makeEngine(persona: ThrowingPersonaStub(), memory: spy, llm: llm)
    var thrown: Error?
    do {
        _ = try await engine.executeTurn(userMessage: "hi")
    } catch {
        thrown = error
    }
    guard case .personaLoadFailed = thrown as? TurnEngineError else {
        Issue.record("expected TurnEngineError.personaLoadFailed, got \(String(describing: thrown))")
        return
    }
    #expect(spy.calls == 0)
    #expect(llm.callCount == 0)
}

@Test
func turnEngine_executeTurn_rejects_empty_message() async throws {
    let dir = try makeTempDir("empty")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let spy = SpyMemoryRecaller()
    let engine = makeEngine(persona: persona, memory: spy, llm: llm)
    var thrown: Error?
    do { _ = try await engine.executeTurn(userMessage: "") } catch { thrown = error }
    guard case .emptyMessage = thrown as? TurnEngineError else {
        Issue.record("expected emptyMessage, got \(String(describing: thrown))")
        return
    }
    #expect(spy.calls == 0)
    #expect(llm.callCount == 0)
}

@Test
func turnEngine_buildTurnContext_empty_throws_emptyMessage() async throws {
    let dir = try makeTempDir("bctx-empty")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let spy = SpyMemoryRecaller()
    let engine = makeEngine(persona: persona, memory: spy, llm: llm)
    var thrown: Error?
    do { _ = try await engine.buildTurnContext(surface: "chat", userMessage: "") } catch { thrown = error }
    guard case .emptyMessage = thrown as? TurnEngineError else {
        Issue.record("expected emptyMessage, got \(String(describing: thrown))")
        return
    }
    #expect(spy.calls == 0)
    #expect(llm.callCount == 0)
}

@Test
func turnEngine_buildTurnContext_whitespace_throws_emptyMessage() async throws {
    let dir = try makeTempDir("bctx-ws")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let spy = SpyMemoryRecaller()
    let engine = makeEngine(persona: persona, memory: spy, llm: llm)
    var thrown: Error?
    do { _ = try await engine.buildTurnContext(surface: "chat", userMessage: "  \n\t ") } catch { thrown = error }
    guard case .emptyMessage = thrown as? TurnEngineError else {
        Issue.record("expected emptyMessage, got \(String(describing: thrown))")
        return
    }
    #expect(spy.calls == 0)
    #expect(llm.callCount == 0)
}

@Test
func turnEngine_executeTurn_rejects_whitespace_message() async throws {
    let dir = try makeTempDir("ws")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let spy = SpyMemoryRecaller()
    let engine = makeEngine(persona: persona, memory: spy, llm: llm)
    var thrown: Error?
    do { _ = try await engine.executeTurn(userMessage: "   \n\t  ") } catch { thrown = error }
    guard case .emptyMessage = thrown as? TurnEngineError else {
        Issue.record("expected emptyMessage, got \(String(describing: thrown))")
        return
    }
    #expect(spy.calls == 0)
    #expect(llm.callCount == 0)
}

@Test
func turnEngine_executeTurn_elapsedMs_monotonic_even_when_injected_clock_goes_backwards() async throws {
    let dir = try makeTempDir("monoclock")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let counter = NSLock()
    nonisolated(unsafe) var step: Int = 0
    let backwardsClock: @Sendable () -> Date = {
        counter.lock(); defer { counter.unlock() }
        let d = Date(timeIntervalSince1970: 1_000_000 - Double(step))
        step += 1
        return d
    }
    let engine = SwiftNativeTurnEngine(
        persona: persona,
        memory: nil,
        router: StubRouting(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "m", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: llm,
        tools: MockToolDispatchClient(),
        clock: backwardsClock
    )
    let r = try await engine.executeTurn(userMessage: "x")
    #expect(r.elapsedMs >= 0)
}

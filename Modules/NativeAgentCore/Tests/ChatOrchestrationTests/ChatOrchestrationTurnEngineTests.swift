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

private actor CatalogWalkGate {
    enum Walk: Hashable {
        case names
        case schemas
    }

    private var entered: Set<Walk> = []
    private var bothWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter(_ walk: Walk) async {
        entered.insert(walk)
        if entered.count == 2 {
            let waiters = bothWaiters
            bothWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBothEntered() async {
        guard entered.count < 2 else { return }
        await withCheckedContinuation { continuation in
            bothWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func entryCount() -> Int { entered.count }
}

private final class CoordinatedCatalogToolClient: ToolDispatchClient, @unchecked Sendable {
    let gate: CatalogWalkGate
    let names: [String]
    let schemas: [LLMToolSchema]

    init(gate: CatalogWalkGate, names: [String], schemas: [LLMToolSchema]) {
        self.gate = gate
        self.names = names
        self.schemas = schemas
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .null
    }

    func listAvailableTools() async throws -> [String] {
        await gate.enter(.names)
        return names
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        await gate.enter(.schemas)
        return schemas
    }
}

private final class QuietHoursReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let window: TurnQuietHoursWindow?

    init(window: TurnQuietHoursWindow?) {
        self.window = window
    }

    func read(dataRoot: URL) -> TurnQuietHoursWindow? {
        _ = dataRoot
        lock.lock()
        reads += 1
        lock.unlock()
        return window
    }

    var count: Int {
        lock.lock()
        let value = reads
        lock.unlock()
        return value
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

private final class ScriptedMemoryRecaller: MemoryRecalling, @unchecked Sendable {
    let hits: [MemoryRecallHit]

    init(hits: [MemoryRecallHit]) {
        self.hits = hits
    }

    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        Array(hits.prefix(k))
    }

    func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit] {
        Array(hits.prefix(k))
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
    clock: @escaping @Sendable () -> Date = { Date() },
    naturalExpressionGuidanceEnabled: Bool = true
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: persona,
        memory: memory,
        router: StubRouting(prefs: routerPrefs, activeProviders: activeProviders),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools,
        clock: clock,
        naturalExpressionGuidanceEnabled: naturalExpressionGuidanceEnabled
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
func turnEngine_naturalExpressionGuidance_isSharedAcrossSurfacesAndReversible() async throws {
    let dir = try makeTempDir("natural-expression-surfaces")
    try writeFile(dir.appendingPathComponent("SOUL.md"), "SURFACE-PERSONA-MARKER")
    let persona = hermeticPersona(root: dir)
    let llm = MockLLMClient(scriptedResponses: ["ok"])
    let enabled = makeEngine(persona: persona, llm: llm)

    for surface in ["chat", "telegram", "slack", "ios", "codex"] {
        let context = try await enabled.buildTurnContext(
            surface: surface,
            userMessage: "hello"
        )
        let stable = try #require(context.systemSegments?.stable)
        #expect(stable.contains("SURFACE-PERSONA-MARKER"))
        #expect(stable.contains(NaturalExpressionGuidance.baseline))
        #expect(context.systemPrompt == context.systemSegments?.combined)
    }

    let disabled = makeEngine(
        persona: persona,
        llm: llm,
        naturalExpressionGuidanceEnabled: false
    )
    let rolledBack = try await disabled.buildTurnContext(
        surface: "chat",
        userMessage: "hello"
    )
    #expect(rolledBack.systemPrompt?.contains(NaturalExpressionGuidance.baseline) == false)
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

    // W5 L1#6: human wall-clock, not a machine stamp. Weekday spelled out and
    // AM/PM explicit — the model was calling 9:29 AM "afternoon" off the old
    // 24-hour rendering.
    #expect(rendered == "Local time: Wednesday, June 17, 2026 at 4:31 AM PDT (America/Los_Angeles). Central: Wednesday, June 17, 2026 at 6:31 AM CDT (America/Chicago).")
}

@Test
func turnEngine_clockContext_omits_central_when_local_is_central() async throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(utc.date(from: DateComponents(
        year: 2026, month: 8, day: 11, hour: 14, minute: 29
    )))

    let rendered = SwiftNativeTurnEngine.renderClockContext(
        now: now,
        localTimeZone: TimeZone(identifier: "America/Chicago")!
    )

    #expect(rendered == "Local time: Tuesday, August 11, 2026 at 9:29 AM CDT (America/Chicago).")
    #expect(!rendered.contains("Central:"))
    #expect(!rendered.contains("Quiet hours:"))
}

@Test
func turnEngine_clockContext_states_quiet_hours_window_when_configured() async throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let chicago = TimeZone(identifier: "America/Chicago")!
    let window = try #require(TurnQuietHoursWindow(startHour: 19, endHour: 3))

    // 09:29 local — outside a 7 PM → 3 AM window.
    let morning = try #require(utc.date(from: DateComponents(
        year: 2026, month: 8, day: 11, hour: 14, minute: 29
    )))
    let morningLine = SwiftNativeTurnEngine.renderClockContext(
        now: morning, localTimeZone: chicago, quietHours: window)
    #expect(!morningLine.contains("Quiet hours:"))

    // 01:00 local — inside the wrapped window.
    let night = try #require(utc.date(from: DateComponents(
        year: 2026, month: 8, day: 11, hour: 6, minute: 0
    )))
    let nightLine = SwiftNativeTurnEngine.renderClockContext(
        now: night, localTimeZone: chicago, quietHours: window)
    #expect(nightLine.contains("Quiet hours: 7:00 PM–3:00 AM local."))

    // The window is one line, not a second block.
    #expect(!morningLine.contains("\n"))
}

@Test
func turnQuietHoursWindow_reads_user_prefs_and_degrades_to_nil() throws {
    let dir = try makeTempDir("quiethours")
    #expect(TurnQuietHoursWindow.read(dataRoot: dir) == nil) // no file

    try writeFile(
        dir.appendingPathComponent("user_prefs.json"),
        #"{"quiet_hours": {"start": 19, "end": 3}}"#
    )
    #expect(TurnQuietHoursWindow.read(dataRoot: dir)
        == TurnQuietHoursWindow(startHour: 19, endHour: 3))

    // Out-of-range / equal hours mean "not configured", never "always quiet".
    try writeFile(
        dir.appendingPathComponent("user_prefs.json"),
        #"{"quiet_hours": {"start": 5, "end": 5}}"#
    )
    #expect(TurnQuietHoursWindow.read(dataRoot: dir) == nil)
}

// EVAL FENCE: turn.contract
// Ledger row: turn.ingredient.quietHoursWindow
//
// This crosses the real preference file -> turn assembler -> context-summary
// boundary. A configured window must reach both the dynamic prompt and its
// receipt only while the pinned local clock is inside it; an outside-window
// turn must persist the opposite semantic rather than mere configuration.
@Test
func turnEngine_quietHoursPreferenceIsRenderedAndReceiptStampedWithoutStaleState() async throws {
    let dataRoot = try makeTempDir("quiet-hours-receipt-data")
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let traceRoot = try makeTempDir("quiet-hours-receipt-traces")
    defer { try? FileManager.default.removeItem(at: traceRoot) }
    let personaRoot = try makeTempDir("quiet-hours-receipt-persona")
    defer { try? FileManager.default.removeItem(at: personaRoot) }
    try writeFile(personaRoot.appendingPathComponent("SOUL.md"), "QUIET-HOURS-PERSONA")
    try writeFile(
        dataRoot.appendingPathComponent("user_prefs.json"),
        #"{"quiet_hours":{"start":19,"end":3}}"#
    )
    var local = Calendar(identifier: .gregorian)
    local.timeZone = .current
    let activeNow = try #require(local.date(from: DateComponents(
        year: 2026, month: 8, day: 11, hour: 22, minute: 0
    )))
    let traceBus = TurnTraceBus(
        persistLane: TurnTracePersistLane(dataRootOverride: traceRoot)
    )
    func makeEngine(clock: @escaping @Sendable () -> Date) -> SwiftNativeTurnEngine {
        SwiftNativeTurnEngine(
            persona: hermeticPersona(root: personaRoot),
            memory: nil,
            router: StubRouting(prefs: [
                "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
            ]),
            trust: hermeticTrust(),
            llm: MockLLMClient(scriptedResponses: ["unused"]),
            tools: MockToolDispatchClient(),
            clock: clock,
            remPinsDataRoot: dataRoot,
            memoryPromoter: nil,
            turnTraceBus: traceBus
        )
    }

    func persistedSummary(for turnID: String) async throws -> TurnTraceEvent {
        let reader = TurnTraceRecentReader(dataRootOverride: traceRoot)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let event = try await reader.read().events.last(where: {
                $0.turnId == turnID && $0.kind == "context.summary"
            }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "QuietHoursReceipt", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "timed out waiting for persisted context.summary"
        ])
    }

    let activeEngine = makeEngine(clock: { activeNow })
    let configuredTurn = TurnTraceContext.mintTurnId()
    try await TurnTraceContext.$bus.withValue(traceBus) {
        try await TurnTraceContext.$turnId.withValue(configuredTurn) {
            let context = try await activeEngine.buildTurnContext(surface: "chat", userMessage: "hello")
            #expect(context.systemSegments?.dynamic.contains("Quiet hours: 7:00 PM–3:00 AM local") == true)
        }
    }
    let configured = try await persistedSummary(for: configuredTurn)
    #expect(try objectValue(try objectValue(configured.payload)["flags"])["clock.quietHoursActive"] == .bool(true))

    let outsideNow = try #require(local.date(from: DateComponents(
        year: 2026, month: 8, day: 11, hour: 10, minute: 0
    )))
    let outsideEngine = makeEngine(clock: { outsideNow })
    let outsideTurn = TurnTraceContext.mintTurnId()
    try await TurnTraceContext.$bus.withValue(traceBus) {
        try await TurnTraceContext.$turnId.withValue(outsideTurn) {
            let context = try await outsideEngine.buildTurnContext(surface: "chat", userMessage: "hello")
            #expect(context.systemSegments?.dynamic.contains("Quiet hours:") == false)
        }
    }
    let outside = try await persistedSummary(for: outsideTurn)
    #expect(try objectValue(try objectValue(outside.payload)["flags"])["clock.quietHoursActive"] == .bool(false))
}

@Test
func turnEngine_quietHoursPreference_isReadExactlyOncePerBareAndHistoryTurn() async throws {
    let dataRoot = try makeTempDir("quiet-hours-single-read")
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let personaRoot = try makeTempDir("quiet-hours-single-read-persona")
    defer { try? FileManager.default.removeItem(at: personaRoot) }
    try writeFile(personaRoot.appendingPathComponent("SOUL.md"), "QUIET-SINGLE-READ")

    var local = Calendar(identifier: .gregorian)
    local.timeZone = .current
    let now = try #require(local.date(from: DateComponents(
        year: 2026, month: 8, day: 27, hour: 22, minute: 0
    )))
    let probe = QuietHoursReadProbe(
        window: TurnQuietHoursWindow(startHour: 19, endHour: 3)
    )
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaRoot),
        memory: nil,
        router: StubRouting(prefs: [
            "chat": SurfacePreference(
                surface: "chat", model: "gpt-5.5", reasoningEffort: "high"
            ),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["unused"]),
        tools: MockToolDispatchClient(),
        clock: { now },
        remPinsDataRoot: dataRoot,
        memoryPromoter: nil,
        quietHoursReader: { probe.read(dataRoot: $0) }
    )

    let bare = try await engine.buildTurnContext(surface: "chat", userMessage: "bare")
    #expect(bare.systemPrompt?.contains("Quiet hours: 7:00 PM–3:00 AM local") == true)
    #expect(probe.count == 1)

    let pinnedHistoryTurn = await engine.captureTurnQuietHoursSnapshot()
    #expect(probe.count == 2)
    let history = try await engine.buildTurnContextWithHistory(
        surface: "chat",
        userMessage: "history",
        sessionId: "quiet-history",
        historyLimit: 0,
        historyReader: SessionHistoryReader(dataRoot: dataRoot),
        personaOverride: nil,
        clockNowOverride: now,
        quietHoursSnapshot: pinnedHistoryTurn
    )
    #expect(history.systemPrompt?.contains("Quiet hours: 7:00 PM–3:00 AM local") == true)
    #expect(probe.count == 2)

    // A native-tools loop may rebuild context after a load. Reusing the same
    // turn snapshot keeps the preference read count pinned across iterations.
    _ = try await engine.buildTurnContextWithHistory(
        surface: "chat",
        userMessage: "history iteration 2",
        sessionId: "quiet-history",
        historyLimit: 0,
        historyReader: SessionHistoryReader(dataRoot: dataRoot),
        personaOverride: nil,
        clockNowOverride: now,
        quietHoursSnapshot: pinnedHistoryTurn
    )
    #expect(probe.count == 2)
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

    // The clock line changes EVERY turn, so it must never land in the stable
    // (cacheable) segment — a per-turn byte in the stable prefix would churn
    // the provider cache for the whole session.
    #expect(seg.stable.contains("CLOCK-STABLE-PERSONA"))
    #expect(!seg.stable.contains("Local time:"))
    #expect(!seg.stable.contains("Current time:"))
    #expect(seg.dynamic.contains("Local time:"))
    // The zone identifier rides along so the model never has to guess it.
    #expect(seg.dynamic.contains("(\(TimeZone.current.identifier))"))
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
    let clock = try #require(seg.dynamic.range(of: "Local time:"))
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

/// Ledger row `speed.rem_pins.read` (core.substrate.organism).
///
/// The REM index is synchronous disk I/O on the ordinary turn path.  A valid
/// index, deletion, and malformed replacement must all pass through the real
/// read stage, emit the stage timing, and never retain stale bytes in the
/// prompt. Merely exercising `REMPinsReader` directly would not prove that the
/// turn engine still performs and traces the read.
@Test
func turnEngine_remPinsReadStage_hasNoStaleCacheAfterDeleteOrMalformedIndex() async throws {
    let dataRoot = try makeTempDir("rem-pins-stage")
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let personaRoot = try makeTempDir("rem-pins-stage-persona")
    defer { try? FileManager.default.removeItem(at: personaRoot) }
    try writeFile(personaRoot.appendingPathComponent("SOUL.md"), "REM-STAGE-PERSONA")

    let pinsURL = dataRoot.appendingPathComponent("rem_pins.json")
    try """
    {"GROWTH.md":[{"id":"pin-stage","text":"REM-PIN-MARKER","createdAt":"2026-06-01T00:00:00Z"}]}
    """.write(to: pinsURL, atomically: true, encoding: .utf8)

    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaRoot),
        memory: nil,
        router: StubRouting(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["unused"]),
        tools: MockToolDispatchClient(),
        remPinsDataRoot: dataRoot,
        memoryPromoter: nil
    )

    func summaryStage(_ event: TurnTraceEvent) throws -> JSONValue? {
        let payload = try objectValue(event.payload)
        let stages = try objectValue(payload["stageMs"])
        return stages["rem_pins.read"]
    }

    let healthyTurn = TurnTraceContext.mintTurnId()
    let healthyEvents = await collectTraceEvents(kind: "context.summary", turnId: healthyTurn) {
        await TurnTraceContext.$turnId.withValue(healthyTurn) {
            let context = try? await engine.buildTurnContext(
                surface: "chat", userMessage: "hello", personaOverride: nil,
                imageBlocks: [], includeClockContext: false
            )
            #expect(context?.systemPrompt?.contains("REM-PIN-MARKER") == true)
        }
    }
    #expect(healthyEvents.count == 1)
    let healthyEvent = try #require(healthyEvents.first)
    #expect(try summaryStage(healthyEvent) != nil)

    // Deletion is a distinct adverse persistent state from malformed bytes:
    // the previous valid contents must not be retained in an engine-local
    // cache, and the ordinary timed read must still occur.
    try FileManager.default.removeItem(at: pinsURL)
    let deletedTurn = TurnTraceContext.mintTurnId()
    let deletedEvents = await collectTraceEvents(kind: "context.summary", turnId: deletedTurn) {
        await TurnTraceContext.$turnId.withValue(deletedTurn) {
            let context = try? await engine.buildTurnContext(
                surface: "chat", userMessage: "hello", personaOverride: nil,
                imageBlocks: [], includeClockContext: false
            )
            #expect(context?.systemPrompt?.contains("REM-PIN-MARKER") == false)
        }
    }
    #expect(deletedEvents.count == 1)
    let deletedEvent = try #require(deletedEvents.first)
    #expect(try summaryStage(deletedEvent) != nil)

    // Corrupt replacement bytes are an adverse persistent state: they must
    // fail closed (no injection) without silently bypassing the timed stage.
    try "{not-json".write(to: pinsURL, atomically: true, encoding: .utf8)
    let corruptTurn = TurnTraceContext.mintTurnId()
    let corruptEvents = await collectTraceEvents(kind: "context.summary", turnId: corruptTurn) {
        await TurnTraceContext.$turnId.withValue(corruptTurn) {
            let context = try? await engine.buildTurnContext(
                surface: "chat", userMessage: "hello", personaOverride: nil,
                imageBlocks: [], includeClockContext: false
            )
            #expect(context?.systemPrompt?.contains("REM-PIN-MARKER") == false)
        }
    }
    #expect(corruptEvents.count == 1)
    let corruptEvent = try #require(corruptEvents.first)
    #expect(try summaryStage(corruptEvent) != nil)
}

@Test
func turnEngine_remPinDedupeDoesNotDropEmptyPreviewRecallHits() async throws {
    let dataRoot = try makeTempDir("rem-pin-empty-preview")
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let personaRoot = try makeTempDir("rem-pin-empty-preview-persona")
    defer { try? FileManager.default.removeItem(at: personaRoot) }
    try writeFile(personaRoot.appendingPathComponent("SOUL.md"), "REM-PIN-EMPTY-PREVIEW")
    try """
    {"GROWTH.md":[{"id":"pin-empty","text":"Pinned durable fact","createdAt":"2026-06-01T00:00:00Z"}]}
    """.write(
        to: dataRoot.appendingPathComponent("rem_pins.json"),
        atomically: true,
        encoding: .utf8
    )

    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaRoot),
        memory: ScriptedMemoryRecaller(hits: [
            MemoryRecallHit(score: 0.9, preview: "", content: "full memory body")
        ]),
        router: StubRouting(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["unused"]),
        tools: MockToolDispatchClient(),
        remPinsDataRoot: dataRoot,
        memoryPromoter: nil
    )

    let context = try await engine.buildTurnContext(
        surface: "chat",
        userMessage: "recall the pinned fact",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )
    #expect(context.systemPrompt?.contains("Pinned durable fact") == true)
    #expect(context.recalled.count == 1, "empty preview must not self-match every pin")
    #expect(context.recalled.first?.preview == "")
}

@Test
func turnEngine_remPinDedupeStillDropsNonEmptyPreviewDuplicates() async throws {
    let dataRoot = try makeTempDir("rem-pin-nonempty-preview")
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let personaRoot = try makeTempDir("rem-pin-nonempty-preview-persona")
    defer { try? FileManager.default.removeItem(at: personaRoot) }
    try writeFile(personaRoot.appendingPathComponent("SOUL.md"), "REM-PIN-NONEMPTY-PREVIEW")
    try """
    {"GROWTH.md":[{"id":"pin-dup","text":"Pinned durable fact about User","createdAt":"2026-06-01T00:00:00Z"}]}
    """.write(
        to: dataRoot.appendingPathComponent("rem_pins.json"),
        atomically: true,
        encoding: .utf8
    )

    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaRoot),
        memory: ScriptedMemoryRecaller(hits: [
            MemoryRecallHit(score: 0.9, preview: "Pinned durable fact", content: "full memory body")
        ]),
        router: StubRouting(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["unused"]),
        tools: MockToolDispatchClient(),
        remPinsDataRoot: dataRoot,
        memoryPromoter: nil
    )

    let context = try await engine.buildTurnContext(
        surface: "chat",
        userMessage: "recall the pinned fact",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )
    #expect(context.systemPrompt?.contains("Pinned durable fact about User") == true)
    #expect(context.recalled.isEmpty, "non-empty overlapping previews should still dedupe")
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

@Test(.timeLimit(.minutes(1)))
func turnEngine_toolCatalogWalks_enterConcurrently_andPreserveResults() async throws {
    let dir = try makeTempDir("tool-catalog-overlap")
    defer { try? FileManager.default.removeItem(at: dir) }
    let schema = LLMToolSchema(
        name: "beta",
        description: "Beta tool",
        parametersJSON: Data(#"{"type":"object"}"#.utf8)
    )
    let gate = CatalogWalkGate()
    let tools = CoordinatedCatalogToolClient(
        gate: gate,
        names: ["zeta", "beta"],
        schemas: [schema]
    )
    let engine = makeEngine(
        persona: hermeticPersona(root: dir),
        llm: MockLLMClient(scriptedResponses: ["unused"]),
        tools: tools
    )

    let build = Task {
        try await engine.buildTurnContext(surface: "chat", userMessage: "hi")
    }
    await gate.waitUntilBothEntered()
    #expect(await gate.entryCount() == 2)
    await gate.release()
    let context = try await build.value

    // The overlap changes scheduling only. Dispatcher order remains canonical.
    #expect(context.toolsAvailable == ["zeta", "beta"])
    #expect(context.toolSchemas == [schema])
}

@Test
func turnEngine_schemaSeed_scopesContextExpansionWithoutRepeatingCatalogWalk() async throws {
    let dir = try makeTempDir("tool-schema-seed")
    defer { try? FileManager.default.removeItem(at: dir) }
    let seeded = LLMToolSchema(
        name: "seeded",
        description: "Preloaded schema",
        parametersJSON: Data(#"{"type":"object"}"#.utf8)
    )
    let live = LLMToolSchema(
        name: "live",
        description: "Fresh schema",
        parametersJSON: Data(#"{"type":"object"}"#.utf8)
    )
    let tools = SnapshotToolClient(names: ["live"], schemas: [live])
    let engine = makeEngine(
        persona: hermeticPersona(root: dir),
        llm: MockLLMClient(scriptedResponses: ["unused", "unused"]),
        tools: tools
    )

    let reused = try await engine.buildTurnContext(
        surface: "chat",
        userMessage: "reuse",
        personaOverride: nil,
        imageBlocks: [],
        toolSchemaCatalogSeed: TurnToolSchemaCatalogSeed(schemas: [seeded])
    )
    #expect(reused.toolSchemas == [seeded])
    #expect(tools.namesCalls == 1)
    #expect(tools.schemasCalls == 0)

    // No ContextFlow packet means context_expand is ineligible. Filtering that
    // one packet-scoped schema must not throw away the rest of the eager
    // catalog and repeat its registry/MCP walk.
    let contextExpand = LLMToolSchema(
        name: "context_expand",
        description: "Scoped expansion",
        parametersJSON: Data(#"{"type":"object"}"#.utf8)
    )
    let scoped = try await engine.buildTurnContext(
        surface: "chat",
        userMessage: "refresh",
        personaOverride: nil,
        imageBlocks: [],
        toolSchemaCatalogSeed: TurnToolSchemaCatalogSeed(schemas: [contextExpand, seeded])
    )
    #expect(scoped.toolSchemas == [seeded])
    #expect(tools.namesCalls == 2)
    #expect(tools.schemasCalls == 0)

    let readFile = LLMToolSchema(
        name: "read_file",
        description: "Read",
        parametersJSON: Data(#"{"type":"object"}"#.utf8)
    )
    let preload = TurnToolSchemaCatalogSeed(schemas: [readFile, seeded])
    #expect(preload.schemas(contextExpandEligible: false) == [readFile, seeded])
    let expanded = preload.schemas(contextExpandEligible: true)
    #expect(expanded.map(\.name) == ["read_file", "context_expand", "seeded"])
    #expect(expanded[1] == TurnToolSchemaCatalogSeed.canonicalContextExpandSchema)
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

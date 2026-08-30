import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import DreamREMCycle
import Testing
import TrustCenter
@testable import ChatOrchestration
@testable import Context

private final class FluidPersonaStub: PersonaEngineProtocol, @unchecked Sendable {
    enum Failure: Error { case shouldNotRead }

    let docs: [PersonaDoc]
    let throwsOnRead: Bool

    init(docs: [PersonaDoc] = [], throwsOnRead: Bool = false) {
        self.docs = docs
        self.throwsOnRead = throwsOnRead
    }

    func listPersonaDocs() async throws -> [PersonaDoc] {
        if throwsOnRead { throw Failure.shouldNotRead }
        return docs
    }

    func getPersonaDoc(id: String) async throws -> PersonaDoc? {
        if throwsOnRead { throw Failure.shouldNotRead }
        return docs.first { $0.id == id }
    }
}

private final class FluidRoutingStub: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { .init(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { .init() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { .init() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "test-model", reasoningEffort: "low")]
    }
    func activeProvidersForSurfaces() async -> [String: String] { [:] }
}

private actor FluidContextStub: ContextTurnPreparing {
    enum Failure: Error { case unavailable }

    let mode: ContextFlowMode
    let prepared: ContextPreparedTurn?
    let fail: Bool
    private(set) var prepareCount = 0
    private(set) var lastRequest: ContextTurnRequest?

    init(mode: ContextFlowMode, prepared: ContextPreparedTurn? = nil, fail: Bool = false) {
        self.mode = mode
        self.prepared = prepared
        self.fail = fail
    }

    func contextFlowMode() async -> ContextFlowMode { mode }

    func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        prepareCount += 1
        lastRequest = request
        if fail { throw Failure.unavailable }
        return try #require(prepared)
    }
}

private actor FluidMemoryStub: MemoryRecalling {
    private(set) var recallCount = 0
    private(set) var servedHits: [[String]] = []

    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        recallCount += 1
        return [MemoryRecallHit(
            score: 1,
            sessionId: nil,
            role: nil,
            ts: nil,
            preview: "legacy recall must not run",
            content: "legacy recall must not run",
            source: "test"
        )]
    }

    func recordServedContextHits(ids: [String]) async {
        servedHits.append(ids)
    }
}

private func fluidPreparedTurn(
    mode: ContextFlowMode = .active,
    selectionMicroseconds: Int? = 1
) throws -> ContextPreparedTurn {
    let personaID = ContextPersonaID(rawValue: "canonical")
    let fingerprint = "persona-fingerprint"
    let document = try RequiredDocument(
        kind: .soul,
        sourceHash: "soul-hash",
        text: "RAM identity",
        tokenCount: 2
    )
    let key = try StablePromptKernelKey(
        personaID: personaID,
        surfaceVariant: ContextSurfaceVariant(rawValue: "chat"),
        sourceFingerprint: fingerprint
    )
    let kernel = try StablePromptKernel(
        key: key,
        renderedPrompt: "# SOUL\nRAM identity",
        includedDocumentIDs: [document.id],
        tokenCount: 4
    )
    let mirror = try RequiredDocumentMirror(
        personaID: personaID,
        sourceFingerprint: fingerprint,
        documents: [document],
        kernels: [kernel]
    )
    let snapshot = try ContextGenerationSnapshot(
        generationID: 1,
        sourceFingerprint: "generation-fingerprint",
        requiredDocumentMirrors: [mirror]
    )
    let arena = try ContextArena(budget: .mib32)
    _ = arena.publish(snapshot)
    let lease = try arena.acquireSnapshot()
    let budget = ContextBudgetUsage(
        characterLimit: 6_000,
        usedCharacters: 0,
        mandatoryCharacters: 0
    )
    let receipt = ContextSelectionReceipt(
        id: "receipt",
        needFingerprint: "need",
        generationID: 1,
        sourceFingerprint: snapshot.sourceFingerprint,
        selectionTimeBucket: 1,
        eligibility: [],
        candidateScores: [],
        selectedAtomIDs: [],
        pointerAtomIDs: [],
        mandatoryAtomIDs: [],
        coveredMandatoryAtomIDs: [],
        mandatoryCoverage: 1,
        conflicts: [],
        budget: budget,
        degradedSources: [],
        cacheState: .hit,
        measuredSelectionMicroseconds: selectionMicroseconds
    )
    let packet = ContextPacket(
        generationID: 1,
        sourceFingerprint: snapshot.sourceFingerprint,
        selectedItems: [],
        expandablePointers: [],
        conflictSets: [],
        degradedSources: [],
        budget: budget,
        receipt: receipt
    )
    return ContextPreparedTurn(
        mode: mode,
        kernel: kernel,
        mirror: mirror,
        packet: packet,
        lease: lease,
        generation: ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: .distantPast,
                reason: "test",
                sourceFingerprint: snapshot.sourceFingerprint,
                atomCount: 0,
                sourceCount: 0
            ),
            sources: [],
            atoms: [],
            relationships: []
        ),
        need: NeedSignal(
            message: "hello",
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate],
                allowedSourceIDs: []
            ),
            availableGenerationID: 1
        )
    )
}

private func fluidEngine(
    persona: any PersonaEngineProtocol,
    flow: (any ContextTurnPreparing)?,
    memory: (any MemoryRecalling)? = nil,
    tools: any ToolDispatchClient = MockToolDispatchClient()
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: persona,
        memory: memory,
        router: FluidRoutingStub(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: tools,
        contextFlow: flow
    )
}

private actor FluidCancellationGate {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor GatedFluidContextStub: ContextTurnPreparing {
    let prepared: ContextPreparedTurn
    let gate: FluidCancellationGate
    let throwsAfterGate: Bool

    init(prepared: ContextPreparedTurn, gate: FluidCancellationGate, throwsAfterGate: Bool) {
        self.prepared = prepared
        self.gate = gate
        self.throwsAfterGate = throwsAfterGate
    }

    func contextFlowMode() async -> ContextFlowMode { .active }
    func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        await gate.suspend()
        if throwsAfterGate { throw CancellationError() }
        return prepared
    }
}

private actor GatedFluidCatalog: ToolDispatchClient {
    let gate: FluidCancellationGate
    init(gate: FluidCancellationGate) { self.gate = gate }
    func listAvailableTools() async throws -> [String] {
        await gate.suspend()
        return []
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue { .null }
}

@Test(arguments: ["prepared_packet", "prepare_error", "later_catalog"])
func cancelledContextAssemblyDoesNotReturnHealthyContextOrRecordServedMemories(boundary: String) async throws {
    let prepared = try fluidPreparedTurn()
    prepared.attachMemoryRecordProvenance(["cancelled-memory"])
    let gate = FluidCancellationGate()
    let memory = FluidMemoryStub()
    let flow: any ContextTurnPreparing
    let tools: any ToolDispatchClient
    if boundary == "later_catalog" {
        flow = FluidContextStub(mode: .active, prepared: prepared)
        tools = GatedFluidCatalog(gate: gate)
    } else {
        flow = GatedFluidContextStub(prepared: prepared, gate: gate, throwsAfterGate: boundary == "prepare_error")
        tools = MockToolDispatchClient()
    }
    let engine = fluidEngine(
        persona: FluidPersonaStub(docs: [PersonaDoc(id: "SOUL", content: "fixture identity", sizeBytes: 16, mtime: .distantPast)]),
        flow: flow, memory: memory, tools: tools
    )
    let preparation = Task { () -> Bool in
        do {
            _ = try await engine.buildTurnContext(
                surface: "chat", userMessage: "hello", personaOverride: nil,
                imageBlocks: [], includeClockContext: false
            )
            return false
        } catch is CancellationError {
            return true
        } catch {
            Issue.record("expected cancellation, received \(error)")
            return false
        }
    }
    await gate.waitUntilEntered()
    preparation.cancel()
    await gate.release()
    #expect(await preparation.value, "cancelled assembly must not return a healthy context")
    #expect(await memory.servedHits.isEmpty)
    #expect(await memory.recallCount == 0, "cancellation is not ordinary fallback recall")
}

@Test func uncancelledProviderCancellationErrorRetainsOrdinaryContextFallback() async throws {
    let gate = FluidCancellationGate()
    let flow = GatedFluidContextStub(prepared: try fluidPreparedTurn(), gate: gate, throwsAfterGate: true)
    let memory = FluidMemoryStub()
    let engine = fluidEngine(
        persona: FluidPersonaStub(docs: [PersonaDoc(id: "SOUL", content: "fixture identity", sizeBytes: 16, mtime: .distantPast)]),
        flow: flow, memory: memory
    )
    let preparation = Task { () throws -> Bool in
        let context = try await engine.buildTurnContext(
            surface: "chat", userMessage: "hello", personaOverride: nil,
            imageBlocks: [], includeClockContext: false
        )
        return context.fluidContextTurn == nil && context.recalled.count == 1
    }
    await gate.waitUntilEntered()
    await gate.release()
    #expect(try await preparation.value)
    #expect(await memory.recallCount == 1)
    #expect(await memory.servedHits.isEmpty)
}

@Test func activeFluidContextDoesNotRunTheDuplicateLegacyMemoryRecall() async throws {
    let prepared = try fluidPreparedTurn()
    let flow = FluidContextStub(mode: .active, prepared: prepared)
    let memory = FluidMemoryStub()
    let context = try await fluidEngine(
        persona: FluidPersonaStub(throwsOnRead: true),
        flow: flow,
        memory: memory
    ).buildTurnContext(
        surface: "chat",
        userMessage: "hello",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )

    #expect(context.recalled.isEmpty)
    #expect(await memory.recallCount == 0)
}

@Test func activeFluidContextBumpsUseCountForPacketServedMemories() async throws {
    let prepared = try fluidPreparedTurn()
    prepared.attachMemoryRecordProvenance(["rec-b", "rec-a"])
    let flow = FluidContextStub(mode: .active, prepared: prepared)
    let memory = FluidMemoryStub()
    _ = try await fluidEngine(
        persona: FluidPersonaStub(throwsOnRead: true),
        flow: flow,
        memory: memory
    ).buildTurnContext(
        surface: "chat",
        userMessage: "hello",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )

    // The serve bump is fire-and-forget off the turn path — poll under a
    // deadline instead of sleeping blind (hangproof convention).
    // The deadline is generous (10s) because under full-suite parallelism the
    // detached bump Task can starve for seconds behind other suites' work; the
    // claim under test is that the bump EVENTUALLY lands, not that it lands
    // fast. Still bounded, so a bump that never fires fails instead of hanging.
    var hits: [[String]] = []
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        hits = await memory.servedHits
        if !hits.isEmpty { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hits.count == 1)
    // attachMemoryRecordProvenance dedupes and sorts; the bump serves that set.
    #expect(hits.first == ["rec-a", "rec-b"])
    #expect(await memory.recallCount == 0)
}

@Test func fluidTurnWithoutProvenanceNeverBumps() async throws {
    let prepared = try fluidPreparedTurn()
    let flow = FluidContextStub(mode: .active, prepared: prepared)
    let memory = FluidMemoryStub()
    _ = try await fluidEngine(
        persona: FluidPersonaStub(throwsOnRead: true),
        flow: flow,
        memory: memory
    ).buildTurnContext(
        surface: "chat",
        userMessage: "hello",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )
    // Bounded settle window: the no-bump claim needs the fire-and-forget lane
    // a beat to (not) run before asserting emptiness.
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(await memory.servedHits.isEmpty)
}

@Test func activeFluidContextUsesRAMKernelWithoutReadingPersona() async throws {
    let prepared = try fluidPreparedTurn()
    let flow = FluidContextStub(mode: .active, prepared: prepared)
    let engine = fluidEngine(
        persona: FluidPersonaStub(throwsOnRead: true),
        flow: flow
    )

    let context = try await engine.buildTurnContext(
        surface: "chat",
        userMessage: "hello",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )

    #expect(context.systemPrompt == "# SOUL\nRAM identity\n\n\(NaturalExpressionGuidance.baseline)")
    #expect(context.personaDocs == ["SOUL": "RAM identity"])
    #expect(context.fluidContextTurn === prepared)
    #expect(await flow.prepareCount == 1)
}

@Test func sharedTurnEngineKeepsNormalPacketLeanWithBoundedMandatoryGrowthRoom() async throws {
    let prepared = try fluidPreparedTurn()
    let flow = FluidContextStub(mode: .active, prepared: prepared)
    let engine = fluidEngine(
        persona: FluidPersonaStub(throwsOnRead: true),
        flow: flow
    )

    _ = try await engine.buildTurnContext(
        surface: "chat",
        userMessage: "hello",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )

    let request = try #require(await flow.lastRequest)
    #expect(request.characterBudget == 6_000)
    #expect(request.maximumCharacterBudget == 24_000)
    #expect(request.postMandatoryCharacterReserve == 4_000)
}

@Test func activeFluidContextFailureFallsBackToCurrentPersonaPath() async throws {
    let flow = FluidContextStub(mode: .active, fail: true)
    let persona = FluidPersonaStub(docs: [
        PersonaDoc(id: "SOUL", content: "disk identity", sizeBytes: 13, mtime: .distantPast),
    ])
    let context = try await fluidEngine(persona: persona, flow: flow).buildTurnContext(
        surface: "chat",
        userMessage: "hello",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )

    #expect(context.systemPrompt?.contains("disk identity") == true)
    #expect(context.fluidContextTurn == nil)
}

@Test func shadowFluidContextNeverChangesPromptBytes() async throws {
    let prepared = try fluidPreparedTurn(mode: .shadow)
    let flow = FluidContextStub(mode: .shadow, prepared: prepared)
    let persona = FluidPersonaStub(docs: [
        PersonaDoc(
            id: "SOUL",
            content: "production identity",
            sizeBytes: 19,
            mtime: .distantPast
        ),
    ])
    let context = try await fluidEngine(persona: persona, flow: flow).buildTurnContext(
        surface: "chat",
        userMessage: "hello",
        personaOverride: nil,
        imageBlocks: [],
        includeClockContext: false
    )

    #expect(context.systemPrompt?.contains("production identity") == true)
    #expect(context.systemPrompt?.contains("RAM identity") == false)
    #expect(context.fluidContextTurn == nil)
    for _ in 0..<50 {
        if await flow.prepareCount > 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await flow.prepareCount == 1)
}

@Test func generationLeaseSurvivesTurnContextTransformations() throws {
    let prepared = try fluidPreparedTurn()
    let base = TurnContext(
        surface: "chat",
        personaDocs: ["SOUL": "RAM identity"],
        recalled: [],
        modelId: "test-model",
        reasoningEffort: "low",
        toolsAvailable: [],
        systemPrompt: "# SOUL\nRAM identity",
        userMessage: "hello",
        systemSegments: SystemPromptSegments(stable: "# SOUL\nRAM identity", dynamic: ""),
        fluidContextTurn: prepared
    )

    let clocked = SwiftNativeTurnEngine.contextByAppendingClockContext(
        base,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        localTimeZone: TimeZone(secondsFromGMT: 0)!
    )
    let runtime = SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
        clocked,
        runtimeContext: "runtime state"
    )

    #expect(clocked.fluidContextTurn === prepared)
    #expect(runtime.fluidContextTurn === prepared)
    #expect(!prepared.lease.isReleased)
}

// MARK: - Packet provenance (2026-07-11)

/// The prepared turn's memory-record provenance seam: attach-once, bounded,
/// deterministic — and the TurnContext union that feeds recalledIds on active
/// turns where ctx.recalled is empty because memory rides the packet.
@Suite("PacketProvenance")
struct PacketProvenanceTests {

    @Test func attachIsBoundedDedupedSortedAndOnce() throws {
        let prepared = try fluidPreparedTurn()
        #expect(prepared.selectedMemoryRecordIDs.isEmpty, "unattached == empty == pre-provenance")

        let noisy = (0..<40).map { "rec-\(String(format: "%02d", $0))" } + ["rec-00", "", "rec-01"]
        prepared.attachMemoryRecordProvenance(noisy)
        let ids = prepared.selectedMemoryRecordIDs
        #expect(ids.count == 32, "cap 32: \(ids.count)")
        #expect(ids == ids.sorted(), "deterministic order")
        #expect(Set(ids).count == ids.count, "deduped")
        #expect(!ids.contains(""), "empties dropped")

        prepared.attachMemoryRecordProvenance(["rec-late"])
        #expect(!prepared.selectedMemoryRecordIDs.contains("rec-late"),
                "attach-once: a second attach must be ignored")
    }

    @Test func emptyAttachStillLatchesNothing() throws {
        let prepared = try fluidPreparedTurn()
        prepared.attachMemoryRecordProvenance([])
        // An empty attach latches the empty value; a later real attach is
        // ignored. The runtime never attaches empty (it guards), but the seam
        // must stay deterministic either way.
        prepared.attachMemoryRecordProvenance(["rec-a"])
        #expect(prepared.selectedMemoryRecordIDs.isEmpty)
    }

    @Test func resolvedRecalledIdsUnionsLegacyAndPacketProvenance() throws {
        let prepared = try fluidPreparedTurn()
        prepared.attachMemoryRecordProvenance(["rec-b", "rec-a", "rec-legacy"])

        let legacy = MemoryRecallHit(
            score: 1, sessionId: nil, role: nil, ts: nil,
            preview: "p", content: nil, source: "test",
            rankingSignals: nil,
            extras: .object(["id": .string("rec-legacy")])
        )
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [legacy],
            modelId: "m",
            reasoningEffort: "low",
            toolsAvailable: [],
            systemPrompt: nil,
            userMessage: "hi",
            fluidContextTurn: prepared
        )
        // Legacy hit keeps first position; packet additions follow sorted;
        // the shared id appears exactly once.
        #expect(ctx.resolvedRecalledIds == ["rec-legacy", "rec-a", "rec-b"])
    }

    @Test func activeTurnWithNoLegacyRecallStampsFromPacketAlone() throws {
        let prepared = try fluidPreparedTurn()
        prepared.attachMemoryRecordProvenance(["rec-2", "rec-1"])
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "m",
            reasoningEffort: "low",
            toolsAvailable: [],
            systemPrompt: nil,
            userMessage: "hi",
            fluidContextTurn: prepared
        )
        #expect(ctx.resolvedRecalledIds == ["rec-1", "rec-2"],
                "the mind-into-circulation gap: this was [] before provenance")
    }

    @Test func noFluidTurnKeepsLegacyBehaviorByteIdentical() {
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "m",
            reasoningEffort: "low",
            toolsAvailable: [],
            systemPrompt: nil,
            userMessage: "hi"
        )
        #expect(ctx.resolvedRecalledIds.isEmpty)
    }

    /// Conformance pin (2026-07-24): PersonaEngine cannot import Context, so
    /// its default-persona resolver keeps a private "canonical" literal while
    /// the coordinator's resident-owns-memory-store gate compares against
    /// `ContextPersonaID.resident`. If either side drifts, the gate silently
    /// stops matching and every memory source vanishes from live selection —
    /// exactly the vocabulary-mismatch class this pin exists to catch.
    @Test func personaEngineDefaultPersonaIdMatchesContextResident() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResidentConformance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "conformance soul\n".write(
            to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8
        )
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        let compiler = PersonaCompiler(
            engine: SwiftNativePersonaEngine(root: root, dataRoot: dataRoot)
        )

        let snapshot = try await compiler.contextSourceSnapshot(surface: "chat")

        #expect(snapshot.packet.personaKind == "Default")
        #expect(snapshot.packet.personaId == ContextPersonaID.resident.rawValue)
    }

    /// PRODUCT POLICY (User approved, 2026-07-24): a persona slot id is
    /// PRESENTATION-ONLY — EVERY slot recalls from the one shared memory store,
    /// unfiltered. Regression history on both halves:
    ///   * Resident: "canonical" used to be passed through and zero-hit every
    ///     record (both the auto-recall lane and the recall_memory tool).
    ///   * Custom slots: passing "Agent" through wasn't isolation, it was an
    ///     unmintable scope — record persona ids are AGENT NAMES, so the filter
    ///     protected an empty set forever and killed the whole memory lane.
    /// Compartmentalization, if ever wanted, belongs to the per-record
    /// disclosure layer, not to this filter.
    @Test func memoryRecallPersonaFilterMapsEveryPersonaSlotToUnfiltered() {
        #expect(memoryRecallPersonaFilter(ContextPersonaID.resident.rawValue) == nil)
        #expect(memoryRecallPersonaFilter(nil) == nil)
        // A custom persona SLOT id — deliberately NOT the record vocabulary.
        #expect(memoryRecallPersonaFilter("Agent") == nil)
        // Even a slot id that collides with a live agent name resolves to the
        // shared store: this helper answers about SLOTS, not records.
        #expect(memoryRecallPersonaFilter("Agent") == nil)
    }
}

// MARK: - memory.recallHits counts the RESOLVED lane (2026-08-21)

/// On an `.active` turn the legacy `recall()` lane is skipped by design and
/// memory rides the packet, so a counter over `recalled.count` read 0 on
/// 511/511 live turns while `contextFlow.memoryRecords` averaged ~12. The
/// trace counter must follow `resolvedRecalledIds` (legacy ∪ packet
/// provenance) — the union the recalled-memory stamp actually consumes — and
/// `memoryRecall.injectedHitCount` must agree with it. The legacy-only count
/// keeps its own honest lane name.
@Test func contextSummaryRecallHitsCountsResolvedPacketProvenanceOnActiveTurns() async throws {
    let prepared = try fluidPreparedTurn()
    prepared.attachMemoryRecordProvenance(["rec-c", "rec-a", "rec-b"])
    let flow = FluidContextStub(mode: .active, prepared: prepared)
    let memory = FluidMemoryStub()
    let engine = fluidEngine(
        persona: FluidPersonaStub(throwsOnRead: true),
        flow: flow,
        memory: memory
    )

    let traceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("recallhits-resolved-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: traceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: traceRoot) }
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: traceRoot))
    let sub = await bus.subscribe()
    let turnId = TurnTraceContext.mintTurnId()
    let drain = Task { () -> TurnTraceEvent? in
        for await event in sub.stream where event.kind == "context.summary" && event.turnId == turnId {
            return event
        }
        return nil
    }

    let context = try await TurnTraceContext.$bus.withValue(bus) {
        try await TurnTraceContext.$turnId.withValue(turnId) {
            try await engine.buildTurnContext(
                surface: "chat",
                userMessage: "hello",
                personaOverride: nil,
                imageBlocks: [],
                includeClockContext: false
            )
        }
    }
    let stopper = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await bus.unsubscribe(sub.id)
    }
    let event = try #require(await drain.value, "no context.summary receipt within 3s")
    stopper.cancel()
    await bus.unsubscribe(sub.id)

    guard case .object(let payload) = event.payload,
          case .object(let counts)? = payload["counts"],
          case .object(let memoryRecall)? = payload["memoryRecall"] else {
        Issue.record("context.summary payload missing counts/memoryRecall")
        return
    }
    // Premise: this IS an active turn — legacy recall never ran, memory came
    // via the packet. Without that the assertion below would be vacuous.
    #expect(context.recalled.isEmpty)
    #expect(await memory.recallCount == 0)
    #expect(context.resolvedRecalledIds == ["rec-a", "rec-b", "rec-c"])

    #expect(counts["memory.recallHits"] == .int(3),
            "resolved lane: \(String(describing: counts["memory.recallHits"]))")
    #expect(counts["memory.recallHits.legacy"] == .int(0))
    #expect(counts["contextFlow.memoryRecords"] == .int(3))
    #expect(memoryRecall["outcome"] == .string("contextFlow"))
    #expect(memoryRecall["injectedHitCount"] == .int(3),
            "injected must follow the resolved lane: \(String(describing: memoryRecall["injectedHitCount"]))")
}

// MARK: - A7: the dark stage lanes (persona.compile / memory.recall), 2026-08-28
//
// Both lanes were PRESENT and structurally ZERO on every ContextFlow-active
// turn (431/431 live turns in data/turn_traces/2026-08-25..28, max 1ms) because
// (a) whole-millisecond truncation hides sub-ms work and (b) on the active path
// the real memory retrieval happens inside the packet selector, not in the
// engine's bracket. The stage-budget gate only checks key ABSENCE, so a lane
// that reads 0 forever passes it — these tests are the teeth for the zero case.

private func fluidContextSummaryPayload(
    prepared: ContextPreparedTurn
) async throws -> [String: JSONValue] {
    let flow = FluidContextStub(mode: .active, prepared: prepared)
    let engine = fluidEngine(persona: FluidPersonaStub(throwsOnRead: true), flow: flow)
    let traceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stage-relight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: traceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: traceRoot) }
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: traceRoot))
    let sub = await bus.subscribe()
    let turnId = TurnTraceContext.mintTurnId()
    let drain = Task { () -> TurnTraceEvent? in
        for await event in sub.stream
        where event.kind == "context.summary" && event.turnId == turnId {
            return event
        }
        return nil
    }
    _ = try await TurnTraceContext.$bus.withValue(bus) {
        try await TurnTraceContext.$turnId.withValue(turnId) {
            try await engine.buildTurnContext(
                surface: "chat",
                userMessage: "hello",
                personaOverride: nil,
                imageBlocks: [],
                includeClockContext: false
            )
        }
    }
    let stopper = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await bus.unsubscribe(sub.id)
    }
    let event = try #require(await drain.value, "no context.summary receipt within 3s")
    stopper.cancel()
    await bus.unsubscribe(sub.id)
    guard case .object(let payload) = event.payload else {
        throw FluidStageRelightError.invalidPayload
    }
    return payload
}

private enum FluidStageRelightError: Error { case invalidPayload }

@Test func activeTurnLightsPersonaCompileAndMemoryRecallStages() async throws {
    // 1,500µs of selector latency: proves the lane carries the SELECTOR's real
    // measurement (ceil → 2ms), not the engine's near-zero bracket.
    let prepared = try fluidPreparedTurn(selectionMicroseconds: 1_500)
    let payload = try await fluidContextSummaryPayload(prepared: prepared)
    guard case .object(let stageMs)? = payload["stageMs"],
          case .object(let counts)? = payload["counts"] else {
        Issue.record("context.summary payload missing stageMs/counts")
        return
    }

    #expect(stageMs["memory.recall"] == .int(2),
            "memory.recall: \(String(describing: stageMs["memory.recall"]))")
    #expect(counts["memory.recallMicros"] == .int(1_500))

    // persona.compile brackets the mirror→document map: real work, tens of µs,
    // which is exactly what truncated to a permanent 0 before.
    guard case .int(let personaMs)? = stageMs["persona.compile"],
          case .int(let personaMicros)? = counts["persona.compileMicros"] else {
        Issue.record("persona.compile lane absent: \(stageMs)")
        return
    }
    #expect(personaMs >= 1, "persona.compile still dark: \(personaMs)ms")
    #expect(personaMicros > 0, "persona.compile micros: \(personaMicros)")
}

@Test func absentSelectorLatencySampleIsNotReportedAsFastRecall() async throws {
    // Absence is evidence: the selector reports an unmeasured selection as nil,
    // and on a prepared turn the lane must stay ABSENT — neither the selector's
    // number (there is none) nor the engine bracket's atom-serving time, which
    // is exactly the structural zero this fix removed.
    let prepared = try fluidPreparedTurn(selectionMicroseconds: nil)
    let payload = try await fluidContextSummaryPayload(prepared: prepared)
    if case .object(let counts)? = payload["counts"],
       case .int(let micros)? = counts["memory.recallMicros"] {
        Issue.record("prepared turn with no selector sample reported memory.recallMicros=\(micros) — bracket time laundered into the recall lane")
    }
    if case .object(let stageMs)? = payload["stageMs"],
       stageMs["memory.recall"] != nil {
        Issue.record("prepared turn with no selector sample still carries a stageMs.memory.recall value")
    }
}

// MARK: - B11: an empty preview must not occupy a recall slot

@Test func emptyRecallPreviewsDoNotConsumeMemoryBlockSlots() throws {
    let budget = ContextBudgetPolicy.resolve(windowTokens: nil, surface: "chat")
    func hit(_ text: String) -> MemoryRecallHit {
        MemoryRecallHit(
            score: 1, sessionId: nil, role: nil, ts: nil,
            preview: text, content: nil, source: "test"
        )
    }
    // Every slot filled with blanks, then one real memory behind them.
    var recalled = (0..<budget.recallRowLimit).map { _ in hit("   ") }
    recalled.append(hit("User takes his espresso short"))

    let block = try #require(
        SwiftNativeTurnEngine.renderRecalledMemoryBlock(recalled, budget: budget),
        "the real memory was starved by empty previews"
    )
    #expect(block.contains("User takes his espresso short"))
}

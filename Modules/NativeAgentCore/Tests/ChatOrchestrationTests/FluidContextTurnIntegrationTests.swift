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
}

private func fluidPreparedTurn(mode: ContextFlowMode = .active) throws -> ContextPreparedTurn {
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
        measuredSelectionMicroseconds: 1
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
    memory: (any MemoryRecalling)? = nil
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: persona,
        memory: memory,
        router: FluidRoutingStub(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        contextFlow: flow
    )
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

    #expect(context.systemPrompt == "# SOUL\nRAM identity")
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

import Testing
import Foundation
@testable import ChatOrchestration
@testable import Context
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter

// MARK: - evals-total-coverage · fence core.chat.engine
//
// Ledger row closed here:
//   * chat.toolLoop.fluidContextToolScopeBinding (REPORTS-ONLY → COVERED)
//
// Silent-failure class: dead control with a POLITE ERROR. `context_expand` is
// how the model pulls a pointer's full text mid-turn; if the loop ever stops
// binding FluidContextToolScope.$current (a dispatch path that doesn't route
// through the shared runSingleDispatch, a detached Task around a tool), every
// expand returns `{status: failed, reason: context_generation_unavailable}` —
// a tool RESULT, not an error — and the model answers from the truncated
// packet as if that were all there was.
//
// Every pre-existing test binds the scope ITSELF (FluidContextToolDispatchTests
// wraps each call in `FluidContextToolScope.$current.withValue(...)`), so
// nothing proved the LOOP binds it. This file never binds it: the only way the
// tool can see a generation is if executeTurnWithToolLoop put it there. That is
// exactly the production-inert shape the fluid-context wave shipped once
// already.
//
// The ContextPreparedTurn fixture below mirrors FluidContextToolDispatchTests'
// private one (test helpers do not cross files); it is the same generation /
// pointer / arena-lease shape.

private let fixtureGenerationID: Int64 = 7
private let fixtureGenerationFingerprint = "fluid-context-loop-generation-7"

private func makePreparedTurn(
    offeredAtomIDs: Set<String>,
    pointerGenerationID: Int64? = nil,
    needSurface: ContextSurface = .chat
) throws -> ContextPreparedTurn {
    let offered = makeAtom(
        id: "atom:offered",
        body: "Complete offered procedure text."
    )
    let unoffered = makeAtom(
        id: "atom:unoffered",
        body: "Unselected generation text."
    )
    let atoms = [offered, unoffered]
    let source = makeSource(for: offered)
    let generation = ContextStoredGeneration(
        generation: ContextGenerationRecord(
            id: fixtureGenerationID,
            parentID: fixtureGenerationID - 1,
            createdAt: Date(timeIntervalSince1970: 10_000),
            reason: "tool dispatch fixture",
            sourceFingerprint: fixtureGenerationFingerprint,
            atomCount: atoms.count,
            sourceCount: 1
        ),
        sources: [source],
        atoms: atoms,
        relationships: []
    )

    let pointerGenerationID = pointerGenerationID ?? fixtureGenerationID
    let pointers = atoms
        .filter { offeredAtomIDs.contains($0.draft.id.rawValue) }
        .map { ContextAtomPointer(atom: $0, generationID: pointerGenerationID) }
    let budget = ContextBudgetUsage(
        characterLimit: 6_000,
        usedCharacters: 0,
        mandatoryCharacters: 0
    )
    let receipt = ContextSelectionReceipt(
        id: "selection-receipt",
        needFingerprint: "need-fingerprint",
        generationID: fixtureGenerationID,
        sourceFingerprint: fixtureGenerationFingerprint,
        selectionTimeBucket: 1,
        eligibility: [],
        candidateScores: [],
        selectedAtomIDs: [],
        pointerAtomIDs: pointers.map(\.atomID),
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
        generationID: fixtureGenerationID,
        sourceFingerprint: fixtureGenerationFingerprint,
        selectedItems: [],
        expandablePointers: pointers,
        conflictSets: [],
        degradedSources: [],
        budget: budget,
        receipt: receipt
    )

    let personaID = ContextPersonaID(rawValue: "fixture-persona")
    let document = try RequiredDocument(
        kind: .soul,
        sourceHash: "soul-hash",
        text: "Fixture identity",
        tokenCount: 2
    )
    let kernelKey = try StablePromptKernelKey(
        personaID: personaID,
        surfaceVariant: ContextSurfaceVariant(rawValue: "chat"),
        sourceFingerprint: fixtureGenerationFingerprint
    )
    let kernel = try StablePromptKernel(
        key: kernelKey,
        renderedPrompt: "# SOUL\nFixture identity",
        includedDocumentIDs: [document.id],
        tokenCount: 4
    )
    let mirror = try RequiredDocumentMirror(
        personaID: personaID,
        sourceFingerprint: fixtureGenerationFingerprint,
        documents: [document],
        kernels: [kernel]
    )
    let snapshot = try ContextGenerationSnapshot(
        generationID: fixtureGenerationID,
        sourceFingerprint: fixtureGenerationFingerprint,
        requiredDocumentMirrors: [mirror]
    )
    let arena = try ContextArena(budget: .mib32)
    _ = arena.publish(snapshot)
    let lease = try arena.acquireSnapshot()
    let need = NeedSignal(
        message: "Expand the offered procedure",
        surface: needSurface,
        origin: .localAuthenticated,
        authorization: ContextSelectionAuthorization(
            allowedOrigins: [.localAuthenticated],
            allowedPrivacy: [.localPrivate],
            allowedSourceIDs: [source.descriptor.id]
        ),
        availableGenerationID: fixtureGenerationID,
        now: Date(timeIntervalSince1970: 20_000),
        timeBucketSeconds: 60
    )

    return ContextPreparedTurn(
        mode: .active,
        kernel: kernel,
        mirror: mirror,
        packet: packet,
        lease: lease,
        generation: generation,
        need: need
    )
}

private func makeAtom(id: String, body: String) -> ContextStoredAtom {
    let atomID = ContextAtomID(rawValue: id)
    let draft = ContextAtomDraft(
        id: atomID,
        sourceID: ContextSourceID(rawValue: "source:fixture"),
        kind: .procedure,
        headingPath: ["Procedure"],
        sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
        sourceHash: "source-hash-v1",
        body: body,
        deterministicSummary: "Procedure summary",
        authority: .approved,
        confidence: 0.9,
        freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 18_000)),
        privacy: .localPrivate,
        permittedSurfaces: [.chat],
        injectionPolicy: .onDemand,
        contentRole: .procedure
    )
    return ContextStoredAtom(
        versionKey: "\(id)@\(fixtureGenerationID)",
        draft: draft,
        validFromGeneration: 1,
        validToGeneration: nil
    )
}

private func makeSource(for atom: ContextStoredAtom) -> ContextStoredSource {
    ContextStoredSource(
        descriptor: ContextSourceDescriptor(
            id: atom.draft.sourceID,
            owner: "fixture",
            kind: .skill,
            canonicalLocator: "fixture.md",
            authority: .approved,
            privacy: .localPrivate,
            permittedSurfaces: [.chat],
            injectionPolicy: .onDemand
        ),
        sourceHash: atom.draft.sourceHash,
        health: .healthy,
        lastError: nil,
        validFromGeneration: 1,
        validToGeneration: nil
    )
}

// MARK: - loop wiring

private struct FluidLoopPersona: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class FluidLoopRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "fluid-model", reasoningEffort: "high")]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
}

/// A dispatcher that reports what the LOOP put in FluidContextToolScope at
/// dispatch time. It never binds the scope itself — that is the whole point.
private final class ScopeObservingDispatch: ToolDispatchClient, @unchecked Sendable {
    nonisolated(unsafe) private(set) var observedGenerationIDs: [Int64?] = []
    nonisolated(unsafe) private(set) var observedPointerCounts: [Int?] = []

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let prepared = FluidContextToolScope.current
        observedGenerationIDs.append(prepared?.packet.generationID)
        observedPointerCounts.append(prepared?.packet.expandablePointers.count)
        // A child task must inherit the binding too — a tool that hops off the
        // structured chain is the other way this control goes dead.
        let childSaw = await Task { FluidContextToolScope.current?.packet.generationID }.value
        return .object([
            "ok": .bool(true),
            "childSawGenerationID": childSaw.map { JSONValue.int($0) } ?? .null,
        ])
    }

    func listAvailableTools() async throws -> [String] { ["recall_memory"] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [LLMToolSchema(
            name: "recall_memory",
            description: "scope probe",
            parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
        )]
    }
}

private final class FluidLoopLLM: LLMClient, @unchecked Sendable {
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

private func fluidLoopToolCall(id: String, name: String) -> String {
    #"{"tool_calls":[{"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]}"#
}

private func makeFluidLoopEngine(
    llm: any LLMClient,
    tools: any ToolDispatchClient
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: FluidLoopPersona(),
        memory: nil,
        router: FluidLoopRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

private func contextCarryingTurnContext(_ prepared: ContextPreparedTurn) -> TurnContext {
    TurnContext(
        surface: "chat",
        personaDocs: [:],
        recalled: [],
        modelId: "fluid-model",
        reasoningEffort: "high",
        toolsAvailable: ["recall_memory"],
        systemPrompt: "sys",
        userMessage: "expand the procedure",
        toolSchemas: [LLMToolSchema(
            name: "recall_memory",
            description: "scope probe",
            parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
        )],
        fluidContextTurn: prepared
    )
}

// MARK: - tests

@Test
func toolLoop_bindsTheFluidContextScopeAroundEveryDispatch_withoutTheTestBindingIt() async throws {
    #expect(FluidContextToolScope.current == nil, "the test must not pre-bind the scope")
    let prepared = try makePreparedTurn(offeredAtomIDs: ["atom:offered"])
    let tools = ScopeObservingDispatch()
    let llm = FluidLoopLLM(scripted: [
        fluidLoopToolCall(id: "c1", name: "recall_memory"),
        "answered from the expanded pointer",
    ])
    let engine = makeFluidLoopEngine(llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "expand the procedure",
        llm: llm,
        tools: tools,
        preBuiltContext: contextCarryingTurnContext(prepared)
    )

    #expect(result.reply == "answered from the expanded pointer")
    // THE WIRING ASSERTION: the tool saw THIS turn's generation, and it could
    // only have come from the loop.
    #expect(tools.observedGenerationIDs == [fixtureGenerationID])
    #expect(tools.observedPointerCounts == [1])
    // The binding survived into a task spawned inside the tool.
    let record = try #require(result.toolDispatches.first)
    #expect(record.result == .object([
        "ok": .bool(true),
        "childSawGenerationID": .int(fixtureGenerationID),
    ]))
    // And the scope did not leak past the turn.
    #expect(FluidContextToolScope.current == nil)
}

@Test
func streamingToolLoop_bindsTheFluidContextScopeToo() async throws {
    let prepared = try makePreparedTurn(offeredAtomIDs: ["atom:offered"])
    let tools = ScopeObservingDispatch()
    let llm = FluidLoopLLM(scripted: [
        fluidLoopToolCall(id: "c1", name: "recall_memory"),
        "streamed answer",
    ])
    let engine = makeFluidLoopEngine(llm: llm, tools: tools)

    let result = try await engine.executeTurnWithStreamingToolLoop(
        userMessage: "expand the procedure",
        llm: llm,
        tools: tools,
        preBuiltContext: contextCarryingTurnContext(prepared)
    )

    #expect(result.reply == "streamed answer")
    #expect(tools.observedGenerationIDs == [fixtureGenerationID])
    #expect(tools.observedPointerCounts == [1])
}

@Test
func contextExpand_withoutAGenerationReturnsTheHonestUnavailableReason_notACrash() async throws {
    // The negative control the "polite error" hazard needs: a turn with no
    // fluidContextTurn must still complete, and context_expand must say so
    // rather than fabricating an answer or throwing.
    let dispatcher = SwiftToolDispatcher(
        dataRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-loop-noscope-\(UUID().uuidString)")
    )
    #expect(FluidContextToolScope.current == nil)
    let unavailable = try dispatcher.impl_context_expand(
        input: ["atom_id": .string("atom:offered")], surface: "chat"
    )
    #expect(unavailable == .object([
        "status": .string("failed"),
        "reason": .string("context_generation_unavailable"),
    ]))

    // Bound, but for a pointer this turn did not offer: a DIFFERENT, equally
    // honest reason — so "unavailable" can never be mistaken for "not offered".
    let prepared = try makePreparedTurn(offeredAtomIDs: [])
    let notOffered = try FluidContextToolScope.$current.withValue(prepared) {
        try dispatcher.impl_context_expand(
            input: ["atom_id": .string("atom:offered")], surface: "chat"
        )
    }
    guard case .object(let object) = notOffered else {
        Issue.record("expected an object result")
        return
    }
    #expect(object["reason"] == .string("pointer_not_offered_this_turn"))
}

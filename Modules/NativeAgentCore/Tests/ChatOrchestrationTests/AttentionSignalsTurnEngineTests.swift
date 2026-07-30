import Foundation
import CognitiveSubstrate
import DreamREMCycle
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import Testing
import TrustCenter
@testable import ChatOrchestration
@testable import Context

// MARK: - Stubs

private final class AttentionPersonaStub: PersonaEngineProtocol, @unchecked Sendable {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class AttentionRoutingStub: ProviderRoutingProtocol, @unchecked Sendable {
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

/// Captures the ContextTurnRequest the engine builds, then throws so we never
/// need a real prepared generation. `.active` mode guarantees prepareContextTurn
/// is invoked with the request; the engine catches the throw (fallback path) and
/// finishes the turn normally.
private actor CapturingContextFlow: ContextTurnPreparing {
    enum Stop: Error { case captured }
    private let queryTicket: ContextQueryEmbeddingTicket?
    private(set) var lastRequest: ContextTurnRequest?

    init(queryTicket: ContextQueryEmbeddingTicket? = nil) {
        self.queryTicket = queryTicket
    }

    func contextFlowMode() async -> ContextFlowMode { .active }

    func beginQueryEmbedding(_ text: String) async -> ContextQueryEmbeddingTicket? {
        _ = text
        return queryTicket
    }

    func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        lastRequest = request
        throw Stop.captured
    }
}

private struct AttentionProviderStub: CognitiveContextProviding {
    let signals: CognitiveAttentionSignals?
    let delayNanos: UInt64
    let recordsTraceStages: Bool

    init(
        signals: CognitiveAttentionSignals?,
        delayNanos: UInt64 = 0,
        recordsTraceStages: Bool = false
    ) {
        self.signals = signals
        self.delayNanos = delayNanos
        self.recordsTraceStages = recordsTraceStages
    }

    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? { nil }

    func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? {
        let trace = CognitiveAttentionTraceContext.recorder
        if recordsTraceStages { trace?.recordAdmission() }
        let started = DispatchTime.now().uptimeNanoseconds
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if recordsTraceStages { trace?.recordElapsed("substrate", since: started) }
        if Task.isCancelled { trace?.markCancellationObserved() }
        return signals
    }
}

private func attentionEngine(
    provider: (any CognitiveContextProviding)?,
    flow: any ContextTurnPreparing,
    translator: (@Sendable (String) -> ContextAtomID?)? = nil
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: AttentionPersonaStub(),
        memory: nil,
        router: AttentionRoutingStub(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        contextFlow: flow,
        cognitiveContextProvider: provider,
        memoryAtomTranslator: translator
    )
}

private func capturedRequest(
    provider: (any CognitiveContextProviding)?,
    translator: (@Sendable (String) -> ContextAtomID?)? = nil,
    queryTicket: ContextQueryEmbeddingTicket? = nil
) async throws -> ContextTurnRequest {
    let flow = CapturingContextFlow(queryTicket: queryTicket)
    _ = try await attentionEngine(provider: provider, flow: flow, translator: translator)
        .buildTurnContext(
            surface: "chat",
            userMessage: "hello",
            personaOverride: nil,
            imageBlocks: [],
            includeClockContext: false
        )
    return try #require(await flow.lastRequest)
}

@Test func readySemanticQueryEmbeddingFlowsIntoSelectionRequest() async throws {
    let ticket = ContextQueryEmbeddingTicket()
    ticket.publish([0.25, 0.75], modelFingerprint: "test-epoch")

    let request = try await capturedRequest(provider: nil, queryTicket: ticket)

    #expect(request.queryEmbedding == [0.25, 0.75])
    #expect(request.queryEmbeddingModelFingerprint == "test-epoch")
}

@Test func unfinishedSemanticQueryEmbeddingNeverBlocksOrChangesTheRequest() async throws {
    let request = try await capturedRequest(
        provider: nil,
        queryTicket: ContextQueryEmbeddingTicket()
    )

    #expect(request == baselineRequest())
}

// MARK: - (a) provider signals populate the request

@Test func attentionSignalsPopulateTheContextTurnRequest() async throws {
    let atomA = ContextAtomID(rawValue: "atom:aaa")
    let translator: @Sendable (String) -> ContextAtomID? = { recordID in
        recordID == "rec-1" ? atomA : nil
    }
    let signals = CognitiveAttentionSignals(
        terms: ["the mars mission": 0.9, "budget": 0.4],
        unresolvedQuestion: "what is the launch window",
        activeTask: "draft the flight plan",
        goal: "ship the rover",
        predictedToolGroups: ["missions", "markets"],
        memoryActivation: ["rec-1": 0.8, "rec-unknown": 0.5],
        workingMemoryRecordIDs: ["rec-1"]
    )
    let request = try await capturedRequest(
        provider: AttentionProviderStub(signals: signals),
        translator: translator
    )

    #expect(request.contextualTerms == ["the mars mission", "budget"])
    #expect(request.unresolvedQuestion == "what is the launch window")
    #expect(request.activeTask == "draft the flight plan")
    #expect(request.goal == "ship the rover")
    #expect(request.predictedToolGroups == ["missions", "markets"])
    // Only the translatable record maps; the unknown one is dropped.
    #expect(request.cognitiveActivation == [atomA: 0.8])
    #expect(request.workingAtomIDs == [atomA])
}

@Test func attentionSignalsWithoutTranslatorStillFlowTermsAndIntent() async throws {
    let signals = CognitiveAttentionSignals(
        terms: ["orbit": 0.7],
        goal: "land safely",
        memoryActivation: ["rec-1": 0.8],
        workingMemoryRecordIDs: ["rec-1"]
    )
    // No translator injected → memory-keyed activation is dropped, rest flows.
    let request = try await capturedRequest(provider: AttentionProviderStub(signals: signals))

    #expect(request.contextualTerms == ["orbit"])
    #expect(request.goal == "land safely")
    #expect(request.cognitiveActivation.isEmpty)
    #expect(request.workingAtomIDs.isEmpty)
}

// MARK: - (b) nil provider / nil signals → baseline request

@Test func nilProviderYieldsBaselineRequest() async throws {
    let request = try await capturedRequest(provider: nil)
    #expect(request == baselineRequest())
}

@Test func nilSignalsYieldBaselineRequest() async throws {
    let request = try await capturedRequest(provider: AttentionProviderStub(signals: nil))
    #expect(request == baselineRequest())
}

@Test func emptySignalsYieldBaselineRequest() async throws {
    let request = try await capturedRequest(
        provider: AttentionProviderStub(signals: CognitiveAttentionSignals())
    )
    #expect(request == baselineRequest())
}

/// The request the unwired turn engine builds for this call shape — the
/// byte-identical baseline every empty/nil path must match.
private func baselineRequest() -> ContextTurnRequest {
    ContextTurnRequest(
        surface: ContextSurface(rawValue: "chat"),
        origin: .localAuthenticated,
        userMessage: "hello",
        personaIDHint: nil,
        sessionID: nil,
        recentTurns: [],
        maximumCharacterBudget: 24_000,
        postMandatoryCharacterReserve: 4_000
    )
}

// MARK: - (c) timeout path proceeds without signals + flag set

@Test func slowProviderTimesOutAndProceedsWithBaselineRequest() async throws {
    // Delay far past the 250ms bound; the race must abandon it.
    let signals = CognitiveAttentionSignals(terms: ["late": 1.0], goal: "too slow")
    let provider = AttentionProviderStub(signals: signals, delayNanos: 5_000_000_000)
    let request = try await capturedRequest(provider: provider)
    #expect(request == baselineRequest())
}

@Test func slowProviderSetsTimeoutTraceFlag() async throws {
    let provider = AttentionProviderStub(
        signals: CognitiveAttentionSignals(terms: ["late": 1.0]),
        delayNanos: 5_000_000_000
    )
    let payload = try await contextSummaryPayload(provider: provider)
    guard case .object(let flags)? = payload["flags"] else {
        Issue.record("context.summary payload missing flags object")
        return
    }
    #expect(flags["contextFlow.attentionTimedOut"] == .bool(true))
}

@Test func attentionSubstageTelemetryStaysInsideContextSummary() async throws {
    let provider = AttentionProviderStub(
        signals: CognitiveAttentionSignals(terms: ["resident": 1.0]),
        recordsTraceStages: true
    )
    let payload = try await contextSummaryPayload(provider: provider)
    guard case .object(let stageMs)? = payload["stageMs"],
          case .object(let flags)? = payload["flags"] else {
        Issue.record("context.summary payload missing attention telemetry")
        return
    }
    #expect(stageMs["contextFlow.attention.actorAdmission"] != nil)
    #expect(stageMs["contextFlow.attention.substrate"] != nil)
    #expect(flags["contextFlow.attentionCompleted"] == .bool(true))
    #expect(flags["contextFlow.attentionCancellationObserved"] == .bool(false))
    #expect(flags["contextFlow.attentionTimedOut"] != .bool(true))
}

private func contextSummaryPayload(
    provider: any CognitiveContextProviding
) async throws -> [String: JSONValue] {
    let flow = CapturingContextFlow()

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("attention-trace-\(UUID().uuidString)", isDirectory: true)
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let subscription = await bus.subscribe(capacity: 16)
    let turnId = TurnTraceContext.mintTurnId()
    let drain = Task { () -> [TurnTraceEvent] in
        var events: [TurnTraceEvent] = []
        for await event in subscription.stream {
            events.append(event)
            if event.kind == "context.summary" { break }
        }
        return events
    }

    await TurnTraceContext.$bus.withValue(bus) {
        await TurnTraceContext.$turnId.withValue(turnId) {
            _ = try? await attentionEngine(provider: provider, flow: flow).buildTurnContext(
                surface: "chat",
                userMessage: "hello",
                personaOverride: nil,
                imageBlocks: [],
                includeClockContext: false
            )
        }
    }

    let timeout = Task {
        try? await Task.sleep(for: .seconds(3))
        await bus.unsubscribe(subscription.id)
    }
    let events = await drain.value
    timeout.cancel()
    await bus.unsubscribe(subscription.id)
    try? FileManager.default.removeItem(at: root)

    let summary = try #require(events.first {
        $0.kind == "context.summary" && $0.turnId == turnId
    })
    guard case .object(let payload) = summary.payload else {
        throw AttentionSummaryError.invalidPayload
    }
    return payload
}

private enum AttentionSummaryError: Error { case invalidPayload }

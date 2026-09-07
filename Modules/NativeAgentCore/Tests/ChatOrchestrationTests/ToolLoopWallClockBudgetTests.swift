import Foundation
import Testing
@testable import ChatOrchestration
import DreamREMCycle
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
import TrustCenter

private final class ToolLoopManualMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    func now() -> UInt64 {
        lock.withLock { nanoseconds }
    }

    func advance(seconds: TimeInterval) {
        lock.withLock {
            nanoseconds += UInt64(seconds * 1_000_000_000)
        }
    }
}

private final class ToolLoopBudgetRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider {
        throw ProviderRoutingError.providerNotFound
    }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        // Every surface the budget tests drive: the progress extension is
        // surface-UNIFORM, so the tests exercise more than chat/telegram.
        Dictionary(
            uniqueKeysWithValues: ["chat", "telegram", "ios", "mac"].map {
                ($0, SurfacePreference(surface: $0, model: "test-model", reasoningEffort: "high"))
            }
        )
    }
}

private func makeToolLoopBudgetEngine(
    tag: String,
    llm: any LLMClient,
    tools: any ToolDispatchClient
) throws -> SwiftNativeTurnEngine {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tool-loop-budget-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: ToolLoopBudgetRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

private final class AdvancingToolLoopLLM: LLMClient, @unchecked Sendable {
    private let responses: [String]
    private let advance: @Sendable () -> Void
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    init(responses: [String], advance: @escaping @Sendable () -> Void) {
        self.responses = responses
        self.advance = advance
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        nextResponse()
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        nextResponse()
    }

    private func nextResponse() -> String {
        let index = lock.withLock {
            let index = calls
            calls += 1
            return index
        }
        advance()
        guard !responses.isEmpty else { return "" }
        return responses[index % responses.count]
    }
}

private final class AdvancingStreamingToolLoopLLM: LLMClient, @unchecked Sendable {
    private let iterations: [[LLMMessageStreamEvent]]
    private let advance: @Sendable () -> Void
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    init(
        iterations: [[LLMMessageStreamEvent]],
        advance: @escaping @Sendable () -> Void
    ) {
        self.iterations = iterations
        self.advance = advance
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "" }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let index = lock.withLock {
            let index = calls
            calls += 1
            return index
        }
        advance()
        let events = iterations.isEmpty ? [] : iterations[index % iterations.count]
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@Test
func wholeTurnWallClockBudget_hasSurfaceScopedPolicyAndCanonicalWorkshopAliases() {
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: "chat") == 600)
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: "mac") == 600)
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: "slack") == 600)
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: "ios") == 600)
    // 2026-08-31: telegram was the SHORTEST budget in the app (300) on the
    // surface where the agent does real remote research — a live multi-tool
    // turn got clipped. Same interactive floor as chat now.
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: "telegram") == 600)
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: " TELEGRAM ") == 600)

    for surface in [
        "workshop", "mission", "missions", " WORKSHOP ",
        "autonomy", "background", "swarm", "swarms", "worker", "training",
    ] {
        #expect(
            WholeTurnWallClockBudget.defaultSeconds(for: surface) == 3_900,
            "expected \(surface) to retain the unattended turn window"
        )
    }
}

@Test
func wholeTurnWallClockBudget_expiresAtTheMonotonicBoundaryWithoutSleeping() async {
    let clock = ToolLoopManualMonotonicClock()
    let now: WholeTurnWallClockBudget.MonotonicClock = { clock.now() }

    await WholeTurnWallClockBudget.$nowNanoseconds.withValue(now) {
        let budget = WholeTurnWallClockBudget.start(surface: "chat")
        #expect(!budget.isExhausted)
        clock.advance(seconds: 599.999)
        #expect(!budget.isExhausted)
        clock.advance(seconds: 0.001)
        #expect(budget.isExhausted)
    }
}

private let budgetToolCall =
    #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#

/// Every structured-loop budget scenario in this file: N tool-calling rounds
/// then a final reply, on a manual clock that advances by `advanceSeconds` per
/// provider call. `toolResult` decides whether each round is PRODUCTIVE (a real
/// result → the budget re-earns its window) or stuck (an error envelope → no
/// extension), which is the whole progress-aware contract.
private func runStructuredBudgetTurn(
    surface: String,
    tag: String,
    responses: [String],
    advanceSeconds: TimeInterval,
    toolResult: JSONValue
) async throws -> (result: TurnEngineResult, providerCalls: Int) {
    let clock = ToolLoopManualMonotonicClock()
    let llm = AdvancingToolLoopLLM(
        responses: responses,
        advance: { clock.advance(seconds: advanceSeconds) }
    )
    let tools = MockToolDispatchClient(scripted: ["echo": toolResult])
    let engine = try makeToolLoopBudgetEngine(tag: tag, llm: llm, tools: tools)
    let now: WholeTurnWallClockBudget.MonotonicClock = { clock.now() }
    let result = try await WholeTurnWallClockBudget.$nowNanoseconds.withValue(now) {
        try await engine.executeTurnWithToolLoop(
            surface: surface,
            userMessage: "use echo",
            llm: llm,
            tools: tools
        )
    }
    return (result, llm.callCount)
}

@Test
func structuredWholeTurnBudget_stopsAStuckTurnThroughTheExistingExhaustionTerminal() async throws {
    // A turn whose dispatches all FAIL earns no extension: it is exactly the
    // runaway the brake exists for, so telegram's 600s floor still kills it.
    let (telegram, telegramCalls) = try await runStructuredBudgetTurn(
        surface: "telegram",
        tag: "stuck-telegram",
        responses: [budgetToolCall, "must not start"],
        advanceSeconds: 700,
        toolResult: .object(["status": .string("failed"), "error": .string("nope")])
    )
    #expect(telegramCalls == 1)
    #expect(telegram.providerCallCount == 1)
    #expect(telegram.toolDispatches.map(\.name) == ["echo"])
    #expect(
        telegram.reply == ToolLoopExhaustion.fallbackReply(
            iterationLimit: ToolLoopBudget.defaultIterations(for: "telegram"),
            dispatchCount: 1,
            providerRounds: 1,
            wallClockElapsedSeconds: 700
        )
    )
    // Literal pin: a wall-clock stop must NAME the wall clock and the actual
    // rounds — never the iteration limit (the 2026-08-27 misdiagnosis was a
    // 188s budget cut reported as "exhausted after 180 iterations"). The
    // elapsed value stays truthful for an extended turn too: it is measured
    // from turn start, never from the last extension.
    #expect(telegram.reply.contains("turn stopped by wall-clock budget after 700s / 1 provider rounds"))

    let (chat, chatCalls) = try await runStructuredBudgetTurn(
        surface: "chat",
        tag: "stuck-chat",
        responses: [budgetToolCall, "finished on the second round"],
        advanceSeconds: 400,
        toolResult: .object(["status": .string("failed"), "error": .string("nope")])
    )
    #expect(chatCalls == 2)
    #expect(chat.providerCallCount == 2)
    #expect(chat.reply == "finished on the second round")
}

/// The live motivation (2026-08-31): the resident agent was doing real
/// multi-tool research and got clipped mid-work. A turn that keeps landing
/// tool results must run WELL past the surface floor. Uniform across surfaces
/// — the extension is a property of the budget, never of the lane.
@Test
func structuredWholeTurnBudget_productiveTurnRunsPastTheSurfaceFloorOnEverySurface() async throws {
    for surface in ["telegram", "chat", "ios", "mac"] {
        let (result, providerCalls) = try await runStructuredBudgetTurn(
            surface: surface,
            tag: "productive-\(surface)",
            responses: [
                budgetToolCall, budgetToolCall, budgetToolCall, "finished after four rounds",
            ],
            advanceSeconds: 400,
            toolResult: .string("ok")
        )
        // Four provider calls = 1600s of turn on a 600s surface budget. Every
        // one of those rounds landed a result, so the deadline kept sliding.
        #expect(providerCalls == 4, "\(surface): productive rounds must extend the budget")
        #expect(result.providerCallCount == 4, "\(surface)")
        #expect(result.toolDispatches.count == 3, "\(surface)")
        #expect(result.reply == "finished after four rounds", "\(surface)")
    }
}

/// The other half of the contract: a SPIN loop (every dispatch erroring) gets
/// no extension and still dies at the surface budget.
@Test
func structuredWholeTurnBudget_spinningTurnNeverExtendsPastTheSurfaceBudget() async throws {
    let (result, providerCalls) = try await runStructuredBudgetTurn(
        surface: "telegram",
        tag: "spin",
        responses: [budgetToolCall],
        advanceSeconds: 400,
        toolResult: .object(["status": .string("failed"), "error": .string("still stuck")])
    )
    // Rounds land at 400s and 800s; the third boundary check is past the 600s
    // floor. A productive turn with this shape would have kept going.
    #expect(providerCalls == 2)
    #expect(result.providerCallCount == 2)
    #expect(result.toolDispatches.count == 2)
    #expect(result.reply.contains("turn stopped by wall-clock budget after 800s / 2 provider rounds"))
}

/// An iteration that dispatches NOTHING is not progress, however much text the
/// model produced. Protocol-violation bounces run the loop without a single
/// dispatch, so the budget must expire on schedule.
@Test
func structuredWholeTurnBudget_iterationsWithoutDispatchesDoNotExtend() async throws {
    let malformed = "\nool_use name=\"echo\">{}</tool_use>"
    let (result, providerCalls) = try await runStructuredBudgetTurn(
        surface: "telegram",
        tag: "no-dispatch",
        responses: [malformed],
        advanceSeconds: 300,
        toolResult: .string("ok")
    )
    // Bounces at 300s and 600s; the third boundary check is at the floor.
    #expect(providerCalls == 2)
    #expect(result.providerCallCount == 2)
    #expect(result.toolDispatches.isEmpty)
}

@Test
func wholeTurnWallClockBudget_progressSlidesTheDeadlineAndStopsAtTheAbsoluteCeiling() async {
    let clock = ToolLoopManualMonotonicClock()
    let now: WholeTurnWallClockBudget.MonotonicClock = { clock.now() }

    await WholeTurnWallClockBudget.$nowNanoseconds.withValue(now) {
        var budget = WholeTurnWallClockBudget.start(surface: "telegram")
        clock.advance(seconds: 500)
        #expect(!budget.isExhausted)
        budget.recordProgress()
        clock.advance(seconds: 500)
        // 1000s in on a 600s surface budget, still alive: the round at 500s
        // re-granted the window.
        #expect(!budget.isExhausted)

        // 2026-09-06: the ceiling is `progressCeilingSeconds` — 6h — not
        // `start + defaultUnattendedSeconds` (3_900). The old ceiling killed
        // turns that were still landing productive rounds an hour in, and a
        // turn that re-earns its window every round is by definition not the
        // runaway the brake exists for. The surface window (600s here) and the
        // per-round extension are untouched, so a STUCK turn still dies at its
        // surface budget — that is the row above and `wholeTurnWallClockBudget`
        // exhaustion elsewhere in this file.
        //
        // Keep producing all the way to the ceiling: 41 more productive rounds
        // of 500s each carries this turn from 1_000s to 21_500s.
        for _ in 0..<41 {
            budget.recordProgress()
            clock.advance(seconds: 500)
        }
        #expect(!budget.isExhausted)  // 21_500s
        // This round's extension is CLAMPED to the ceiling: 21_500 + 600 would
        // be 22_100, the deadline lands on 21_600.
        budget.recordProgress()
        clock.advance(seconds: 99)
        #expect(!budget.isExhausted)  // 21_599s
        clock.advance(seconds: 1)
        budget.recordProgress()  // productive, and it CANNOT help any more
        #expect(budget.isExhausted)
        #expect(budget.elapsedSeconds == 21_600)
    }
}

/// 2026-09-06: this row used to read "unattended surfaces are ALREADY at the
/// ceiling so progress adds nothing", which was true while the ceiling was
/// `start + defaultUnattendedSeconds`. `progressCeilingSeconds` is now 6h, so
/// an unattended surface extends like every other one — by its own 3_900s
/// window per productive round — and what is still worth pinning is the half
/// that did not change: a round that produces NOTHING dies at the surface
/// budget regardless of how long the ceiling is.
@Test
func wholeTurnWallClockBudget_unattendedSurfacesExtendByTheirWindowAndDieWhenTheyStop() async {
    let clock = ToolLoopManualMonotonicClock()
    let now: WholeTurnWallClockBudget.MonotonicClock = { clock.now() }

    await WholeTurnWallClockBudget.$nowNanoseconds.withValue(now) {
        var budget = WholeTurnWallClockBudget.start(surface: "autonomy")
        clock.advance(seconds: 1_000)
        budget.recordProgress()   // deadline slides to 1_000 + 3_900
        clock.advance(seconds: 2_899)
        #expect(!budget.isExhausted)
        clock.advance(seconds: 1)
        // 3_900s in, and under the OLD ceiling this was the end of the turn.
        #expect(!budget.isExhausted)
        // Nothing produced from here: the window that last round granted runs
        // out at 4_900 and the turn dies there, well short of the 6h ceiling.
        clock.advance(seconds: 999)
        #expect(!budget.isExhausted)  // 4_899s
        clock.advance(seconds: 1)
        #expect(budget.isExhausted)   // 4_900s
        #expect(budget.elapsedSeconds == 4_900)
    }
}

private func runStreamingBudgetTurn(
    tag: String,
    iterations: [[LLMMessageStreamEvent]],
    advanceSeconds: TimeInterval,
    toolResult: JSONValue
) async throws -> (result: TurnEngineResult, providerCalls: Int) {
    let clock = ToolLoopManualMonotonicClock()
    let llm = AdvancingStreamingToolLoopLLM(
        iterations: iterations,
        advance: { clock.advance(seconds: advanceSeconds) }
    )
    let tools = MockToolDispatchClient(scripted: ["echo": toolResult])
    let engine = try makeToolLoopBudgetEngine(tag: tag, llm: llm, tools: tools)
    let now: WholeTurnWallClockBudget.MonotonicClock = { clock.now() }
    let result = try await WholeTurnWallClockBudget.$nowNanoseconds.withValue(now) {
        try await engine.executeTurnWithStreamingToolLoop(
            surface: "chat",
            userMessage: "stream echo",
            llm: llm,
            tools: tools
        )
    }
    return (result, llm.callCount)
}

private let budgetStreamedCall: [LLMMessageStreamEvent] = [
    .toolCall(LLMStreamToolCall(id: "stream-1", name: "echo", inputJSON: Data("{}".utf8))),
]

@Test
func streamingWholeTurnBudget_expiresThroughTheSameExhaustionTerminal() async throws {
    // Failing dispatch → no extension → the 600s ceiling still applies.
    let (result, providerCalls) = try await runStreamingBudgetTurn(
        tag: "stream",
        iterations: [budgetStreamedCall],
        advanceSeconds: 601,
        toolResult: .object(["status": .string("failed"), "error": .string("nope")])
    )

    #expect(providerCalls == 1)
    #expect(result.providerCallCount == 1)
    #expect(result.toolDispatches.map(\.name) == ["echo"])
    #expect(
        result.reply == ToolLoopExhaustion.fallbackReply(
            iterationLimit: ToolLoopBudget.defaultIterations(for: "chat"),
            dispatchCount: 1,
            providerRounds: 1,
            wallClockElapsedSeconds: 601
        )
    )
}

@Test
func streamingWholeTurnBudget_productiveRoundsExtendTheSameWay() async throws {
    let (result, providerCalls) = try await runStreamingBudgetTurn(
        tag: "stream-productive",
        iterations: [
            budgetStreamedCall,
            budgetStreamedCall,
            budgetStreamedCall,
            [.textDelta("finished after four rounds")],
        ],
        advanceSeconds: 400,
        toolResult: .string("ok")
    )

    #expect(providerCalls == 4)
    #expect(result.providerCallCount == 4)
    #expect(result.toolDispatches.count == 3)
    #expect(result.reply.contains("finished after four rounds"))
}

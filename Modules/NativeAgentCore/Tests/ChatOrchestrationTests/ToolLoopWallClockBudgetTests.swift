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
        [
            "chat": SurfacePreference(
                surface: "chat", model: "test-model", reasoningEffort: "high"
            ),
            "telegram": SurfacePreference(
                surface: "telegram", model: "test-model", reasoningEffort: "high"
            ),
        ]
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
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: "telegram") == 300)
    #expect(WholeTurnWallClockBudget.defaultSeconds(for: " TELEGRAM ") == 300)

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

@Test
func structuredWholeTurnBudget_isolatesTelegramAndUsesExistingExhaustionTerminal() async throws {
    let call = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#

    func run(surface: String) async throws -> (TurnEngineResult, Int) {
        let clock = ToolLoopManualMonotonicClock()
        let llm = AdvancingToolLoopLLM(
            responses: [call, "finished on the second round"],
            advance: { clock.advance(seconds: 400) }
        )
        let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
        let engine = try makeToolLoopBudgetEngine(tag: surface, llm: llm, tools: tools)
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

    // Interactive moved 180 → 600 (2026-08-27: 180 sat below the measured
    // p95 of real chat turns), so the tier contrast runs the other way now:
    // telegram (300s) exhausts on the round-1 advance, chat (600s) finishes.
    let (telegram, telegramCalls) = try await run(surface: "telegram")
    #expect(telegramCalls == 1)
    #expect(telegram.providerCallCount == 1)
    #expect(telegram.toolDispatches.map(\.name) == ["echo"])
    #expect(
        telegram.reply == ToolLoopExhaustion.fallbackReply(
            iterationLimit: ToolLoopBudget.defaultIterations(for: "telegram"),
            dispatchCount: 1,
            providerRounds: 1,
            wallClockElapsedSeconds: 400
        )
    )
    // Literal pin: a wall-clock stop must NAME the wall clock and the actual
    // rounds — never the iteration limit (the 2026-08-27 misdiagnosis was a
    // 188s budget cut reported as "exhausted after 180 iterations").
    #expect(telegram.reply.contains("turn stopped by wall-clock budget after 400s / 1 provider rounds"))

    let (chat, chatCalls) = try await run(surface: "chat")
    #expect(chatCalls == 2)
    #expect(chat.providerCallCount == 2)
    #expect(chat.reply == "finished on the second round")
}

@Test
func streamingWholeTurnBudget_expiresThroughTheSameExhaustionTerminal() async throws {
    let clock = ToolLoopManualMonotonicClock()
    let llm = AdvancingStreamingToolLoopLLM(
        iterations: [[
            .toolCall(LLMStreamToolCall(
                id: "stream-1", name: "echo", inputJSON: Data("{}".utf8)
            )),
        ]],
        advance: { clock.advance(seconds: 601) }
    )
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let engine = try makeToolLoopBudgetEngine(tag: "stream", llm: llm, tools: tools)
    let now: WholeTurnWallClockBudget.MonotonicClock = { clock.now() }

    let result = try await WholeTurnWallClockBudget.$nowNanoseconds.withValue(now) {
        try await engine.executeTurnWithStreamingToolLoop(
            surface: "chat",
            userMessage: "stream echo",
            llm: llm,
            tools: tools
        )
    }

    #expect(llm.callCount == 1)
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

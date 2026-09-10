import Foundation
import Testing
@testable import StandingBots
@testable import ChatOrchestration
import NativeAgentCore
import ProviderRouting
import PersonaEngine
import PersistenceCore
import TrustCenter
import ApprovalInbox

struct BotTestPersona: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

final class BotTestRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider { throw ProviderRoutingError.invalidRequest }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "claude-sonnet-4-5", reasoningEffort: "low")]
    }
    func activeProvidersForSurfaces() async -> [String: String] { ["chat": "anthropic"] }
}

final class BotTestAdapter: LLMAdapter, @unchecked Sendable {
    let providerId: String
    private let lock = NSLock()
    private var scripts: [[LLMMessageStreamEvent]]
    private var seen: [(String, String?, String?, String?)] = []
    init(provider: String = "openai", scripts: [[LLMMessageStreamEvent]]) { providerId = provider; self.scripts = scripts }
    var calls: [(String, String?, String?, String?)] { lock.lock(); defer { lock.unlock() }; return seen }
    private func next(_ model: String) -> [LLMMessageStreamEvent] {
        lock.lock(); defer { lock.unlock() }
        seen.append((model, LLMCallContext.providerId, LLMCallContext.reasoningEffort, LLMCallContext.serviceTier))
        return scripts.isEmpty ? [.textDelta("Done")] : scripts.removeFirst()
    }
    func complete(prompt: String, system: String?, model: String) async throws -> String { "unused" }
    func streamMessages(messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let events = next(model)
        return AsyncThrowingStream { c in for event in events { c.yield(event) }; c.finish() }
    }
}

struct BotTestTools: ToolDispatchClient {
    func listAvailableTools() async throws -> [String] { ["tool_catalog"] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [LLMToolSchema(name: "tool_catalog", description: "Read tools.", parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8))]
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue { .object(["ok": .bool(true)]) }
}

actor BotTestApprovals: NonBlockingApprovalFiler {
    var filed = 0
    func fileApprovalRequest(toolName: String, surface: String, payload: JSONValue, reason: String) async throws -> String { filed += 1; return "approval-1" }
    func awaitResolution(id: String) async throws -> ApprovalDecision { throw BotRunnerError.notPermitted }
    func pendingApprovalResult(id: String, toolName: String, surface: String, payload: JSONValue, reason: String) async -> JSONValue {
        .object(["status": .string("waiting_approval"), "approvalId": .string(id)])
    }
}

struct BotRuntimeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-session-" + UUID().uuidString)
    var definitions: BotDefinitionStore { BotDefinitionStore(dataRoot: root) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func bot(tokens: Int = 1000) throws -> BotDefinition {
        var bot = BotDefinition(name: "Chosen name", brief: "A freely chosen task", cadence: .manual, budget: BotBudget(tokens: tokens, seconds: 30), outputFormat: "")
        bot.provider = "openai"; bot.model = "gpt-5.5"; bot.reasoningEffort = "high"; bot.fast = true
        bot.dailyTokenCeiling = 100_000
        return try definitions.create(bot)
    }
    func client(_ adapter: BotTestAdapter, approvals: BotTestApprovals? = nil) -> SwiftNativeChatOrchestrationClient {
        let router = BotTestRouting()
        let llm = SwiftNativeLLMClient(router: router, codex: adapter, anthropic: adapter, openAI: adapter, openAIOAuthDirect: adapter, anthropicOAuthDirect: adapter, moonshotCatalogDataRoot: root)
        let tools = BotTestTools()
        let trust = SwiftNativeTrustCenter(dataRoot: root)
        let engine = SwiftNativeTurnEngine(persona: BotTestPersona(), memory: nil, router: router, trust: trust,
            llm: llm, tools: tools, providerRecoverySleep: { _ in try Task.checkCancellation() }, remPinsDataRoot: root)
        return SwiftNativeChatOrchestrationClient(engine: engine, tools: tools, llm: llm, streamingLLM: llm,
            history: SessionHistoryReader(dataRoot: root), dataRoot: root, trust: trust, approvalFiler: approvals,
            toolLoopMaxIterations: 3)
    }
    func transcript(_ bot: BotDefinition) throws -> String {
        try String(contentsOf: root.appendingPathComponent("chat/messages/" + bot.sessionID + ".jsonl"), encoding: .utf8)
    }
}

@Test func runIsASessionTurn() async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    let bot = try f.bot()
    let client = f.client(BotTestAdapter(scripts: [[.textDelta("A reply without a prescribed form.")]]))
    let runner = BotRunner(dataRoot: f.root, session: StandingBotContinuity.session(client: client, dataRoot: f.root))
    let entry = try #require(try await runner.run(bot: bot.id))
    #expect(entry.actualReply == "A reply without a prescribed form.")
    #expect(entry.sessionID == bot.sessionID)
    let transcript = try f.transcript(bot)
    #expect(transcript.contains(bot.brief))
    #expect(transcript.contains(entry.actualReply))
    let index = try String(contentsOf: f.root.appendingPathComponent("chat/sessions.json"), encoding: .utf8)
    #expect(index.contains(bot.sessionID))
}

@Test func textOnlyAccountKeepsReplyAndRunNote() async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    var bot = try f.bot()
    bot.provider = "codex"
    bot = try f.definitions.update(bot)
    let adapter = BotTestAdapter(provider: "codex", scripts: [[.textDelta("A plain reply.")]])
    let entry = try #require(try await BotRunner(dataRoot: f.root,
        session: StandingBotContinuity.session(client: f.client(adapter), dataRoot: f.root)).run(bot: bot.id))
    #expect(entry.actualReply == "A plain reply.")
    #expect(entry.statusDetail == ProviderToolCapability.unavailableNote)
    #expect(adapter.calls.allSatisfy { $0.1 == "codex" })
}

@Test func approvalNeededEndsWaitingWithReplyKept() async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    let bot = try f.bot()
    let trustDir = f.root.appendingPathComponent("trust")
    try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
    try Data(#"{"toolAutonomy":{"tool_catalog":"confirm"},"autonomyDefault":"confirm"}"#.utf8).write(to: trustDir.appendingPathComponent("policy.json"))
    let approvals = BotTestApprovals()
    let adapter = BotTestAdapter(scripts: [[.textDelta("The reply so far."), .toolCall(LLMStreamToolCall(id: "call-1", name: "tool_catalog", inputJSON: Data("{}".utf8)))]])
    let client = f.client(adapter, approvals: approvals)
    let entry = try #require(try await BotRunner(dataRoot: f.root,
        session: StandingBotContinuity.session(client: client, dataRoot: f.root)).run(bot: bot.id))
    #expect(entry.runtimeStatus == .waitingForApproval)
    #expect(entry.actualReply == "The reply so far.")
    #expect(try f.transcript(bot).contains(entry.actualReply))
    #expect(await approvals.filed == 1)
    #expect(adapter.calls.count == 1)
}

@Test(arguments: ["openai", "anthropic", "openai_oauth_direct"]) func capKeepsPartialWork(provider: String) async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    var bot = try f.bot(tokens: 12)
    bot.provider = provider
    if provider == "anthropic" { bot.model = "claude-sonnet-4-5" }
    bot = try f.definitions.update(bot)
    let client = f.client(BotTestAdapter(provider: provider, scripts: [[.textDelta("Partial work"), .textDelta(" and more")]]))
    let entry = try #require(try await BotRunner(dataRoot: f.root,
        session: StandingBotContinuity.session(client: client, dataRoot: f.root)).run(bot: bot.id))
    #expect(entry.runtimeStatus == .interrupted)
    // The Anthropic text protocol appends its length notice to a cut answer; the partial work leads.
    #expect(entry.actualReply.hasPrefix("Partial work"))
    #expect(entry.statusDetail == "Stopped at the per-run token limit.")
    #expect(try f.transcript(bot).contains("Partial work"))
}

actor BotRunBarrier {
    var started = false
    var release: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func enter() async { started = true; observers.forEach { $0.resume() }; observers = []; await withCheckedContinuation { release = $0 } }
    func waitForStart() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func finish() { release?.resume(); release = nil }
}

@Test func noOverlapForOneBot() async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    let bot = try f.bot()
    let barrier = BotRunBarrier()
    let first = BotRunner(dataRoot: f.root, session: { _, _ in await barrier.enter(); return BotTurnReply(reply: "First") })
    let second = BotRunner(dataRoot: f.root, session: { _, _ in return BotTurnReply(reply: "Second") })
    let task = Task { try await first.run(bot: bot.id) }
    await barrier.waitForStart()
    #expect(throws: BotRunAdmissionError.alreadyRunning) {
        try BotRunQueue(dataRoot: f.root).claim(bot: bot.id, requestID: nil, manual: true)
    }
    let followUp = Task { try await second.ask(bot: bot.id, question: "Follow-up") }
    let receipt = try BotRunQueue(dataRoot: f.root).enqueue(bot: bot.id)
    #expect(receipt.accepted)
    await barrier.finish()
    _ = try await task.value
    #expect(try await followUp.value == "Second")
    let rows = try ShelfStore(dataRoot: f.root).shelfRead(bot: bot.id).rows
    #expect(try rows.map { try ShelfStore(dataRoot: f.root).entry($0.id).actualReply } == ["First", "Second"])
}

@Test func botsModelChoiceReachesProviderCall() async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    let bot = try f.bot()
    let adapter = BotTestAdapter(scripts: [[.textDelta("Chosen model replied.")]])
    let client = f.client(adapter)
    _ = try await BotRunner(dataRoot: f.root, session: StandingBotContinuity.session(client: client, dataRoot: f.root)).run(bot: bot.id)
    let call = try #require(adapter.calls.first)
    #expect(call.0 == "gpt-5.5")
    #expect(call.1 == "openai")
    #expect(call.2 == "high")
    #expect(call.3 == "priority")
}

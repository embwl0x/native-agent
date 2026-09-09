import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import TrustCenter
import ProviderRouting
import PersonaEngine

enum StandingBotToolPolicy {
    static func validate(name: String, catalog: Set<String>) throws {
        guard catalog.contains(name) else {
            throw StandingBotsError.invalidValue("Tool source '\(name)' is not in the agent's available tool catalog. Choose an available tool name or a public http(s) URL.")
        }
    }

    /// Bots run unattended. A source may read (files the policy allows, connectors,
    /// search, the catalog) but never act: shell, Mac control, browser, MCP, write
    /// and send tools are refused as sources even when Trust would allow them in
    /// chat without approval. Person-owned settings such as the cadence floor stay
    /// out of reach of any bot.
    static func validate(name: String, input: [String: JSONValue], dataRoot: URL) async throws {
        let envelope = await SwiftNativeSecurityCenter(dataRoot: dataRoot).evaluateTool(
            tool: name, input: input, origin: SecurityOriginContext(surface: "standing_bots"))
        let bucket = SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: name)
        guard bucket != nil, ![ChatToolCatalogBucket.shell, .macControl, .browser, .mcp, .unclassified].contains(bucket!),
              ToolPreloadHeuristics.macIntegrationGates[name]?.mode != .write,
              !envelope.capabilities.isEmpty, !envelope.hasSideEffects,
              envelope.capabilities.contains(where: { $0.hasSuffix("_read") || $0 == "tool_catalog" }) else {
            throw StandingBotsError.invalidValue("Tool source '\(name)' refused: a bot source may read but never act. Write, send, Mac-control, browser, shell and connector-server tools cannot be sources. Choose a read tool from the agent's catalog or a public http(s) URL.")
        }
    }
}

/// Adapts the existing structured loop to one isolated, shelf-only bot run.
public enum StandingBotToolLoop {
    public static let maximumRounds = 4

    /// Reload canonical authority at each fetch, tool and provider boundary.
    public static func admitted(dataRoot: URL, tool: String = "bot_run_once") async -> Bool {
        let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        guard policy["enableAutonomy"] == .bool(true) else { return false }
        let envelope = await SwiftNativeSecurityCenter(dataRoot: dataRoot).evaluateTool(
            tool: tool, input: [:], origin: SecurityOriginContext(surface: "standing_bots"))
        return envelope.allowed && !envelope.requiresApproval
    }

    public static func session(dataRoot: URL, tools: any ToolDispatchClient,
                               lifecycleObserver: (any LLMCallLifecycleObserving)? = nil) -> BotRunnerToolSession {
        { system, prompt, names, budget, admission in
            let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
            let snapshot = try await router.checkedRoutingSnapshot()
            guard let preference = snapshot.preferences["dream"],
                  let provider = snapshot.activeProviders["dream"] else { throw BotRunnerError.notPermitted }
            let adapter: any LLMAdapter
            let cheap: String
            switch provider {
            case "openai": adapter = OpenAIAdapter(); cheap = "gpt-5.4-mini"
            case "anthropic": adapter = AnthropicAdapter(); cheap = "claude-haiku-4-5"
            case "anthropic_oauth_direct": adapter = AnthropicOAuthDirectAdapter(); cheap = "claude-haiku-4-5"
            default: throw BotRunnerError.notPermitted
            }
            let model = snapshot.pinnedModels["dream"] == nil ? cheap : preference.model
            let wire = BotStructuredProvider(adapter: adapter, model: model, router: router, snapshot: snapshot,
                                             lifecycleObserver: lifecycleObserver)
            return try await run(dataRoot: dataRoot, tools: tools, llm: wire, system: system, prompt: prompt,
                                 names: names, budget: budget, admission: admission)
        }
    }

    public static func run(dataRoot: URL, tools: any ToolDispatchClient, llm: any LLMClient,
                           system: String, prompt: String, names: [String], budget: BotBudget,
                           admission: @escaping BotRunnerAdmission) async throws -> BotToolSessionResult {
        for name in names { try await StandingBotToolPolicy.validate(name: name, input: [:], dataRoot: dataRoot) }
        let schemas = try await tools.listAvailableToolSchemas().filter { names.contains($0.name) }
        guard Set(schemas.map(\.name)) == Set(names) else { throw BotRunnerError.unavailableSource }
        let state = BotToolRunState(tokens: budget.tokens)
        let sessionID = "bot:" + UUID().uuidString
        let gated = makeGatedToolDispatchClient(tools: tools, dataRoot: dataRoot,
                                               verifiedSessionId: sessionID)
        let scoped = BotScopedDispatcher(inner: gated, schemas: schemas, dataRoot: dataRoot,
                                         state: state, admission: admission)
        let bounded = BotBudgetedProvider(inner: llm, state: state, admission: admission)
        let engine = SwiftNativeTurnEngine(persona: SwiftNativePersonaEngine.isolated(dataRoot: dataRoot),
            memory: nil, router: SwiftNativeProviderRouting(dataRoot: dataRoot),
            trust: SwiftNativeTrustCenter(dataRoot: dataRoot), llm: bounded, tools: scoped,
            memoryPromoter: nil, naturalExpressionGuidanceEnabled: false)
        let context = TurnContext(surface: "standing_bots", personaDocs: [:], recalled: [], modelId: "",
            reasoningEffort: "none", toolsAvailable: names, systemPrompt: system, userMessage: prompt, toolSchemas: schemas)
        do {
            let result = try await LLMCallContext.$turnActiveTools.withValue(Set(names)) {
                try await engine.executeTurnWithToolLoop(surface: "standing_bots", userMessage: prompt, toolSessionId: sessionID,
                maxIterations: maximumRounds, turnWallClockSecondsOverride: budget.seconds,
                llm: bounded, tools: scoped, preBuiltContext: context, providerAdmission: { try await state.check(admission) })
            }
            try await state.check(admission)
            guard result.completionState == .completed else { throw BotRunnerError.budgetStop }
            return await state.result(book: result.reply)
        } catch {
            // The shared loop may wrap a provider denial after a tool receipt.
            // Preserve the bot's canonical permission terminal in either path.
            try await state.check(admission)
            throw error
        }
    }
}

private actor BotToolRunState {
    var remaining: Int
    var calls = 0
    var toolCalls = 0
    var reservedOutputs = 0
    var denied = false
    var checked: Set<String> = []
    var failures: [String] = []
    init(tokens: Int) { remaining = tokens }
    func check(_ admission: BotRunnerAdmission) async throws {
        try Task.checkCancellation()
        do { guard !denied, try await admission() else { throw BotRunnerError.notPermitted } }
        catch { denied = true; throw BotRunnerError.notPermitted }
        guard !denied else { throw BotRunnerError.notPermitted }
        try Task.checkCancellation()
    }
    func deny() { denied = true }
    func admitTool() throws {
        guard toolCalls < 16 else { throw BotRunnerError.budgetStop }
        toolCalls += 1
    }
    func record(_ name: String, error: String? = nil) {
        if let error { failures.append("Could not check tool:\(name): \(error)") } else { checked.insert(name) }
    }
    func reserve(inputBytes: Int) throws -> Int {
        guard calls < StandingBotToolLoop.maximumRounds else { throw BotRunnerError.budgetStop }
        // Provider-owned thinking replay is not represented in LLMMessage.
        // Reserve all prior output ceilings again as possible hidden input.
        let input = inputBytes + reservedOutputs + 1024
        let available = remaining - input
        let output = min(4096, available / (StandingBotToolLoop.maximumRounds - calls))
        guard output >= 128 else { throw BotRunnerError.budgetStop }
        remaining -= input + output
        reservedOutputs += output
        calls += 1
        return output
    }
    func result(book: String) -> BotToolSessionResult {
        BotToolSessionResult(book: book, checkedTools: checked.sorted(), failures: failures)
    }
}

private struct BotScopedDispatcher: ToolDispatchClient {
    let inner: any ToolDispatchClient
    let schemas: [LLMToolSchema]
    let dataRoot: URL
    let state: BotToolRunState
    let admission: BotRunnerAdmission
    func listAvailableTools() async throws -> [String] { schemas.map(\.name) }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { schemas }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        try await state.check(admission)
        try await state.admitTool()
        guard schemas.contains(where: { $0.name == tool }) else {
            await state.deny(); throw BotRunnerError.notPermitted
        }
        do {
            try await StandingBotToolPolicy.validate(name: tool, input: input, dataRoot: dataRoot)
            let envelope = await SwiftNativeSecurityCenter(dataRoot: dataRoot).evaluateTool(
                tool: tool, input: input, origin: SecurityOriginContext(surface: surface))
            guard envelope.allowed, !envelope.requiresApproval else {
                await state.deny(); throw BotRunnerError.notPermitted
            }
            let value = try await inner.dispatch(tool: tool, input: input, surface: surface)
            try Task.checkCancellation()
            let bytes = try value.serializedData(pretty: false)
            guard ChatToolOutcome.outputLooksSuccessful(value) else {
                await state.record(tool, error: "tool returned a failure envelope")
                return .object(["status": .string("failed"), "untrustedEvidence": .string(String(decoding: bytes.prefix(8192), as: UTF8.self))])
            }
            guard bytes.count <= 8192 else {
                await state.record(tool, error: "result exceeded evidence cap")
                return .object(["untrustedEvidence": .string(String(decoding: bytes.prefix(8192), as: UTF8.self)), "truncated": .bool(true)])
            }
            await state.record(tool)
            return .object(["untrustedEvidence": value, "source": .string("tool:" + tool)])
        } catch is AutonomyGateError {
            await state.deny()
            throw BotRunnerError.notPermitted
        } catch {
            await state.record(tool, error: String(describing: error))
            throw error
        }
    }
}

private struct BotStructuredProvider: LLMClient {
    let adapter: any LLMAdapter
    let model: String
    let router: SwiftNativeProviderRouting
    let snapshot: ProviderRoutingSnapshot
    let lifecycleObserver: (any LLMCallLifecycleObserving)?
    func complete(prompt: String, system: String?, model: String?) async throws -> String { throw BotRunnerError.invalidBook }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        let current = try await router.checkedRoutingSnapshot()
        guard current.preferences["dream"] == snapshot.preferences["dream"],
              current.activeProviders["dream"] == snapshot.activeProviders["dream"],
              current.pinnedModels["dream"] == snapshot.pinnedModels["dream"] else { throw BotRunnerError.notPermitted }
        try Task.checkCancellation()
        try await ProviderRequestAdmission.check?()
        return try await SwiftNativeLLMClient.withStandingBotLifecycle(observer: lifecycleObserver,
            providerId: snapshot.activeProviders["dream"]!, model: self.model) {
            try await adapter.completeMessages(messages: messages, system: system, model: self.model, tools: tools)
        }
    }
}

private struct BotBudgetedProvider: LLMClient {
    let inner: any LLMClient
    let state: BotToolRunState
    let admission: BotRunnerAdmission
    func complete(prompt: String, system: String?, model: String?) async throws -> String { throw BotRunnerError.invalidBook }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        try await state.check(admission)
        var bytes = system?.utf8.count ?? 0
        for message in messages {
            bytes += 128
            for block in message.content {
                switch block {
                case .text(let text): bytes += text.utf8.count
                case .toolUse(let id, let name, let input): bytes += id.utf8.count + name.utf8.count + input.count
                case .toolResult(let id, let content, _): bytes += id.utf8.count + content.utf8.count
                case .image: throw BotRunnerError.budgetStop
                }
            }
        }
        for schema in tools ?? [] { bytes += schema.parametersJSON.count + schema.name.utf8.count + schema.description.utf8.count + 128 }
        let limit = try await state.reserve(inputBytes: bytes)
        return try await LLMCallContext.$botOutputTokenLimit.withValue(limit) {
            try await ProviderRequestAdmission.$check.withValue({ try await state.check(admission) }) {
                try await inner.completeMessages(messages: messages, system: system, model: model, surface: surface, tools: tools)
            }
        }
    }
}

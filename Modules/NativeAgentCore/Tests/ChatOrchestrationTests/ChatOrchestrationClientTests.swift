import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import DreamREMCycle
import ApprovalInbox
import MacIntegration
import CognitiveSubstrate

private let makeTempRoot: @Sendable (String) throws -> URL = makeChatOrchestrationTempRoot

@Test
func chatClient_modelToolLoadPersistsAfterTurn() async throws {
    let root = try makeTempRoot("transient-tool-load")
    let sessionId = "s-transient-tool-load-\(UUID().uuidString)"
    // 2026-07-21 audit: the store under test is the temp-root one the
    // dispatcher/engine share — asserting through ActiveToolsStore.shared ran
    // a real GC sweep over the LIVE dir and could never see a persistence
    // regression (which lands in the temp root).
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")

    let loadCall = #"{"tool_calls":[{"id":"load1","type":"function","function":{"name":"tool_load","arguments":"{\"names\":[\"x_search\"],\"session_id\":\"\#(sessionId)\"}"}}]}"#
    let llm = ToolSchemaCapturingLLM(scriptedResponses: [loadCall, "loaded for this turn only"])
    let tools = SwiftToolDispatcher(dataRoot: root)
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 3
    )

    let resp = try await client.chat(
        message: "search OpenAI news",
        sessionId: sessionId,
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(resp.output == "loaded for this turn only")
    #expect(llm.callCount == 2)
    #expect(llm.toolNamesByCall.count == 2)
    #expect(!llm.toolNamesByCall[0].contains("x_search"))
    #expect(llm.toolNamesByCall[1].contains("x_search"))
    // INVERTED 2026-07-25: these expectations used to pin turn-end amnesia
    // (cleanupTransientActiveTools). That wiped the model's explicit
    // tool_load results every turn, forcing a full extra LLM round-trip to
    // re-load before nearly every action (live slowdown, 2026-07-25).
    // tool_load now PERSISTS for the session; the store's 24h TTL and
    // tool_unload own decay.
    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(state.activeTools.contains("x_search"))
    #expect(FileManager.default.fileExists(atPath: activePath.path))
}

@Test
func chatClient_streamingModelToolLoadAddsSchemaOnNextIteration() async throws {
    let root = try makeTempRoot("stream-transient-tool-load")
    let sessionId = "s-stream-transient-tool-load-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")

    let llm = StructuredStreamingScriptLLM(scriptedEvents: [
        [.toolCall(LLMStreamToolCall(
            id: "load1",
            name: "tool_load",
            inputJSON: Data(#"{"names":["x_search"],"session_id":"\#(sessionId)"}"#.utf8)
        ))],
        [.textDelta("loaded for this streaming turn only")],
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 3
    )

    var finalText: String?
    for try await event in client.chatStream(
        message: "search OpenAI news",
        sessionId: sessionId,
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalText = result.reply }
    }

    #expect(finalText == "loaded for this streaming turn only")
    #expect(llm.streamCallCount == 2)
    #expect(llm.toolNamesByCall.count == 2)
    #expect(!llm.toolNamesByCall[0].contains("x_search"))
    #expect(llm.toolNamesByCall[1].contains("x_search"))
    // INVERTED 2026-07-25: persistence after the turn is the CORRECT
    // behavior — see chatClient_modelToolLoadPersistsAfterTurn's note.
    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(state.activeTools.contains("x_search"))
    #expect(FileManager.default.fileExists(atPath: activePath.path))
}

@Test
func chatClient_textCompatibilityToolLoadPersistsAfterTurn() async throws {
    let root = try makeTempRoot("text-transient-tool-load")
    let sessionId = "s-text-transient-tool-load-\(UUID().uuidString)"
    let activeDir = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
    let activePath = activeDir.appendingPathComponent("\(sessionId).json")

    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let tools = SwiftToolDispatcher(dataRoot: root)
    let stream = ScriptedTextStreamingLLM(chunksByCall: [
        [#"<tool_use name="tool_load">{"names":["x_search"],"session_id":"\#(sessionId)"}</tool_use>"#],
        ["loaded for this text turn only"],
    ])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 3
    )

    let resp = try await client.chat(
        message: "search OpenAI news",
        sessionId: sessionId,
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(resp.output == "loaded for this text turn only")
    #expect(stream.callCount == 2)
    #expect(llm.callCount == 0)
    // INVERTED 2026-07-25: these expectations used to pin turn-end amnesia
    // (cleanupTransientActiveTools). That wiped the model's explicit
    // tool_load results every turn, forcing a full extra LLM round-trip to
    // re-load before nearly every action (live slowdown, 2026-07-25).
    // tool_load now PERSISTS for the session; the store's 24h TTL and
    // tool_unload own decay.
    let state = await tools.activeToolsStore.load(sessionId: sessionId)
    #expect(state.activeTools.contains("x_search"))
    #expect(FileManager.default.fileExists(atPath: activePath.path))
}

@Test
func chatClient_non_streaming_explicit_model_overrides_surface_context() async throws {
    let root = try makeTempRoot("explicit-model")
    let llm = ModelCapturingLLM(reply: "model override ok")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    let resp = try await client.chat(
        message: "hi there", sessionId: "s-explicit-model",
        model: "gpt-5.5", reasoningEffort: "medium",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )

    #expect(resp.output == "model override ok")
    #expect(resp.model == "gpt-5.5")
    #expect(resp.reasoningEffort == "medium")
    #expect(llm.models.last == "gpt-5.5")
}

@Test
func chatClient_freezesOneCheckedRouteAcrossContextAndMultipleProviderCalls() async throws {
    let root = try makeTempRoot("frozen-route-generation")
    let router = RotatingCheckedRoutingForClient()
    let adapter = RouteTupleCapturingAdapter()
    let llm = SwiftNativeLLMClient(
        router: router,
        codex: adapter,
        anthropic: adapter,
        openAI: adapter,
        moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
    )
    let tools = SwiftToolDispatcher(dataRoot: root)
    let engine = makeEngine(root: root, llm: llm, tools: tools, router: router)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 3
    )

    let response = try await client.chat(
        message: "show available tools",
        sessionId: "s-frozen-route-generation",
        model: "",
        reasoningEffort: "",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(response.output == "route remained frozen")
    #expect(response.model == "gpt-route-a")
    #expect(response.reasoningEffort == "medium")
    #expect(router.checkedCallCount == 3)
    #expect(adapter.calls.count == 2)
    #expect(adapter.calls.allSatisfy { $0.model == "gpt-route-a" })
    #expect(adapter.calls.allSatisfy { $0.admittedModel == "gpt-route-a" })
    #expect(adapter.calls.allSatisfy { $0.provider == "openai" })
    #expect(adapter.calls.allSatisfy { $0.effort == "medium" })
    #expect(adapter.calls.allSatisfy { $0.tier == "priority" })
    #expect(adapter.calls.allSatisfy { $0.system?.contains("provider=openai") == true })
    #expect(adapter.calls.allSatisfy { $0.system?.contains("provider=xai_oauth_direct") == false })
}

// EVAL FENCE: core.chat.engine / chat.admission.llmCallContextBinding
// Drive the public streaming admission facade and observe its checked route at
// the real provider boundary. The caller must remain unbound before and after
// the child stream task so one turn cannot leak admission into another.
@Test
func chatAdmissionBinding_streamFacadeBindsCheckedRouteAndRestoresCaller() async throws {
    #expect(LLMCallContext.admittedModel == nil)
    #expect(LLMCallContext.providerId == nil)
    #expect(LLMCallContext.reasoningEffort == nil)
    #expect(LLMCallContext.serviceTier == nil)

    let root = try makeTempRoot("frozen-stream-route-generation")
    defer { try? FileManager.default.removeItem(at: root) }
    let router = RotatingCheckedRoutingForClient(surface: "ios")
    let adapter = RouteTupleCapturingAdapter()
    let llm = SwiftNativeLLMClient(
        router: router,
        codex: adapter,
        anthropic: adapter,
        openAI: adapter,
        moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
    )
    let tools = SwiftToolDispatcher(dataRoot: root)
    let engine = makeEngine(root: root, llm: llm, tools: tools, router: router)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 3
    )

    var finalText: String?
    for try await event in client.chatStream(
        message: "show available tools",
        sessionId: "s-frozen-stream-route-generation",
        model: "",
        reasoningEffort: "",
        fileAccess: "workspace",
        attachments: [],
        persona: nil,
        surface: "ios",
        suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalText = result.reply }
    }

    #expect(finalText == "route remained frozen")
    #expect(adapter.calls.count == 2)
    #expect(adapter.calls.allSatisfy { $0.model == "gpt-route-a" })
    #expect(adapter.calls.allSatisfy { $0.admittedModel == "gpt-route-a" })
    #expect(adapter.calls.allSatisfy { $0.provider == "openai" })
    #expect(adapter.calls.allSatisfy { $0.effort == "medium" })
    #expect(adapter.calls.allSatisfy { $0.tier == "priority" })
    #expect(router.checkedCallCount >= 1)

    #expect(LLMCallContext.admittedModel == nil)
    #expect(LLMCallContext.providerId == nil)
    #expect(LLMCallContext.reasoningEffort == nil)
    #expect(LLMCallContext.serviceTier == nil)
}

// Regression tripwire only (not ledger evidence): detached work is an explicit
// isolation boundary and must not inherit an admitted provider route.
@Test
func llmCallContext_detachedTaskDoesNotInheritAdmittedTuple() async {
    struct Route: Sendable, Equatable {
        let model: String?
        let provider: String?
        let effort: String?
        let tier: String?
    }

    func currentRoute() -> Route {
        Route(
            model: LLMCallContext.admittedModel,
            provider: LLMCallContext.providerId,
            effort: LLMCallContext.reasoningEffort,
            tier: LLMCallContext.serviceTier
        )
    }

    let empty = Route(model: nil, provider: nil, effort: nil, tier: nil)
    let expected = Route(
        model: "gpt-admitted",
        provider: "openai_oauth_direct",
        effort: "xhigh",
        tier: "priority"
    )
    #expect(currentRoute() == empty)

    let observations = await LLMCallContext.$admittedModel.withValue(expected.model) {
        await LLMCallContext.$providerId.withValue(expected.provider) {
            await LLMCallContext.$reasoningEffort.withValue(expected.effort) {
                await LLMCallContext.$serviceTier.withValue(expected.tier) {
                    let before = currentRoute()
                    let detached = await Task.detached { currentRoute() }.value
                    let after = currentRoute()
                    return (before: before, detached: detached, after: after)
                }
            }
        }
    }

    #expect(observations.before == expected)
    #expect(observations.detached.model == nil)
    #expect(observations.detached.provider == nil)
    #expect(observations.detached.effort == nil)
    #expect(observations.detached.tier == nil)
    #expect(observations.after == expected)
    #expect(currentRoute() == empty)
}

@Test
func chatClient_anthropicTextCompatibilityFreezesTelegramRouteAcrossToolRounds() async throws {
    let root = try makeTempRoot("frozen-anthropic-route-generation")
    defer { try? FileManager.default.removeItem(at: root) }
    let router = RotatingCheckedRoutingForClient(
        surface: "telegram",
        firstModel: "claude-opus-route-a",
        firstEffort: "high",
        firstProvider: "anthropic_oauth_direct"
    )
    let llm = ModelCapturingLLM(reply: "structured path must remain unused")
    let textStream = ScriptedTextStreamingLLM(chunksByCall: [
        [#"<tool_use name="tool_catalog">{}</tool_use>"#],
        ["telegram route remained frozen"],
    ])
    let tools = SwiftToolDispatcher(dataRoot: root)
    let engine = makeEngine(root: root, llm: llm, tools: tools, router: router)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: textStream,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 3
    )

    var finalText: String?
    for try await event in client.chatStream(
        message: "show available tools",
        sessionId: "s-frozen-anthropic-route-generation",
        model: "",
        reasoningEffort: "",
        fileAccess: "workspace",
        attachments: [],
        persona: nil,
        surface: "telegram",
        suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalText = result.reply }
    }

    #expect(finalText == "telegram route remained frozen")
    #expect(llm.models.isEmpty)
    #expect(textStream.routeCalls.count == 2)
    #expect(textStream.routeCalls.allSatisfy { $0.model == "claude-opus-route-a" })
    #expect(textStream.routeCalls.allSatisfy { $0.admittedModel == "claude-opus-route-a" })
    #expect(textStream.routeCalls.allSatisfy { $0.provider == "anthropic_oauth_direct" })
    #expect(textStream.routeCalls.allSatisfy { $0.effort == "high" })
    #expect(textStream.routeCalls.allSatisfy { $0.tier == "priority" })
    #expect(textStream.routeCalls.allSatisfy { $0.surface == "telegram" })
    #expect(router.checkedCallCount >= 1)
}

@Test
func chatClient_suppressUserAppend_skips_user_persistence() async throws {
    let root = try makeTempRoot("suppress")
    let llm = MockLLMClient(scriptedResponses: ["assistant reply"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    _ = try await client.chat(
        message: "user said this", sessionId: "s-sup",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: true
    )
    let lines = readJSONL(root, sessionId: "s-sup")
    #expect(lines.count == 1)
    #expect(lines[0]["role"] as? String == "assistant")
}

@Test
func chatClient_session_history_is_loaded_and_threaded() async throws {
    let root = try makeTempRoot("hist")
    // Pre-seed prior turns on disk.
    let prior1: JSONValue = .object([
        "id": .string("a"), "role": .string("user"),
        "content": .string("earlier user msg"),
        "createdAt": .string("2026-01-01T00:00:00Z"),
    ])
    let prior2: JSONValue = .object([
        "id": .string("b"), "role": .string("assistant"),
        "content": .string("earlier assistant msg"),
        "createdAt": .string("2026-01-01T00:00:01Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "s-hist", lines: [
        (try? prior1.serialize(pretty: false)) ?? "",
        (try? prior2.serialize(pretty: false)) ?? "",
    ])
    let llm = MockLLMClient(scriptedResponses: ["new reply"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let history = SessionHistoryReader(dataRoot: root)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: history, dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let resp = try await client.chat(
        message: "follow-up", sessionId: "s-hist",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(resp.output == "new reply")
    // Verify SessionHistoryReader did surface the prior turns.
    let loaded = try await history.messages(forSessionId: "s-hist")
    #expect(loaded.count >= 2)
    #expect(loaded[0].content == "earlier user msg")
    #expect(loaded[1].content == "earlier assistant msg")
    // Post-chat the file should have the prior 2 + new user + new assistant.
    let after = readJSONL(root, sessionId: "s-hist")
    #expect(after.count == 4)
}

@Test
func chatClient_autonomy_blocks_denied_tool() async throws {
    // Verify the AutonomyGate denial path. Construct gate directly with a
    // FixedTrustResolver returning "deny" so we don't depend on full
    // SwiftNativeTrustCenter wiring for this assertion.
    let gate = AutonomyGate(trust: FixedTrustResolver(level: "deny"))
    let inner = MockToolDispatchClient(scripted: ["risky": .string("would have run")])
    let gated = AutonomyGatedDispatcher(inner: inner, gate: gate)
    var thrown: Error?
    do {
        _ = try await gated.dispatch(tool: "risky", input: [:], surface: "chat")
    } catch {
        thrown = error
    }
    guard let e = thrown as? AutonomyGateError else {
        Issue.record("expected AutonomyGateError, got \(String(describing: thrown))")
        return
    }
    if case .toolDenied = e {
        // expected
    } else {
        Issue.record("expected .toolDenied, got \(e)")
    }
    #expect(inner.dispatches.isEmpty)
}

@Test
func autonomyGate_mapsTrustApprovalLevels() {
    for level in ["confirm", "send_approval", "destructive_strong"] {
        guard case .requireApproval(let reason) = AutonomyGate.map(level: level) else {
            Issue.record("expected \(level) to require approval")
            continue
        }
        #expect(reason.contains(level))
    }
}

@Test
func chatClient_personaWriteGuard_blocksProtectedDocsButAllowsGrowth() async throws {
    let gate = AutonomyGate(trust: FixedTrustResolver(level: "auto"))
    let inner = MockToolDispatchClient(scripted: [
        "persona_write": .object(["ok": .bool(true)]),
    ])
    let gated = AutonomyGatedDispatcher(inner: inner, gate: gate)

    _ = try await gated.dispatch(
        tool: "persona_write",
        input: ["kind": .string("growth"), "content": .string("# Growth")],
        surface: "telegram"
    )

    var blocked = false
    do {
        _ = try await gated.dispatch(
            tool: "persona_write",
            input: ["kind": .string("soul"), "content": .string("# Soul")],
            surface: "telegram"
        )
    } catch is AutonomyGateError {
        blocked = true
    }
    #expect(blocked)
    #expect(inner.dispatches.map(\.tool) == ["persona_write"])
}

/// Captures the ChatToolSessionContext TaskLocal value visible at dispatch
/// time, so we can assert the authoritative gate threads the verified session
/// down to inner app-side dispatchers (the invoke_claude false-block fix).
private final class SessionCapturingDispatch: ToolDispatchClient, @unchecked Sendable {
    // Single sequential dispatch per test, read after the await completes — no
    // concurrent access, so plain stored state is safe (NSLock is unavailable
    // in async contexts anyway).
    private(set) var didDispatch = false
    private(set) var seenSession: String?
    private(set) var seenChatId: String?

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        didDispatch = true
        seenSession = ChatToolSessionContext.verifiedSessionId
        seenChatId = ChatToolSessionContext.verifiedChatId
        return .string("ok")
    }
    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

@Test
func autonomyGatedDispatcher_threads_verifiedSession_to_inner() async throws {
    // The authoritative gate must bind ChatToolSessionContext so a downstream
    // app dispatcher (AppChatToolDispatcher) reconstructs the same trusted
    // origin instead of re-gating session-blind and false-blocking a trusted
    // remote invoke. Regression guard for security/audit.jsonl 2026-06-09 19:24.
    let gate = AutonomyGate(trust: FixedTrustResolver(level: "auto"))
    let spy = SessionCapturingDispatch()
    let gated = AutonomyGatedDispatcher(
        inner: spy, gate: gate, verifiedSessionId: "telegram:111222333"
    )
    _ = try await gated.dispatch(
        tool: "persona_write",
        input: ["kind": .string("growth"), "content": .string("# Growth")],
        surface: "telegram"
    )
    #expect(spy.didDispatch)
    #expect(spy.seenSession == "telegram:111222333")
}

@Test
func autonomyGatedDispatcher_nilSession_leaves_taskLocal_unset() async throws {
    // No session in play (e.g. stateless caller) → the TaskLocal stays nil, so
    // downstream gates fall back to surface-only origin. Must not leak a value.
    let gate = AutonomyGate(trust: FixedTrustResolver(level: "auto"))
    let spy = SessionCapturingDispatch()
    let gated = AutonomyGatedDispatcher(
        inner: spy, gate: gate, verifiedSessionId: nil
    )
    _ = try await gated.dispatch(
        tool: "persona_write",
        input: ["kind": .string("growth"), "content": .string("# Growth")],
        surface: "chat"
    )
    #expect(spy.didDispatch)
    #expect(spy.seenSession == nil)
}

@Test
func resolvedChatId_prefers_verifiedChatId_over_session_string() async throws {
    // UUID session (post-/new) — chatId is NOT parseable from the string, but
    // the transport-verified chatId must win so allowlist trust still resolves.
    ChatToolSessionContext.$verifiedChatId.withValue("111222333") {
        #expect(AutonomyGatedDispatcher.resolvedChatId(sessionId: "9F0C-UUID-SESSION") == "111222333")
    }
    // 2026-09-06: the `telegram:<chatId>` session-string fallback was DELETED
    // (7df7a4cd, "PARSE SITE 2 of 5"). It was unsound: `chat/sessions.json`
    // holds app-sourced rows keyed `telegram:codex-probe`, for which it yielded
    // the literal "codex-probe" as a chat identity. The session id is a storage
    // key, not provenance — identity comes from the transport or not at all. So
    // a legacy-shaped session with no verified chatId now resolves to nil, and
    // this line pins the deletion rather than the old parse.
    #expect(AutonomyGatedDispatcher.resolvedChatId(sessionId: "telegram:111222333") == nil)
    // No verified chatId + UUID session → nil (correctly untrusted, no forgery).
    #expect(AutonomyGatedDispatcher.resolvedChatId(sessionId: "9F0C-UUID-SESSION") == nil)
}

@Test
func autonomyGatedDispatcher_threads_verifiedChatId_to_inner() async throws {
    // The transport binds verifiedChatId around the turn; it must reach the
    // downstream app gate so a UUID-session Telegram invoke resolves trust.
    let gate = AutonomyGate(trust: FixedTrustResolver(level: "auto"))
    let spy = SessionCapturingDispatch()
    let gated = AutonomyGatedDispatcher(
        inner: spy, gate: gate, verifiedSessionId: "9F0C-UUID-SESSION"
    )
    try await ChatToolSessionContext.$verifiedChatId.withValue("111222333") {
        _ = try await gated.dispatch(
            tool: "persona_write",
            input: ["kind": .string("growth"), "content": .string("# Growth")],
            surface: "telegram"
        )
    }
    #expect(spy.didDispatch)
    #expect(spy.seenChatId == "111222333")
    #expect(spy.seenSession == "9F0C-UUID-SESSION")
}

@Test
func chatToolSessionInjection_autofills_tool_load_and_catalog_session() {
    // The bug: the text-compat path's copy of this lacked the tool_load/
    // tool_catalog auto-fill, so claude-* chats bounced lazy-loads with
    // missing_session_id. Now both paths share this one implementation.
    let load = ChatToolSessionInjection.apply(
        toolName: "tool_load",
        input: ["names": .array([.string("git_status")])],
        sessionId: "sess-123"
    )
    #expect(load["session_id"] == .string("sess-123"))
    #expect(load["__session_id"] == .string("sess-123"))

    let catalog = ChatToolSessionInjection.apply(toolName: "tool_catalog", input: [:], sessionId: "sess-123")
    #expect(catalog["session_id"] == .string("sess-123"))

    let traces = ChatToolSessionInjection.apply(
        toolName: "recent_trace_summary", input: [:], sessionId: "sess-123"
    )
    #expect(traces["session_id"] == .string("sess-123"))

    // Empty session → nothing injected (no forged session).
    let empty = ChatToolSessionInjection.apply(toolName: "tool_load", input: [:], sessionId: "")
    #expect(empty["session_id"] == nil)

    // An explicit session_id from the LLM is preserved, not overwritten.
    let explicit = ChatToolSessionInjection.apply(
        toolName: "tool_load",
        input: ["session_id": .string("explicit")],
        sessionId: "sess-123"
    )
    #expect(explicit["session_id"] == .string("explicit"))
}

@Test
func agentIntrospect_providerStamp_reports_live_turn_model() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("providerStamp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Inside a turn the exact admitted transport wins. Model inference cannot
    // distinguish API-key, OAuth-direct, Codex, and OpenRouter routes.
    let live = await ChatTurnRuntimeContext.$current.withValue(
        .init(
            model: "gpt-5.6",
            surface: "telegram",
            providerID: "openai_oauth_direct"
        )
    ) {
        await SwiftToolDispatcher.providerStamp(dataRoot: root)
    }
    guard case .object(let obj) = live else { Issue.record("not an object"); return }
    #expect(obj["model"] == .string("gpt-5.6"))
    #expect(obj["name"] == .string("openai_oauth_direct"))
    #expect(obj["surface"] == .string("telegram"))
    #expect(obj["source"] == .string("live_turn"))

    // Outside a turn (no bound model) it must NOT claim a live model — it falls
    // back to configured/unresolved, never live_turn.
    let offTurn = await SwiftToolDispatcher.providerStamp(dataRoot: root)
    guard case .object(let offObj) = offTurn else { Issue.record("not an object"); return }
    #expect(offObj["source"] != .string("live_turn"))
}

@Test
func chatClient_fileAccess_none_blocks_fs_prefixed_tools() async throws {
    let inner = MockToolDispatchClient(scripted: [
        "fs.read": .string("nope"),
        "persona_read": .string("nope"),
        "shell.exec": .string("nope"),
        "echo": .string("ok"),
    ])
    let gated = FileAccessGatedDispatcher(inner: inner, fileAccess: "none")
    var blocked = false
    do {
        _ = try await gated.dispatch(tool: "fs.read", input: [:], surface: "chat")
    } catch is AutonomyGateError {
        blocked = true
    }
    #expect(blocked)
    // Non-fs tool still works.
    let r = try await gated.dispatch(tool: "echo", input: [:], surface: "chat")
    if case .string(let s) = r { #expect(s == "ok") } else { Issue.record("echo result wrong") }
    // listAvailableTools filters out blocked names.
    let names = try await gated.listAvailableTools()
    #expect(names.contains("echo"))
    #expect(!names.contains("fs.read"))
    #expect(!names.contains("persona_read"))
    #expect(!names.contains("shell.exec"))
}

@Test
func chatClient_fileAccess_readOnly_blocks_writes_but_keeps_reads_and_macControl() async throws {
    let schemaJSON = Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
    let schemas = [
        LLMToolSchema(name: "read_file", description: "read", parametersJSON: schemaJSON),
        LLMToolSchema(name: "file_excerpt", description: "excerpt", parametersJSON: schemaJSON),
        LLMToolSchema(name: "git_status", description: "status", parametersJSON: schemaJSON),
        LLMToolSchema(name: "system_info", description: "system", parametersJSON: schemaJSON),
        LLMToolSchema(name: "persona_read", description: "persona read", parametersJSON: schemaJSON),
        LLMToolSchema(name: "persona_write", description: "persona write", parametersJSON: schemaJSON),
        LLMToolSchema(name: "persona_append_section", description: "persona append", parametersJSON: schemaJSON),
        LLMToolSchema(name: "write_file", description: "write", parametersJSON: schemaJSON),
        LLMToolSchema(name: "shell.exec", description: "shell", parametersJSON: schemaJSON),
        LLMToolSchema(name: "mac_quit_app", description: "quit", parametersJSON: schemaJSON),
        LLMToolSchema(name: "echo", description: "echo", parametersJSON: schemaJSON),
    ]
    let inner = SchemaBackedToolDispatch(
        schemas: schemas,
        scripted: [
            "read_file": .string("read"),
            "file_excerpt": .string("excerpt"),
            "git_status": .string("status"),
            "system_info": .string("system"),
            "persona_read": .string("persona read"),
            "persona_write": .string("persona write"),
            "persona_append_section": .string("persona append"),
            "write_file": .string("write"),
            "shell.exec": .string("shell"),
            "mac_quit_app": .string("quit"),
            "echo": .string("ok"),
        ]
    )
    let gated = FileAccessGatedDispatcher(inner: inner, fileAccess: "read_only")

    let read = try await gated.dispatch(tool: "read_file", input: [:], surface: "chat")
    #expect(read == .string("read"))
    let git = try await gated.dispatch(tool: "git_status", input: [:], surface: "chat")
    #expect(git == .string("status"))
    let personaRead = try await gated.dispatch(tool: "persona_read", input: [:], surface: "chat")
    #expect(personaRead == .string("persona read"))

    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: `mac_quit_app` was blocked and unlisted
    // in read-only mode along with the file/persona writes. NEW CONTRACT: it
    // was removed from readOnlyBlockedExact — quitting an app is not a file
    // write, and the Trust Center accessibility category is its gate. The mode
    // still means read-only for everything that touches the filesystem or the
    // persona, which is what the rest of this row pins.
    let quit = try await gated.dispatch(tool: "mac_quit_app", input: [:], surface: "chat")
    #expect(quit == .string("quit"), "mac_quit_app passes read-only mode post-cutover")

    for blockedTool in ["write_file", "shell.exec", "persona_write", "persona_append_section"] {
        var blocked = false
        do {
            _ = try await gated.dispatch(tool: blockedTool, input: [:], surface: "chat")
        } catch is AutonomyGateError {
            blocked = true
        }
        #expect(blocked, "\(blockedTool) should be blocked in read-only mode")
    }

    let names = try await gated.listAvailableTools()
    #expect(names.contains("read_file"))
    #expect(names.contains("file_excerpt"))
    #expect(names.contains("git_status"))
    #expect(names.contains("system_info"))
    #expect(names.contains("persona_read"))
    #expect(names.contains("echo"))
    #expect(!names.contains("write_file"))
    #expect(!names.contains("persona_write"))
    #expect(!names.contains("persona_append_section"))
    #expect(!names.contains("shell.exec"))
    #expect(names.contains("mac_quit_app"), "mac_quit_app is listed in read-only mode post-cutover")

    let schemaNames = try await gated.listAvailableToolSchemas().map(\.name)
    #expect(schemaNames.contains("read_file"))
    #expect(schemaNames.contains("git_status"))
    #expect(schemaNames.contains("persona_read"))
    #expect(!schemaNames.contains("write_file"))
    #expect(!schemaNames.contains("persona_write"))
    #expect(!schemaNames.contains("persona_append_section"))
    #expect(!schemaNames.contains("shell.exec"))
    #expect(schemaNames.contains("mac_quit_app"))
}

@Test
func chatClient_fileAccess_unknown_blocks_file_tools() async throws {
    let inner = MockToolDispatchClient(scripted: [
        "read_file": .string("read"),
        "echo": .string("ok"),
    ])
    let gated = FileAccessGatedDispatcher(inner: inner, fileAccess: "bogus")
    var blocked = false
    do {
        _ = try await gated.dispatch(tool: "read_file", input: [:], surface: "chat")
    } catch is AutonomyGateError {
        blocked = true
    }
    #expect(blocked)

    let echo = try await gated.dispatch(tool: "echo", input: [:], surface: "chat")
    #expect(echo == .string("ok"))
}

@Test
func chatClient_empty_message_no_attachments_throws_emptyMessage() async throws {
    let root = try makeTempRoot("empty")
    let llm = MockLLMClient(scriptedResponses: ["unused"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm, history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    var thrown: Error?
    do {
        _ = try await client.chat(
            message: "   ", sessionId: "s-empty",
            model: "client-model", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], suppressUserAppend: false
        )
    } catch {
        thrown = error
    }
    #expect(thrown is ChatOrchestrationError)
}

// MARK: - Follow-up tests (5 fixes)

@Test
func factory_with_deps_injected_returns_SwiftNative() async throws {
    let root = try makeTempRoot("factory")
    let llm = MockLLMClient(scriptedResponses: ["x"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = makeChatOrchestrationClient(
        engine: engine, llm: llm, tools: tools
    )
    #expect(client is SwiftNativeChatOrchestrationClient)

    // No deps → auto-constructed SwiftNative.
    let bare = makeChatOrchestrationClient()
    #expect(bare is SwiftNativeChatOrchestrationClient)
}

@Test
func alternateRootChatMemoryRecallerReadsOnlyInjectedMemoryStore() async throws {
    let root = try makeTempRoot("factory-memory-root")
    defer { try? FileManager.default.removeItem(at: root) }

    let config = root
        .appendingPathComponent("config", isDirectory: true)
        .appendingPathComponent("embeddings.json")
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{\"backend\":\"mock\"}".utf8).write(to: config, options: .atomic)

    let uniqueText = "alternate-root-memory-\(UUID().uuidString)"
    let vector = try #require(try await MockEmbeddingProvider().embed([uniqueText]).first)
    let storage = try MemoryStorage(dataRoot: root)
    _ = try await storage.insertMemory(StoredMemory(
        content: uniqueText,
        embedding: vector,
        status: "active"
    ))

    let recaller = makeChatMemoryRecaller(dataRoot: root)
    let hits = try await recaller.recall(uniqueText, k: 4)
    #expect(hits.contains { $0.content == uniqueText })
    #expect(makeChatMemoryPromoter(dataRoot: root) == nil)
}

@Test
func alternateRootDefaultChatFactoryFailsClosedBeforeProviderCredentials() async throws {
    let root = try makeTempRoot("factory-provider-root")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = makeChatOrchestrationClient(
        tools: MockToolDispatchClient(),
        dataRoot: root,
        providerRecoverySleep: { _ in try Task.checkCancellation() }
    )

    await #expect(throws: ChatOrchestrationError.self) {
        _ = try await client.chat(
            message: "must not borrow live providers",
            sessionId: "alternate-provider-root",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            fileAccess: "workspace",
            attachments: [],
            suppressUserAppend: true
        )
    }
}

@Test
func gatedToolFactoryReadsAutonomyFromInjectedRoot() async throws {
    let root = try makeTempRoot("gated-factory-root")
    defer { try? FileManager.default.removeItem(at: root) }
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. This row's INTENT is unchanged — prove the factory
    // reads autonomy from the INJECTED dataRoot and not the live one — but the
    // probe had to move: `autonomyDefault: deny` no longer denies, because the
    // merged Trust Center defaults now carry `toolAutonomy["default"] = "auto"`
    // and an override table entry outranks the bare default. An explicit
    // USER-SET per-tool block is the remaining lever that still bites (it
    // outranks even an active Full Mac posture), so the probe uses that.
    try writeTrustPolicy(root, .object([
        "autonomyDefault": .string("deny"),
        "toolAutonomy": .object(["echo": .string("blocked")]),
    ]))
    let inner = MockToolDispatchClient(scripted: ["echo": .string("must-not-run")])
    let gated = makeGatedToolDispatchClient(
        tools: inner,
        fileAccess: "auto",
        approvalFiler: nil,
        dataRoot: root
    )

    await #expect(throws: AutonomyGateError.self) {
        _ = try await gated.dispatch(tool: "echo", input: [:], surface: "chat")
    }
    #expect(inner.dispatches.isEmpty)
}

@Test
func alternateRootToolDispatcherKeepsLazyLoadStateOutOfLiveRoot() async throws {
    let root = try makeTempRoot("dispatcher-active-tools-root")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = "active-root-\(UUID().uuidString)"
    let relativePath = "chat/active_tools/\(sessionID).json"
    let injectedPath = root.appendingPathComponent(relativePath)
    // 2026-07-21 audit: the live path is asserted read-only — a leak must
    // stay on disk as failure evidence; tests never delete under the live
    // data root.
    let livePath = PersistenceCore.defaultDataRoot().appendingPathComponent(relativePath)

    let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
    _ = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionID),
            "names": .array([.string("read_file")]),
        ],
        surface: "chat"
    )

    #expect(FileManager.default.fileExists(atPath: injectedPath.path))
    #expect(!FileManager.default.fileExists(atPath: livePath.path))
}

@Test
func alternateRootToolDispatcherOwnsMemoryAndRejectsCanonicalBodyTools() async throws {
    let root = try makeTempRoot("dispatcher-memory-root")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root
        .appendingPathComponent("config", isDirectory: true)
        .appendingPathComponent("embeddings.json")
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{\"backend\":\"mock\"}".utf8).write(to: config, options: .atomic)

    let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
    let unique = "dispatcher-root-memory-\(UUID().uuidString)"
    let commit = try await dispatcher.dispatch(
        tool: "commit_memory",
        input: ["text": .string(unique)],
        surface: "chat"
    )
    guard case .object(let commitObject) = commit else {
        Issue.record("commit_memory returned a non-object")
        return
    }
    #expect(commitObject["status"] == .string("ok"))

    let stored = try await MemoryStorage(dataRoot: root).listMemories(status: "active")
    #expect(stored.contains { $0.content == unique })
    let liveMatches = try await SwiftNativeMemoryV2.shared.listMemory(kind: nil)
    let leakedIntoLiveMemory = liveMatches.contains(where: { record in
        record.text == unique
    })
    #expect(leakedIntoLiveMemory == false)
    #expect(dispatcher.knowledgeGraphPath == root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("knowledge_graph.json"))

    let names = try await dispatcher.listAvailableTools()
    #expect(!names.contains("restart_app"))
    #expect(!names.contains("x_status"))
    let blocked = try await dispatcher.dispatch(tool: "restart_app", input: [:], surface: "chat")
    guard case .object(let blockedObject) = blocked else {
        Issue.record("alternate-root restart returned a non-object")
        return
    }
    #expect(blockedObject["reason"] == .string("canonical_body_unavailable"))
}

@Test
func alternateRootChatTraceBusPersistsOnlyUnderInjectedRoot() async throws {
    let root = try makeTempRoot("factory-turn-trace-root")
    defer { try? FileManager.default.removeItem(at: root) }
    let turnID = "alternate-trace-\(UUID().uuidString)"
    let event = TurnTraceEvent(turnId: turnID, kind: "root.isolation")
    let injectedPath = TurnTracePersistLane(dataRootOverride: root).path(for: event.ts)
    let livePath = PersistenceCore.defaultDataRoot()
        .appendingPathComponent("turn_traces", isDirectory: true)
        .appendingPathComponent(injectedPath.lastPathComponent)

    TurnTraceBus.fire(event, on: makeChatTurnTraceBus(dataRoot: root))
    for _ in 0..<100 {
        let text = (try? String(contentsOf: injectedPath, encoding: .utf8)) ?? ""
        if text.contains(turnID) { break }
        try await Task.sleep(for: .milliseconds(100))
    }

    #expect((try? String(contentsOf: injectedPath, encoding: .utf8))?.contains(turnID) == true)
    #expect((try? String(contentsOf: livePath, encoding: .utf8))?.contains(turnID) != true)
}

@Test
func chatClient_swiftNative_sanity_returns_reply_with_mock_deps() async throws {
    let root = try makeTempRoot("sanity")
    let llm = MockLLMClient(scriptedResponses: ["sanity reply"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = makeChatOrchestrationClient(
        engine: engine, llm: llm, tools: tools, dataRoot: root
    )
    #expect(client is SwiftNativeChatOrchestrationClient)
    guard let swift = client as? SwiftNativeChatOrchestrationClient else { return }
    let resp = try await swift.chat(
        message: "ping", sessionId: "s-sanity",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: true
    )
    #expect(resp.output == "sanity reply")
    #expect(resp.sessionId == "s-sanity")
    #expect(readJSONL(root, sessionId: "s-sanity").last?["content"] as? String == "sanity reply")
}

@Test
func chatClient_terminalTraceCarriesAuthoritativeMetacognitiveObservations() async throws {
    let root = try makeTempRoot("metacognitive-terminal")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = MockLLMClient(scriptedResponses: ["observed reply"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        turnTraceBus: bus,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    _ = try await client.chat(
        message: "observe this turn",
        sessionId: "s-metacognitive-terminal",
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: true
    )

    var terminal: TurnTraceEvent?
    for _ in 0..<100 {
        let events = try await TurnTraceRecentReader(dataRootOverride: root).read().events
        terminal = events.last { $0.kind == "turn.terminal" }
        if terminal != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let event = try #require(terminal)
    guard case .object(let payload) = event.payload else {
        Issue.record("terminal trace payload was not an object")
        return
    }
    #expect(payload["schema"] == .string("metacognition.observed.v1"))
    #expect(payload["status"] == .string("completed"))
    #expect(payload["modelUsed"] == .string("client-model"))
    #expect(payload["reasoningEffort"] == .string("high"))
    #expect(payload["contextSource"] == .string("legacy"))
    #expect(payload["contextSelectedAtomCount"] == .int(0))
    #expect(payload["contextPacketCharacters"] == .int(0))
    #expect(payload["contextExpandablePointerCount"] == .int(0))
    #expect(payload["toolDispatchCount"] == .int(0))
    #expect(payload["failedToolDispatchCount"] == .int(0))
    #expect(payload["contextExpansionCount"] == .int(0))
    if case .int(let elapsed)? = payload["turnElapsedMs"] {
        #expect(elapsed >= 0)
    } else {
        Issue.record("terminal trace did not carry turnElapsedMs")
    }
    if case .int(let schemaCount)? = payload["toolSchemaCount"] {
        #expect(schemaCount >= 0)
    } else {
        Issue.record("terminal trace did not carry toolSchemaCount")
    }
    if case .int(let recalledCount)? = payload["recalledMemoryCount"] {
        #expect(recalledCount >= 0)
    } else {
        Issue.record("terminal trace did not carry recalledMemoryCount")
    }
}

private actor StubApprovalFiler: ApprovalFiler {
    enum Outcome: Sendable { case approve, deny }
    let outcome: Outcome
    private(set) var fileCount = 0
    init(outcome: Outcome) { self.outcome = outcome }
    func fileApprovalRequest(toolName: String, surface: String, payload: JSONValue, reason: String) async throws -> String {
        fileCount += 1
        return "appr-test-1"
    }
    func awaitResolution(id: String) async throws -> ApprovalDecision {
        switch outcome {
        case .approve: return .approved
        case .deny:    return .denied
        }
    }
    func getCount() -> Int { fileCount }
}

@Test
func requireApproval_with_filer_continues_on_approve() async throws {
    let trust = FixedTrustResolver(level: "supervised")
    let filer = StubApprovalFiler(outcome: .approve)
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let inner = MockToolDispatchClient(scripted: ["risky.tool": .string("dispatched-after-approval")])
    let gated = AutonomyGatedDispatcher(inner: inner, gate: gate, hasFiler: true, approvalTimeoutSeconds: 5)
    let result = try await gated.dispatch(tool: "risky.tool", input: [:], surface: "chat")
    if case .string(let s) = result { #expect(s == "dispatched-after-approval") } else {
        Issue.record("expected dispatched string, got \(result)")
    }
    let filed = await filer.getCount()
    #expect(filed == 1)
    #expect(inner.dispatches.count == 1)
}

@Test
func requireApproval_with_filer_denies_on_deny() async throws {
    let trust = FixedTrustResolver(level: "supervised")
    let filer = StubApprovalFiler(outcome: .deny)
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let inner = MockToolDispatchClient(scripted: ["risky.tool": .string("should-not-run")])
    let gated = AutonomyGatedDispatcher(inner: inner, gate: gate, hasFiler: true, approvalTimeoutSeconds: 5)
    var thrown: Error?
    do {
        _ = try await gated.dispatch(tool: "risky.tool", input: [:], surface: "chat")
    } catch {
        thrown = error
    }
    #expect(thrown is AutonomyGateError)
    #expect(inner.dispatches.isEmpty)
}

@Test
func ChatResponse_decodes_message_and_messages_fields() throws {
    let json = """
    {"runId":"r1","model":"m","output":"o","sessionId":"s",
     "message":{"role":"assistant","content":"hi","timestamp":"2026-05-31T00:00:00Z"},
     "messages":[{"role":"user","content":"q","timestamp":"2026-05-31T00:00:00Z"},
                 {"role":"assistant","content":"a","timestamp":"2026-05-31T00:00:01Z"}]}
    """
    let decoded = try JSONDecoder().decode(ChatResponse.self, from: Data(json.utf8))
    #expect(decoded.message?.content == "hi")
    #expect(decoded.messages?.count == 2)
    #expect(decoded.messages?[0].role == "user")
    #expect(decoded.messages?[1].content == "a")

    // Round-trip: re-encode and re-decode preserves fields.
    let data = try JSONEncoder().encode(decoded)
    let again = try JSONDecoder().decode(ChatResponse.self, from: data)
    #expect(again.message?.content == "hi")
    #expect(again.messages?.count == 2)
}

/// LLM that records every prompt/system it sees so a test can assert what
/// the tool loop actually fed the model. Uses a serial DispatchQueue to stay
/// async-safe without NSLock.unlock (unavailable in async contexts).
private final class RecordingLLMClient: LLMClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecordingLLMClient")
    private var _prompts: [String] = []
    private var _systems: [String?] = []
    let reply: String
    init(reply: String) { self.reply = reply }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        queue.sync {
            _prompts.append(prompt)
            _systems.append(system)
        }
        return reply
    }
    var prompts: [String] { queue.sync { _prompts } }
    var systems: [String?] { queue.sync { _systems } }
}

@Test
func chatClient_threads_session_history_into_tool_loop() async throws {
    let root = try makeTempRoot("threadhist")
    // Pre-seed prior turns on disk.
    let prior1: JSONValue = .object([
        "id": .string("p1"), "role": .string("user"),
        "content": .string("PRIOR_USER_MSG_TOKEN"),
        "createdAt": .string("2026-01-01T00:00:00Z"),
    ])
    let prior2: JSONValue = .object([
        "id": .string("p2"), "role": .string("assistant"),
        "content": .string("PRIOR_ASSISTANT_MSG_TOKEN"),
        "createdAt": .string("2026-01-01T00:00:01Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "s-thread", lines: [
        (try? prior1.serialize(pretty: false)) ?? "",
        (try? prior2.serialize(pretty: false)) ?? "",
    ])
    let llm = RecordingLLMClient(reply: "new reply with no tool calls")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let history = SessionHistoryReader(dataRoot: root)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: history, dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    _ = try await client.chat(
        message: "follow-up question", sessionId: "s-thread",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    // The recording LLM should have been called at least once, and the
    // prompt+system pair must contain the prior turns — not just the new msg.
    #expect(llm.prompts.count >= 1)
    let firstPrompt = llm.prompts.first ?? ""
    let firstSystem: String = (llm.systems.first ?? nil) ?? ""
    let combined = firstPrompt + "\n" + firstSystem
    #expect(combined.contains("PRIOR_USER_MSG_TOKEN"),
            "history-threaded prior user message must reach the LLM")
    #expect(combined.contains("PRIOR_ASSISTANT_MSG_TOKEN"),
            "history-threaded prior assistant message must reach the LLM")
    #expect(combined.contains("follow-up question"),
            "the new user message must also reach the LLM")
}

@Test
func chatClient_does_not_duplicate_current_user_turn_as_prior_history() async throws {
    let root = try makeTempRoot("threadhist-no-current-dup")
    let prior: JSONValue = .object([
        "id": .string("p1"), "role": .string("user"),
        "content": .string("PRIOR_CONTEXT_ONLY"),
        "createdAt": .string("2026-01-01T00:00:00Z"),
    ])
    try writeMessagesJSONL(root, sessionId: "s-thread", lines: [
        (try? prior.serialize(pretty: false)) ?? "",
    ])
    let llm = RecordingLLMClient(reply: "new reply with no tool calls")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let history = SessionHistoryReader(dataRoot: root)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: history, dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    _ = try await client.chat(
        message: "CURRENT_USER_DUP_TOKEN", sessionId: "s-thread",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(llm.prompts.first?.contains("CURRENT_USER_DUP_TOKEN") == true)
    let firstSystem: String = (llm.systems.first ?? nil) ?? ""
    // 2026-09-06: the replayed transcript no longer rides the system segment —
    // v2Prefix relocated it out of the churning dynamic block (the whole point
    // of ConversationPrefixV2ProjectionTests). So the history assertion moves
    // to the prompt+system pair, exactly like the sibling
    // `chatClient_threads_session_history_into_tool_loop` above. What this test
    // actually owns is unchanged and still checked on both halves: the CURRENT
    // user turn must not ALSO appear as a prior-history row.
    let combined = (llm.prompts.first ?? "") + "\n" + firstSystem
    #expect(combined.contains("PRIOR_CONTEXT_ONLY"))
    #expect(!combined.contains("[user] CURRENT_USER_DUP_TOKEN"))
}

@Test
func chatClient_imageAttachment_reachesLLM_asNativeImageBlock() async throws {
    let root = try makeTempRoot("vision-e2e")
    let llm = MessageCapturingLLM(reply: "I see a cat")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let att = MultimodalAttachment(
        type: "image", base64: "QUJDRA==", mime: "image/png", name: "cat.png", byteSize: 4
    )
    _ = try await client.chat(
        message: "what is this?", sessionId: "s-vision",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [att], suppressUserAppend: false
    )
    let first = try #require(llm.capturedMessages.first)
    #expect(first.role == .user)
    // Image block FIRST, text LAST.
    guard case let .image(mediaType, base64, _, _) = first.content.first else {
        Issue.record("expected first content block to be .image, got \(first.content)"); return
    }
    #expect(mediaType == "image/png")
    #expect(base64 == "QUJDRA==")
    #expect(first.content.last == .text("what is this?"))
}

// History no-balloon: persisted user record keeps metadata (no base64) and the
// raw content; later history rebuilds never re-embed image bytes.
@Test
func chatClient_imageAttachment_persistsMetadataWithoutBase64() async throws {
    let root = try makeTempRoot("vision-noballoon")
    let llm = MessageCapturingLLM(reply: "ok")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let att = MultimodalAttachment(
        type: "image", base64: "QUJDRA==", mime: "image/png", name: "cat.png", byteSize: 4
    )
    _ = try await client.chat(
        message: "look at this", sessionId: "s-noballoon",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [att], suppressUserAppend: false
    )
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("s-noballoon.jsonl")
    let raw = try String(contentsOf: path, encoding: .utf8)
    // base64 bytes NEVER persisted.
    #expect(!raw.contains("QUJDRA=="))
    // metadata present, content is the raw message, no stringified suffix.
    #expect(raw.contains("\"byteSize\""))
    #expect(raw.contains("image/png"))
    #expect(raw.contains("look at this"))
    #expect(!raw.contains("[attachments:"))
}

// Image-only turn (empty caption) must NOT be rejected as emptyMessage — the
// image block alone is a valid turn and must reach the LLM.
@Test
func chatClient_imageOnly_noCaption_reachesLLM() async throws {
    let root = try makeTempRoot("vision-imageonly")
    let llm = MessageCapturingLLM(reply: "I see it")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let att = MultimodalAttachment(
        type: "image", base64: "QUJDRA==", mime: "image/png", name: "cat.png", byteSize: 4
    )
    let resp = try await client.chat(
        message: "", sessionId: "s-imageonly",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [att], suppressUserAppend: false
    )
    #expect(resp.output == "I see it")
    let first = try #require(llm.capturedMessages.first)
    // Content is image-only (no trailing text block).
    #expect(first.content.count == 1)
    guard case .image = first.content[0] else {
        Issue.record("expected image-only content, got \(first.content)"); return
    }
}

private final class RotatingCheckedRoutingForClient: ProviderRoutingProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let surface: String
    private let firstModel: String
    private let firstEffort: String
    private let firstProvider: String

    init(
        surface: String = "chat",
        firstModel: String = "gpt-route-a",
        firstEffort: String = "medium",
        firstProvider: String = "openai"
    ) {
        self.surface = surface
        self.firstModel = firstModel
        self.firstEffort = firstEffort
        self.firstProvider = firstProvider
    }

    var checkedCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { .init(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { .init() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { .init() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        fatalError("execution must use checkedRoutingSnapshot")
    }
    func activeProvidersForSurfaces() async -> [String: String] {
        fatalError("execution must use checkedRoutingSnapshot")
    }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        let generation = lock.withLock {
            calls += 1
            return calls
        }
        if generation == 1 {
            return ProviderRoutingSnapshot(
                preferences: [
                    surface: SurfacePreference(
                        surface: surface,
                        model: firstModel,
                        reasoningEffort: firstEffort,
                        serviceTier: "priority"
                    )
                ],
                activeProviders: [surface: firstProvider],
                pinnedModels: [:]
            )
        }
        return ProviderRoutingSnapshot(
            preferences: [
                surface: SurfacePreference(
                    surface: surface,
                    model: "grok-route-b",
                    reasoningEffort: "low",
                    serviceTier: "default"
                )
            ],
            activeProviders: [surface: "xai_oauth_direct"],
            pinnedModels: [:]
        )
    }
}

private final class RouteTupleCapturingAdapter: LLMAdapter, @unchecked Sendable {
    let providerId = "openai"

    struct Call: Sendable {
        let model: String
        let admittedModel: String?
        let provider: String?
        let effort: String?
        let tier: String?
        let system: String?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        let index = lock.withLock {
            recorded.append(Call(
                model: model,
                admittedModel: LLMCallContext.admittedModel,
                provider: LLMCallContext.providerId,
                effort: LLMCallContext.reasoningEffort,
                tier: LLMCallContext.serviceTier,
                system: system
            ))
            return recorded.count
        }
        if index == 1 {
            return #"{"tool_calls":[{"id":"route-1","type":"function","function":{"name":"tool_catalog","arguments":"{}"}}]}"#
        }
        return "route remained frozen"
    }
}

/// Trust resolver that returns a hard-coded autonomy level for everything.

private final class FixedTrustResolver: AutonomyResolver, @unchecked Sendable {
    let level: String
    init(level: String) { self.level = level }
    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String { level }
}

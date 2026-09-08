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
func chatClient_streaming_uses_structured_chat_path_and_yields_final_delta() async throws {
    let root = try makeTempRoot("stream")
    let llm = MockLLMClient(scriptedResponses: ["assistant streamed-compatible reply"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        streamingLLM: stream, history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    var deltas: [String] = []
    var finalText: String?
    var hadError = false
    for try await event in client.chatStream(
        message: "go", sessionId: "s-stream",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .final(let r): finalText = r.reply
        case .error: hadError = true
        case .toolUse, .toolResult, .notice: break
        }
    }
    #expect(!hadError)
    #expect(stream.callCount == 0)
    #expect(llm.callCount == 1)
    // Protocol-marker withholding may safely re-chunk text while preserving
    // the ordered visible reply byte-for-byte.
    #expect(deltas.joined() == "assistant streamed-compatible reply")
    #expect(finalText == "assistant streamed-compatible reply")
    let lines = readJSONL(root, sessionId: "s-stream")
    #expect(lines.count == 2)
    #expect(lines[1]["content"] as? String == "assistant streamed-compatible reply")
    let sessions = readChatSessions(root)
    let session = try #require(sessions.first(where: { $0["id"] as? String == "s-stream" }))
    #expect(session["messageCount"] as? Int == 2)
    #expect(session["lastMessagePreview"] as? String == "assistant streamed-compatible reply")
    #expect(session["title"] as? String == "go")
    #expect(session["updatedAt"] != nil)
}

@Test
func chatClient_streaming_uses_structured_provider_deltas_without_sync_complete() async throws {
    let root = try makeTempRoot("stream-structured-deltas")
    let llm = StructuredStreamingScriptLLM(scriptedEvents: [[
        .textDelta("Hel"),
        .textDelta("lo"),
    ]])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        streamingLLM: stream, history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    var deltas: [String] = []
    var finalText: String?
    for try await event in client.chatStream(
        message: "hello", sessionId: "s-stream-structured-deltas",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .final(let r): finalText = r.reply
        case .toolUse, .toolResult, .error, .notice: break
        }
    }

    #expect(stream.callCount == 0)
    #expect(llm.streamCallCount == 1)
    #expect(llm.syncCallCount == 0)
    #expect(deltas.joined() == "Hello")
    #expect(finalText == "Hello")
    let lines = readJSONL(root, sessionId: "s-stream-structured-deltas")
    #expect(lines.count == 2)
    #expect(lines[1]["content"] as? String == "Hello")
}

@Test
func chatClient_streaming_claude_models_use_text_streaming_compatibility_path() async throws {
    let root = try makeTempRoot("stream-claude-compat")
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["compat ", "reply"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        turnTraceBus: bus,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    var deltas: [String] = []
    var finalText: String?
    for try await event in client.chatStream(
        message: "hello", sessionId: "s-stream-claude-compat",
        model: "claude-opus-4-8", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .final(let r): finalText = r.reply
        case .toolUse, .toolResult, .error, .notice: break
        }
    }

    #expect(stream.callCount == 1)
    #expect(stream.lastModel == "claude-opus-4-8")
    #expect(llm.callCount == 0)
    #expect(deltas == ["compat reply"])
    #expect(finalText == "compat reply")
    #expect(stream.lastSystem?.contains("NativeAgent Swift tool protocol") == true)

    let lines = readJSONL(root, sessionId: "s-stream-claude-compat")
    #expect(lines.count == 2)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["content"] as? String == "compat reply")

    var terminal: TurnTraceEvent?
    for _ in 0..<100 {
        let events = try await TurnTraceRecentReader(dataRootOverride: root).read().events
        terminal = events.last { $0.kind == "turn.terminal" }
        if terminal != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let terminalEvent = try #require(terminal)
    guard case .object(let payload) = terminalEvent.payload else {
        Issue.record("text compatibility terminal payload was not an object")
        return
    }
    #expect(payload["schema"] == .string("metacognition.observed.v1"))
    #expect(payload["modelUsed"] == .string("claude-opus-4-8"))
    #expect(payload["reasoningEffort"] == .string("high"))
    #expect(payload["contextSource"] == .string("legacy"))
    #expect(payload["toolDispatchCount"] == .int(0))
    #expect(payload["toolSchemaCount"] != nil)
}

@Test
func chatClient_textCompatibilityRendersBoundedEnumValuesInToolSignature() async throws {
    let root = try makeTempRoot("stream-claude-enum-signature")
    let schema = LLMToolSchema(
        name: "workshop_submit",
        description: "Submit Workshop work.",
        parametersJSON: Data(#"{"type":"object","properties":{"procedure":{"type":"string","enum":["local_file_copy_v1"]},"text":{"type":"string"}},"required":["text"]}"#.utf8)
    )
    let tools = SchemaBackedToolDispatch(schemas: [schema], scripted: [:])
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use"])
    let stream = MockStreamingLLMClient(chunks: ["done"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    for try await _ in client.chatStream(
        message: "copy a workspace file",
        sessionId: "s-stream-claude-enum-signature",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {}

    #expect(
        stream.lastSystem?.contains(
            "workshop_submit(procedure=local_file_copy_v1, text*)"
        ) == true
    )
}

@Test
func chatClient_telegram_claude_uses_text_streaming_compatibility_path() async throws {
    let root = try makeTempRoot("telegram-claude-compat")
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["telegram ", "reply"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    let response = try await client.chat(
        message: "hello",
        sessionId: "s-telegram-claude-compat",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: "Agent",
        surface: "telegram",
        suppressUserAppend: false,
        progress: nil
    )

    #expect(stream.callCount == 1)
    #expect(stream.lastModel == "claude-opus-4-8")
    #expect(llm.callCount == 0)
    #expect(response.output == "telegram reply")
    #expect(response.sessionId == "s-telegram-claude-compat")
    #expect(stream.lastSystem?.contains("NativeAgent Swift tool protocol") == true)

    let lines = readJSONL(root, sessionId: "s-telegram-claude-compat")
    #expect(lines.count == 2)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[0]["source"] as? String == "telegram")
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["source"] as? String == "telegram")
    #expect(lines[1]["content"] as? String == "telegram reply")
    let sessions = readChatSessions(root)
    let session = try #require(sessions.first(where: { $0["id"] as? String == "s-telegram-claude-compat" }))
    #expect(session["source"] as? String == "telegram")
}

@Test
func chatClient_telegram_claude_compatibility_dispatches_text_tool_markers() async throws {
    let root = try makeTempRoot("telegram-claude-compat-tools")
    // This test asserts the DISPATCH PLUMBING (text tool markers -> dispatcher),
    // not autonomy gating - pin git_log to auto in the hermetic policy so the
    // dispatch isn't gated by default-policy semantics (it previously passed
    // only off the user's LIVE policy.json, the exact leak W-F removes).
    try writeTrustPolicy(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read recent git commits through the Swift dispatcher.",
        parametersJSON: Data(#"{"type":"object","properties":{"cwd":{"type":"string"},"limit":{"type":"integer"}},"required":[]}"#.utf8)
    )
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: [
            "git_log": .object([
                "status": .string("ok"),
                "commits": .array([.string("abc1234 Fix chat loop")]),
            ]),
        ]
    )
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let stream = ScriptedTextStreamingLLM(chunksByCall: [
        [#"<tool_use name="git_log">{"limit":30}</tool_use>"#],
        ["Recent commits include abc1234 Fix chat loop."],
    ])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer
    )
    let progress = ToolProgressCapture()

    let response = try await client.chat(
        message: "look at commits",
        sessionId: "s-telegram-claude-compat-tools",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: "Agent",
        surface: "telegram",
        suppressUserAppend: false,
        progress: { event in await progress.record(event) }
    )

    #expect(stream.callCount == 2)
    #expect(stream.lastModel == "claude-opus-4-8")
    #expect(llm.callCount == 0)
    #expect(tools.dispatches.count == 1)
    #expect(tools.dispatches.first?.tool == "git_log")
    #expect(tools.dispatches.first?.surface == "telegram")
    #expect(await progress.uses() == ["git_log"])
    #expect(await progress.results() == ["git_log"])
    #expect(response.output == "Recent commits include abc1234 Fix chat loop.")
    let firstSystem = try #require(stream.systems.first ?? nil)
    #expect(firstSystem.contains("NativeAgent Swift tool protocol"))
    #expect(firstSystem.contains("git_log"))

    let lines = readJSONL(root, sessionId: "s-telegram-claude-compat-tools")
    #expect(lines.count == 3)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[0]["source"] as? String == "telegram")
    #expect(lines[1]["role"] as? String == "tool")
    #expect(lines[1]["source"] as? String == "telegram")
    let toolMetadata = try #require(lines[1]["metadata"] as? [String: Any])
    #expect(toolMetadata["toolName"] as? String == "git_log")
    #expect(lines[2]["role"] as? String == "assistant")
    #expect(lines[2]["source"] as? String == "telegram")
    #expect(lines[2]["content"] as? String == "Recent commits include abc1234 Fix chat loop.")
    #expect((lines[2]["content"] as? String)?.contains("<tool_use") == false)
    let cognitive = await observer.all()
    #expect(cognitive.map(\.kind).contains(.toolStarted))
    #expect(cognitive.map(\.kind).contains(.toolSucceeded))
    #expect(cognitive.first { $0.kind == .toolStarted }?.metadata["surface"] == .string("telegram"))
}

@Test
func chatClient_textCompatibilityBoundsLargeProviderPayloadButKeepsTurnRecoveryHandle() async throws {
    let root = try makeTempRoot("text-compat-result-recovery")
    try writeTrustPolicy(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read recent git information.",
        parametersJSON: Data(#"{"type":"object","properties":{},"required":[]}"#.utf8)
    )
    let fullPayload = "BEGIN|" + String(repeating: "0123456789abcdef", count: 8_000) + "|END"
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: ["git_log": .object(["payload": .string(fullPayload)])]
    )
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let stream = ScriptedTextStreamingLLM(chunksByCall: [
        [#"<tool_use name="git_log">{}</tool_use>"#],
        ["done after bounded recovery"],
    ])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    let response = try await client.chat(
        message: "inspect the large result",
        sessionId: "s-text-compat-result-recovery",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: "Agent",
        surface: "telegram",
        suppressUserAppend: false
    )

    #expect(response.output == "done after bounded recovery")
    #expect(stream.callCount == 2)
    let secondPrompt = try #require(stream.prompts.last)
    #expect(secondPrompt.contains("provider_projection"))
    #expect(secondPrompt.contains("bounded_tool_result"))
    #expect(secondPrompt.contains("result_handle"))
    #expect(secondPrompt.contains("full_result_retained"))
    #expect(!secondPrompt.contains(fullPayload))
    #expect(secondPrompt.count < 80_000)
}

@Test
func chatClient_textCompatibilityStopsOnlyAfterSixteenExactNoProgressRounds() async throws {
    let root = try makeTempRoot("text-compat-no-progress")
    try writeTrustPolicy(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read a stable status.",
        parametersJSON: Data(#"{"type":"object","properties":{},"required":[]}"#.utf8)
    )
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: ["git_log": .string("unchanged")]
    )
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let stream = ScriptedTextStreamingLLM(chunksByCall: [[
        #"<tool_use name="git_log">{}</tool_use>"#,
    ]])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 20
    )

    let response = try await client.chat(
        message: "check until there is progress",
        sessionId: "s-text-compat-no-progress",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: "Agent",
        surface: "telegram",
        suppressUserAppend: false
    )

    #expect(response.output.contains("stopped the tool loop after sixteen identical rounds"))
    #expect(response.output.contains("No tool capability was disabled"))
    #expect(stream.callCount == 16)
    #expect(tools.dispatches.count == 16)
}

@Test
func chatClient_telegram_claude_compatibility_ignores_placeholder_tool_marker() async throws {
    let root = try makeTempRoot("telegram-claude-placeholder-tool")
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read recent git commits through the Swift dispatcher.",
        parametersJSON: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
    )
    let tools = SchemaBackedToolDispatch(schemas: [schema], scripted: ["git_log": .string("unused")])
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let stream = ScriptedTextStreamingLLM(chunksByCall: [[
        "I already have enough from the prior result.\n<tool_use name=\"...\">{}</tool_use>",
    ]])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let progress = ToolProgressCapture()

    let response = try await client.chat(
        message: "what did the tool result say?",
        sessionId: "s-telegram-claude-placeholder-tool",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: "Agent",
        surface: "telegram",
        suppressUserAppend: false,
        progress: { event in await progress.record(event) }
    )

    #expect(stream.callCount == 1)
    #expect(llm.callCount == 0)
    #expect(tools.dispatches.isEmpty)
    #expect(await progress.uses().isEmpty)
    #expect(await progress.results().isEmpty)
    #expect(response.output == "I already have enough from the prior result.")
    #expect(!response.output.contains("<tool_use"))
    #expect(!response.output.contains("..."))

    let lines = readJSONL(root, sessionId: "s-telegram-claude-placeholder-tool")
    #expect(lines.count == 2)
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["content"] as? String == "I already have enough from the prior result.")
}

@Test
func chatClient_telegram_active_anthropic_provider_uses_text_streaming_compatibility_path() async throws {
    let root = try makeTempRoot("telegram-active-anthropic-compat")
    try await SwiftNativePersistenceCore().writeJSON(
        .object(["telegram": .string("anthropic_oauth_direct")]),
        to: root
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("active.json")
    )
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["active ", "reply"])
    let engine = makeEngine(
        root: root,
        llm: llm,
        tools: tools,
        router: StubRoutingForClient(
            prefs: [
                "chat": SurfacePreference(
                    surface: "chat", model: "gpt-5.5", reasoningEffort: "high"
                ),
                "telegram": SurfacePreference(
                    surface: "telegram", model: "claude-opus-4-8", reasoningEffort: "high"
                ),
            ],
            active: ["telegram": "anthropic_oauth_direct"]
        )
    )
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    let response = try await client.chat(
        message: "hello",
        sessionId: "s-telegram-active-anthropic-compat",
        model: "gpt-5.5",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: "Agent",
        surface: "telegram",
        suppressUserAppend: false,
        progress: nil
    )

    #expect(stream.callCount == 1)
    #expect(llm.callCount == 0)
    #expect(response.output == "active reply")
    #expect(response.sessionId == "s-telegram-active-anthropic-compat")
    #expect(response.model == "claude-opus-4-8")
    #expect(response.requestedModel == "gpt-5.5")

    let lines = readJSONL(root, sessionId: "s-telegram-active-anthropic-compat")
    #expect(lines.count == 2)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["content"] as? String == "active reply")
}

@Test
func chatClient_ios_claude_streaming_uses_text_streaming_compatibility_path() async throws {
    let root = try makeTempRoot("ios-claude-compat")
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["ios ", "reply"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    var deltas: [String] = []
    var finalText: String?
    for try await event in client.chatStream(
        message: "hello",
        sessionId: "s-ios-claude-compat",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: "Agent",
        surface: "ios",
        suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .final(let r): finalText = r.reply
        case .toolUse, .toolResult, .error, .notice: break
        }
    }

    #expect(stream.callCount == 1)
    #expect(stream.lastModel == "claude-opus-4-8")
    #expect(llm.callCount == 0)
    #expect(deltas == ["ios reply"])
    #expect(finalText == "ios reply")
    #expect(stream.lastSystem?.contains("NativeAgent Swift tool protocol") == true)

    let lines = readJSONL(root, sessionId: "s-ios-claude-compat")
    #expect(lines.count == 2)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[0]["source"] as? String == "ios")
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["source"] as? String == "ios")
    #expect(lines[1]["content"] as? String == "ios reply")
}

@Test(arguments: [false, true])
func chatClient_nonStreamingPersistsToolReceiptsWithOrWithoutProgress(progressEnabled: Bool) async throws {
    let root = try makeTempRoot("nonstream-tool-receipts")
    defer { try? FileManager.default.removeItem(at: root) }
    // These are the real public-caller shapes: bridge chat without a callback,
    // and Telegram chat with one. Both use the same structured execution path.
    let surface = progressEnabled ? "telegram" : "chat"
    let session = "s-nonstream-tool-receipts"
    let schema = LLMToolSchema(
        name: "tool_catalog", description: "Inert fixture tool",
        parametersJSON: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8))
    let toolCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"tool_catalog","arguments":"{}"}}]}"#
    let llm = ToolSchemaCapturingLLM(scriptedResponses: [toolCall, "The fixture is queued, not completed."])
    // Use an always-available inert tool to isolate receipt plumbing from lazy
    // activation and real bridge dispatch. Its scripted output models queued work.
    let tools = SchemaBackedToolDispatch(schemas: [schema], scripted: [
        "tool_catalog": .object(["status": .string("queued"), "messageId": .string("fixture-message")]),
    ])
    let router = StubRoutingForClient(prefs: [
        surface: SurfacePreference(surface: surface, model: "client-model", reasoningEffort: "high"),
    ])
    let engine = makeEngine(root: root, llm: llm, tools: tools, router: router)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root), toolLoopMaxIterations: 4)
    let captured = ToolProgressCapture()
    let captureProgress: ChatOrchestrationProgressHandler = { event in await captured.record(event) }
    let progress: ChatOrchestrationProgressHandler? = progressEnabled ? captureProgress : nil

    let response = try await client.chat(
        message: "Use the fixture tool.", sessionId: session, model: "client-model",
        reasoningEffort: "high", fileAccess: "workspace", attachments: [], persona: nil,
        surface: surface, suppressUserAppend: false, progress: progress)

    #expect(response.output == "The fixture is queued, not completed.")
    #expect(tools.dispatches.count == 1)
    let rows = readJSONL(root, sessionId: session)
    #expect(rows.compactMap { $0["role"] as? String } == ["user", "tool", "assistant"])
    let receipt = try #require(rows.first { $0["role"] as? String == "tool" })
    let final = try #require(rows.last)
    let runID = try #require(receipt["runId"] as? String)
    #expect(!runID.isEmpty)
    #expect(final["runId"] as? String == runID)
    #expect(receipt["source"] as? String == (progressEnabled ? "telegram" : "app"))
    let metadata = try #require(receipt["metadata"] as? [String: Any])
    #expect(metadata["kind"] as? String == ChatTranscriptToolMessageKind.toolUse)
    #expect(metadata["ok"] as? Bool == true)
    #expect(metadata["resultClass"] as? String == ChatToolOutcome.ExactResultClass.unknown.rawValue)
    #expect((metadata["resultSummary"] as? String)?.contains("queued") == true)
    #expect(await captured.uses() == (progressEnabled ? ["tool_catalog"] : []))
    #expect(await captured.results() == (progressEnabled ? ["tool_catalog"] : []))
}

@Test
func chatClient_streaming_passes_tool_schemas_dispatches_and_persists_tool_rows() async throws {
    let root = try makeTempRoot("stream-structured-tools")
    let schemaJSON = Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
    let schema = LLMToolSchema(
        name: "tool_catalog",
        description: "List available tools",
        parametersJSON: schemaJSON
    )
    let toolCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"tool_catalog","arguments":"{}"}}]}"#
    let llm = ToolSchemaCapturingLLM(scriptedResponses: [toolCall, "final answer after tool"])
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: ["tool_catalog": .object(["ok": .bool(true), "count": .int(1)])]
    )
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 4,
        cognitiveObserver: observer
    )

    var finalText: String?
    var toolUseCount = 0
    var toolResultCount = 0
    for try await event in client.chatStream(
        message: "what tools do you have", sessionId: "s-stream-structured-tools",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .toolUse(let name, _):
            toolUseCount += 1
            #expect(name == "tool_catalog")
        case .toolResult(let name, _):
            toolResultCount += 1
            #expect(name == "tool_catalog")
        case .final(let r): finalText = r.reply
        case .delta, .error, .notice: break
        }
    }

    #expect(stream.callCount == 0)
    #expect(llm.callCount == 2)
    #expect(llm.toolNamesByCall == [["tool_catalog"], ["tool_catalog"]])
    #expect(tools.dispatches.map(\.tool) == ["tool_catalog"])
    #expect(toolUseCount == 1)
    #expect(toolResultCount == 1)
    #expect(finalText == "final answer after tool")

    let lines = readJSONL(root, sessionId: "s-stream-structured-tools")
    #expect(lines.count == 3)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[1]["role"] as? String == "tool")
    #expect(lines[2]["role"] as? String == "assistant")
    let metadata = lines[1]["metadata"] as? [String: Any]
    #expect(metadata?["toolName"] as? String == "tool_catalog")
    #expect(metadata?["ok"] as? Bool == true)
    let resultSummary = metadata?["resultSummary"] as? String ?? ""
    #expect(resultSummary.contains("\"count\""))
    #expect(resultSummary.contains("1"))
    #expect(lines[2]["content"] as? String == "final answer after tool")

    let cognitive = await observer.all()
    #expect(cognitive.map(\.kind).contains(.toolStarted))
    #expect(cognitive.map(\.kind).contains(.toolSucceeded))
    let started = try #require(cognitive.first { $0.kind == .toolStarted })
    #expect(started.subject.id == "tool_catalog")
    #expect(started.summary.contains("tool_catalog started"))
}

@Test
func chatClient_streaming_redacts_tool_inputs_and_results_before_progress_and_persistence() async throws {
    let root = try makeTempRoot("stream-tool-redaction")
    let apiKey = "sk-" + String(repeating: "A", count: 24)
    let bearer = "Bearer " + String(repeating: "b", count: 24)
    let argsData = try JSONSerialization.data(withJSONObject: ["api_key": apiKey])
    let argsString = String(decoding: argsData, as: UTF8.self)
    let toolCallData = try JSONSerialization.data(withJSONObject: [
        "tool_calls": [[
            "id": "c1",
            "type": "function",
            "function": [
                "name": "tool_catalog",
                "arguments": argsString,
            ],
        ]],
    ])
    let toolCall = String(decoding: toolCallData, as: UTF8.self)
    let schema = LLMToolSchema(
        name: "tool_catalog",
        description: "List available tools",
        parametersJSON: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
    )
    let llm = ToolSchemaCapturingLLM(scriptedResponses: [toolCall, "final answer after redacted tool"])
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: [
            "tool_catalog": .object([
                "ok": .bool(true),
                "token": .string(bearer),
                "key": .string(apiKey),
            ]),
        ]
    )
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 4,
        cognitiveObserver: observer
    )

    let progressPayloads = StringCapture()
    for try await event in client.chatStream(
        message: "use a tool",
        sessionId: "s-stream-tool-redaction",
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {
        switch event {
        case .toolUse(_, let input), .toolResult(_, let input):
            await progressPayloads.append((try? input.serialize(pretty: false)) ?? "")
        case .error(let message):
            await progressPayloads.append(message)
        default:
            break
        }
    }

    let progressJoined = await progressPayloads.all().joined(separator: "\n")
    #expect(!progressJoined.contains(apiKey))
    #expect(!progressJoined.contains(bearer))
    #expect(progressJoined.contains("[REDACTED_OPENAI_KEY]"))
    #expect(progressJoined.contains("[REDACTED_NAMED_SECRET]"))

    let lines = readJSONL(root, sessionId: "s-stream-tool-redaction")
    #expect(lines.count == 3)
    let persisted = String(describing: lines[1])
    #expect(!persisted.contains(apiKey))
    #expect(!persisted.contains(bearer))
    #expect(persisted.contains("[REDACTED_OPENAI_KEY]"))
    #expect(persisted.contains("[REDACTED_NAMED_SECRET]"))

    let cognitiveEvents = await observer.all()
    let cognitiveJoined: String = cognitiveEvents
        .map { event -> String in
            let metadata = (try? JSONValue.object(event.metadata).serialize(pretty: false)) ?? ""
            return "\(event.summary)\n\(metadata)"
        }
        .joined(separator: "\n")
    #expect(!cognitiveJoined.contains(apiKey))
    #expect(!cognitiveJoined.contains(bearer))
    #expect(cognitiveJoined.contains("[REDACTED_OPENAI_KEY]"))
    #expect(cognitiveJoined.contains("[REDACTED_NAMED_SECRET]"))
}

@Test
func chatClient_streaming_structured_tool_call_dispatches_without_marker_delta() async throws {
    let root = try makeTempRoot("stream-tool-events")
    let schema = LLMToolSchema(
        name: "tool_catalog",
        description: "List available tools",
        parametersJSON: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
    )
    let llm = StructuredStreamingScriptLLM(scriptedEvents: [
        [
            .textDelta("Checking tools."),
            .toolCall(LLMStreamToolCall(
                id: "call_1",
                name: "tool_catalog",
                inputJSON: Data("{}".utf8)
            )),
        ],
        [.textDelta("I can see the tool catalog now.")],
    ])
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: ["tool_catalog": .object(["ok": .bool(true), "count": .int(1)])]
    )
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 4
    )

    var deltas: [String] = []
    var finalText: String?
    var toolUseCount = 0
    for try await event in client.chatStream(
        message: "what tools do you have", sessionId: "s-stream-tool-events",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .toolUse(let name, _):
            toolUseCount += 1
            #expect(name == "tool_catalog")
        case .final(let r): finalText = r.reply
        case .toolResult, .error, .notice: break
        }
    }

    #expect(stream.callCount == 0)
    #expect(llm.streamCallCount == 2)
    #expect(llm.syncCallCount == 0)
    #expect(llm.toolNamesByCall == [["tool_catalog"], ["tool_catalog"]])
    #expect(tools.dispatches.map(\.tool) == ["tool_catalog"])
    #expect(toolUseCount == 1)
    #expect(deltas.joined() == "Checking tools.I can see the tool catalog now.")
    #expect(!deltas.joined().contains("<tool_use"))
    // Transcript fidelity (2026-07-31): the persisted assistant row is the
    // SAME bytes the surface rendered — pre-tool narration included. These two
    // assertions used to read "I can see the tool catalog now.", which pinned
    // the defect: "Checking tools." was streamed, then dropped on reload.
    #expect(finalText == "Checking tools.I can see the tool catalog now.")
    #expect(finalText == deltas.joined())

    let lines = readJSONL(root, sessionId: "s-stream-tool-events")
    #expect(lines.count == 3)
    #expect(lines[1]["role"] as? String == "tool")
    #expect(lines[2]["content"] as? String == "Checking tools.I can see the tool catalog now.")
}

@Test
func chatClient_streaming_structured_placeholder_tool_call_is_ignored() async throws {
    let root = try makeTempRoot("stream-placeholder-tool")
    let schema = LLMToolSchema(
        name: "tool_catalog",
        description: "List available tools",
        parametersJSON: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
    )
    let llm = StructuredStreamingScriptLLM(scriptedEvents: [[
        .textDelta("I have enough context now."),
        .toolCall(LLMStreamToolCall(
            id: "call_placeholder",
            name: "...",
            inputJSON: Data("{}".utf8)
        )),
    ]])
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: ["tool_catalog": .object(["ok": .bool(true)])]
    )
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 4
    )

    var deltas: [String] = []
    var finalText: String?
    var toolUseCount = 0
    for try await event in client.chatStream(
        message: "do you need anything else?", sessionId: "s-stream-placeholder-tool",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .toolUse:
            toolUseCount += 1
        case .final(let r): finalText = r.reply
        case .toolResult, .error, .notice: break
        }
    }

    #expect(stream.callCount == 0)
    #expect(llm.streamCallCount == 1)
    #expect(llm.syncCallCount == 0)
    #expect(tools.dispatches.isEmpty)
    #expect(toolUseCount == 0)
    #expect(deltas.joined() == "I have enough context now.")
    #expect(finalText == "I have enough context now.")

    let lines = readJSONL(root, sessionId: "s-stream-placeholder-tool")
    #expect(lines.count == 2)
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["content"] as? String == "I have enough context now.")
}

@Test
func chatClient_streaming_tool_loop_can_run_past_six_iterations() async throws {
    let root = try makeTempRoot("stream-tools-past-six")
    let toolScripts = (0..<7).map { idx in
        #"{"tool_calls":[{"id":"c\#(idx)","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    }
    let llm = MockLLMClient(scriptedResponses: toolScripts + ["streaming done"])
    let tools = MockToolDispatchClient(scripted: ["echo": .string("ok")])
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        toolLoopMaxIterations: 8
    )

    var finalText: String?
    var toolUseCount = 0
    var toolResultCount = 0
    for try await event in client.chatStream(
        message: "use tools", sessionId: "s-stream-tools",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .toolUse: toolUseCount += 1
        case .toolResult: toolResultCount += 1
        case .final(let r): finalText = r.reply
        case .delta, .error, .notice: break
        }
    }

    #expect(stream.callCount == 0)
    #expect(llm.callCount == 8)
    #expect(toolUseCount == 7)
    #expect(toolResultCount == 7)
    #expect(finalText == "streaming done")
    let lines = readJSONL(root, sessionId: "s-stream-tools")
    #expect(lines.filter { $0["role"] as? String == "tool" }.count == 7)
    #expect(lines.last?["content"] as? String == "streaming done")
}

@Test
func chatClient_streaming_structured_llm_error_persists_assistant_error_turn() async throws {
    let root = try makeTempRoot("structured-error")
    let llm = ThrowingStructuredLLM()
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["should-not-use"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        streamingLLM: stream, history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    var deltas: [String] = []
    var sawError = false
    for try await event in client.chatStream(
        message: "go", sessionId: "s-cancel",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        switch event {
        case .delta(let s): deltas.append(s)
        case .error: sawError = true
        case .final, .toolUse, .toolResult, .notice: break
        }
    }
    #expect(stream.callCount == 0)
    #expect(deltas.isEmpty)
    #expect(sawError)
    let lines = readJSONL(root, sessionId: "s-cancel")
    #expect(lines.count == 2)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[1]["role"] as? String == "assistant")
    #expect((lines[1]["content"] as? String)?.hasPrefix("Chat error:") == true)
    let sessions = readChatSessions(root)
    let session = try #require(sessions.first(where: { $0["id"] as? String == "s-cancel" }))
    #expect(session["messageCount"] as? Int == 2)
    #expect((session["lastMessagePreview"] as? String)?.hasPrefix("Chat error:") == true)
}

@Test
func chatClient_telegram_structured_llm_error_does_not_persist_assistant_error_turn() async throws {
    let root = try makeTempRoot("telegram-structured-error")
    let llm = ThrowingStructuredLLM()
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    do {
        _ = try await client.chat(
            message: "go",
            sessionId: "s-telegram-error",
            model: "client-model",
            reasoningEffort: "high",
            fileAccess: "workspace",
            attachments: [],
            persona: "Agent",
            surface: "telegram",
            suppressUserAppend: false,
            progress: nil
        )
        Issue.record("expected chat failure")
    } catch {
        // Expected: Telegram poll loop owns the user-facing retry/error notice.
    }
    let lines = readJSONL(root, sessionId: "s-telegram-error")
    #expect(lines.count == 1)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[0]["content"] as? String == "go")
    let sessions = readChatSessions(root)
    let session = try #require(sessions.first(where: { $0["id"] as? String == "s-telegram-error" }))
    #expect(session["messageCount"] as? Int == 1)
    #expect(session["lastMessagePreview"] as? String == "go")
}

@Test
func factory_convenience_overload_chatStream_uses_structured_path_without_stream_nil_guard() async throws {
    // The runtime-only convenience factory used to expose a streaming nil-guard
    // failure. chatStream now uses the structured tool loop, so the app chat
    // path must run past any text-stream client dependency.
    //
    // Any OTHER error (notConfigured / network / persist) is fine here; those
    // prove execution flowed into the structured provider path.
    let client = makeChatOrchestrationClient()
    #expect(client is SwiftNativeChatOrchestrationClient)

    var sawNilGuard = false
    var sawAnyEvent = false
    do {
        for try await event in client.chatStream(
            message: "hello", sessionId: nil, model: "", reasoningEffort: "",
            fileAccess: "workspace", attachments: [], suppressUserAppend: true
        ) {
            sawAnyEvent = true
            if case .error(let msg) = event,
               msg.contains("no streaming LLM client wired") {
                sawNilGuard = true
            }
        }
    } catch {
        // Throwing is fine — proves we ran past the nil-guard.
    }
    #expect(sawAnyEvent)
    #expect(!sawNilGuard, "auto-constructed factory should wire a streamingLLM")
}

private actor StringCapture {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func all() -> [String] {
        values
    }
}

private actor ToolProgressCapture {
    private var toolUses: [String] = []
    private var toolResults: [String] = []

    func record(_ event: TurnStreamEvent) {
        switch event {
        case .toolUse(let name, _):
            toolUses.append(name)
        case .toolResult(let name, _):
            toolResults.append(name)
        default:
            break
        }
    }

    func uses() -> [String] {
        toolUses
    }

    func results() -> [String] {
        toolResults
    }
}

private final class ThrowingStructuredLLM: LLMClient, @unchecked Sendable {
    struct Boom: Error {}

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw Boom()
    }

    func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        throw Boom()
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        throw Boom()
    }
}

private func readChatSessions(_ root: URL) -> [[String: Any]] {
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions.json")
    guard let data = try? Data(contentsOf: path),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    return parsed
}

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

@Test func cognitiveRuntimeContextCanCarryOrganismPostureWithoutCapsule() throws {
    let posture = OrganismBehaviorPosture(
        generatedAt: Date(timeIntervalSince1970: 7_000),
        enabled: true,
        posture: "careful",
        claimDiscipline: .verifyBeforeCompletion,
        toolStrategy: .verifyBeforeRetry,
        directives: ["After provider or tool brittleness, verify before saying the work is done."]
    )
    let rendered = try #require(SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
        runId: "run-1",
        sessionId: "session-1",
        surface: "telegram",
        fileAccess: "read_only",
        capsule: nil,
        posture: posture
    ))

    #expect(rendered.contains("[OrganismBehavior]"))
    #expect(rendered.contains("tool_claims: verifyBeforeCompletion"))
    #expect(rendered.contains("verify before saying the work is done"))
    #expect(!rendered.contains("[CognitiveSubstrate]"))
}

@Test
func chatClient_optionalCognitiveObserverReceivesBoundedRedactedEvents() async throws {
    let root = try makeTempRoot("cognitive-observer")
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let observer = CognitiveEventCapture()
    let fixedDate = Date(timeIntervalSince1970: 1_234)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer,
        clock: { fixedDate }
    )

    try await client.appendMessage(
        sessionId: "s-cognition",
        role: "user",
        content: "ask the scheduler doctor, then use sk-abcdefghijklmnopqrstuvwxyz123456 carefully",
        runId: "run-1",
        attachments: []
    )
    try await client.appendToolMessage(
        sessionId: "s-cognition",
        runId: "run-1",
        toolName: "read_file",
        inputJSON: #"{"path":"/tmp/a"}"#,
        resultSummary: "OPENAI_API_KEY=abcdefghijklmnopqrstuvwxyz",
        ok: false
    )

    let events = await observer.all()
    #expect(events.map(\.kind) == [.userMessageReceived, .toolFailed])
    // Audit C2 (2026-07-09): user turns carry PER-TURN subjects now — the old
    // per-session subject collapsed every user turn onto one positively-ratcheting
    // node, defeating the felt sting path in production.
    #expect(events.first?.subject.type == "chat.user_turn")
    #expect(events.first?.turnKind == .live)
    #expect(events.first?.occurredAt == fixedDate)
    #expect(events.first?.summary.count ?? 0 <= 500)
    #expect(events.first?.summary.contains("sk-" + "abcdefghijklmnopqrstuvwxyz123456") == false)
    #expect(events.first?.summary.contains("[REDACTED_OPENAI_KEY]") == true)
    #expect(events.last?.subject.id == "read_file")
    #expect(events.last?.metadata["trustRisk"] == .string("low"))
    #expect(events.last?.summary.contains("OPENAI_API_KEY=abcdefghijklmnopqrstuvwxyz") == false)
    #expect(events.last?.summary.contains("[REDACTED_NAMED_SECRET]") == true)
}

@Test
func canonicalMotorToolProgressDoesNotCreateAnUnmatchedGenericStart() async throws {
    let root = try makeTempRoot("canonical-motor-progress")
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer
    )

    await client.observeCognitiveProgressEvent(
        sessionId: "s-motor-progress",
        runId: "run-1",
        surface: "chat",
        event: .toolUse(name: "workshop_submit", input: .object([:])),
        toolResultAlreadyPersisted: false
    )
    await client.observeCognitiveProgressEvent(
        sessionId: "s-motor-progress",
        runId: "run-1",
        surface: "chat",
        event: .toolUse(name: "read_file", input: .object(["path": .string("README.md")])),
        toolResultAlreadyPersisted: false
    )

    let starts = await observer.all().filter { $0.kind == .toolStarted }
    #expect(starts.map(\.subject.id) == ["read_file"])
}

@Test
func canonicalMotorToolProgressPreservesOwnerlessFailureButDefersOwnedTerminal() async throws {
    let root = try makeTempRoot("canonical-motor-ownerless-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer
    )

    await client.observeCognitiveProgressEvent(
        sessionId: "s-motor-ownerless-failure",
        runId: "run-1",
        surface: "chat",
        event: .toolResult(
            name: "workshop_submit",
            output: .object(["status": .string("failed"), "reason": .string("policy denied")])
        ),
        toolResultAlreadyPersisted: false
    )
    await client.observeCognitiveProgressEvent(
        sessionId: "s-motor-ownerless-failure",
        runId: "run-1",
        surface: "chat",
        event: .toolResult(
            name: "workshop_submit",
            output: .object(["status": .string("failed"), "id": .string("workshop-1")])
        ),
        toolResultAlreadyPersisted: false
    )

    let events = await observer.all()
    #expect(events.map(\.kind) == [.toolFailed])
    #expect(events.first?.subject.id == "workshop_submit")
}

@Test
func providerLifecycleObserverOwnsProviderFailurePhysiologyWithoutProgressDuplicate() async throws {
    let root = try makeTempRoot("provider-lifecycle-cognition-owner")
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let observed = CognitiveEventCapture()
    let fallback = CognitiveEventCapture()
    let observedClient = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observed,
        providerLifecycleObserverInstalled: true
    )
    let fallbackClient = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: fallback
    )

    for client in [observedClient, fallbackClient] {
        await client.observeCognitiveProgressEvent(
            sessionId: "s-provider-owner",
            runId: "run-1",
            surface: "chat",
            event: .error("provider transport failed"),
            toolResultAlreadyPersisted: false
        )
    }

    #expect(await observed.all().isEmpty)
    #expect(await fallback.all().map(\.kind) == [.providerFailure])
}

@Test
func providerLifecycleObserverOwnsPersistedFailurePhysiologyWithoutDroppingCognitiveEvidence() async throws {
    let root = try makeTempRoot("provider-lifecycle-persisted-owner")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let observed = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observed,
        providerLifecycleObserverInstalled: true
    )

    try await client.appendFailureMessageIfNeeded(
        sessionId: "s-provider-persisted-owner",
        runId: "run-1",
        errorMessage: "provider transport failed",
        persona: nil
    )

    let event = try #require(await observed.all().first)
    #expect(event.kind == .providerFailure)
    #expect(event.metadata[CognitiveSomaticSignalAdapter.somaticOwnerMetadataKey] == .string(
        CognitiveSomaticSignalAdapter.providerLifecycleSomaticOwner
    ))
    #expect(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "33000000-0000-0000-0000-000000000005")!
    ) == nil)

    let transcript = root
        .appendingPathComponent("chat/messages", isDirectory: true)
        .appendingPathComponent("s-provider-persisted-owner.jsonl")
    let persisted = try String(contentsOf: transcript, encoding: .utf8)
    #expect(persisted.contains("Chat error: provider transport failed"))
}

@Test
func chatClient_cognitiveToolOutcomes_require_exact_nonmotor_terminal_evidence() async throws {
    let root = try makeTempRoot("cognitive-tool-truth")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer
    )

    try await client.appendToolMessage(
        sessionId: "s-cognitive-truth", runId: "run-1",
        toolName: "slack_post_message", inputJSON: "{}",
        resultSummary: #"{"status":"pending_approval"}"#,
        ok: true, cognitiveResult: .unknown
    )
    try await client.appendToolMessage(
        sessionId: "s-cognitive-truth", runId: "run-1",
        toolName: "workshop_submit", inputJSON: "{}",
        resultSummary: #"{"status":"completed"}"#,
        ok: true, cognitiveResult: .unknown
    )
    try await client.appendToolMessage(
        sessionId: "s-cognitive-truth", runId: "run-1",
        toolName: "read_file", inputJSON: "{}",
        resultSummary: #"{"status":"completed"}"#,
        ok: true, cognitiveResult: .succeeded
    )
    try await client.appendToolMessage(
        sessionId: "s-cognitive-truth", runId: "run-1",
        toolName: "shell", inputJSON: "{}",
        resultSummary: #"{"status":"failed"}"#,
        ok: false, cognitiveResult: .failed
    )

    let events = await observer.all()
    #expect(events.map(\.kind) == [.toolSucceeded, .toolFailed])
    #expect(events.map(\.subject.id) == ["read_file", "shell"])
}

/// Mind-into-circulation (2026-07-10): the assistant turn's recalled MemoryV2
/// record ids ride the cognitive event as `memoryRecordIds` metadata — the
/// convention `attentionSignals(at:)` reads to feed felt-memory activation
/// back into Fluid Context. User turns never carry the stamp (they didn't use
/// the recalls); ids are deduped and ordered so the node metadata is stable.
@Test
func appendMessage_stampsRecalledMemoryIdsOnAssistantEventsOnly() async throws {
    let root = try makeTempRoot("recall-stamp")
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer
    )

    try await client.appendMessage(
        sessionId: "s-recall",
        role: "user",
        content: "what did we decide about the garden?",
        runId: "run-r",
        attachments: [],
        recalledMemoryIds: ["mem-should-not-stamp"]
    )
    try await client.appendMessage(
        sessionId: "s-recall",
        role: "assistant",
        content: "We decided raised beds on the south side.",
        runId: "run-r",
        attachments: [],
        recalledMemoryIds: ["mem-b", "mem-a", "mem-b"]
    )

    let events = await observer.all()
    #expect(events.count == 2)
    #expect(events.first?.metadata["memoryRecordIds"] == nil,
            "user turns never carry the recall stamp")
    let stamped = try #require(events.last?.metadata["memoryRecordIds"])
    #expect(stamped == .array([.string("mem-a"), .string("mem-b")]),
            "assistant stamp is deduped + sorted: \(stamped)")
}

@Test
func appendToolMessage_persistsBoundedReceiptInsteadOfFullToolPayload() async throws {
    let root = try makeTempRoot("bounded-tool-receipt")
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    try await client.appendToolMessage(
        sessionId: "s-bounded-tool",
        runId: "run-1",
        toolName: "tool_catalog",
        inputJSON: String(repeating: "i", count: 3_950)
            + " OPENAI_API_KEY=abcdefghijklmnopqrstuvwxyz "
            + String(repeating: "i", count: 6_000),
        resultSummary: String(repeating: "r", count: 20_000),
        ok: true
    )

    let path = root
        .appendingPathComponent("chat/messages", isDirectory: true)
        .appendingPathComponent("s-bounded-tool.jsonl")
    let data = try Data(contentsOf: path)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let metadata = try #require(object["metadata"] as? [String: Any])
    let storedInput = try #require(metadata["inputJSON"] as? String)
    let storedResult = try #require(metadata["resultSummary"] as? String)

    #expect(storedInput.count < 4_100)
    #expect(storedResult.count < 8_100)
    #expect(storedInput.contains("tool input truncated in transcript"))
    #expect(storedResult.contains("tool result truncated in transcript"))
    #expect(storedInput.contains("[REDACTED_NAMED_SECRET]"))
    #expect(!storedInput.contains("OPENAI_API_KEY=abcdefghijklmnopqrstuvwxyz"))
    #expect(!storedInput.hasSuffix("iiii"))
    #expect(!storedResult.hasSuffix("rrrr"))
}

@Test
func appendMessage_rejectsMalformedSessionIndexBeforeCreatingTranscript() async throws {
    let root = try makeTempRoot("session-index-fail-closed")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionsPath = root.appendingPathComponent("chat/sessions.json")
    try FileManager.default.createDirectory(
        at: sessionsPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let malformed = Data(#"[{"id":"keep-me"},null]"#.utf8)
    try malformed.write(to: sessionsPath)
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let client = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    await #expect(throws: ChatSessionIndexFileError.self) {
        try await client.appendMessage(
            sessionId: "new-session",
            role: "user",
            content: "must not create an orphan",
            runId: nil,
            attachments: []
        )
    }

    #expect(try Data(contentsOf: sessionsPath) == malformed)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("chat/messages/new-session.jsonl").path
    ))
}

@Test
func chatClient_assistantCognitiveEventsUseTurnScopedSubject() async throws {
    let root = try makeTempRoot("cognitive-assistant-subject")
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let observer = CognitiveEventCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: observer
    )

    try await client.appendMessage(
        sessionId: "s-cognition",
        role: "assistant",
        content: String(repeating: "x", count: 640),
        runId: "run-1",
        attachments: []
    )

    let events = await observer.all()
    let event = try #require(events.first)
    #expect(event.kind == .assistantTurnCompleted)
    #expect(event.subject.type == "chat.assistant_turn")
    #expect(event.subject.id.hasPrefix("s-cognition:"))
    #expect(event.metadata["role"] == .string("assistant"))
    #expect(event.summary.count == 500)
    #expect(event.metadata[CognitiveSubstrate.replyCharacterCountMetadataKey] == .int(640))
    #expect(event.sourceClass == .selfReported)
}

@Test
func chatClient_injectedCognitiveRuntimeAddsCapsule() async throws {
    let root = try makeTempRoot("cognitive-runtime")
    let llm = MessageCapturingLLM(reply: "I will check the result next.")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let cognition = CognitiveRuntimeCapture(capsuleText: "- Focus: active test focus")
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition
    )

    let response = try await client.chat(
        message: "hello",
        sessionId: "s-cognition-runtime",
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(response.output == "I will check the result next.")
    let system = try #require(llm.capturedSystems.compactMap { $0 }.first)
    #expect(system.contains("[CognitiveSubstrate]"))
    // The one functional handling line rides the injection seam (not the
    // capsule kernel) — on BOTH paths; this is the structured one.
    #expect(system.contains("she never quotes or mentions it"))
    #expect(system.contains("active test focus"))
}

@Test
func chatClient_usesOneCombinedCognitiveProjectionAndCommitsAfterInjection() async throws {
    let root = try makeTempRoot("combined-cognitive-runtime")
    let llm = MessageCapturingLLM(reply: "combined")
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let cognition = CombinedCognitiveTurnProjectionCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition
    )

    _ = try await client.chat(
        message: "use the coherent read",
        sessionId: "s-combined-cognition",
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    let counts = await cognition.counts()
    #expect(counts.projection == 1)
    #expect(counts.fallbackCapsule == 0)
    #expect(counts.commit == 1)
    let system = try #require(llm.capturedSystems.compactMap { $0 }.first)
    #expect(system.contains("one coherent turn projection"))
    #expect(system.contains("tool_claims: verifyBeforeCompletion"))
}

@Test
func chatClient_overlapsResidentProjectionWithContextWithoutChangingProviderInputs() async throws {
    let root = try makeTempRoot("resident-preparation-overlap")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = TurnPreparationOverlapProbe()
    let llm = MessageCapturingLLM(reply: "overlapped")
    let schema = LLMToolSchema(
        name: "mcp__preparation_probe__read",
        description: "Read the preparation overlap probe.",
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
    let tools = SchemaBackedToolDispatch(
        schemas: [schema],
        scripted: [:],
        beforeSchemaList: {
            await probe.rendezvous(.context)
        }
    )
    let cognition = CombinedCognitiveTurnProjectionCapture(preparationProbe: probe)
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition
    )

    let response = try await client.chat(
        message: "keep every resident input",
        sessionId: "s-resident-preparation-overlap",
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(response.output == "overlapped")
    #expect(await probe.didOverlap(), "context and cognition must enter concurrently")
    #expect(llm.capturedModels.first == "client-model")
    let system = try #require(llm.capturedSystems.compactMap { $0 }.first)
    #expect(system.contains("one coherent turn projection"))
    #expect(llm.capturedToolNames.first == ["mcp_preparation_probe_read"])
    let counts = await cognition.counts()
    #expect(counts.projection == 1)
    #expect(counts.fallbackCapsule == 0)
    #expect(counts.commit == 1)
}

/// Wave-2 review fix (2026-07-01): the one-line capsule handling seam moved out
/// of the kernel and must ride BOTH injection paths. This pins the TEXT-COMPAT
/// path (the primary one for Anthropic models) — the structured path is pinned
/// in chatClient_injectedCognitiveRuntimeAddsCapsule.
@Test
func chatClient_textCompatibilityCapsuleCarriesHandlingSeamLine() async throws {
    let root = try makeTempRoot("cognitive-textcompat-seam")
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["unused-structured"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["seam reply"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let cognition = CognitiveRuntimeCapture(capsuleText: "- Focus: seam test focus")
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition
    )

    var finalText: String?
    for try await event in client.chatStream(
        message: "hello there",
        sessionId: "s-textcompat-seam",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {
        if case .final(let result) = event {
            finalText = result.reply
        }
    }

    #expect(finalText == "seam reply")
    let system = try #require(stream.lastSystem)
    #expect(system.contains("[CognitiveSubstrate]"))
    #expect(system.contains("she never quotes or mentions it"))
    #expect(system.contains("seam test focus"))
}

@Test
func chatClient_textCompatibilityUsesCombinedCognitiveProjection() async throws {
    let root = try makeTempRoot("combined-cognitive-textcompat")
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["unused-structured"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["combined stream"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let cognition = CombinedCognitiveTurnProjectionCapture()
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition
    )

    for try await _ in client.chatStream(
        message: "use the coherent streaming read",
        sessionId: "s-combined-textcompat",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {}

    let counts = await cognition.counts()
    #expect(counts.projection == 1)
    #expect(counts.fallbackCapsule == 0)
    #expect(counts.commit == 1)
    let system = try #require(stream.lastSystem)
    #expect(system.contains("one coherent turn projection"))
    #expect(system.contains("tool_claims: verifyBeforeCompletion"))
}

private actor CognitiveRuntimeCapture: CognitiveRuntimeProviding {
    private var events: [CognitiveEvent] = []
    private let capsuleText: String

    init(capsuleText: String) {
        self.capsuleText = capsuleText
    }

    func observe(_ event: CognitiveEvent) async {
        events.append(event)
    }

    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? {
        guard request.mode == .inject else { return nil }
        return CognitiveCapsule(
            generatedAt: Date(timeIntervalSince1970: 1_234),
            mode: .inject,
            stableKernel: "Private working state. Use lightly; do not quote.",
            dynamicContext: capsuleText,
            provenanceNodeIds: [],
            truncated: false
        )
    }

    func allEvents() -> [CognitiveEvent] {
        events
    }
}

private actor CombinedCognitiveTurnProjectionCapture: CognitiveRuntimeProviding {
    private var events: [CognitiveEvent] = []
    private var projectionCalls = 0
    private var compatibilityCapsuleCalls = 0
    private var commitCalls = 0
    private let preparationProbe: TurnPreparationOverlapProbe?

    init(preparationProbe: TurnPreparationOverlapProbe? = nil) {
        self.preparationProbe = preparationProbe
    }

    func observe(_ event: CognitiveEvent) async {
        events.append(event)
    }

    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? {
        compatibilityCapsuleCalls += 1
        return nil
    }

    func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitiveTurnProjection {
        projectionCalls += 1
        if let preparationProbe {
            await preparationProbe.rendezvous(.cognition)
        }
        let fixedAt = Date(timeIntervalSince1970: 8_000)
        return CognitiveTurnProjection(
            fixedAt: fixedAt,
            capsule: CognitiveCapsule(
                generatedAt: fixedAt,
                mode: .inject,
                stableKernel: "How you feel:",
                dynamicContext: "- Focus: one coherent turn projection",
                provenanceNodeIds: [],
                truncated: false
            ),
            posture: OrganismBehaviorPosture(
                generatedAt: fixedAt,
                enabled: true,
                posture: "careful",
                claimDiscipline: .verifyBeforeCompletion,
                toolStrategy: .preferKnownPath,
                directives: ["Use the already verified path first."]
            )
        )
    }

    func commitTurnProjection(
        _ projection: CognitiveTurnProjection,
        request: CognitiveCapsuleRequest
    ) async {
        commitCalls += 1
    }

    func counts() -> (projection: Int, fallbackCapsule: Int, commit: Int) {
        (projectionCalls, compatibilityCapsuleCalls, commitCalls)
    }
}

private actor TurnPreparationOverlapProbe {
    enum Lane: Sendable {
        case context
        case cognition
    }

    private var arrived: Set<String> = []
    private var overlapped = false

    /// Both fixture lanes wait for their peer before returning. A serialized
    /// implementation therefore fails `didOverlap` after the bounded wait;
    /// suite-level scheduler contention cannot create a false failure.
    func rendezvous(_ lane: Lane) async {
        arrived.insert(lane == .context ? "context" : "cognition")
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while arrived.count < 2, DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if arrived.count == 2 { overlapped = true }
    }

    func didOverlap() -> Bool {
        overlapped
    }
}

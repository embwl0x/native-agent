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
func chatClient_non_streaming_no_tools_returns_response_and_persists() async throws {
    let root = try makeTempRoot("plain")
    let llm = MockLLMClient(scriptedResponses: ["hello from the model"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(
        root: root,
        llm: llm,
        tools: tools,
        router: StubRoutingForClient(
            prefs: ["chat": SurfacePreference(
                surface: "chat", model: "client-model", reasoningEffort: "high"
            )],
            active: ["chat": "openai_oauth_direct"]
        )
    )
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let resp = try await client.chat(
        message: "hi there", sessionId: "s-plain",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(resp.output == "hello from the model")
    #expect(resp.sessionId == "s-plain")
    #expect(resp.model == "client-model")
    let lines = readJSONL(root, sessionId: "s-plain")
    #expect(lines.count == 2)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["content"] as? String == "hello from the model")
    let outcome = try #require((lines[1]["metadata"] as? [String: Any])?["outcomeObservation"] as? [String: Any])
    #expect(outcome["schema"] as? String == "response.outcome-observation.v2")
    #expect(outcome["messageID"] as? String == lines[1]["id"] as? String)
    #expect(outcome["sessionID"] as? String == "s-plain")
    #expect(outcome["responsePersistence"] as? String == "persisted")
    #expect(outcome["providerID"] as? String == "openai_oauth_direct")
    let evidence = try #require(outcome["dimensionStates"] as? [String: String])
    #expect(evidence["provider"] == "observed")
    let serializedOutcome = try JSONSerialization.data(withJSONObject: outcome)
    let outcomeText = String(decoding: serializedOutcome, as: UTF8.self)
    #expect(!outcomeText.contains("hello from the model"))

    let admitted = try await durableAssistantOutcome(root: root, sessionID: "s-plain")
    #expect(admitted.observation.dimensionStates == [
        "responsePersistence": .observed,
        "context": .censored,
        "provider": .observed,
        "tools": .notApplicable,
        "motor": .notApplicable,
        "reaction": .unknown,
    ])

    // A real accepted turn with no checked/inferred provider still persists a
    // response, but must call that provider evidence unknown rather than
    // inferring transport from successful model prose.
    let missingLLM = MockLLMClient(scriptedResponses: ["reply without a provider route"])
    let missingTools = MockToolDispatchClient()
    let missingModel = "opaque-eval-model-with-no-provider"
    let missingEngine = makeEngine(
        root: root,
        llm: missingLLM,
        tools: missingTools,
        router: StubRoutingForClient(prefs: [
            "chat": SurfacePreference(
                surface: "chat", model: missingModel, reasoningEffort: "medium"
            ),
        ])
    )
    let missingClient = SwiftNativeChatOrchestrationClient(
        engine: missingEngine, tools: missingTools, llm: missingLLM,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    _ = try await missingClient.chat(
        message: "provider route unavailable", sessionId: "s-missing-provider",
        model: missingModel, reasoningEffort: "medium",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    let missing = try await durableAssistantOutcome(
        root: root,
        sessionID: "s-missing-provider"
    )
    #expect(missing.observation.providerID == nil)
    #expect(missing.observation.dimensionStates == [
        "responsePersistence": .observed,
        "context": .censored,
        "provider": .unknown,
        "tools": .notApplicable,
        "motor": .notApplicable,
        "reaction": .unknown,
    ])

    // A durable next user row immediately following the exact assistant anchor
    // promotes reaction PRESENCE only. Its prose is not classified as praise,
    // criticism, or quality evidence.
    _ = try await client.enqueueUserMessage(
        message: "continue from that answer",
        sessionId: "s-plain",
        persona: nil,
        surface: "chat"
    )

    // Simulate history written before continuation receipts shipped. Exact
    // transcript adjacency remains enough to observe reaction PRESENCE on the
    // read side; no sentiment or quality is inferred from the user's prose.
    try FileManager.default.removeItem(
        at: root.appendingPathComponent("context/feedback.jsonl")
    )

    // Population health keeps absent observations separate from state counts,
    // and names a permanently-dark nonterminal lane instead of presenting it
    // as measured zero evidence.
    try writeChatMessagesJSONL(
        root: root,
        sessionId: "s-legacy-without-outcome",
        rows: [[
            "id": .string("legacy-assistant"),
            "sessionId": .string("s-legacy-without-outcome"),
            "role": .string("assistant"),
            "content": .string("legacy durable reply"),
            "createdAt": .string("2026-08-24T00:00:00Z"),
        ]]
    )
    let audit = try await OutcomeDimensionStatePopulationReader(dataRoot: root).read()
    #expect(audit.totalRows == 3)
    #expect(audit.absentObservations == 1)
    #expect(audit.distributions["provider"]?[.observed] == 1)
    #expect(audit.distributions["provider"]?[.unknown] == 1)
    #expect(audit.distributions["reaction"]?[.observed] == 1)
    #expect(audit.distributions["reaction"]?[.unknown] == 1)
    #expect(!audit.permanentlyNonterminalDimensions.contains("reaction"))
    #expect(audit.permanentlyNonterminalDimensions.contains("context"))
    #expect(!audit.permanentlyNonterminalDimensions.contains("provider"))
    #expect(!audit.rankedLeads.contains(where: { $0.hasPrefix("reaction:") }))
    #expect(audit.rankedLeads.first?.contains("outcome observation absent") == true)

    // A row derived from the real persisted assistant bytes but missing one of
    // the six closed dimensions is corrupt, not a five-dimensional success.
    guard case .object(var corruptRow)? = missing.message.extras,
          case .object(var corruptMetadata)? = corruptRow["metadata"],
          case .object(var corruptOutcome) = missing.value,
          case .object(var corruptStates)? = corruptOutcome["dimensionStates"] else {
        Issue.record("could not prepare durable corrupt outcome fixture")
        return
    }
    corruptStates.removeValue(forKey: "reaction")
    corruptOutcome["dimensionStates"] = .object(corruptStates)
    corruptMetadata["outcomeObservation"] = .object(corruptOutcome)
    corruptRow["metadata"] = .object(corruptMetadata)
    let corruptRoot = try makeTempRoot("plain-corrupt-outcome")
    defer { try? FileManager.default.removeItem(at: corruptRoot) }
    try writeChatMessagesJSONL(
        root: corruptRoot,
        sessionId: "s-corrupt-outcome",
        rows: [corruptRow]
    )
    let corruptMessages = try await SessionHistoryReader(dataRoot: corruptRoot)
        .messages(forSessionId: "s-corrupt-outcome")
    let corruptAssistant = try #require(corruptMessages.first)
    guard case .object(let reloadedCorruptRow)? = corruptAssistant.extras,
          case .object(let reloadedCorruptMetadata)? = reloadedCorruptRow["metadata"],
          let reloadedCorruptOutcome = reloadedCorruptMetadata["outcomeObservation"] else {
        Issue.record("corrupt durable row did not reload")
        return
    }
    #expect(ResponseOutcomeObservationV2(jsonValue: reloadedCorruptOutcome) == nil)
}

// Ack-on-enqueue seam (wake-delivery-classification, 2026-07-25): the enqueue
// puts the user row durably on disk BEFORE any turn runs, and the later turn
// with suppressUserAppend produces the exact transcript the normal path
// yields — so a transport can ack at append time without changing what the
// engine sees.
@Test
func enqueueUserMessage_appends_durably_then_suppressed_turn_matches_normal_shape() async throws {
    let root = try makeTempRoot("enqueue-ack")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = MockLLMClient(scriptedResponses: ["reply after enqueue"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    let enqueued = try await client.enqueueUserMessage(
        message: "[from: claude, via bridge] long work order",
        sessionId: "s-enqueue",
        persona: nil,
        surface: "chat"
    )
    #expect(enqueued.sessionId == "s-enqueue")
    // Durable BEFORE any turn: exactly one user row on disk.
    let afterEnqueue = readJSONL(root, sessionId: "s-enqueue")
    #expect(afterEnqueue.count == 1)
    #expect(afterEnqueue[0]["role"] as? String == "user")
    #expect(afterEnqueue[0]["content"] as? String == "[from: claude, via bridge] long work order")

    let resp = try await client.chat(
        message: "[from: claude, via bridge] long work order",
        sessionId: enqueued.sessionId,
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [],
        persona: nil, surface: "chat",
        suppressUserAppend: true
    )
    #expect(resp.output == "reply after enqueue")
    // Same final transcript shape as the normal (append-inside-turn) path:
    // one user row, one assistant row — never a doubled user append.
    let lines = readJSONL(root, sessionId: "s-enqueue")
    #expect(lines.count == 2)
    #expect(lines[0]["role"] as? String == "user")
    #expect(lines[1]["role"] as? String == "assistant")
    #expect(lines[1]["content"] as? String == "reply after enqueue")
}

// An empty message must be rejected BEFORE anything lands on disk — an
// enqueue ack for a message that can never run a turn would be a lie.
@Test
func enqueueUserMessage_rejects_empty_message_without_touching_disk() async throws {
    let root = try makeTempRoot("enqueue-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = MockLLMClient(scriptedResponses: [])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    await #expect(throws: (any Error).self) {
        _ = try await client.enqueueUserMessage(
            message: "   \n", sessionId: "s-empty", persona: nil, surface: "chat"
        )
    }
    #expect(readJSONL(root, sessionId: "s-empty").isEmpty)
}

// Ledger row `chat.persistence.resolveSessionId`. The resolver is the one
// filename/index boundary for every durable chat row. A missing identity used
// to mint an invisible UUID here, producing an orphan transcript; malformed
// identities already failed, but nothing proved all failure classes leave the
// store untouched or that a normalized valid ID lands on one stable file.
@Test
func resolveSessionId_requiresAnExplicitSafeIdentity_andPersistenceUsesItsStableNormalizedForm() async throws {
    let root = try makeTempRoot("resolve-session-id")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = MockLLMClient(scriptedResponses: [])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    func expectRejected(_ sessionID: String?, _ expected: ChatOrchestrationError) {
        do {
            _ = try SwiftNativeChatOrchestrationClient.resolveSessionId(sessionID)
            Issue.record("expected session id \(String(describing: sessionID)) to be rejected")
        } catch let error as ChatOrchestrationError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // Nil is distinct from malformed input: it means the caller lost the
    // conversation identity and must not be silently assigned a new one.
    expectRejected(nil, .underlying("missing chat session id"))
    for invalid in ["", " \n\t ", "../escape", "chat/messages", "chat\\messages", ".hidden", "a..b", "bad\u{0000}id"] {
        expectRejected(invalid, .underlying("invalid chat session id"))
    }

    let rawID = " \n telegram:12345 \t "
    let normalized = try SwiftNativeChatOrchestrationClient.resolveSessionId(rawID)
    #expect(normalized == "telegram:12345")
    #expect(
        try SwiftNativeChatOrchestrationClient.resolveSessionId(rawID) == normalized,
        "normalization must be stable across retries so a reload cannot split the transcript"
    )

    // Exercise the real append/index transaction, not a path helper: the raw
    // input must become one canonical transcript and sessions.json identity.
    let enqueued = try await client.enqueueUserMessage(
        message: "retain this in the canonical session",
        sessionId: rawID,
        persona: nil,
        surface: "chat"
    )
    #expect(enqueued.sessionId == normalized)
    let messageDirectory = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    let transcript = messageDirectory.appendingPathComponent("\(normalized).jsonl")
    #expect(FileManager.default.fileExists(atPath: transcript.path))
    #expect(!FileManager.default.fileExists(atPath: messageDirectory.appendingPathComponent(rawID + ".jsonl").path))
    #expect(readJSONL(root, sessionId: normalized).map { $0["content"] as? String } == ["retain this in the canonical session"])

    let sessionsPath = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions.json")
    let indexBefore = try Data(contentsOf: sessionsPath)
    let indexRows = try JSONSerialization.jsonObject(with: indexBefore) as? [[String: Any]] ?? []
    #expect(indexRows.map { $0["id"] as? String }.contains(normalized))

    // The next mounted caller threads the retained canonical identity back to
    // the same persistence boundary. It appends to this conversation rather
    // than creating an orphan transcript/index row.
    let repeated = try await client.enqueueUserMessage(
        message: "append through the retained session",
        sessionId: enqueued.sessionId,
        persona: nil,
        surface: "chat"
    )
    #expect(repeated.sessionId == normalized)
    #expect(
        readJSONL(root, sessionId: normalized).map { $0["content"] as? String }
            == ["retain this in the canonical session", "append through the retained session"]
    )
    let indexAfterRepeat = try Data(contentsOf: sessionsPath)
    let repeatRows = try JSONSerialization.jsonObject(with: indexAfterRepeat) as? [[String: Any]] ?? []
    #expect(repeatRows.filter { $0["id"] as? String == normalized }.count == 1)

    // Every adverse input fails before either the transcript or session index
    // is changed. This includes nil, which is the former orphaning path.
    let adverseInputs: [String?] = [nil, "", "   ", "../escape", "chat/messages", "bad\\id"]
    for invalid in adverseInputs {
        await #expect(throws: (any Error).self) {
            _ = try await client.enqueueUserMessage(
                message: "must not persist",
                sessionId: invalid,
                persona: nil,
                surface: "chat"
            )
        }
    }
    #expect(try Data(contentsOf: sessionsPath) == indexAfterRepeat)
    #expect(readJSONL(root, sessionId: normalized).count == 2)
    let files = try FileManager.default.contentsOfDirectory(
        at: messageDirectory,
        includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
    #expect(files == ["\(normalized).jsonl", "\(normalized).jsonl.lock"])
}

@Test
func codexCompletionBindingRoundTripsThroughCanonicalAssistantTranscript() async throws {
    let root = try makeTempRoot("codex-completion-binding")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = MockLLMClient(scriptedResponses: ["durable bridge answer"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let binding = CodexCompletionTranscriptBinding(
        deliveryId: "delivery-transcript",
        requestDigest: "request-transcript",
        model: "stale-shell-model",
        reasoningEffort: "low"
    )
    let response = try await ChatPersistenceContext.$codexCompletionBinding
        .withValue(binding) {
            try await client.chat(
                message: "complete once",
                sessionId: "s-codex-binding",
                model: "client-model",
                reasoningEffort: "high",
                fileAccess: "workspace",
                attachments: [],
                suppressUserAppend: false
            )
        }
    let path = root
        .appendingPathComponent("chat/messages", isDirectory: true)
        .appendingPathComponent("s-codex-binding.jsonl")
    let rows = try await SwiftNativePersistenceCore().readJSONL(path)
    let recoveredResponse = try CodexCompletionTranscriptEvidence.recoverResponse(
        from: rows,
        deliveryId: binding.deliveryId,
        requestDigest: binding.requestDigest,
        sessionId: "s-codex-binding"
    )
    let recovered = try #require(recoveredResponse)
    #expect(recovered.output == response.output)
    #expect(recovered.runId == response.runId)
    #expect(recovered.model == "client-model")
    #expect(recovered.reasoningEffort == "high")
}

@Test
func canonicalAssistantRegenerationReplacesOneRowInsideTheTranscriptLock() async throws {
    let root = try makeTempRoot("canonical-regenerate")
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    try writeChatSessionsJSON(root, sessions: [[
        "id": "s-regenerate",
        "title": "Regenerate",
        "createdAt": "2026-07-12T12:00:00Z",
        "updatedAt": "2026-07-12T12:00:00Z",
    ]])
    let client = makeClientForNoticeTests(root: root, turnTraceBus: bus)
    try await client.appendMessage(
        sessionId: "s-regenerate",
        role: "user",
        content: "question",
        runId: "run-user",
        attachments: []
    )
    try await TurnTraceContext.$turnId.withValue("turn-old") {
        try await client.appendMessage(
            sessionId: "s-regenerate",
            role: "assistant",
            content: "old answer",
            runId: "run-old",
            attachments: [],
            canonicalAssistantCompletion: true
        )
    }
    let oldRow = try #require(readJSONL(root, sessionId: "s-regenerate").last)
    let oldID = try #require(oldRow["id"] as? String)
    let oldMetadata = try #require(oldRow["metadata"] as? [String: Any])
    #expect(oldMetadata["turnTraceId"] as? String == "turn-old")
    let oldOutcome = try #require(oldMetadata["outcomeObservation"] as? [String: Any])
    #expect(oldOutcome["messageID"] as? String == oldID)
    #expect(oldOutcome["turnID"] as? String == "turn-old")

    try await TurnTraceContext.$turnId.withValue("turn-retry") {
        try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(oldID) {
            try await client.appendMessage(
                sessionId: "s-regenerate",
                role: "assistant",
                content: "new answer",
                runId: "run-new",
                attachments: [],
                canonicalAssistantCompletion: true
            )
        }
    }

    let rows = readJSONL(root, sessionId: "s-regenerate")
    #expect(rows.count == 2)
    #expect(rows.map { $0["content"] as? String } == ["question", "new answer"])
    #expect(rows.last?["runId"] as? String == "run-new")
    #expect(rows.contains { ($0["id"] as? String) == oldID } == false)
    let newMetadata = try #require(rows.last?["metadata"] as? [String: Any])
    #expect(newMetadata["turnTraceId"] as? String == "turn-retry")
    let newOutcome = try #require(newMetadata["outcomeObservation"] as? [String: Any])
    #expect(newOutcome["messageID"] as? String == rows.last?["id"] as? String)
    #expect(newOutcome["turnID"] as? String == "turn-retry")

    var reaction: TurnTraceEvent?
    for _ in 0..<100 where reaction == nil {
        if let snapshot = try? await TurnTraceRecentReader(dataRootOverride: root).read() {
            reaction = snapshot.events.last {
                $0.kind == "turn.reaction"
            }
        }
        if reaction == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    let exactReaction = try #require(reaction)
    #expect(exactReaction.turnId == "turn-retry")
    #expect(exactReaction.sessionId == "s-regenerate")
    guard case .object(let reactionPayload) = exactReaction.payload else {
        Issue.record("retry reaction payload missing")
        return
    }
    #expect(reactionPayload["schema"] == .string("metacognition.reaction.v1"))
    #expect(reactionPayload["reaction"] == .string("explicit_retry"))
    #expect(reactionPayload["targetTurnId"] == .string("turn-old"))
    #expect(reactionPayload["controlAuthority"] == .bool(false))
}

@Test
func canonicalAssistantRegenerationFailsBeforeAppendWhenTargetIsMissing() async throws {
    let root = try makeTempRoot("canonical-regenerate-missing")
    try writeChatSessionsJSON(root, sessions: [[
        "id": "s-regenerate-missing",
        "title": "Regenerate",
        "createdAt": "2026-07-12T12:00:00Z",
        "updatedAt": "2026-07-12T12:00:00Z",
    ]])
    let client = makeClientForNoticeTests(root: root)
    try await client.appendMessage(
        sessionId: "s-regenerate-missing",
        role: "assistant",
        content: "keep me",
        runId: "run-old",
        attachments: [],
        canonicalAssistantCompletion: true
    )

    await #expect(throws: ChatOrchestrationError.self) {
        try await ChatPersistenceContext.$replacementAssistantMessageID.withValue("missing-row") {
            try await client.appendMessage(
                sessionId: "s-regenerate-missing",
                role: "assistant",
                content: "must not append",
                runId: "run-new",
                attachments: [],
                canonicalAssistantCompletion: true
            )
        }
    }

    let rows = readJSONL(root, sessionId: "s-regenerate-missing")
    #expect(rows.count == 1)
    #expect(rows.first?["content"] as? String == "keep me")
    #expect(rows.first?["runId"] as? String == "run-old")
}

@Test(arguments: ["valid", "missing", "stale"])
func textCompatibilityRegenerationRequiresSuccessfulFinalPersistence(target: String) async throws {
    let root = try makeTempRoot("compat-regenerate-\(target)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = "compat-regenerate"
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["structured lane must not run"])
    let tools = MockToolDispatchClient()
    let streamer = MockStreamingLLMClient(chunks: ["Replacement answer."])
    let client = SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools),
        tools: tools, llm: llm, streamingLLM: streamer,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    try await client.appendMessage(
        sessionId: sessionID, role: "user", content: "Question", runId: "old-user", attachments: []
    )
    try await client.appendMessage(
        sessionId: sessionID, role: "assistant", content: "Original answer", runId: "old-answer",
        attachments: [], canonicalAssistantCompletion: true
    )
    let oldID = try #require(readJSONL(root, sessionId: sessionID).last?["id"] as? String)
    if target == "stale" {
        try await client.appendMessage(
            sessionId: sessionID, role: "user", content: "Newer question", runId: "newer-user", attachments: []
        )
    }
    let path = root.appendingPathComponent("chat/messages/\(sessionID).jsonl")
    let originalBytes = try Data(contentsOf: path)
    let replacementID = target == "missing" ? "missing-assistant" : oldID
    var response: ChatResponse?
    var failure: Error?
    do {
        response = try await TurnTraceContext.$turnId.withValue("compat-retry-turn") {
            try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(replacementID) {
                try await client.chat(
                    message: "Question", sessionId: sessionID, model: "claude-opus-4-8",
                    reasoningEffort: "high", fileAccess: "workspace", attachments: [],
                    persona: nil, surface: "telegram", suppressUserAppend: true, progress: nil
                )
            }
        }
    } catch { failure = error }
    #expect(streamer.callCount == 1)
    #expect(llm.callCount == 0)
    if target == "valid" {
        #expect(failure == nil)
        let savedResponse = try #require(response)
        #expect(savedResponse.output == "Replacement answer.")
        let rows = readJSONL(root, sessionId: sessionID)
        #expect(rows.count == 2)
        #expect(rows.filter { $0["role"] as? String == "assistant" }.count == 1)
        #expect(rows.last?["content"] as? String == savedResponse.output)
        #expect(rows.last?["runId"] as? String == savedResponse.runId)
        let metadata = try #require(rows.last?["metadata"] as? [String: Any])
        #expect(metadata["turnTraceId"] as? String == "compat-retry-turn")
        let outcome = try #require(metadata["outcomeObservation"] as? [String: Any])
        #expect(outcome["messageID"] as? String == rows.last?["id"] as? String)
    } else {
        #expect(response == nil)
        #expect(failure is ChatOrchestrationError)
        #expect(String(describing: failure).contains("persist assistant turn failed"))
        #expect(try Data(contentsOf: path) == originalBytes)
    }
}

@Test
func canonicalAssistantRegenerationKeepsItsOwnToolReceiptsBeforeTheReplacement() async throws {
    let root = try makeTempRoot("regenerate-with-tools")
    defer { try? FileManager.default.removeItem(at: root) }
    let schema = LLMToolSchema(
        name: "tool_catalog", description: "Inert fixture tool",
        parametersJSON: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8))
    let toolCall = #"{"tool_calls":[{"id":"retry-tool","type":"function","function":{"name":"tool_catalog","arguments":"{}"}}]}"#
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["old answer", toolCall, "new answer after tool"])
    let tools = SchemaBackedToolDispatch(schemas: [schema], scripted: [
        "tool_catalog": .object(["status": .string("queued"), "messageId": .string("fixture-message")]),
    ])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root), toolLoopMaxIterations: 4)
    let session = "s-regenerate-with-tools"
    _ = try await client.chat(
        message: "question", sessionId: session, model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false)
    let oldID = try #require(readJSONL(root, sessionId: session).last?["id"] as? String)
    let response = try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(oldID) {
        try await client.chat(
            message: "question", sessionId: session, model: "client-model", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], suppressUserAppend: true)
    }
    #expect(response.output == "new answer after tool")
    let rows = readJSONL(root, sessionId: session)
    #expect(rows.compactMap { $0["role"] as? String } == ["user", "tool", "assistant"])
    #expect(rows.contains { $0["id"] as? String == oldID } == false)
    let receipt = try #require(rows.first { $0["role"] as? String == "tool" })
    #expect(receipt["runId"] as? String == response.runId)
    #expect(rows.last?["runId"] as? String == response.runId)
    let metadata = try #require(receipt["metadata"] as? [String: Any])
    #expect(metadata["resultClass"] as? String == "unknown")
    #expect(tools.dispatches.count == 1)
}

@Test
func canonicalAssistantRegenerationPreservesItsPendingApprovalReceipt() async throws {
    let root = try makeTempRoot("regenerate-pending-receipt")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = makeClientForNoticeTests(root: root)
    let session = "s-regenerate-pending"
    try await client.appendMessage(
        sessionId: session, role: "assistant", content: "old answer", runId: "old-run",
        attachments: [], canonicalAssistantCompletion: true)
    let oldID = try #require(readJSONL(root, sessionId: session).last?["id"] as? String)
    try await client.appendToolMessage(
        sessionId: session, runId: "retry-run", toolName: "write_file", inputJSON: "{}",
        resultSummary: #"{"status":"waiting_approval","approvalId":"pending-fixture"}"#, ok: true)
    let receiptBefore = try #require(readJSONL(root, sessionId: session).last)
    try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(oldID) {
        try await client.appendMessage(
            sessionId: session, role: "assistant", content: "Waiting for approval.", runId: "retry-run",
            attachments: [], canonicalAssistantCompletion: true)
    }
    let rows = readJSONL(root, sessionId: session)
    #expect(rows.compactMap { $0["role"] as? String } == ["tool", "assistant"])
    #expect(rows.first?["id"] as? String == receiptBefore["id"] as? String)
    let metadata = try #require(rows.first?["metadata"] as? [String: Any])
    #expect(metadata["kind"] as? String == ChatTranscriptToolMessageKind.approvalPending)
    #expect(metadata["approvalId"] as? String == "pending-fixture")
}

@Test(arguments: ["foreign-run", "foreign-session", "untyped", "user", "assistant"])
func canonicalAssistantRegenerationRejectsUnrelatedTrailingRows(shape: String) async throws {
    let root = try makeTempRoot("regenerate-foreign-tail")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = makeClientForNoticeTests(root: root)
    let session = "s-regenerate-foreign"
    try await client.appendMessage(
        sessionId: session, role: "assistant", content: "old answer", runId: "old-run",
        attachments: [], canonicalAssistantCompletion: true)
    let oldID = try #require(readJSONL(root, sessionId: session).last?["id"] as? String)
    let trailer: JSONValue = .object([
        "id": .string("later-row"), "role": .string(["user", "assistant"].contains(shape) ? shape : "tool"),
        "content": .string("preserve this row"),
        "sessionId": .string(shape == "foreign-session" ? "other-session" : session),
        "runId": .string(shape == "foreign-run" ? "other-run" : "retry-run"),
        "metadata": .object([
            "kind": .string(shape == "untyped" ? "legacy" : ChatTranscriptToolMessageKind.toolUse),
            "toolName": .string("tool_catalog"),
        ]),
    ])
    let path = root.appendingPathComponent("chat/messages/\(session).jsonl")
    try await SwiftNativePersistenceCore().appendJSONL(trailer, to: path)
    let before = try Data(contentsOf: path)
    await #expect(throws: ChatOrchestrationError.self) {
        try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(oldID) {
            try await client.appendMessage(
                sessionId: session, role: "assistant", content: "must not replace", runId: "retry-run",
                attachments: [], canonicalAssistantCompletion: true)
        }
    }
    #expect(try Data(contentsOf: path) == before)
}

@Test
func canonicalAssistantRegenerationRefusesAnInteriorTargetInsideTheTranscriptLock() async throws {
    let root = try makeTempRoot("canonical-regenerate-interior")
    try writeChatSessionsJSON(root, sessions: [[
        "id": "s-regenerate-interior",
        "title": "Regenerate interior",
        "createdAt": "2026-08-19T12:00:00Z",
        "updatedAt": "2026-08-19T12:00:00Z",
    ]])
    let client = makeClientForNoticeTests(root: root)
    try await client.appendMessage(
        sessionId: "s-regenerate-interior",
        role: "assistant",
        content: "old answer",
        runId: "run-old",
        attachments: [],
        canonicalAssistantCompletion: true
    )
    let oldRows = readJSONL(root, sessionId: "s-regenerate-interior")
    let oldID = try #require(oldRows.first?["id"] as? String)
    try await client.appendMessage(
        sessionId: "s-regenerate-interior",
        role: "user",
        content: "a newer turn",
        runId: "run-new-user",
        attachments: []
    )

    await #expect(throws: ChatOrchestrationError.self) {
        try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(oldID) {
            try await client.appendMessage(
                sessionId: "s-regenerate-interior",
                role: "assistant",
                content: "must not replace history",
                runId: "run-retry",
                attachments: [],
                canonicalAssistantCompletion: true
            )
        }
    }

    let rows = readJSONL(root, sessionId: "s-regenerate-interior")
    #expect(rows.count == 2)
    #expect(rows.map { $0["content"] as? String } == ["old answer", "a newer turn"])
}

@Test
func chatSessionAutocompactor_compactsSummaryTailAndEmitsTrace() async throws {
    let root = try makeTempRoot("autocompactor-direct")
    let sessionId = "s-autocompactor-direct"
    let rows = (0..<26).map { index in
        let fillCount = index < 6 ? 8_000 : 40
        return chatMessageRow(
            role: index.isMultiple(of: 2) ? "user" : "assistant",
            content: "DIRECT-COMPACT-MSG-\(index) " + String(repeating: "x", count: fillCount),
            index: index
        )
    }
    try writeChatMessagesJSONL(root: root, sessionId: sessionId, rows: rows)

    let outcome = try await ChatSessionAutocompactor(
        dataRoot: root,
        config: ChatSessionAutocompactionConfig(thresholdTokens: 2_000, keepCount: 20)
    ).compactIfNeeded(
        sessionId: sessionId,
        model: "client-model",
        surface: "chat",
        runId: "run-autocompact"
    )

    #expect(outcome.compacted)
    #expect(outcome.messagesBefore == 26)
    #expect(outcome.messagesAfter == 21)
    #expect(outcome.messagesReplaced == 6)

    let compacted = readJSONL(root, sessionId: sessionId)
    #expect(compacted.count == 21)
    #expect(compacted.first?["role"] as? String == "system")
    #expect((compacted.first?["content"] as? String)?.contains("[NativeAgent compacted 6 earlier message(s).]") == true)
    #expect((compacted.first?["content"] as? String)?.contains("DIRECT-COMPACT-MSG-0") == true)
    #expect(compacted[1]["content"] as? String == "DIRECT-COMPACT-MSG-6 " + String(repeating: "x", count: 40))

    let traces = readTraceRows(root)
    let event = try #require(traces.first { $0["kind"] as? String == "context.compact" })
    #expect(event["status"] as? String == "ok")
    let payload = try #require(event["payload"] as? [String: Any])
    #expect(payload["schema"] as? String == "context.compact.v1")
    #expect(payload["sessionId"] as? String == sessionId)
    #expect(payload["trigger"] as? String == "auto_threshold")
    #expect(payload["thresholdTokens"] as? Int == 2_000)
    #expect(payload["messagesReplaced"] as? Int == 6)
}

@Test
func chatSessionAutocompactor_reducesTailWhenPreferredTailStaysOverThreshold() async throws {
    let root = try makeTempRoot("autocompactor-oversized-tail")
    let sessionId = "s-autocompactor-oversized-tail"
    let rows = (0..<26).map { index in
        chatMessageRow(
            role: index.isMultiple(of: 2) ? "user" : "assistant",
            content: "OVERSIZED-TAIL-MSG-\(index) " + String(repeating: "z", count: 1_000),
            index: index
        )
    }
    try writeChatMessagesJSONL(root: root, sessionId: sessionId, rows: rows)

    let outcome = try await ChatSessionAutocompactor(
        dataRoot: root,
        config: ChatSessionAutocompactionConfig(thresholdTokens: 10, keepCount: 20)
    ).compactIfNeeded(
        sessionId: sessionId,
        model: "client-model",
        surface: "chat",
        runId: "run-autocompact-oversized-tail"
    )

    #expect(outcome.compacted)
    #expect(outcome.messagesBefore == 26)
    #expect(outcome.messagesAfter == 2)
    #expect(outcome.messagesReplaced == 25)

    let compacted = readJSONL(root, sessionId: sessionId)
    #expect(compacted.count == 2)
    #expect(compacted.first?["role"] as? String == "system")
    #expect((compacted.first?["content"] as? String)?.contains("[NativeAgent compacted 25 earlier message(s).]") == true)
    #expect(compacted[1]["content"] as? String == "OVERSIZED-TAIL-MSG-25 " + String(repeating: "z", count: 1_000))
}

@Test
func chatSessionAutocompactor_foldsPriorOversizedTailWhenNewerTurnExists() async throws {
    let root = try makeTempRoot("autocompactor-prior-oversized-tail")
    let sessionId = "s-autocompactor-prior-oversized-tail"
    let rows = [
        chatMessageRow(
            role: "system",
            content: "[NativeAgent compacted 25 earlier message(s).]\nuser: old compacted context",
            index: 0
        ),
        chatMessageRow(
            role: "assistant",
            content: "PRIOR-GIANT-RAW-TURN " + String(repeating: "g", count: 2_000),
            index: 1
        ),
        chatMessageRow(
            role: "user",
            content: "newest current turn stays raw",
            index: 2
        ),
    ]
    try writeChatMessagesJSONL(root: root, sessionId: sessionId, rows: rows)

    let outcome = try await ChatSessionAutocompactor(
        dataRoot: root,
        config: ChatSessionAutocompactionConfig(thresholdTokens: 10, keepCount: 20)
    ).compactIfNeeded(
        sessionId: sessionId,
        model: "client-model",
        surface: "chat",
        runId: "run-autocompact-prior-oversized-tail"
    )

    #expect(outcome.compacted)
    #expect(outcome.messagesBefore == 3)
    #expect(outcome.messagesAfter == 2)
    #expect(outcome.messagesReplaced == 2)

    let compacted = readJSONL(root, sessionId: sessionId)
    #expect(compacted.count == 2)
    #expect(compacted.first?["role"] as? String == "system")
    #expect((compacted.first?["content"] as? String)?.contains("PRIOR-GIANT-RAW-TURN") == true)
    #expect(compacted[1]["content"] as? String == "newest current turn stays raw")
}

@Test
func chatClient_autocompactsBeforeContextAssembly() async throws {
    let root = try makeTempRoot("autocompact-client")
    let sessionId = "s-autocompact-client"
    let rows = longChatMessageRows(prefix: "CLIENT-AUTOCOMPACT-MSG", fill: "y")
    try writeChatMessagesJSONL(root: root, sessionId: sessionId, rows: rows)
    let llm = MockLLMClient(scriptedResponses: ["post-compact reply"])
    let tools = MockToolDispatchClient()
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        autocompactionConfig: ChatSessionAutocompactionConfig(thresholdTokens: 2_000, keepCount: 20, distillEnabled: false)
    )

    let response = try await client.chat(
        message: "current user turn",
        sessionId: sessionId,
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(response.output == "post-compact reply")
    let compacted = readJSONL(root, sessionId: sessionId)
    #expect(compacted.count == 22)
    #expect(compacted.first?["role"] as? String == "system")
    #expect((compacted.first?["content"] as? String)?.contains("[NativeAgent compacted 6 earlier message(s).]") == true)
    #expect(compacted[20]["content"] as? String == "current user turn")
    #expect(compacted[21]["content"] as? String == "post-compact reply")
    #expect(readTraceRows(root).contains { $0["kind"] as? String == "context.compact" })
}

@Test
func chatClient_structuredStreamingAutocompactsBeforeContextAssembly() async throws {
    let root = try makeTempRoot("autocompact-structured-stream")
    let sessionId = "s-autocompact-structured-stream"
    try writeChatMessagesJSONL(
        root: root,
        sessionId: sessionId,
        rows: longChatMessageRows(prefix: "STREAM-AUTOCOMPACT-MSG", fill: "s")
    )
    let llm = StructuredStreamingScriptLLM(scriptedEvents: [[
        .textDelta("stream compact reply"),
    ]])
    let tools = MockToolDispatchClient()
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
        autocompactionConfig: ChatSessionAutocompactionConfig(thresholdTokens: 2_000, keepCount: 20, distillEnabled: false)
    )

    var finalText: String?
    for try await event in client.chatStream(
        message: "current streaming user turn",
        sessionId: sessionId,
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {
        if case .final(let result) = event {
            finalText = result.reply
        }
    }

    #expect(finalText == "stream compact reply")
    #expect(stream.callCount == 0)
    #expect(llm.streamCallCount == 1)
    let compacted = readJSONL(root, sessionId: sessionId)
    #expect(compacted.count == 22)
    #expect(compacted.first?["role"] as? String == "system")
    #expect((compacted.first?["content"] as? String)?.contains("[NativeAgent compacted 6 earlier message(s).]") == true)
    #expect(compacted[20]["content"] as? String == "current streaming user turn")
    #expect(compacted[21]["content"] as? String == "stream compact reply")
    #expect(readTraceRows(root).contains { $0["kind"] as? String == "context.compact" })
}

@Test
func chatClient_textCompatibilityAutocompactsBeforeContextAssembly() async throws {
    let root = try makeTempRoot("autocompact-text-compat")
    let sessionId = "s-autocompact-text-compat"
    try writeChatMessagesJSONL(
        root: root,
        sessionId: sessionId,
        rows: longChatMessageRows(prefix: "TEXTCOMPAT-AUTOCOMPACT-MSG", fill: "t")
    )
    let llm = ToolSchemaCapturingLLM(scriptedResponses: ["should-not-use-structured-tools"])
    let tools = MockToolDispatchClient()
    let stream = MockStreamingLLMClient(chunks: ["compat compact reply"])
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: stream,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        autocompactionConfig: ChatSessionAutocompactionConfig(thresholdTokens: 2_000, keepCount: 20, distillEnabled: false)
    )

    var finalText: String?
    for try await event in client.chatStream(
        message: "current textcompat user turn",
        sessionId: sessionId,
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

    #expect(finalText == "compat compact reply")
    #expect(stream.callCount == 1)
    #expect(llm.callCount == 0)
    let compacted = readJSONL(root, sessionId: sessionId)
    #expect(compacted.count == 22)
    #expect(compacted.first?["role"] as? String == "system")
    #expect((compacted.first?["content"] as? String)?.contains("[NativeAgent compacted 6 earlier message(s).]") == true)
    #expect(compacted[20]["content"] as? String == "current textcompat user turn")
    #expect(compacted[21]["content"] as? String == "compat compact reply")
    #expect(readTraceRows(root).contains { $0["kind"] as? String == "context.compact" })
}

private func durableAssistantOutcome(
    root: URL,
    sessionID: String
) async throws -> (message: ChatMessage, value: JSONValue, observation: ResponseOutcomeObservationV2) {
    let messages = try await SessionHistoryReader(dataRoot: root).messages(forSessionId: sessionID)
    let assistant = try #require(messages.last { $0.role == "assistant" })
    guard case .object(let row)? = assistant.extras,
          case .object(let metadata)? = row["metadata"],
          let value = metadata["outcomeObservation"],
          let observation = ResponseOutcomeObservationV2(jsonValue: value) else {
        Issue.record("durable assistant outcome did not pass the canonical decoder")
        throw CocoaError(.coderReadCorrupt)
    }
    return (assistant, value, observation)
}

private func writeChatMessagesJSONL(root: URL, sessionId: String, rows: [[String: JSONValue]]) throws {
    let dir = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(sessionId).jsonl")
    var payload = Data()
    for row in rows {
        payload.append(Data((try JSONValue.object(row).serialize(pretty: false)).utf8))
        payload.append(0x0A)
    }
    try payload.write(to: path, options: .atomic)
}

private func longChatMessageRows(
    prefix: String,
    count: Int = 25,
    fill: String
) -> [[String: JSONValue]] {
    (0..<count).map { index in
        let fillCount = index < 6 ? 8_000 : 40
        return chatMessageRow(
            role: index.isMultiple(of: 2) ? "user" : "assistant",
            content: "\(prefix)-\(index) " + String(repeating: fill, count: fillCount),
            index: index
        )
    }
}

private func chatMessageRow(
    role: String,
    content: String,
    index: Int,
    runId: String? = nil
) -> [String: JSONValue] {
    var row: [String: JSONValue] = [
        "id": .string("msg-\(index)"),
        "sessionId": .string("s"),
        "role": .string(role),
        "content": .string(content),
        "createdAt": .string("2026-06-24T12:00:\(String(format: "%02d", index % 60))Z"),
    ]
    if let runId {
        row["runId"] = .string(runId)
    }
    return row
}

private func readTraceRows(_ root: URL) -> [[String: Any]] {
    let path = root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

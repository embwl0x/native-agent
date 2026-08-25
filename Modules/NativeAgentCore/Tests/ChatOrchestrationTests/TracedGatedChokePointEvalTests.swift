import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter

// MARK: - evals-total-coverage · fence core.chat.engine
//
// Ledger rows closed here:
//   * chat.dispatch.tracedGatedChokePoint (UNCOVERED    → COVERED)
//   * chat.telemetry.turnAccepted         (REPORTS-ONLY → COVERED)
//
// makeTracedGatedDispatcher's own doc-comment calls it "CHOKE POINT for chat
// tool dispatch … so the ChatToolDispatchTracer wrapper sees EVERY dispatch
// exactly once", and NOTHING enforced it. A loop that composes its own
// AutonomyGatedDispatcher — trivial, the pieces are public — loses tool.dispatch
// rows for that whole lane, so SYS-10's per-tool outcome table under-reports
// without any number going red. ORDER matters too: the tracer sits OUTERMOST so
// gate DENIALS are traced; invert the wrapping and every refusal stops being
// recorded while every success still is.
//
// `turn.accepted` is the instrument's per-surface TURN COUNTER and these three
// call sites are its only emitters in the repo. A lane that stops emitting it
// reports as FEWER TURNS, never as an error — the exact shape that makes "she
// felt slower this week" unmeasurable.
//
// All three PRODUCTION lanes are driven end to end through
// SwiftNativeChatOrchestrationClient on a hermetic dataRoot.

// MARK: - hermetic root

private func chokePointRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chokepoint-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A trust policy that AUTO-allows one tool and hard-BLOCKS another, so one
/// turn produces both a successful dispatch and a gate denial.
private func writeGateSplitPolicy(_ root: URL, allowed: String, blocked: String) throws {
    let dir = root.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let policy: [String: Any] = [
        "permissionLevel": "workspace",
        "toolAutonomy": [
            allowed: "auto",
            blocked: "blocked",
            "default": "auto",
        ],
    ]
    try JSONSerialization.data(withJSONObject: policy)
        .write(to: dir.appendingPathComponent("policy.json"))
}

private func writeOAuthFixtureForCompat(_ root: URL) throws {
    let dir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["access_token": "tok-chokepoint"])
        .write(to: dir.appendingPathComponent("anthropic_oauth_direct.json"))
}

private func toolDispatchRows(_ root: URL) -> [[String: JSONValue]] {
    let path = root.appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard case .object(let object)? = try? JSONValue.parse(Data(line.utf8)),
              object["kind"] == .string("tool.dispatch") else { return nil }
        return object
    }
}

private func rowTitle(_ row: [String: JSONValue]) -> String {
    if case .string(let title)? = row["title"] { return title }
    return ""
}

private func rowStatus(_ row: [String: JSONValue]) -> String {
    if case .string(let status)? = row["status"] { return status }
    return ""
}

// MARK: - scripted wiring

private let allowedTool = "recall_memory"   // always-on core, policy: auto
private let blockedTool = "time_now"        // always-on core, policy: blocked

private func openAIBatchJSON(_ names: [(id: String, name: String)]) -> String {
    let calls = names.map {
        #"{"id":"\#($0.id)","type":"function","function":{"name":"\#($0.name)","arguments":"{}"}}"#
    }.joined(separator: ",")
    return #"{"tool_calls":[\#(calls)]}"#
}

private final class ChokePointTools: ToolDispatchClient, @unchecked Sendable {
    nonisolated(unsafe) private(set) var dispatched: [String] = []
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        dispatched.append(tool)
        return .object(["ok": .bool(true), "tool": .string(tool)])
    }
    func listAvailableTools() async throws -> [String] { [allowedTool, blockedTool] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [allowedTool, blockedTool].map {
            LLMToolSchema(
                name: $0,
                description: "test tool \($0)",
                parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
            )
        }
    }
}

private final class ChokePointLLM: LLMClient, @unchecked Sendable {
    private let scripted: [String]
    nonisolated(unsafe) private var index = 0
    init(scripted: [String]) { self.scripted = scripted }
    func complete(prompt: String, system: String?, model: String?) async throws -> String { next() }
    func completeMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) async throws -> String { next() }
    func streamMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let reply = next()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.finish()
        }
    }
    private func next() -> String {
        guard !scripted.isEmpty else { return "" }
        let out = scripted[min(index, scripted.count - 1)]
        index += 1
        return out
    }
}

/// Text-compat lane: yields the scripted reply as SSE text deltas, and conforms
/// to MessagesStreamingLLMClient so the append-only shape is eligible.
private final class ChokePointStreamingLLM:
    StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    private let scripted: [String]
    nonisolated(unsafe) private var index = 0
    init(scripted: [String]) { self.scripted = scripted }

    private func next() -> String {
        guard !scripted.isEmpty else { return "" }
        let out = scripted[min(index, scripted.count - 1)]
        index += 1
        return out
    }

    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        let reply = next()
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }

    func streamMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let reply = next()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.finish()
        }
    }
}

private final class ChokePointRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "choke-model", reasoningEffort: "high")]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
}

private func makeChokePointClient(
    root: URL,
    llm: any LLMClient,
    tools: any ToolDispatchClient,
    streamingLLM: (any StreamingLLMClient)? = nil,
    turnTraceBus: TurnTraceBus = .shared
) -> SwiftNativeChatOrchestrationClient {
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: ChokePointRouting(),
        trust: SwiftNativeTrustCenter(dataRoot: root),
        llm: llm,
        tools: tools,
        activeToolsStore: ActiveToolsStore(dataRoot: root),
        turnTraceBus: turnTraceBus
    )
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        streamingLLM: streamingLLM,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        turnTraceBus: turnTraceBus,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
}

// MARK: - trace collection on a per-test bus

private func observedBy(_ event: TurnTraceEvent) -> String? {
    guard case .object(let payload) = event.payload,
          case .string(let label)? = payload["observedBy"] else { return nil }
    return label
}

// MARK: - chat.dispatch.tracedGatedChokePoint

@Test
func chokePoint_structuredLane_tracesOneRowPerCallIncludingTheGateDenial() async throws {
    let root = try chokePointRoot("structured")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeGateSplitPolicy(root, allowed: allowedTool, blocked: blockedTool)

    let tools = ChokePointTools()
    let llm = ChokePointLLM(scripted: [
        openAIBatchJSON([(id: "c1", name: allowedTool), (id: "c2", name: blockedTool)]),
        "final answer",
    ])
    let client = makeChokePointClient(root: root, llm: llm, tools: tools)

    let response = try await client.chat(
        message: "use both tools", sessionId: "s-choke-structured",
        model: "choke-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(response.output == "final answer")

    let rows = toolDispatchRows(root)
    // EXACTLY one row per model tool call — including the DENIED one. That the
    // denial is present is what proves the tracer is OUTERMOST.
    #expect(rows.count == 2, "expected 2 tool.dispatch rows, got \(rows.count)")
    #expect(rows.map(rowTitle).sorted() == [allowedTool, blockedTool].sorted())
    let byTitle = Dictionary(uniqueKeysWithValues: rows.map { (rowTitle($0), $0) })
    #expect(rowStatus(byTitle[allowedTool] ?? [:]) == "ok")
    #expect(rowStatus(byTitle[blockedTool] ?? [:]) != "ok", "a gate denial was traced as a success")
    // The gate actually held: the blocked tool never reached the inner client.
    #expect(tools.dispatched == [allowedTool])
}

@Test
func chokePoint_structuredStreamingLane_tracesOneRowPerCallIncludingTheGateDenial() async throws {
    let root = try chokePointRoot("stream")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeGateSplitPolicy(root, allowed: allowedTool, blocked: blockedTool)

    let tools = ChokePointTools()
    let llm = ChokePointLLM(scripted: [
        openAIBatchJSON([(id: "c1", name: allowedTool), (id: "c2", name: blockedTool)]),
        "streamed answer",
    ])
    let client = makeChokePointClient(root: root, llm: llm, tools: tools)

    var final: String?
    for try await event in client.chatStream(
        message: "use both tools", sessionId: "s-choke-stream",
        model: "choke-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], persona: nil,
        surface: "chat", suppressUserAppend: false
    ) {
        if case .final(let result) = event { final = result.reply }
    }
    #expect(final == "streamed answer")

    let rows = toolDispatchRows(root)
    #expect(rows.count == 2, "expected 2 tool.dispatch rows, got \(rows.count)")
    #expect(rows.map(rowTitle).sorted() == [allowedTool, blockedTool].sorted())
    #expect(tools.dispatched == [allowedTool])
}

@Test
func chokePoint_textCompatLane_tracesOneRowPerCall() async throws {
    let root = try chokePointRoot("compat")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeGateSplitPolicy(root, allowed: allowedTool, blocked: blockedTool)
    try writeOAuthFixtureForCompat(root)

    let tools = ChokePointTools()
    // The text-compat lane speaks the in-band MARKER protocol, not native
    // tool_calls.
    let streaming = ChokePointStreamingLLM(scripted: [
        "<tool_use id=\"c1\" name=\"\(allowedTool)\">{}</tool_use>",
        "<tool_use id=\"c2\" name=\"\(blockedTool)\">{}</tool_use>",
        "compat answer",
    ])
    let llm = ChokePointLLM(scripted: ["structured-path-should-not-run"])
    let client = makeChokePointClient(
        root: root, llm: llm, tools: tools, streamingLLM: streaming
    )

    var final: String?
    for try await event in client.chatStream(
        message: "use both tools", sessionId: "s-choke-compat",
        model: "claude-opus-4-8", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], persona: nil,
        surface: "chat", suppressUserAppend: false
    ) {
        if case .final(let result) = event { final = result.reply }
    }
    #expect(final == "compat answer")

    let rows = toolDispatchRows(root)
    // Two model tool calls across two iterations ⇒ two rows, no more, no fewer.
    #expect(rows.count == 2, "expected 2 tool.dispatch rows, got \(rows.count)")
    #expect(rows.map(rowTitle).sorted() == [allowedTool, blockedTool].sorted())
    #expect(tools.dispatched == [allowedTool])
}

// MARK: - chat.telemetry.turnAccepted

@Test
func turnAccepted_structuredLaneEmitsExactlyOneCarryingItsOwnObservedByLabel() async throws {
    let root = try chokePointRoot("accepted-structured")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = ChokePointTools()
    let llm = ChokePointLLM(scripted: ["plain answer"])
    let events = try await withHermeticTraceBus(kinds: ["turn.accepted"]) { bus in
        let client = makeChokePointClient(
            root: root, llm: llm, tools: tools, turnTraceBus: bus
        )
        _ = try await client.chat(
            message: "hi", sessionId: "s-accept-structured",
            model: "choke-model", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], suppressUserAppend: false
        )
    }

    #expect(events.count == 1, "expected exactly 1 turn.accepted, got \(events.count)")
    let event = try #require(events.first)
    #expect(observedBy(event) == "structured_chat.entry")
    #expect(event.sessionId == "s-accept-structured")
    #expect(event.surface == "chat")
}

@Test
func turnAccepted_streamingLaneEmitsExactlyOneCarryingItsOwnObservedByLabel() async throws {
    let root = try chokePointRoot("accepted-stream")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = ChokePointTools()
    let llm = ChokePointLLM(scripted: ["plain answer"])
    let events = try await withHermeticTraceBus(kinds: ["turn.accepted"]) { bus in
        let client = makeChokePointClient(
            root: root, llm: llm, tools: tools, turnTraceBus: bus
        )
        for try await _ in client.chatStream(
            message: "hi", sessionId: "s-accept-stream",
            model: "choke-model", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], persona: nil,
            surface: "chat", suppressUserAppend: false
        ) {}
    }

    #expect(events.count == 1, "expected exactly 1 turn.accepted, got \(events.count)")
    let event = try #require(events.first)
    #expect(observedBy(event) == "structured_stream.entry")
    #expect(event.sessionId == "s-accept-stream")
}

@Test
func turnAccepted_textCompatLaneEmitsExactlyOneCarryingItsOwnObservedByLabel() async throws {
    let root = try chokePointRoot("accepted-compat")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeOAuthFixtureForCompat(root)
    let tools = ChokePointTools()
    let streaming = ChokePointStreamingLLM(scripted: ["compat answer"])
    let llm = ChokePointLLM(scripted: ["structured-path-should-not-run"])
    let events = try await withHermeticTraceBus(kinds: ["turn.accepted"]) { bus in
        let client = makeChokePointClient(
            root: root, llm: llm, tools: tools, streamingLLM: streaming, turnTraceBus: bus
        )
        for try await _ in client.chatStream(
            message: "hi", sessionId: "s-accept-compat",
            model: "claude-opus-4-8", reasoningEffort: "high",
            fileAccess: "workspace", attachments: [], persona: nil,
            surface: "chat", suppressUserAppend: false
        ) {}
    }

    #expect(events.count == 1, "expected exactly 1 turn.accepted, got \(events.count)")
    let event = try #require(events.first)
    #expect(observedBy(event) == "text_compat.entry")
    #expect(event.sessionId == "s-accept-compat")
}

@Test
func turnAccepted_isEmittedEvenWhenTheTurnFailsBeforeTheProviderCall() async throws {
    // Accept is NOT conditional on success: a turn that dies in context build
    // must still be COUNTED, otherwise a lane that starts failing reads as a
    // falling turn VOLUME rather than as errors.
    let root = try chokePointRoot("accepted-fail")
    defer { try? FileManager.default.removeItem(at: root) }

    struct PersonaBoom: Error {}
    final class ThrowingPersona: PersonaEngineProtocol, @unchecked Sendable {
        func listPersonaDocs() async throws -> [PersonaDoc] { throw PersonaBoom() }
        func getPersonaDoc(id: String) async throws -> PersonaDoc? { throw PersonaBoom() }
    }
    let tools = ChokePointTools()
    let llm = ChokePointLLM(scripted: ["never reached"])

    let threw = LockedBox<Bool>(false)
    let events = try await withHermeticTraceBus(kinds: ["turn.accepted"]) { bus in
        let engine = SwiftNativeTurnEngine(
            persona: ThrowingPersona(),
            memory: nil,
            router: ChokePointRouting(),
            trust: SwiftNativeTrustCenter(dataRoot: root),
            llm: llm,
            tools: tools,
            activeToolsStore: ActiveToolsStore(dataRoot: root),
            turnTraceBus: bus
        )
        let client = SwiftNativeChatOrchestrationClient(
            engine: engine, tools: tools, llm: llm,
            history: SessionHistoryReader(dataRoot: root), dataRoot: root,
            turnTraceBus: bus,
            trust: SwiftNativeTrustCenter(dataRoot: root)
        )
        do {
            _ = try await client.chat(
                message: "hi", sessionId: "s-accept-fail",
                model: "choke-model", reasoningEffort: "high",
                fileAccess: "workspace", attachments: [], suppressUserAppend: false
            )
        } catch {
            threw.set(true)
        }
    }

    #expect(threw.get(), "the scripted persona failure did not reach the caller")
    #expect(events.count == 1, "a failed turn was not counted")
    #expect(observedBy(try #require(events.first)) == "structured_chat.entry")
}

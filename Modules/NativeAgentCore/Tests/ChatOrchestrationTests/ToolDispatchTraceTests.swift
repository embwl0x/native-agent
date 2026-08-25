import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter

// MARK: - helpers

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tooltrace-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func tracesPath(_ root: URL) -> URL {
    root.appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
}

private func currentTurnTracesPath(_ root: URL, now: Date = Date()) -> URL {
    TurnTracePersistLane(dataRootOverride: root).path(for: now)
}

private func readTraceLines(_ root: URL) -> [String] {
    guard let data = try? Data(contentsOf: tracesPath(root)),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func parseRows(_ lines: [String]) -> [[String: JSONValue]] {
    lines.compactMap { line in
        guard case .object(let obj)? = try? JSONValue.parse(Data(line.utf8)) else { return nil }
        return obj
    }
}

private func firstTraceEvent(
    _ stream: AsyncStream<TurnTraceEvent>
) async -> TurnTraceEvent? {
    await withTaskGroup(of: TurnTraceEvent?.self) { group in
        group.addTask {
            for await event in stream { return event }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(500))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private final class ThrowingDispatch: ToolDispatchClient, @unchecked Sendable {
    struct Boom: Error {}
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        throw Boom()
    }
    func listAvailableTools() async throws -> [String] { ["broken"] }
}

private final class MockLLMForTrace: LLMClient, @unchecked Sendable {
    private let scriptedResponses: [String]
    private let lock = NSLock()
    private var idx = 0

    init(scriptedResponses: [String]) {
        self.scriptedResponses = scriptedResponses
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        next()
    }

    func complete(
        prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?
    ) async throws -> String {
        next()
    }

    func completeMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        next()
    }

    private func next() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !scriptedResponses.isEmpty else { return "" }
        let out = scriptedResponses[idx % scriptedResponses.count]
        idx += 1
        return out
    }
}

private final class SchemaToolDispatchForTrace: ToolDispatchClient, @unchecked Sendable {
    private let schemas: [LLMToolSchema]
    private let scripted: [String: JSONValue]

    init(schemas: [LLMToolSchema], scripted: [String: JSONValue]) {
        self.schemas = schemas
        self.scripted = scripted
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        scripted[tool] ?? .null
    }

    func listAvailableTools() async throws -> [String] { schemas.map(\.name).sorted() }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { schemas }
}

private final class StubRoutingForTrace: ProviderRoutingProtocol, @unchecked Sendable {
    let prefs: [String: SurfacePreference]
    init(prefs: [String: SurfacePreference]) { self.prefs = prefs }
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] { prefs }
}

private func makeEngine(
    root: URL,
    llm: any LLMClient,
    tools: any ToolDispatchClient
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: StubRoutingForTrace(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "client-model", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

// MARK: - Tests

@Test
func exact_tool_outcome_never_promotes_pending_or_ambiguous_envelopes() {
    #expect(ChatToolOutcome.exactResultClass(.object([
        "status": .string("pending_approval"),
        "ok": .bool(true),
    ])) == .unknown)
    #expect(ChatToolOutcome.exactResultClass(.object([
        "content": .string("successfully completed"),
    ])) == .unknown)
    #expect(ChatToolOutcome.exactResultClass(.object([
        "status": .string("completed"),
    ])) == .succeeded)
    #expect(ChatToolOutcome.exactResultClass(.object([
        "exit_code": .int(7),
    ])) == .failed)
    #expect(ChatToolOutcome.exactResultClass(.object([
        "status": .string("dry_run"),
        "dryRun": .bool(true),
    ])) == .unknown)
}

@Test
func canonical_motor_tools_suppress_owned_terminals_but_preserve_ownerless_failures() {
    let success: JSONValue = .object(["status": .string("completed")])
    let failure: JSONValue = .object(["status": .string("failed")])
    let ownedFailures: [(String, JSONValue)] = [
        ("workshop_submit", .object(["status": .string("failed"), "id": .string("workshop-1")])),
        ("browser.navigate", .object(["status": .string("failed"), "runId": .string("browser-1")])),
        ("mac_focus_app", .object(["status": .string("failed"), "operationId": .string("mac-1")])),
        ("slack_post_message", .object(["status": .string("failed"), "approvalId": .string("approval-1")])),
        ("agentmail_send", .object(["status": .string("failed"), "approval_id": .string("approval-2")])),
        ("external_send", .object(["status": .string("failed"), "approvalId": .string("approval-3")])),
    ]
    for (tool, ownedFailure) in ownedFailures {
        #expect(ChatToolOutcome.cognitiveResult(tool: tool, output: success) == .unknown)
        #expect(ChatToolOutcome.cognitiveResult(tool: tool, output: failure) == .failed)
        #expect(ChatToolOutcome.cognitiveResult(tool: tool, output: ownedFailure) == .unknown)
    }
    #expect(ChatToolOutcome.cognitiveResult(
        tool: "read_file", output: success
    ) == .succeeded)
    #expect(ChatToolOutcome.cognitiveResult(
        tool: "read_file", output: failure
    ) == .failed)
}

@Test
func deterministic_refusals_do_not_manufacture_tool_brittleness() {
    let refusalEnvelopes: [JSONValue] = [
        .object([
            "status": .string("failed"),
            "error_code": .string("path_not_allowed"),
        ]),
        .object([
            "status": .string("failed"),
            "error_code": .string("file_not_found"),
        ]),
        .object([
            "status": .string("pending_approval"),
            "requires_approval": .bool(true),
        ]),
        .object([
            "status": .string("denied"),
            "decision": .string("deny"),
            "reasons": .array([.string("policy")]),
        ]),
    ]
    for envelope in refusalEnvelopes {
        #expect(ChatToolOutcome.exactResultClass(envelope) != .succeeded)
        #expect(ChatToolOutcome.cognitiveResult(tool: "read_file", output: envelope) == .unknown)
    }

    let implementationFailure: JSONValue = .object([
        "status": .string("failed"),
        "error_code": .string("io_failure"),
    ])
    #expect(ChatToolOutcome.cognitiveResult(
        tool: "read_file",
        output: implementationFailure
    ) == .failed)
}

@Test
func causal_tool_boundary_is_shared_and_external_protocol_results_stay_neutral() throws {
    let aliases: [(String, JSONValue, ToolCausalBoundary.MotorDomain, String)] = [
        ("workshop_submit", .object(["id": .string("workshop-1")]), .workshopExecution, "workshop-1"),
        ("browser.navigate", .object(["runId": .string("browser-1")]), .browser, "browser-1"),
        ("mac_quit_app", .object(["operation_id": .string("mac-1")]), .macControl, "mac-1"),
        ("external_send", .object(["approvalId": .string("send-1")]), .externalSend, "send-1"),
    ]
    for (tool, output, domain, ownerID) in aliases {
        let reference = try #require(ToolCausalBoundary.motorReference(tool: tool, output: output))
        #expect(reference.domain == domain)
        #expect(reference.ownerActionID == ownerID)
        #expect(reference.actionIdentity == CausalTransitionEvidence.opaqueIdentity(ownerID))
    }
    #expect(ToolCausalBoundary.motorReference(
        tool: "browser.navigate",
        output: .object(["runId": .string("browser-dry"), "dryRun": .bool(true)])
    ) == nil)

    let remoteSuccess: JSONValue = .object([
        "content": .array([.object(["type": .string("text"), "text": .string("done")])]),
        "isError": .bool(false),
    ])
    let remoteFailure: JSONValue = .object([
        "content": .array([.object(["type": .string("text"), "text": .string("partial failure")])]),
        "isError": .bool(true),
    ])
    #expect(ChatToolOutcome.cognitiveResult(
        tool: "mcp__external__send", output: remoteSuccess
    ) == .unknown)
    #expect(ChatToolOutcome.cognitiveResult(
        tool: "mcp__external__send", output: remoteFailure
    ) == .unknown)
    #expect(!ChatToolOutcome.outputLooksSuccessful(remoteFailure))
    #expect(ChatToolOutcome.exactResultClass(remoteFailure) == .failed)
}

@Test
func tracer_records_one_row_with_argKeys_not_values() async throws {
    let root = try makeTempRoot("ok-row")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = MockToolDispatchClient(scripted: [
        "time_now": .object(["status": .string("ok"), "iso": .string("2026-06-10T12:00:00Z")]),
    ])
    let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)

    let result = try await tracer.dispatch(
        tool: "time_now",
        input: ["city": .string("tokyo-secret-value"), "tz": .string("Asia/Tokyo")],
        surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected envelope object")
        return
    }
    #expect(obj["status"] == .string("ok"))

    let lines = readTraceLines(root)
    #expect(lines.count == 1)
    // PRIVACY: key names only — no argument values, no result body.
    #expect(!lines[0].contains("tokyo-secret-value"))
    #expect(!lines[0].contains("Asia/Tokyo"))
    #expect(!lines[0].contains("2026-06-10T12:00:00Z"))
    let rows = parseRows(lines)
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row["kind"] == .string("tool.dispatch"))
    #expect(row["title"] == .string("time_now"))
    #expect(row["status"] == .string("ok"))
    guard case .object(let payload)? = row["payload"] else {
        Issue.record("expected payload object")
        return
    }
    #expect(payload["argKeys"] == .array([.string("city"), .string("tz")]))
    #expect(payload["surface"] == .string("chat"))
    guard case .object(let receipt)? = payload["receipt"] else {
        Issue.record("expected compact action receipt")
        return
    }
    #expect(receipt["action"] == .string("tool_dispatch"))
    #expect(receipt["surface"] == .string("chat"))
    #expect(receipt["target"] == .string("time_now"))
    #expect(receipt["decision"] == .string("attempted"))
    #expect(receipt["outcome"] == .string("completed"))
    #expect(receipt["permanence"] == .string("bounded_trace"))
    #expect(receipt["risk"] == .string("low"))
    #expect(receipt["tracePath"] == .string("data/traces/events.jsonl"))
    #expect(receipt["errorClass"] == nil)
    if case .int(let ms)? = payload["durationMs"] {
        #expect(ms >= 0)
    } else {
        Issue.record("expected int durationMs")
    }
    if case .string(let createdAt)? = row["createdAt"] {
        #expect(createdAt.contains("T"))
    } else {
        Issue.record("expected ISO8601 createdAt")
    }
    // Flock sibling proves the append ran under the cross-process lock path.
    #expect(FileManager.default.fileExists(atPath: tracesPath(root).path + ".lock"))
}

@Test
func tracer_thrown_dispatch_records_failed_row_and_rethrows() async throws {
    let root = try makeTempRoot("throw-row")
    defer { try? FileManager.default.removeItem(at: root) }
    let tracer = ChatToolDispatchTracer(inner: ThrowingDispatch(), dataRoot: root)

    await #expect(throws: ThrowingDispatch.Boom.self) {
        _ = try await tracer.dispatch(
            tool: "broken", input: ["q": .string("x")], surface: "chat"
        )
    }

    let rows = parseRows(readTraceLines(root))
    #expect(rows.count == 1)
    #expect(rows[0]["title"] == .string("broken"))
    #expect(rows[0]["status"] == .string("failed"))
}

@Test
func tracer_failure_shaped_envelope_records_failed_row() async throws {
    let root = try makeTempRoot("envelope-row")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = MockToolDispatchClient(scripted: [
        "shell": .object(["status": .string("failed"), "reason": .string("not_loaded")]),
    ])
    let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)

    _ = try await tracer.dispatch(tool: "shell", input: [:], surface: "chat")

    let rows = parseRows(readTraceLines(root))
    #expect(rows.count == 1)
    #expect(rows[0]["status"] == .string("failed"))
    guard case .object(let payload)? = rows[0]["payload"],
          case .object(let receipt)? = payload["receipt"] else {
        Issue.record("expected failed compact action receipt")
        return
    }
    #expect(receipt["outcome"] == .string("failed"))
    #expect(receipt["errorClass"] == .string("result_failed"))
}

@Test
func tracer_cap_trims_to_5000_lines_under_flock() async throws {
    let root = try makeTempRoot("cap")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = tracesPath(root)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // Seed 5100 rows; the next traced append (5101 total) must tail-trim to
    // exactly 5000, dropping the oldest 101.
    let seeded = (1...5100).map { #"{"i":\#($0)}"# }.joined(separator: "\n") + "\n"
    try seeded.write(to: path, atomically: true, encoding: .utf8)

    let inner = MockToolDispatchClient(scripted: ["time_now": .object(["status": .string("ok")])])
    let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root, trimCheckInterval: 1)
    _ = try await tracer.dispatch(tool: "time_now", input: [:], surface: "chat")

    let lines = readTraceLines(root)
    #expect(lines.count == ChatToolDispatchTracer.maxTraceLines)
    #expect(lines.first == #"{"i":102}"#)
    let rows = parseRows([lines.last ?? ""])
    #expect(rows.first?["kind"] == .string("tool.dispatch"))
    #expect(rows.first?["title"] == .string("time_now"))
}

@Test
func chat_turn_through_client_appends_exactly_one_trace_row() async throws {
    let root = try makeTempRoot("client-wire")
    defer { try? FileManager.default.removeItem(at: root) }
    let schema = LLMToolSchema(
        name: "tool_catalog",
        description: "List available tools",
        parametersJSON: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
    )
    let toolCall = #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"tool_catalog","arguments":"{\"q\":\"sekrit-arg-value\"}"}}]}"#
    let llm = MockLLMForTrace(scriptedResponses: [toolCall, "final answer after tool"])
    let tools = SchemaToolDispatchForTrace(
        schemas: [schema],
        scripted: ["tool_catalog": .object(["ok": .bool(true), "count": .int(1)])]
    )
    let engine = makeEngine(root: root, llm: llm, tools: tools)
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine, tools: tools, llm: llm,
        history: SessionHistoryReader(dataRoot: root), dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )

    let resp = try await client.chat(
        message: "what tools do you have", sessionId: "s-trace-wire",
        model: "client-model", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    )
    #expect(resp.output == "final answer after tool")

    let lines = readTraceLines(root)
    let rows = parseRows(lines).filter { $0["kind"] == .string("tool.dispatch") }
    #expect(rows.count == 1)
    #expect(rows.first?["title"] == .string("tool_catalog"))
    #expect(rows.first?["status"] == .string("ok"))
    // Argument values must not reach the unencrypted trace file.
    #expect(!lines.joined().contains("sekrit-arg-value"))
}

@Test
func recent_trace_summary_surfaces_read_failure_as_failed() async throws {
    let root = try makeTempRoot("summary-readfail")
    defer { try? FileManager.default.removeItem(at: root) }
    // The current daily turn-trace file as a DIRECTORY: unreadable as JSONL → must surface
    // status failed, not fabricate "ok, 0 traces".
    try FileManager.default.createDirectory(
        at: currentTurnTracesPath(root), withIntermediateDirectories: true
    )
    let dispatcher = SwiftToolDispatcher(dataRoot: root)

    let result = try await dispatcher.dispatch(
        tool: "recent_trace_summary", input: [:], surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected envelope object")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(obj["count"] == .int(0))
    if case .string(let err)? = obj["error"] {
        #expect(!err.isEmpty)
    } else {
        Issue.record("expected error string on failed read")
    }
}

@Test
func recent_trace_summary_missing_file_stays_honest_empty_ok() async throws {
    let root = try makeTempRoot("summary-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root)

    let result = try await dispatcher.dispatch(
        tool: "recent_trace_summary", input: [:], surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected envelope object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(obj["count"] == .int(0))
    #expect(obj["traces"] == .array([]))
}

@Test
func recent_trace_summary_reads_current_turn_trace_rows_back() async throws {
    let root = try makeTempRoot("summary-roundtrip")
    defer { try? FileManager.default.removeItem(at: root) }
    await TurnTracePersistLane(dataRootOverride: root).append(TurnTraceEvent(
        turnId: "turn-summary",
        kind: "tool.dispatch",
        sessionId: "session-summary",
        surface: "chat",
        payload: .object([
            "name": .string("time_now"),
            "status": .string("ok"),
        ])
    ))

    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let result = try await dispatcher.dispatch(
        tool: "recent_trace_summary", input: [:], surface: "chat"
    )
    guard case .object(let obj) = result else {
        Issue.record("expected envelope object")
        return
    }
    #expect(obj["status"] == .string("ok"))
    #expect(obj["count"] == .int(1))
    guard case .array(let traces)? = obj["traces"],
          case .object(let first)? = traces.first else {
        Issue.record("expected one trace summary row")
        return
    }
    #expect(first["kind"] == .string("tool.dispatch"))
    #expect(first["title"] == .string("time_now"))
    #expect(first["turn_id"] == .string("turn-summary"))
    #expect(first["session_id"] == .string("session-summary"))
    #expect(obj["source"] == .string(
        "data/turn_traces/\(currentTurnTracesPath(root).lastPathComponent)"
    ))
}

@Test
func recent_trace_summary_ignores_empty_optional_filters() async throws {
    let root = try makeTempRoot("summary-empty-filters")
    defer { try? FileManager.default.removeItem(at: root) }
    await TurnTracePersistLane(dataRootOverride: root).append(TurnTraceEvent(
        turnId: "turn-plan-1",
        kind: "turn.plan",
        surface: "chat",
        payload: .object(["status": .string("ok")])
    ))

    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let result = try await dispatcher.dispatch(
        tool: "recent_trace_summary",
        input: ["kind": .string("turn.plan"), "status": .string("")],
        surface: "chat"
    )
    guard case .object(let object) = result else {
        Issue.record("expected summary object")
        return
    }
    #expect(object["count"] == .int(1))
    guard case .array(let traces)? = object["traces"],
          case .object(let trace)? = traces.first else {
        Issue.record("expected one filtered trace")
        return
    }
    #expect(trace["kind"] == .string("turn.plan"))
}

@Test
func recent_trace_summary_reads_current_ledger_not_legacy_aggregate() async throws {
    let root = try makeTempRoot("summary-current-ledger")
    defer { try? FileManager.default.removeItem(at: root) }
    try await SwiftNativePersistenceCore().appendJSONL(.object([
        "kind": .string("legacy.only"),
        "status": .string("ok"),
    ]), to: tracesPath(root))
    await TurnTracePersistLane(dataRootOverride: root).append(TurnTraceEvent(
        turnId: "turn-current",
        kind: "llm.call",
        sessionId: "session-current",
        surface: "chat"
    ))

    let result = try await SwiftToolDispatcher(dataRoot: root).dispatch(
        tool: "recent_trace_summary", input: [:], surface: "chat"
    )
    guard case .object(let object) = result,
          case .array(let traces)? = object["traces"] else {
        Issue.record("expected current trace summaries")
        return
    }
    #expect(object["count"] == .int(1))
    #expect(traces.contains { value in
        guard case .object(let trace) = value else { return false }
        return trace["kind"] == .string("llm.call")
    })
    #expect(!traces.contains { value in
        guard case .object(let trace) = value else { return false }
        return trace["kind"] == .string("legacy.only")
    })
}

@Test(arguments: ["session_id", "sessionId"])
func recent_trace_summary_session_filter_includes_turn_siblings(alias: String) async throws {
    let root = try makeTempRoot("summary-session-\(alias)")
    defer { try? FileManager.default.removeItem(at: root) }
    let lane = TurnTracePersistLane(dataRootOverride: root)
    await lane.append(TurnTraceEvent(
        turnId: "turn-target", kind: "llm.call",
        sessionId: "session-target", surface: "chat"
    ))
    await lane.append(TurnTraceEvent(
        turnId: "turn-target", kind: "tool.dispatch", surface: "chat",
        payload: .object(["name": .string("time_now"), "status": .string("ok")])
    ))
    await lane.append(TurnTraceEvent(
        turnId: "turn-other", kind: "llm.call",
        sessionId: "session-other", surface: "chat"
    ))

    let result = try await SwiftToolDispatcher(dataRoot: root).dispatch(
        tool: "recent_trace_summary",
        input: [alias: .string("session-target")],
        surface: "chat"
    )
    guard case .object(let object) = result,
          case .array(let traces)? = object["traces"] else {
        Issue.record("expected session-filtered traces")
        return
    }
    #expect(object["count"] == .int(2))
    #expect(object["session_id"] == .string("session-target"))
    #expect(traces.allSatisfy { value in
        guard case .object(let trace) = value else { return false }
        return trace["turn_id"] == .string("turn-target")
    })
}

@Test
func tracer_turn_event_uses_injected_session_id() async throws {
    let root = try makeTempRoot("tracer-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let bus = TurnTraceBus(
        persistLane: TurnTracePersistLane(dataRootOverride: root)
    )
    let subscription = await bus.subscribe()
    let tracer = ChatToolDispatchTracer(
        inner: MockToolDispatchClient(scripted: ["time_now": .object(["status": .string("ok")])]),
        dataRoot: root
    )

    _ = try await TurnTraceContext.$turnId.withValue("turn-session") {
        try await TurnTraceContext.$bus.withValue(bus) {
            try await tracer.dispatch(
                tool: "time_now",
                input: ["__session_id": .string("session-injected")],
                surface: "chat"
            )
        }
    }

    let event = await firstTraceEvent(subscription.stream)
    #expect(event?.kind == "tool.dispatch")
    #expect(event?.sessionId == "session-injected")
}

// MARK: - null-error misclassification (2026-08-21) + bounded errorDetail

/// The REAL envelope shape MacControl returned for every one of the 12
/// "failed" `mac_ax_find` dispatches on 2026-08-18 (turn_traces bus preview):
/// `ok:true`, `error:null`, `operationState:completed`. MacControl's own op
/// store had all 12 `completed`; only the trace/receipt/`is_error` bit said
/// failed, because `obj["error"] != nil` is true for a present JSON null.
private let macControlSuccessEnvelope: JSONValue = .object([
    "action": .string("ax_find"),
    "durationMs": .int(67),
    "error": .null,
    "httpStatus": .null,
    "ok": .bool(true),
    "operationId": .string("75D436E4-F471-4BC7-A70A-E3BA0D1B0E0E"),
    "operationState": .string("completed"),
    "verification": .string("satisfied"),
    "viaSwift": .bool(true),
    "output": .object([
        "trusted": .bool(true), "count": .int(0), "searched": .int(14), "matches": .array([]),
    ]),
])

private struct ThrowingDispatchClient: ToolDispatchClient {
    let message: String
    struct Failure: Error, CustomStringConvertible { let description: String }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        throw Failure(description: message)
    }
    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

@Test
func present_null_error_key_is_success_not_failure() {
    // The pin: a present-but-null `error` is NOT an error.
    #expect(ChatToolOutcome.outputLooksSuccessful(macControlSuccessEnvelope))
    #expect(ChatToolOutcome.exactResultClass(macControlSuccessEnvelope) == .succeeded)
    #expect(ChatToolOutcome.failureDetail(macControlSuccessEnvelope) == nil)
    // Mutation: the same envelope with a REAL error string still fails, and
    // the detail names it — so the fix did not make the check blind.
    var failed = macControlSuccessEnvelope
    if case .object(var obj) = failed {
        obj["ok"] = .bool(false)
        obj["error"] = .string("no_frontmost_window")
        failed = .object(obj)
    }
    #expect(!ChatToolOutcome.outputLooksSuccessful(failed))
    #expect(ChatToolOutcome.failureDetail(failed) == "no_frontmost_window")
    // Bare `"error": null` with nothing else is still success (no status).
    #expect(ChatToolOutcome.outputLooksSuccessful(.object(["error": .null])))
    // status:"failed" with a null error stays failed (status wins).
    #expect(!ChatToolOutcome.outputLooksSuccessful(.object(["status": .string("failed"), "error": .null])))
    // `ok:false` / `success:false` beside a null error stay failed (review
    // 2026-08-21: null-stops-counting must not flip boolean failures to ok).
    #expect(!ChatToolOutcome.outputLooksSuccessful(.object(["ok": .bool(false), "error": .null])))
    #expect(!ChatToolOutcome.outputLooksSuccessful(.object(["success": .bool(false), "error": .null])))
    #expect(ChatToolOutcome.failureDetail(.object(["ok": .bool(false), "error": .null])) == nil)
}

@Test
func tracer_writes_ok_row_for_mac_control_success_envelope() async throws {
    let root = try makeTempRoot("macok")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = MockToolDispatchClient(scripted: ["mac_ax_find": macControlSuccessEnvelope])
    let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)
    _ = try await tracer.dispatch(tool: "mac_ax_find", input: ["title": .string("x")], surface: "telegram")
    let rows = parseRows(readTraceLines(root))
    #expect(rows.count == 1)
    #expect(rows.first?["status"] == .string("ok"))
    guard case .object(let payload)? = rows.first?["payload"],
          case .object(let receipt)? = payload["receipt"] else {
        Issue.record("missing payload/receipt"); return
    }
    #expect(receipt["errorClass"] == nil)
    #expect(receipt["outcome"] == .string("completed"))
    // An ok row carries NO errorDetail key at all — not even null.
    #expect(receipt["errorDetail"] == nil)
}

@Test
func failure_envelope_row_carries_bounded_redacted_errorDetail() async throws {
    let root = try makeTempRoot("detail")
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"
    let longTail = String(repeating: "x", count: 400)
    let inner = MockToolDispatchClient(scripted: [
        "mac_ax_find": .object([
            "ok": .bool(false),
            "status": .string("failed"),
            "error": .string("accessibility_not_trusted token=\(secret) \(longTail)"),
            "reason": .string("accessibility_not_trusted token=\(secret) \(longTail)"),
            "output": .object(["body": .string("RESULT BODY MUST NOT LEAK")]),
        ]),
    ])
    let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)
    _ = try await tracer.dispatch(tool: "mac_ax_find", input: [:], surface: "telegram")
    let lines = readTraceLines(root)
    #expect(lines.count == 1)
    let rows = parseRows(lines)
    guard case .object(let payload)? = rows.first?["payload"],
          case .object(let receipt)? = payload["receipt"],
          case .string(let detail)? = receipt["errorDetail"] else {
        Issue.record("failed row must carry receipt.errorDetail"); return
    }
    #expect(rows.first?["status"] == .string("failed"))
    #expect(receipt["errorClass"] == .string("result_failed"))
    #expect(detail.hasPrefix("status=failed | accessibility_not_trusted"))
    // Bounded: limit + the ellipsis.
    #expect(detail.count <= ChatToolOutcome.failureDetailLimit + 1)
    // Redacted BEFORE the cap, so the secret is gone from the whole row.
    #expect(!lines[0].contains(secret))
    #expect(detail.contains("[REDACTED_"))
    // Result body never rides along.
    #expect(!lines[0].contains("RESULT BODY MUST NOT LEAK"))
    // `error` and `reason` repeat one message — kept once.
    #expect(detail.components(separatedBy: "accessibility_not_trusted").count == 2)
}

@Test
func thrown_dispatch_error_row_carries_errorDetail() async throws {
    let root = try makeTempRoot("thrown")
    defer { try? FileManager.default.removeItem(at: root) }
    let tracer = ChatToolDispatchTracer(
        inner: ThrowingDispatchClient(message: "Trust Center Full Mac Accessibility category is not active for mac_ax_find"),
        dataRoot: root
    )
    await #expect(throws: (any Error).self) {
        _ = try await tracer.dispatch(tool: "mac_ax_find", input: [:], surface: "telegram")
    }
    let rows = parseRows(readTraceLines(root))
    guard case .object(let payload)? = rows.first?["payload"],
          case .object(let receipt)? = payload["receipt"] else {
        Issue.record("missing row"); return
    }
    #expect(rows.first?["status"] == .string("failed"))
    #expect(receipt["errorClass"] == .string("dispatch_threw"))
    #expect(receipt["errorDetail"] == .string("Trust Center Full Mac Accessibility category is not active for mac_ax_find"))
}

@Test
func receiptFixedFields_successAndFailureUseCanonicalRiskAndExplicitProvenance() async throws {
    let successRoot = try makeTempRoot("receipt-fixed-success")
    defer { try? FileManager.default.removeItem(at: successRoot) }
    let successTracer = ChatToolDispatchTracer(
        inner: MockToolDispatchClient(scripted: ["time_now": .object(["status": .string("ok")])]),
        dataRoot: successRoot
    )
    _ = try await successTracer.dispatch(tool: "time_now", input: [:], surface: "chat")
    guard case .object(let successPayload)? = parseRows(readTraceLines(successRoot)).first?["payload"],
          case .object(let successReceipt)? = successPayload["receipt"] else {
        Issue.record("missing successful receipt"); return
    }
    #expect(successReceipt["permanence"] == .string("bounded_trace"))
    #expect(successReceipt["risk"] == .string("low"))
    #expect(successReceipt["errorClass"] == nil)
    #expect(successReceipt["errorDetail"] == nil)
    if case .array(let proof)? = successReceipt["proof"] {
        #expect(proof.contains(.string("permanence_source:events_jsonl_tail_retention")))
        #expect(proof.contains(.string("risk_source:security_center.canonical_tool_risk")))
    } else {
        Issue.record("successful receipt must carry provenance proof")
    }

    let failureRoot = try makeTempRoot("receipt-fixed-failure")
    defer { try? FileManager.default.removeItem(at: failureRoot) }
    let failureTracer = ChatToolDispatchTracer(
        inner: MockToolDispatchClient(scripted: [
            "shell": .object(["status": .string("failed"), "error_code": .string("command_failed")]),
        ]),
        dataRoot: failureRoot
    )
    _ = try await failureTracer.dispatch(tool: "shell", input: [:], surface: "chat")
    guard case .object(let failurePayload)? = parseRows(readTraceLines(failureRoot)).first?["payload"],
          case .object(let failureReceipt)? = failurePayload["receipt"] else {
        Issue.record("missing failed receipt"); return
    }
    #expect(failureReceipt["permanence"] == .string("bounded_trace"))
    #expect(failureReceipt["risk"] == .string("critical"))
    #expect(failureReceipt["errorClass"] == .string("result_failed"))
    #expect(failureReceipt["errorDetail"] == .string("code=command_failed | status=failed"))
}

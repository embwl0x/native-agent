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

// MARK: - helpers

func makeChatOrchestrationTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chatclient-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeTrustPolicy(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bytes = try policy.serializedData(pretty: false)
    try bytes.write(to: dir.appendingPathComponent("policy.json"))
}

final class StubRoutingForClient: ProviderRoutingProtocol, @unchecked Sendable {
    let prefs: [String: SurfacePreference]
    let active: [String: String]
    init(
        prefs: [String: SurfacePreference],
        active: [String: String] = [:]
    ) {
        self.prefs = prefs
        self.active = active
    }
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
    func activeProvidersForSurfaces() async -> [String: String] { active }
}

actor CognitiveEventCapture: CognitiveEventObserving {
    private var events: [CognitiveEvent] = []

    func observe(_ event: CognitiveEvent) async {
        events.append(event)
    }

    func all() -> [CognitiveEvent] {
        events
    }
}

final class ModelCapturingLLM: LLMClient, @unchecked Sendable {
    private let reply: String
    private let lock = NSLock()
    private var _models: [String?] = []
    private var _providerRoutes: [String?] = []

    var models: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _models
    }

    var providerRoutes: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _providerRoutes
    }

    init(reply: String = "captured") {
        self.reply = reply
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        record(model)
        return reply
    }

    func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        record(model)
        return reply
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        record(model)
        return reply
    }

    private func record(_ model: String?) {
        lock.lock()
        defer { lock.unlock() }
        _models.append(model)
        _providerRoutes.append(LLMCallContext.providerId)
    }
}

final class ToolSchemaCapturingLLM: LLMClient, @unchecked Sendable {
    private let scriptedResponses: [String]
    private let lock = NSLock()
    private var _callCount = 0
    private var _toolNamesByCall: [[String]] = []

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    var toolNamesByCall: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _toolNamesByCall
    }

    init(scriptedResponses: [String]) {
        self.scriptedResponses = scriptedResponses
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        nextResponse(tools: nil)
    }

    func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        nextResponse(tools: tools)
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        nextResponse(tools: tools)
    }

    private func nextResponse(tools: [LLMToolSchema]?) -> String {
        lock.lock()
        let idx = _callCount
        _callCount += 1
        _toolNamesByCall.append((tools ?? []).map(\.name))
        lock.unlock()
        guard !scriptedResponses.isEmpty else { return "" }
        return scriptedResponses[idx % scriptedResponses.count]
    }
}

final class StructuredStreamingScriptLLM: LLMClient, @unchecked Sendable {
    struct UnexpectedSyncCall: Error {}

    private let scriptedEvents: [[LLMMessageStreamEvent]]
    private let lock = NSLock()
    private var _streamCallCount = 0
    private var _syncCallCount = 0
    private var _toolNamesByCall: [[String]] = []

    var streamCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _streamCallCount
    }

    var syncCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _syncCallCount
    }

    var toolNamesByCall: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _toolNamesByCall
    }

    init(scriptedEvents: [[LLMMessageStreamEvent]]) {
        self.scriptedEvents = scriptedEvents
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        recordSync()
        throw UnexpectedSyncCall()
    }

    func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        recordSync()
        throw UnexpectedSyncCall()
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        recordSync()
        throw UnexpectedSyncCall()
    }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let idx: Int = {
            lock.lock()
            defer { lock.unlock() }
            let idx = _streamCallCount
            _streamCallCount += 1
            _toolNamesByCall.append((tools ?? []).map(\.name))
            return idx
        }()
        let events = scriptedEvents.isEmpty ? [] : scriptedEvents[idx % scriptedEvents.count]
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func recordSync() {
        lock.lock()
        _syncCallCount += 1
        lock.unlock()
    }
}

final class ScriptedTextStreamingLLM: StreamingLLMClient, @unchecked Sendable {
    struct RouteCall: Sendable {
        let model: String?
        let admittedModel: String?
        let provider: String?
        let effort: String?
        let tier: String?
        let surface: String
    }
    private let chunksByCall: [[String]]
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastModel: String?
    private var _systems: [String?] = []
    private var _prompts: [String] = []
    private var _routeCalls: [RouteCall] = []

    init(chunksByCall: [[String]]) {
        self.chunksByCall = chunksByCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    var lastModel: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastModel
    }

    var systems: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return _systems
    }

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _prompts
    }

    var routeCalls: [RouteCall] {
        lock.lock()
        defer { lock.unlock() }
        return _routeCalls
    }

    func stream(
        prompt: String,
        system: String?,
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        stream(prompt: prompt, system: system, model: model, surface: "chat")
    }

    func stream(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) -> AsyncThrowingStream<String, Error> {
        let chunks: [String] = {
            lock.lock()
            defer { lock.unlock() }
            let idx = _callCount
            _callCount += 1
            _lastModel = model
            _systems.append(system)
            _prompts.append(prompt)
            _routeCalls.append(RouteCall(
                model: model,
                admittedModel: LLMCallContext.admittedModel,
                provider: LLMCallContext.providerId,
                effort: LLMCallContext.reasoningEffort,
                tier: LLMCallContext.serviceTier,
                surface: surface
            ))
            return chunksByCall.isEmpty ? [] : chunksByCall[min(idx, chunksByCall.count - 1)]
        }()
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

final class SchemaBackedToolDispatch: ToolDispatchClient, @unchecked Sendable {
    private let schemas: [LLMToolSchema]
    private let scripted: [String: JSONValue]
    private let beforeSchemaList: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var _dispatches: [MockToolDispatchClient.Dispatch] = []

    init(
        schemas: [LLMToolSchema],
        scripted: [String: JSONValue],
        beforeSchemaList: (@Sendable () async -> Void)? = nil
    ) {
        self.schemas = schemas
        self.scripted = scripted
        self.beforeSchemaList = beforeSchemaList
    }

    var dispatches: [MockToolDispatchClient.Dispatch] {
        lock.lock()
        defer { lock.unlock() }
        return _dispatches
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        record(.init(tool: tool, input: input, surface: surface))
        return scripted[tool] ?? .null
    }

    private func record(_ dispatch: MockToolDispatchClient.Dispatch) {
        lock.lock()
        _dispatches.append(dispatch)
        lock.unlock()
    }

    func listAvailableTools() async throws -> [String] {
        schemas.map(\.name).sorted()
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        await beforeSchemaList?()
        return schemas
    }
}

func makeEngine(
    root: URL,
    llm: any LLMClient,
    tools: any ToolDispatchClient,
    turnTraceBus: TurnTraceBus = .shared,
    router: (any ProviderRoutingProtocol)? = nil
) -> SwiftNativeTurnEngine {
    let persona = hermeticPersona(root: root)
    return SwiftNativeTurnEngine(
        persona: persona,
        memory: nil,
        router: router ?? StubRoutingForClient(prefs: [
            "chat": SurfacePreference(surface: "chat", model: "client-model", reasoningEffort: "high"),
        ]),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools,
        providerRecoverySleep: { _ in try Task.checkCancellation() },
        turnTraceBus: turnTraceBus
    )
}

func readJSONL(_ root: URL, sessionId: String) -> [[String: Any]] {
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    var out: [[String: Any]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let d = String(line).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { continue }
        out.append(parsed)
    }
    return out
}

func writeMessagesJSONL(_ root: URL, sessionId: String, lines: [String]) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
                  .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(sessionId).jsonl")
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: path, atomically: true, encoding: .utf8)
}

func writeChatSessionsJSON(_ root: URL, sessions: [[String: String]]) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rows = sessions.map { session -> JSONValue in
        .object(session.mapValues { .string($0) })
    }
    let data = try JSONValue.array(rows).serializedData(pretty: false)
    try data.write(to: dir.appendingPathComponent("sessions.json"))
}

final class MessageCapturingLLM: LLMClient, @unchecked Sendable {
    private let reply: String
    // Single-shot capture in a non-concurrent test turn; no lock needed.
    nonisolated(unsafe) private(set) var capturedMessages: [LLMMessage] = []
    nonisolated(unsafe) private(set) var capturedSystems: [String?] = []
    nonisolated(unsafe) private(set) var capturedModels: [String?] = []
    nonisolated(unsafe) private(set) var capturedToolNames: [[String]] = []
    init(reply: String = "captured") { self.reply = reply }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        capture(system: system, model: model, tools: nil)
        return reply
    }
    func complete(prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?) async throws -> String {
        capture(system: system, model: model, tools: tools)
        return reply
    }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        capturedMessages = messages
        capture(system: system, model: model, tools: tools)
        return reply
    }
    private func capture(system: String?, model: String?, tools: [LLMToolSchema]?) {
        capturedSystems.append(system)
        capturedModels.append(model)
        capturedToolNames.append((tools ?? []).map(\.name))
    }
}

func makeClientForNoticeTests(
    root: URL,
    turnTraceBus: TurnTraceBus = .shared
) -> SwiftNativeChatOrchestrationClient {
    let llm = ModelCapturingLLM()
    let tools = MockToolDispatchClient()
    return SwiftNativeChatOrchestrationClient(
        engine: makeEngine(root: root, llm: llm, tools: tools, turnTraceBus: turnTraceBus),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        turnTraceBus: turnTraceBus,
        trust: hermeticTrust(),
        clock: { Date(timeIntervalSince1970: 1_234) }
    )
}
